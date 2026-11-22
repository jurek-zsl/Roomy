//! The cleaner. It acts only on things the scanner found, checks each one
//! again right before touching it, and logs everything it does.
//!
//! How each item is cleaned:
//! - `--trash`, or anything in "Review first": moved to the Trash, so you can
//!   get it back. It frees its space once you empty the Trash.
//! - Rules whose command is a plain `rm`: deleted directly (never through a shell).
//! - Other rules: the tool's own command runs (`brew cleanup`, `cargo clean`),
//!   because the tool knows its cache best. If the tool isn't installed, the
//!   folder is deleted directly instead.

use crate::rules::Rule;
use crate::verify::{self, Env, Status};
use crate::{Finding, Section};
use serde::Serialize;
use std::ffi::CString;
use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case", tag = "kind", content = "command")]
pub enum Method {
    /// Remove it directly.
    Delete,
    /// Move it to the Trash.
    Trash,
    /// Run the tool's own clean command.
    Command(String),
}

impl Method {
    pub fn label(&self) -> String {
        match self {
            Method::Delete => "delete".into(),
            Method::Trash => "move to Trash".into(),
            Method::Command(c) => format!("run `{c}`"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case", tag = "result")]
pub enum Outcome {
    Cleaned { method: Method, note: Option<String> },
    Skipped { reason: String },
    Failed { method: Method, error: String },
}

pub struct CleanOptions {
    pub home: PathBuf,
    pub trash_dir: PathBuf,
    pub force_trash: bool,
    pub timeout: Duration,
    /// The per-user temp area, the only place outside home it may clean.
    pub tmp_root: Option<PathBuf>,
}

/// Pick how to clean one finding.
pub fn choose_method(f: &Finding, template: Option<&str>, force_trash: bool) -> Method {
    if force_trash || f.section() == Section::Review {
        return Method::Trash;
    }
    match (template, &f.clean) {
        (Some(t), _) if is_plain_remove(t) => Method::Delete,
        (Some(_), Some(cmd)) => Method::Command(cmd.clone()),
        _ => Method::Trash,
    }
}

fn is_plain_remove(t: &str) -> bool {
    matches!(t.trim(), "rm -rf {path}" | "rm -r {path}" | "rm -f {path}" | "rm {path}")
}

/// Main folders the cleaner never removes, relative to home, even if a rule
/// matched one by mistake.
const PROTECTED: &[&str] = &[
    "Applications",
    "Desktop",
    "Documents",
    "Downloads",
    "Library",
    "Library/Application Support",
    "Library/Caches",
    "Library/Containers",
    "Library/Group Containers",
    "Library/Logs",
    "Library/Mobile Documents",
    "Movies",
    "Music",
    "Pictures",
    "Public",
    ".Trash",
    ".cache",
    ".config",
    ".gnupg",
    ".local",
    ".local/bin",
    ".local/share",
    ".ssh",
];

/// Last checks on the path itself. Rules decide what is junk; this makes sure
/// a bad rule or a moved folder can't make the cleaner hit the wrong thing.
pub fn guard(path: &Path, home: &Path, tmp_root: Option<&Path>) -> Result<(), String> {
    if !path.is_absolute() || path.components().any(|c| matches!(c, Component::ParentDir)) {
        return Err("isn't a plain full path".into());
    }
    let root = if let Ok(rest) = path.strip_prefix(home) {
        if rest.as_os_str().is_empty() {
            return Err("is your home folder".into());
        }
        if PROTECTED.iter().any(|p| rest == Path::new(p)) {
            return Err("is one of your Mac's main folders".into());
        }
        home
    } else if let Some((t, rest)) = tmp_root.and_then(|t| path.strip_prefix(t).ok().map(|r| (t, r))) {
        if rest.as_os_str().is_empty() || ["T", "C", "0"].iter().any(|p| rest == Path::new(p)) {
            return Err("is one of the main temp folders".into());
        }
        t
    } else {
        return Err("is outside your home folder".into());
    };
    let meta = fs::symlink_metadata(path).map_err(|_| "is already gone".to_string())?;
    if meta.file_type().is_symlink() {
        return Err("is a link, not the real folder".into());
    }
    // No link anywhere on the way there: the real location must be the same path.
    let parent = path.parent().ok_or("has no parent folder")?;
    let real_parent = fs::canonicalize(parent).map_err(|e| format!("can't be checked: {e}"))?;
    let real_root = fs::canonicalize(root).map_err(|e| format!("can't check {}: {e}", root.display()))?;
    let expected = real_root.join(parent.strip_prefix(root).unwrap_or(parent));
    if real_parent != expected {
        return Err("goes through a link to somewhere else".into());
    }
    Ok(())
}

/// Delete a file or folder. Fixes read-only folders (Go leaves those) and
/// tries once more.
pub fn delete(path: &Path) -> io::Result<()> {
    let meta = fs::symlink_metadata(path)?;
    if !meta.is_dir() {
        return fs::remove_file(path);
    }
    match fs::remove_dir_all(path) {
        Err(e) if e.kind() == io::ErrorKind::PermissionDenied => {
            make_dirs_writable(path);
            fs::remove_dir_all(path)
        }
        other => other,
    }
}

fn make_dirs_writable(dir: &Path) {
    let Ok(m) = fs::symlink_metadata(dir) else { return };
    if !m.is_dir() {
        return;
    }
    let mode = m.permissions().mode();
    if mode & 0o700 != 0o700 {
        let _ = fs::set_permissions(dir, fs::Permissions::from_mode(mode | 0o700));
    }
    if let Ok(entries) = fs::read_dir(dir) {
        for e in entries.flatten() {
            if e.file_type().is_ok_and(|t| t.is_dir()) {
                make_dirs_writable(&e.path());
            }
        }
    }
}

unsafe extern "C" {
    fn renamex_np(from: *const libc::c_char, to: *const libc::c_char, flags: libc::c_uint) -> libc::c_int;
}
const RENAME_EXCL: libc::c_uint = 0x4;

/// Move into the Trash folder. The name gets the parent folder in front
/// ("OhioFiles node_modules") so you can tell items apart there. Never
/// replaces something already in the Trash.
pub fn trash(path: &Path, trash_dir: &Path) -> Result<PathBuf, String> {
    fs::create_dir_all(trash_dir).map_err(|e| format!("can't open the Trash: {e}"))?;
    let name = path.file_name().ok_or("has no name")?.to_string_lossy().into_owned();
    let base = match path.parent().and_then(|p| p.file_name()) {
        Some(parent) => format!("{} {name}", parent.to_string_lossy()),
        None => name,
    };
    let from = CString::new(path.as_os_str().as_bytes()).map_err(|e| e.to_string())?;
    for n in 1..1000 {
        let dest = if n == 1 { trash_dir.join(&base) } else { trash_dir.join(format!("{base} {n}")) };
        let to = CString::new(dest.as_os_str().as_bytes()).map_err(|e| e.to_string())?;
        // SAFETY: two valid C strings; RENAME_EXCL fails instead of replacing.
        if unsafe { renamex_np(from.as_ptr(), to.as_ptr(), RENAME_EXCL) } == 0 {
            return Ok(dest);
        }
        let err = io::Error::last_os_error();
        match err.raw_os_error() {
            Some(libc::EEXIST) => continue,
            Some(libc::EXDEV) => return Err("is on another disk, so it can't go to this Trash".into()),
            _ => return Err(err.to_string()),
        }
    }
    Err("the Trash has too many items with this name".into())
}

#[derive(Debug, PartialEq, Eq)]
pub enum CommandResult {
    Ok,
    /// Exit 127: the shell didn't find the tool.
    NotFound,
    Failed(String),
}

/// Run a clean command with a time limit. Kills the whole process group on
/// timeout, so a hung tool can't leave children behind.
pub fn run_command(cmd: &str, cwd: &Path, timeout: Duration) -> CommandResult {
    let mut child = match Command::new("/bin/sh")
        .arg("-c")
        .arg(cmd)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .spawn()
    {
        Ok(c) => c,
        Err(e) => return CommandResult::Failed(format!("couldn't start it: {e}")),
    };
    let drain = |r: Option<Box<dyn Read + Send>>| {
        std::thread::spawn(move || {
            let mut s = Vec::new();
            if let Some(mut r) = r {
                let _ = r.read_to_end(&mut s);
            }
            String::from_utf8_lossy(&s).into_owned()
        })
    };
    let out = drain(child.stdout.take().map(|r| Box::new(r) as Box<dyn Read + Send>));
    let err = drain(child.stderr.take().map(|r| Box::new(r) as Box<dyn Read + Send>));
    let pgid = child.id() as libc::pid_t;
    let start = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s,
            Ok(None) if start.elapsed() < timeout => std::thread::sleep(Duration::from_millis(50)),
            Ok(None) => {
                // SAFETY: signalling the process group we created.
                unsafe { libc::killpg(pgid, libc::SIGTERM) };
                let grace = Instant::now();
                while grace.elapsed() < Duration::from_secs(3) {
                    if let Ok(Some(_)) = child.try_wait() {
                        return CommandResult::Failed(format!("stopped after {}s with no end", timeout.as_secs()));
                    }
                    std::thread::sleep(Duration::from_millis(50));
                }
                unsafe { libc::killpg(pgid, libc::SIGKILL) };
                let _ = child.wait();
                return CommandResult::Failed(format!("stopped after {}s with no end", timeout.as_secs()));
            }
            Err(e) => return CommandResult::Failed(e.to_string()),
        }
    };
    let (out, err) = (out.join().unwrap_or_default(), err.join().unwrap_or_default());
    match status.code() {
        Some(0) => CommandResult::Ok,
        Some(127) => CommandResult::NotFound,
        code => {
            let text = if err.trim().is_empty() { out } else { err };
            let tail: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty()).collect();
            let tail = tail[tail.len().saturating_sub(3)..].join(" / ");
            let code = code.map_or("a signal".to_string(), |c| format!("code {c}"));
            CommandResult::Failed(if tail.is_empty() { format!("ended with {code}") } else { format!("ended with {code}: {tail}") })
        }
    }
}

/// Clean one finding. `env` should be taken just before this call, so the
/// "is it running" checks see the Mac as it is now, not as it was at scan time.
pub fn clean_one(f: &Finding, rule: &Rule, env: &Env, opts: &CleanOptions) -> Outcome {
    if let Err(e) = guard(&f.path, &opts.home, opts.tmp_root.as_deref()) {
        return Outcome::Skipped { reason: format!("it {e}") };
    }
    let now = verify::verify(&rule.checks, &f.path, env, &opts.home);
    match now.status {
        Status::Blocked => {
            return Outcome::Skipped { reason: now.reason.unwrap_or_else(|| "it's in use".into()) };
        }
        Status::Review if f.status != Status::Review => {
            let why = now.reason.unwrap_or_default();
            return Outcome::Skipped { reason: format!("it changed since the scan ({why}), scan again") };
        }
        _ => {}
    }
    let method = choose_method(f, rule.clean.as_deref(), opts.force_trash);
    match &method {
        Method::Delete => match delete(&f.path) {
            Ok(()) => Outcome::Cleaned { method, note: None },
            Err(e) => Outcome::Failed { method, error: e.to_string() },
        },
        Method::Trash => match trash(&f.path, &opts.trash_dir) {
            Ok(dest) => Outcome::Cleaned { method, note: Some(format!("in the Trash as \"{}\"", dest.file_name().unwrap_or_default().to_string_lossy())) },
            Err(e) => Outcome::Failed { method, error: format!("it {e}") },
        },
        Method::Command(cmd) => match run_command(cmd, &opts.home, opts.timeout) {
            CommandResult::Ok => Outcome::Cleaned { method, note: None },
            CommandResult::NotFound => {
                // The tool isn't installed, so nothing else is using its folder.
                let tool = cmd.split_whitespace().next().unwrap_or("the tool").to_string();
                match delete(&f.path) {
                    Ok(()) => Outcome::Cleaned {
                        method: Method::Delete,
                        note: Some(format!("`{tool}` isn't installed, so the folder was deleted directly")),
                    },
                    Err(e) => Outcome::Failed { method: Method::Delete, error: format!("`{tool}` isn't installed and deleting failed: {e}") },
                }
            }
            CommandResult::Failed(e) => Outcome::Failed { method, error: e },
        },
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pick {
    Act,
    Skip(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanItem {
    /// Index into the findings.
    pub index: usize,
    pub pick: Pick,
}

#[derive(Debug, Default)]
pub struct Plan {
    pub items: Vec<PlanItem>,
    /// Things worth telling the user, like a rule that found nothing.
    pub notes: Vec<String>,
    /// Path targets nothing matched, as given.
    pub unmatched: Vec<String>,
}

/// Decide what to clean.
/// - `targets` are rule ids or paths. A rule id picks everything that rule
///   found. A path picks that exact item, or the "safe now" items inside it
///   (so `clean ~/code/app` cleans one project). Review items must be named
///   by rule id or exact path.
/// - `all_safe` picks everything in "Safe to clean now".
/// - Blocked items are listed as skipped, never acted on.
/// - Path targets that match nothing go to `unmatched`; the caller decides
///   whether that's an error (terminal) or a skipped item (app).
pub fn select(
    findings: &[Finding],
    rule_ids: &[&str],
    targets: &[String],
    all_safe: bool,
    home: &Path,
    cwd: &Path,
) -> Plan {
    let mut plan = Plan::default();
    let mut picked = vec![false; findings.len()];
    for t in targets {
        let hits: Vec<usize> = if rule_ids.contains(&t.as_str()) {
            let hits: Vec<usize> = (0..findings.len()).filter(|&i| findings[i].rule == *t).collect();
            if hits.is_empty() {
                plan.notes.push(format!("rule `{t}` found nothing to clean right now"));
            }
            hits
        } else {
            let p = normalize(t, home, cwd);
            let hits: Vec<usize> = (0..findings.len())
                .filter(|&i| {
                    let f = &findings[i];
                    f.path == p || (f.path.starts_with(&p) && f.section() == Section::SafeNow)
                })
                .collect();
            if hits.is_empty() {
                plan.unmatched.push(t.clone());
            }
            hits
        };
        for i in hits {
            picked[i] = true;
        }
    }
    if all_safe {
        for (i, f) in findings.iter().enumerate() {
            if f.section() == Section::SafeNow {
                picked[i] = true;
            }
        }
    }
    for (i, f) in findings.iter().enumerate() {
        if !picked[i] {
            continue;
        }
        let pick = if f.section() == Section::Blocked {
            Pick::Skip(f.reason.clone().unwrap_or_else(|| "it's in use".into()))
        } else {
            Pick::Act
        };
        plan.items.push(PlanItem { index: i, pick });
    }
    plan
}

fn normalize(t: &str, home: &Path, cwd: &Path) -> PathBuf {
    let p = if t == "~" {
        home.to_path_buf()
    } else if let Some(rest) = t.strip_prefix("~/") {
        home.join(rest)
    } else {
        cwd.join(t)
    };
    // Drop `.` parts so `./target` matches.
    p.components().filter(|c| !matches!(c, Component::CurDir)).collect()
}

#[derive(Serialize)]
pub struct LogEntry<'a> {
    /// Seconds since 1970.
    pub time: u64,
    pub rule: &'a str,
    pub path: &'a Path,
    pub bytes_freed_estimate: u64,
    pub outcome: &'a Outcome,
    pub free_before: Option<u64>,
    pub free_after: Option<u64>,
}

/// Add one line of JSON to the log.
pub fn append_log(log: &Path, entry: &LogEntry) -> io::Result<()> {
    if let Some(dir) = log.parent() {
        fs::create_dir_all(dir)?;
    }
    let mut f = fs::OpenOptions::new().create(true).append(true).open(log)?;
    let line = serde_json::to_string(entry).map_err(io::Error::other)?;
    writeln!(f, "{line}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rules::{Check, Risk, Target};
    use std::os::unix::fs::symlink;

    fn finding(path: &Path, risk: Risk, status: Status, clean: Option<&str>) -> Finding {
        Finding {
            rule: "test-rule".into(),
            category: "test".into(),
            risk,
            status,
            reason: None,
            path: path.to_path_buf(),
            bytes_on_disk: 1,
            bytes_freed: 1,
            files: 1,
            clean: clean.map(|c| crate::fill_command(c, path)),
            explain: String::new(),
        }
    }

    fn rule(clean: Option<&str>, checks: Vec<Check>) -> Rule {
        Rule {
            id: "test-rule".into(),
            name: "Test rule".into(),
            category: "test".into(),
            risk: Risk::Safe,
            explain: String::new(),
            clean: clean.map(str::to_string),
            target: Target::Paths { patterns: vec![], keep_newest: None },
            checks,
        }
    }

    fn opts(home: &Path) -> CleanOptions {
        CleanOptions {
            home: home.to_path_buf(),
            trash_dir: home.join(".Trash"),
            force_trash: false,
            timeout: Duration::from_secs(10),
            tmp_root: None,
        }
    }

    fn folder_with_file(p: &Path) {
        fs::create_dir_all(p).unwrap();
        fs::write(p.join("f"), "x").unwrap();
    }

    fn idle() -> Env {
        Env::from_parts(&[], &[])
    }

    #[test]
    fn methods() {
        let p = Path::new("/h/x");
        let rm = Some("rm -rf {path}");
        let tool = Some("brew cleanup");
        assert_eq!(choose_method(&finding(p, Risk::Safe, Status::Ready, rm), rm, false), Method::Delete);
        assert_eq!(
            choose_method(&finding(p, Risk::Safe, Status::Ready, tool), tool, false),
            Method::Command("brew cleanup".into())
        );
        assert_eq!(choose_method(&finding(p, Risk::Safe, Status::Ready, rm), rm, true), Method::Trash);
        assert_eq!(choose_method(&finding(p, Risk::Review, Status::Ready, rm), rm, false), Method::Trash);
        assert_eq!(choose_method(&finding(p, Risk::Safe, Status::Review, rm), rm, false), Method::Trash);
        assert_eq!(choose_method(&finding(p, Risk::Safe, Status::Ready, None), None, false), Method::Trash);
    }

    #[test]
    fn guard_refuses_dangerous_paths() {
        let home = tempfile::tempdir().unwrap();
        let h = home.path();
        let other = tempfile::tempdir().unwrap();
        folder_with_file(&h.join("Documents"));
        folder_with_file(&h.join("code/app/target"));
        folder_with_file(&other.path().join("target"));
        symlink(other.path(), h.join("linked")).unwrap();
        symlink(h.join("code/app/target"), h.join("code/app/target-link")).unwrap();

        assert!(guard(&h.join("code/app/target"), h, None).is_ok());
        assert!(guard(h, h, None).is_err(), "home itself");
        assert!(guard(&h.join("Documents"), h, None).is_err(), "main folder");
        assert!(guard(other.path(), h, None).is_err(), "outside home");
        assert!(guard(&h.join("code/app/target-link"), h, None).is_err(), "the path is a link");
        assert!(guard(&h.join("linked/target"), h, None).is_err(), "a link on the way");
        assert!(guard(&h.join("code/app/../app/target"), h, None).is_err(), "..");
        assert!(guard(&h.join("code/gone"), h, None).is_err(), "missing");
    }

    #[test]
    fn guard_allows_user_temp_only_inside() {
        let home = tempfile::tempdir().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let t = tmp.path();
        folder_with_file(&t.join("C/clang/ModuleCache"));
        folder_with_file(&t.join("T"));
        assert!(guard(&t.join("C/clang/ModuleCache"), home.path(), Some(t)).is_ok());
        assert!(guard(&t.join("C/clang/ModuleCache"), home.path(), None).is_err(), "no temp root given");
        assert!(guard(t, home.path(), Some(t)).is_err(), "the temp root itself");
        assert!(guard(&t.join("T"), home.path(), Some(t)).is_err(), "a main temp folder");
        assert!(guard(&t.join("C"), home.path(), Some(t)).is_err(), "a main temp folder");
    }

    #[test]
    fn delete_handles_read_only_folders() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("modcache");
        folder_with_file(&p.join("pkg@v1"));
        fs::set_permissions(p.join("pkg@v1"), fs::Permissions::from_mode(0o555)).unwrap();
        delete(&p).unwrap();
        assert!(!p.exists());
    }

    #[test]
    fn trash_never_replaces() {
        let home = tempfile::tempdir().unwrap();
        let h = home.path();
        let t = h.join(".Trash");
        for app in ["a", "b"] {
            folder_with_file(&h.join(format!("{app}/node_modules")));
        }
        folder_with_file(&h.join("c/a/node_modules"));
        let d1 = trash(&h.join("a/node_modules"), &t).unwrap();
        let d2 = trash(&h.join("c/a/node_modules"), &t).unwrap();
        let d3 = trash(&h.join("b/node_modules"), &t).unwrap();
        assert_eq!(d1.file_name().unwrap(), "a node_modules");
        assert_eq!(d2.file_name().unwrap(), "a node_modules 2");
        assert_eq!(d3.file_name().unwrap(), "b node_modules");
        assert!(d1.join("f").exists() && d2.join("f").exists());
        assert!(!h.join("a/node_modules").exists());
    }

    #[test]
    fn commands_report_results() {
        let d = tempfile::tempdir().unwrap();
        let t = Duration::from_secs(10);
        assert_eq!(run_command("true", d.path(), t), CommandResult::Ok);
        assert_eq!(run_command("no-such-tool-xyz --clean", d.path(), t), CommandResult::NotFound);
        match run_command("echo bad thing >&2; exit 3", d.path(), t) {
            CommandResult::Failed(e) => assert!(e.contains("code 3") && e.contains("bad thing"), "{e}"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn hung_command_is_stopped() {
        let d = tempfile::tempdir().unwrap();
        let start = Instant::now();
        let r = run_command("sleep 30 & sleep 30", d.path(), Duration::from_millis(300));
        assert!(matches!(r, CommandResult::Failed(ref e) if e.contains("stopped")), "{r:?}");
        assert!(start.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn clean_deletes_and_rechecks() {
        let home = tempfile::tempdir().unwrap();
        let h = home.path();
        let p = h.join(".cache/tool");
        folder_with_file(&p);
        let f = finding(&p, Risk::Safe, Status::Ready, Some("rm -rf {path}"));
        let r = rule(Some("rm -rf {path}"), vec![Check::NotRunning("Tool".into())]);

        // The tool started after the scan: skip it.
        let busy = Env::from_parts(&["tool"], &[]);
        let out = clean_one(&f, &r, &busy, &opts(h));
        assert!(matches!(out, Outcome::Skipped { ref reason } if reason.contains("running")), "{out:?}");
        assert!(p.exists());

        let out = clean_one(&f, &r, &idle(), &opts(h));
        assert_eq!(out, Outcome::Cleaned { method: Method::Delete, note: None });
        assert!(!p.exists());
    }

    #[test]
    fn missing_tool_falls_back_to_delete() {
        let home = tempfile::tempdir().unwrap();
        let h = home.path();
        let p = h.join(".cache/pods");
        folder_with_file(&p);
        let tpl = Some("no-such-tool-xyz cache clean");
        let out = clean_one(&finding(&p, Risk::Safe, Status::Ready, tpl), &rule(tpl, vec![]), &idle(), &opts(h));
        assert!(matches!(out, Outcome::Cleaned { method: Method::Delete, note: Some(_) }), "{out:?}");
        assert!(!p.exists());
    }

    #[test]
    fn review_items_go_to_trash() {
        let home = tempfile::tempdir().unwrap();
        let h = home.path();
        let p = h.join(".local/share/claude/versions/2.1.300");
        folder_with_file(&p);
        let tpl = Some("rm -rf {path}");
        let f = finding(&p, Risk::Review, Status::Ready, tpl);
        let out = clean_one(&f, &rule(tpl, vec![]), &idle(), &opts(h));
        assert!(matches!(out, Outcome::Cleaned { method: Method::Trash, .. }), "{out:?}");
        assert!(h.join(".Trash/versions 2.1.300/f").exists());
    }

    #[test]
    fn selection() {
        let h = Path::new("/h");
        let mk = |p: &str, risk, status| {
            let mut f = finding(&h.join(p), risk, status, None);
            f.rule = p.split('/').next_back().unwrap().into();
            f
        };
        let found = vec![
            mk("app/target", Risk::Safe, Status::Ready),
            mk("app/web/node_modules", Risk::Safe, Status::Review),
            mk(".cache/uv", Risk::Safe, Status::Blocked),
            mk("versions/2.1.1", Risk::Review, Status::Ready),
        ];
        let ids = ["target", "node_modules", "uv", "2.1.1", "empty-rule"];
        let acts = |plan: &Plan| -> Vec<usize> {
            plan.items.iter().filter(|i| i.pick == Pick::Act).map(|i| i.index).collect()
        };

        // --safe: only the safe one. Review and blocked are left alone.
        let p = select(&found, &ids, &[], true, h, h);
        assert_eq!(acts(&p), vec![0]);
        assert_eq!(p.items.len(), 1);

        // A rule id picks review items too.
        let p = select(&found, &ids, &["2.1.1".into()], false, h, h);
        assert_eq!(acts(&p), vec![3]);

        // A folder picks only the safe items inside it.
        let p = select(&found, &ids, &["~/app".into()], false, h, h);
        assert_eq!(acts(&p), vec![0]);
        // An exact path picks a review item.
        let p = select(&found, &ids, &["web/node_modules".into()], false, h, &h.join("app"));
        assert_eq!(acts(&p), vec![1]);

        // Blocked: listed, never acted on.
        let p = select(&found, &ids, &["uv".into()], false, h, h);
        assert!(acts(&p).is_empty());
        assert!(matches!(p.items[0].pick, Pick::Skip(_)));

        // Unknown paths are reported back; empty rules just get a note.
        let p = select(&found, &ids, &["~/Documents".into()], false, h, h);
        assert!(p.items.is_empty());
        assert_eq!(p.unmatched, vec!["~/Documents".to_string()]);
        let p = select(&found, &ids, &["empty-rule".into()], false, h, h);
        assert!(p.items.is_empty() && p.notes.len() == 1 && p.unmatched.is_empty());
    }

    #[test]
    fn select_matches_exact_path_with_spaces() {
        let h = Path::new("/h");
        let mut f = finding(Path::new("/h/My Code/app/target"), Risk::Safe, Status::Ready, None);
        f.rule = "rust-target".into();
        let p = select(&[f], &["rust-target"], &["/h/My Code/app/target".into()], false, h, h);
        assert_eq!(p.items, vec![PlanItem { index: 0, pick: Pick::Act }]);
        assert!(p.unmatched.is_empty());
    }

    #[test]
    fn log_lines_are_json() {
        let d = tempfile::tempdir().unwrap();
        let log = d.path().join("logs/clean.jsonl");
        let out = Outcome::Skipped { reason: "x".into() };
        let e = LogEntry {
            time: 1,
            rule: "r",
            path: Path::new("/p"),
            bytes_freed_estimate: 5,
            outcome: &out,
            free_before: Some(10),
            free_after: None,
        };
        append_log(&log, &e).unwrap();
        append_log(&log, &e).unwrap();
        let text = fs::read_to_string(&log).unwrap();
        assert_eq!(text.lines().count(), 2);
        let v: serde_json::Value = serde_json::from_str(text.lines().next().unwrap()).unwrap();
        assert_eq!(v["outcome"]["result"], "skipped");
    }
}
