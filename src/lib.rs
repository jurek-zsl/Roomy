//! Roomy: finds space you can free, explains it, and says how to
//! clean it. This crate only scans. It never deletes anything.

pub mod clean;
pub mod finders;
pub mod inspect;
pub mod json;
pub mod known;
pub mod map;
pub mod report;
pub mod rules;
pub mod scan;
pub mod size;
pub mod verify;

use rayon::prelude::*;
use rules::{Risk, Rule};
use serde::Serialize;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use verify::{Env, Status};

#[derive(Debug, Clone, Serialize)]
pub struct Finding {
    pub rule: String,
    pub category: String,
    pub risk: Risk,
    pub status: Status,
    pub reason: Option<String>,
    pub path: PathBuf,
    pub bytes_on_disk: u64,
    pub bytes_freed: u64,
    pub files: u64,
    pub clean: Option<String>,
    pub explain: String,
    /// Context a finder added ("Last opened 7 months ago.").
    pub detail: Option<String>,
    /// A name for this one item, set by finders ("iOS 27.2 Simulator runtime").
    pub label: Option<String>,
}

impl Finding {
    /// Where the report puts this finding.
    pub fn section(&self) -> Section {
        match (self.status, self.risk) {
            (Status::Blocked, _) => Section::Blocked,
            (Status::Review, _) | (_, Risk::Review) => Section::Review,
            _ => Section::SafeNow,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Section {
    SafeNow,
    Review,
    Blocked,
}

pub struct ScanOptions {
    pub home: PathBuf,
    pub rules: Vec<Rule>,
    pub walk: scan::WalkOptions,
    /// Where apps are installed (`/Applications`). Also where Xcode is looked for.
    pub apps_dir: PathBuf,
}

const MB: u64 = 1_000_000;

/// Run every finder rule. Simulator finders only run when Xcode is installed.
fn finder_candidates(opts: &ScanOptions, repos: &[PathBuf], env: &Env) -> Vec<scan::Candidate> {
    use finders::*;
    let now = std::time::SystemTime::now();
    let xcode = has_xcode(&opts.apps_dir);
    let devices = std::sync::OnceLock::new();
    let devices = || devices.get_or_init(|| if xcode { simctl(&["list", "devices", "-j"]).unwrap_or_default() } else { String::new() });
    let mut out = Vec::new();
    for (i, r) in opts.rules.iter().enumerate() {
        let rules::Target::Finder { kind, idle_days, min_mb } = r.target else { continue };
        let found = match kind {
            rules::FinderKind::UnusedApps => unused_apps(&opts.apps_dir, &spotlight_usage, env, now, idle_days),
            rules::FinderKind::StaleProjects => stale_projects(repos, now, idle_days),
            rules::FinderKind::GitGarbage => git_garbage(repos, min_mb * MB),
            rules::FinderKind::SimulatorRuntimes if xcode => {
                simulator_runtimes(&simctl(&["runtime", "list", "-j"]).unwrap_or_default(), devices(), now, idle_days)
            }
            rules::FinderKind::SimulatorDevices if xcode => unavailable_simulators(devices()),
            _ => Vec::new(),
        };
        out.extend(found.into_iter().map(|f| scan::Candidate { rule: i, path: f.path.clone(), found: Some(f) }));
    }
    out
}

/// Find, measure and check everything. Sorted biggest first.
pub fn run(opts: &ScanOptions) -> Vec<Finding> {
    let env = Env::capture();
    let wants_repos = opts.rules.iter().any(|r| {
        matches!(r.target, rules::Target::Finder { kind: rules::FinderKind::StaleProjects | rules::FinderKind::GitGarbage, .. })
    });
    let mut cands = scan::path_candidates(&opts.rules, &opts.home);
    let walked = scan::walk_projects(&opts.rules, &opts.walk, wants_repos);
    cands.extend(walked.candidates);
    cands.extend(finder_candidates(opts, &walked.repos, &env));
    let mut seen = HashSet::new();
    cands.retain(|c| seen.insert(c.path.clone()));

    let mut findings: Vec<Finding> = cands
        .par_iter()
        .map(|c| {
            let r = &opts.rules[c.rule];
            let found = c.found.as_ref();
            let size = match found.and_then(|f| f.bytes) {
                Some(b) => size::Size { on_disk: b, freed: b, files: 0 },
                None => size::measure(&c.path),
            };
            let mut verdict = verify::verify(&r.checks, &c.path, &env, &opts.home);
            if let Some(why) = found.and_then(|f| f.blocked.clone()) {
                verdict = verify::Verdict { status: Status::Blocked, reason: Some(why) };
            }
            Finding {
                rule: r.id.clone(),
                category: r.category.clone(),
                risk: r.risk,
                status: verdict.status,
                reason: verdict.reason,
                path: c.path.clone(),
                bytes_on_disk: size.on_disk,
                bytes_freed: size.freed,
                files: size.files,
                clean: r.clean.as_deref().map(|t| fill_command_id(t, &c.path, found.and_then(|f| f.id.as_deref()))),
                explain: r.explain.clone(),
                detail: found.and_then(|f| f.detail.clone()),
                label: found.and_then(|f| f.label.clone()),
            }
        })
        .filter(|f| f.bytes_on_disk > 0)
        .collect();
    subtract_nested(&mut findings, &opts.rules);
    findings.sort_by(|a, b| b.bytes_freed.cmp(&a.bytes_freed).then(a.path.cmp(&b.path)));
    findings
}

/// A whole stale project also holds its build folders, which are listed on
/// their own. Count those bytes once: the project shows only the rest.
pub fn subtract_nested(findings: &mut [Finding], rules: &[Rule]) {
    let stale: HashSet<&str> = rules
        .iter()
        .filter(|r| matches!(r.target, rules::Target::Finder { kind: rules::FinderKind::StaleProjects, .. }))
        .map(|r| r.id.as_str())
        .collect();
    for i in 0..findings.len() {
        if !stale.contains(findings[i].rule.as_str()) {
            continue;
        }
        let (mut freed, mut disk, mut n) = (0, 0, 0);
        for (j, f) in findings.iter().enumerate() {
            if j != i && f.path.starts_with(&findings[i].path) {
                freed += f.bytes_freed;
                disk += f.bytes_on_disk;
                n += 1;
            }
        }
        if n > 0 {
            let p = &mut findings[i];
            p.bytes_freed = p.bytes_freed.saturating_sub(freed);
            p.bytes_on_disk = p.bytes_on_disk.saturating_sub(disk);
            let what = if n == 1 { "build folder (".to_string() } else { format!("{n} build folders (") };
            let verb = if n == 1 { "is" } else { "are" };
            let d = p.detail.get_or_insert_default();
            d.push_str(&format!(" Its {what}{}) {verb} listed separately.", report::human_bytes(freed)));
        }
    }
}

/// Fill `{path}` and `{parent}` in a clean command, shell-quoted.
pub fn fill_command(template: &str, path: &Path) -> String {
    fill_command_id(template, path, None)
}

/// Like `fill_command`, also filling `{id}` (a finder's id, like a simulator's UDID).
pub fn fill_command_id(template: &str, path: &Path, id: Option<&str>) -> String {
    let parent = path.parent().unwrap_or(Path::new("/"));
    let mut s = template.replace("{path}", &shell_quote(path)).replace("{parent}", &shell_quote(parent));
    if let Some(id) = id {
        s = s.replace("{id}", &shell_quote(Path::new(id)));
    }
    s
}

fn shell_quote(p: &Path) -> String {
    let s = p.to_string_lossy();
    if s.chars().all(|c| c.is_ascii_alphanumeric() || "/._-~+@".contains(c)) {
        s.into_owned()
    } else {
        format!("'{}'", s.replace('\'', r"'\''"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fills_and_quotes_commands() {
        let p = Path::new("/Users/me/My Code/app/target");
        assert_eq!(
            fill_command("cargo clean --manifest-path {parent}/Cargo.toml", p),
            "cargo clean --manifest-path '/Users/me/My Code/app'/Cargo.toml"
        );
        assert_eq!(fill_command("rm -rf {path}", Path::new("/a/b")), "rm -rf /a/b");
        assert_eq!(fill_command("rm -rf {path}", Path::new("/it's")), r"rm -rf '/it'\''s'");
        assert_eq!(fill_command_id("xcrun simctl delete {id}", Path::new("/x"), Some("AB-12")), "xcrun simctl delete AB-12");
        assert_eq!(fill_command_id("x {id}", Path::new("/x"), Some("a b")), "x 'a b'");
    }

    fn f(rule: &str, path: &str, bytes: u64) -> Finding {
        Finding {
            rule: rule.into(),
            category: "c".into(),
            risk: Risk::Review,
            status: Status::Ready,
            reason: None,
            path: path.into(),
            bytes_on_disk: bytes,
            bytes_freed: bytes,
            files: 1,
            clean: None,
            explain: String::new(),
            detail: Some("Last commit 1 year ago.".into()),
            label: None,
        }
    }

    #[test]
    fn stale_projects_count_build_folders_once() {
        let rules = rules::parse_rules(
            r#"
[[rule]]
id = "stale"
category = "c"
risk = "review"
explain = "e"
match = { finder = "stale-projects", idle_days = 1 }
"#,
        )
        .unwrap();
        let mut v = vec![
            f("stale", "/h/code/old", 5_000_000_000),
            f("node-modules", "/h/code/old/node_modules", 3_000_000_000),
            f("node-modules", "/h/code/older/node_modules", 1_000_000_000),
        ];
        subtract_nested(&mut v, &rules);
        assert_eq!(v[0].bytes_freed, 2_000_000_000);
        assert_eq!(v[0].detail.as_deref(), Some("Last commit 1 year ago. Its build folder (3.0 GB) is listed separately."));
        assert_eq!(v[2].bytes_freed, 1_000_000_000);
    }
}
