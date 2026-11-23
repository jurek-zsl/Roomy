//! Safety checks run on every candidate before it is called "safe now".

use crate::rules::{Check, expand_home};
use serde::Serialize;
use std::collections::HashSet;
use std::fs::{self, File};
use std::os::fd::AsRawFd;
use std::path::Path;
use std::process::{Command, Stdio};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Status {
    /// All checks passed.
    Ready,
    /// Might hold something the user wants: they decide.
    Review,
    /// Can't be cleaned right now (in use, locked, app open).
    Blocked,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Verdict {
    pub status: Status,
    pub reason: Option<String>,
}

impl Verdict {
    fn ready(note: Option<String>) -> Self {
        Verdict {
            status: Status::Ready,
            reason: note,
        }
    }
    fn review(r: impl Into<String>) -> Self {
        Verdict {
            status: Status::Review,
            reason: Some(r.into()),
        }
    }
    fn blocked(r: impl Into<String>) -> Self {
        Verdict {
            status: Status::Blocked,
            reason: Some(r.into()),
        }
    }
}

/// A snapshot of running processes, taken once per scan.
pub struct Env {
    /// Lowercased executable names.
    names: HashSet<String>,
    /// Full command lines.
    pub args: Vec<String>,
}

impl Env {
    pub fn capture() -> Env {
        let run = |field: &str| -> Vec<String> {
            Command::new("ps")
                .args(["-axo", field])
                .stderr(Stdio::null())
                .output()
                .map(|o| {
                    String::from_utf8_lossy(&o.stdout)
                        .lines()
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default()
        };
        let names = run("comm=")
            .iter()
            .map(|l| l.trim().rsplit('/').next().unwrap_or("").to_lowercase())
            .filter(|s| !s.is_empty())
            .collect();
        Env {
            names,
            args: run("args="),
        }
    }

    pub fn from_parts(names: &[&str], args: &[&str]) -> Env {
        Env {
            names: names.iter().map(|s| s.to_lowercase()).collect(),
            args: args.iter().map(|s| s.to_string()).collect(),
        }
    }

    pub fn is_running(&self, name: &str) -> bool {
        self.names.contains(&name.to_lowercase())
    }
}

/// Run a rule's checks on one path. Blocking problems win over review ones,
/// because "can't do it now" is the more useful thing to tell the user.
pub fn verify(checks: &[Check], path: &Path, env: &Env, home: &Path) -> Verdict {
    let mut review: Option<Verdict> = None;
    let mut note = None;
    for c in checks {
        match c {
            Check::NotRunning(name) => {
                if env.is_running(name) {
                    return Verdict::blocked(format!("{name} is running"));
                }
            }
            Check::LockFree(p) => {
                if is_locked(&expand_home(p, home)) {
                    return Verdict::blocked("another program is using it (lock held)");
                }
            }
            Check::AppNotRunning => match app_owner(path) {
                Some(app) => {
                    let bundle = format!("/{}.app/", app.to_lowercase());
                    if env.is_running(&app)
                        || env.args.iter().any(|a| a.to_lowercase().contains(&bundle))
                    {
                        return Verdict::blocked(format!("{app} is running"));
                    }
                }
                None => {
                    review.get_or_insert(Verdict::review("can't tell which app this belongs to"));
                }
            },
            Check::NpxIdle => {
                if let Some(pkg) = npx_package_in_use(path, env) {
                    return Verdict::blocked(format!("`{pkg}` from here is running"));
                }
            }
            Check::ProjectIdle(days) => {
                if let Some(ago) = project_last_touched(path).and_then(|t| t.elapsed().ok()) {
                    let d = ago.as_secs() / 86400;
                    if d < *days {
                        let when = match d {
                            0 => "today".to_string(),
                            1 => "yesterday".to_string(),
                            n => format!("{n} days ago"),
                        };
                        review.get_or_insert(Verdict::review(format!(
                            "you worked on this project {when}, so it would just be rebuilt"
                        )));
                    }
                }
            }
            Check::GitIgnored => match git_state(path) {
                GitState::Ignored => {}
                GitState::NoRepo => note = Some("not in a git repo".to_string()),
                GitState::NotIgnored => {
                    review.get_or_insert(Verdict::review(
                        "git doesn't ignore it, so it may not be build output",
                    ));
                }
                GitState::HasTracked => {
                    review.get_or_insert(Verdict::review("holds files tracked by git"));
                }
            },
        }
    }
    review.unwrap_or(Verdict::ready(note))
}

/// Folders that say nothing about when you last worked on a project.
const NOT_WORK: &[&str] = &[
    ".git",
    "node_modules",
    "target",
    ".build",
    "build",
    "dist",
    ".next",
    ".venv",
    "venv",
    "Pods",
    ".gradle",
    ".godot",
    ".turbo",
    "__pycache__",
];

/// When the project holding this build folder was last worked on: the newest
/// change among its files two levels down (skipping build output), and git's
/// index and HEAD log. The project is the nearest folder above with `.git`,
/// or the build folder's parent.
pub fn project_last_touched(build_dir: &Path) -> Option<std::time::SystemTime> {
    let parent = build_dir.parent()?;
    let root = parent
        .ancestors()
        .take(6)
        .find(|a| a.join(".git").exists())
        .unwrap_or(parent);
    let mut newest = None;
    let mut see = |p: &Path| {
        if let Ok(t) = fs::symlink_metadata(p).and_then(|m| m.modified()) {
            newest = newest.max(Some(t));
        }
    };
    for g in [".git/index", ".git/logs/HEAD"] {
        see(&root.join(g));
    }
    let mut dirs = vec![(root.to_path_buf(), 0)];
    if parent != root {
        dirs.push((parent.to_path_buf(), 0));
    }
    while let Some((dir, depth)) = dirs.pop() {
        see(&dir);
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        for e in rd.flatten() {
            let p = e.path();
            if p == build_dir || NOT_WORK.contains(&e.file_name().to_string_lossy().as_ref()) {
                continue;
            }
            see(&p);
            if depth < 1 && e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                dirs.push((p, depth + 1));
            }
        }
    }
    newest
}

/// `.../Application Support/Notion/Partitions/...` → "Notion".
pub fn app_owner(path: &Path) -> Option<String> {
    let mut parts = path
        .components()
        .map(|c| c.as_os_str().to_string_lossy().into_owned());
    parts.find(|p| p == "Application Support")?;
    parts.next()
}

#[derive(Debug, PartialEq, Eq)]
enum GitState {
    NoRepo,
    Ignored,
    NotIgnored,
    HasTracked,
}

fn git_state(path: &Path) -> GitState {
    let (Some(parent), Some(name)) = (path.parent(), path.file_name()) else {
        return GitState::NoRepo;
    };
    let git = |args: &[&str]| {
        Command::new("git")
            .arg("-C")
            .arg(parent)
            .args(args)
            .arg(name)
            .stderr(Stdio::null())
            .output()
            .ok()
    };
    let inside = Command::new("git")
        .arg("-C")
        .arg(parent)
        .args(["rev-parse", "--is-inside-work-tree"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !inside {
        return GitState::NoRepo;
    }
    if git(&["ls-files", "--"]).is_some_and(|o| !o.stdout.is_empty()) {
        return GitState::HasTracked;
    }
    match git(&["check-ignore", "-q", "--"]) {
        Some(o) if o.status.success() => GitState::Ignored,
        _ => GitState::NotIgnored,
    }
}

/// True when another process holds a lock on the file (flock).
fn is_locked(path: &Path) -> bool {
    let Ok(f) = File::open(path) else {
        return false;
    };
    let fd = f.as_raw_fd();
    // SAFETY: fd is a valid open file descriptor owned by `f`.
    let rc = unsafe { libc::flock(fd, libc::LOCK_EX | libc::LOCK_NB) };
    if rc == 0 {
        unsafe { libc::flock(fd, libc::LOCK_UN) };
        return false;
    }
    std::io::Error::last_os_error().raw_os_error() == Some(libc::EWOULDBLOCK)
}

/// npx folders hold a `package.json` listing the package they run. A
/// running `npm exec <pkg>` / `npx <pkg>` means that folder is in use.
fn npx_package_in_use(dir: &Path, env: &Env) -> Option<String> {
    let text = std::fs::read_to_string(dir.join("package.json")).ok()?;
    let json: serde_json::Value = serde_json::from_str(&text).ok()?;
    let deps = json.get("dependencies")?.as_object()?;
    let dir_str = dir.to_string_lossy();
    deps.keys()
        .find(|pkg| {
            env.args
                .iter()
                .any(|a| a.contains(pkg.as_str()) || a.contains(dir_str.as_ref()))
        })
        .cloned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn git(dir: &Path, args: &[&str]) {
        let ok = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .output()
            .unwrap()
            .status
            .success();
        assert!(ok, "git {args:?}");
    }

    fn repo() -> tempfile::TempDir {
        let t = tempfile::tempdir().unwrap();
        git(t.path(), &["init", "-q"]);
        t
    }

    #[test]
    fn git_ignored_folder_is_ready() {
        let t = repo();
        fs::write(t.path().join(".gitignore"), "target/\n").unwrap();
        fs::create_dir(t.path().join("target")).unwrap();
        let v = verify(
            &[Check::GitIgnored],
            &t.path().join("target"),
            &Env::from_parts(&[], &[]),
            t.path(),
        );
        assert_eq!(v.status, Status::Ready);
    }

    #[test]
    fn not_ignored_folder_needs_review() {
        let t = repo();
        fs::create_dir(t.path().join("build")).unwrap();
        fs::write(t.path().join("build/app.ipa"), "x").unwrap();
        let v = verify(
            &[Check::GitIgnored],
            &t.path().join("build"),
            &Env::from_parts(&[], &[]),
            t.path(),
        );
        assert_eq!(v.status, Status::Review);
    }

    #[test]
    fn tracked_files_need_review() {
        let t = repo();
        fs::create_dir(t.path().join("dist")).unwrap();
        fs::write(t.path().join("dist/keep.js"), "x").unwrap();
        git(t.path(), &["add", "dist/keep.js"]);
        fs::write(t.path().join(".gitignore"), "dist/\n").unwrap();
        let v = verify(
            &[Check::GitIgnored],
            &t.path().join("dist"),
            &Env::from_parts(&[], &[]),
            t.path(),
        );
        assert_eq!(v.status, Status::Review);
        assert!(v.reason.unwrap().contains("tracked"));
    }

    #[test]
    fn no_repo_is_ready_with_note() {
        let t = tempfile::tempdir().unwrap();
        fs::create_dir(t.path().join("target")).unwrap();
        let v = verify(
            &[Check::GitIgnored],
            &t.path().join("target"),
            &Env::from_parts(&[], &[]),
            t.path(),
        );
        assert_eq!(v.status, Status::Ready);
        assert_eq!(v.reason.as_deref(), Some("not in a git repo"));
    }

    #[test]
    fn running_process_blocks() {
        let env = Env::from_parts(&["cargo"], &[]);
        let v = verify(
            &[Check::NotRunning("Cargo".into())],
            Path::new("/x"),
            &env,
            Path::new("/"),
        );
        assert_eq!(v.status, Status::Blocked);
    }

    #[test]
    fn held_lock_blocks() {
        let t = tempfile::tempdir().unwrap();
        let lock = t.path().join(".lock");
        fs::write(&lock, "").unwrap();
        let held = File::open(&lock).unwrap();
        assert_eq!(unsafe { libc::flock(held.as_raw_fd(), libc::LOCK_SH) }, 0);

        let check = [Check::LockFree(lock.to_string_lossy().into_owned())];
        let env = Env::from_parts(&[], &[]);
        assert_eq!(
            verify(&check, t.path(), &env, t.path()).status,
            Status::Blocked
        );
        // Unlock explicitly: other tests start child processes, and one forked
        // right now briefly shares this file, so closing it alone may not unlock.
        assert_eq!(unsafe { libc::flock(held.as_raw_fd(), libc::LOCK_UN) }, 0);
        assert_eq!(
            verify(&check, t.path(), &env, t.path()).status,
            Status::Ready
        );
    }

    #[test]
    fn running_npx_package_blocks() {
        let t = tempfile::tempdir().unwrap();
        fs::write(
            t.path().join("package.json"),
            r#"{"dependencies":{"@coding-solo/godot-mcp":"^1"}}"#,
        )
        .unwrap();
        let busy = Env::from_parts(&["node"], &["npm exec @coding-solo/godot-mcp"]);
        let idle = Env::from_parts(&["node"], &["node server.js"]);
        assert_eq!(
            verify(&[Check::NpxIdle], t.path(), &busy, t.path()).status,
            Status::Blocked
        );
        assert_eq!(
            verify(&[Check::NpxIdle], t.path(), &idle, t.path()).status,
            Status::Ready
        );
    }

    #[test]
    fn app_not_running_uses_folder_owner() {
        let p =
            Path::new("/h/Library/Application Support/Notion/Partitions/notion/Cache/Cache_Data");
        let c = [Check::AppNotRunning];
        let by_name = Env::from_parts(&["notion"], &[]);
        let v = verify(&c, p, &by_name, Path::new("/h"));
        assert_eq!(v.status, Status::Blocked);
        assert_eq!(v.reason.as_deref(), Some("Notion is running"));
        let by_bundle = Env::from_parts(
            &["notion helper (renderer)"],
            &["/Applications/Notion.app/Contents/Frameworks/Notion Helper"],
        );
        assert_eq!(
            verify(&c, p, &by_bundle, Path::new("/h")).status,
            Status::Blocked
        );
        let idle = Env::from_parts(&["finder"], &["/System/Finder.app/Contents/MacOS/Finder"]);
        assert_eq!(verify(&c, p, &idle, Path::new("/h")).status, Status::Ready);
        // No app folder in the path: can't tell, so the user decides.
        assert_eq!(
            verify(&c, Path::new("/h/x/Cache"), &idle, Path::new("/h")).status,
            Status::Review
        );
    }

    fn age(p: &Path, days: u64) {
        let t = std::time::SystemTime::now() - std::time::Duration::from_secs(days * 86400);
        fs::File::options()
            .read(true)
            .open(p)
            .unwrap()
            .set_modified(t)
            .unwrap();
    }

    #[test]
    fn project_idle_reviews_recent_projects() {
        let d = tempfile::tempdir().unwrap();
        let app = d.path().join("app");
        fs::create_dir_all(app.join("src")).unwrap();
        fs::create_dir_all(app.join("node_modules/x")).unwrap();
        fs::write(app.join("package.json"), "{}").unwrap();
        fs::write(app.join("src/index.js"), "1").unwrap();
        let env = Env::from_parts(&[], &[]);
        let checks = [Check::ProjectIdle(7)];

        let v = verify(&checks, &app.join("node_modules"), &env, d.path());
        assert_eq!(v.status, Status::Review, "just edited");
        assert!(v.reason.unwrap().contains("rebuilt"));

        for p in [
            app.join("package.json"),
            app.join("src/index.js"),
            app.join("src"),
            app.clone(),
        ] {
            age(&p, 30);
        }
        let v = verify(&checks, &app.join("node_modules"), &env, d.path());
        assert_eq!(v.status, Status::Ready, "idle for a month");
    }
}
