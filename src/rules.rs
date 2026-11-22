//! Loading and validating cleaning rules from TOML.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// The rules shipped with the app.
pub const DEFAULT_RULES: &str = include_str!("../rules/default.toml");

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Risk {
    /// Can be removed without losing anything you can't get back.
    Safe,
    /// Safe, but only while the owning app is closed.
    QuitApp,
    /// Safe in principle, but the user should decide.
    Review,
}

/// A safety check run before a finding is called "safe now".
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Check {
    /// The folder must be ignored by git, otherwise it may hold real work.
    GitIgnored,
    /// A process with this name must not be running.
    NotRunning(String),
    /// No other process may hold a lock on this file.
    LockFree(String),
    /// No running process may be using a package from this npx folder.
    NpxIdle,
    /// The app that owns this `Application Support/<App>/...` folder must
    /// not be running.
    AppNotRunning,
    /// The project this folder belongs to must not have been worked on in
    /// the last N days. Otherwise it goes to Review: it would just be rebuilt.
    ProjectIdle(u64),
}

impl Check {
    pub fn parse(s: &str) -> Result<Check, String> {
        let (name, arg) = match s.split_once(':') {
            Some((n, a)) => (n, Some(a)),
            None => (s, None),
        };
        match (name, arg) {
            ("git-ignored", None) => Ok(Check::GitIgnored),
            ("npx-idle", None) => Ok(Check::NpxIdle),
            ("app-not-running", None) => Ok(Check::AppNotRunning),
            ("not-running", Some(a)) if !a.is_empty() => Ok(Check::NotRunning(a.to_string())),
            ("lock-free", Some(a)) if !a.is_empty() => Ok(Check::LockFree(a.to_string())),
            ("project-idle", Some(a)) => {
                a.parse().map(Check::ProjectIdle).map_err(|_| format!("`{s}` needs a number of days"))
            }
            _ => Err(format!("unknown check `{s}`")),
        }
    }
}

/// Where a rule looks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    /// Fixed locations (glob patterns, `~` allowed).
    Paths { patterns: Vec<String>, keep_newest: Option<usize>, older_than_days: Option<u64> },
    /// A folder name found while walking, with a marker file next to it.
    Project { dir_name: String, sibling: Vec<String> },
    /// Built-in code that finds things a glob can't: apps you don't open,
    /// projects you stopped working on, simulator runtimes.
    Finder { kind: FinderKind, idle_days: u64, min_mb: u64 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FinderKind {
    /// Apps in /Applications not opened for `idle_days`.
    UnusedApps,
    /// Whole git projects with no commit for `idle_days`, fully pushed.
    StaleProjects,
    /// Loose objects and garbage in git repos, at least `min_mb`.
    GitGarbage,
    /// Simulator runtimes no simulator used for `idle_days`, or replaced by a newer one.
    SimulatorRuntimes,
    /// Simulators whose runtime is gone.
    SimulatorDevices,
}

impl FinderKind {
    fn parse(s: &str) -> Option<FinderKind> {
        Some(match s {
            "unused-apps" => FinderKind::UnusedApps,
            "stale-projects" => FinderKind::StaleProjects,
            "git-garbage" => FinderKind::GitGarbage,
            "simulator-runtimes" => FinderKind::SimulatorRuntimes,
            "simulator-devices" => FinderKind::SimulatorDevices,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone)]
pub struct Rule {
    pub id: String,
    /// Readable name for people ("Rust package sources"). Falls back to the id.
    pub name: String,
    pub category: String,
    pub risk: Risk,
    pub explain: String,
    pub clean: Option<String>,
    pub target: Target,
    pub checks: Vec<Check>,
    /// Review items normally go to the Trash. With this, they use the clean
    /// command instead (for things the Trash can't hold, like simulator runtimes).
    pub command_only: bool,
}

#[derive(Deserialize)]
struct RawFile {
    #[serde(default)]
    rule: Vec<RawRule>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawRule {
    id: String,
    #[serde(default)]
    name: Option<String>,
    category: String,
    risk: Risk,
    explain: String,
    #[serde(default)]
    clean: Option<String>,
    #[serde(rename = "match")]
    matcher: RawMatch,
    #[serde(default)]
    verify: Vec<String>,
    #[serde(default)]
    command_only: bool,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum OneOrMany {
    One(String),
    Many(Vec<String>),
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawMatch {
    path: Option<OneOrMany>,
    dir_name: Option<String>,
    #[serde(default)]
    sibling: Vec<String>,
    keep_newest: Option<usize>,
    older_than_days: Option<u64>,
    finder: Option<String>,
    idle_days: Option<u64>,
    min_mb: Option<u64>,
}

/// Parse a rules file. Fails on unknown fields, unknown checks, bad matchers
/// and duplicate ids, so a typo in a rule never silently does nothing.
pub fn parse_rules(text: &str) -> Result<Vec<Rule>, String> {
    let raw: RawFile = toml::from_str(text).map_err(|e| e.to_string())?;
    let mut seen = HashSet::new();
    raw.rule
        .into_iter()
        .map(|r| {
            let id = r.id;
            if !seen.insert(id.clone()) {
                return Err(format!("duplicate rule id `{id}`"));
            }
            let m = r.matcher;
            let finder_opts = m.idle_days.is_some() || m.min_mb.is_some();
            let target = match (m.path, m.dir_name, m.finder) {
                (None, None, Some(f)) => {
                    if m.keep_newest.is_some() || m.older_than_days.is_some() || !m.sibling.is_empty() {
                        return Err(format!("rule `{id}`: a finder only takes `idle_days` and `min_mb`"));
                    }
                    let kind = FinderKind::parse(&f).ok_or_else(|| format!("rule `{id}`: unknown finder `{f}`"))?;
                    Target::Finder { kind, idle_days: m.idle_days.unwrap_or(0), min_mb: m.min_mb.unwrap_or(0) }
                }
                _ if finder_opts => {
                    return Err(format!("rule `{id}`: `idle_days` and `min_mb` only work with `finder`"));
                }
                (Some(p), None, None) => {
                    if !m.sibling.is_empty() {
                        return Err(format!("rule `{id}`: `sibling` only works with `dir_name`"));
                    }
                    let patterns = match p {
                        OneOrMany::One(s) => vec![s],
                        OneOrMany::Many(v) => v,
                    };
                    if patterns.is_empty() {
                        return Err(format!("rule `{id}`: `path` is empty"));
                    }
                    Target::Paths { patterns, keep_newest: m.keep_newest, older_than_days: m.older_than_days }
                }
                (None, Some(dir_name), None) => {
                    if m.keep_newest.is_some() || m.older_than_days.is_some() {
                        return Err(format!("rule `{id}`: `keep_newest` and `older_than_days` only work with `path`"));
                    }
                    Target::Project { dir_name, sibling: m.sibling }
                }
                _ => return Err(format!("rule `{id}`: match needs exactly one of `path`, `dir_name` or `finder`")),
            };
            let checks = r
                .verify
                .iter()
                .map(|c| Check::parse(c).map_err(|e| format!("rule `{id}`: {e}")))
                .collect::<Result<Vec<_>, _>>()?;
            Ok(Rule {
                name: r.name.filter(|n| !n.trim().is_empty()).unwrap_or_else(|| id.clone()),
                id,
                category: r.category,
                risk: r.risk,
                explain: r.explain,
                clean: r.clean,
                target,
                checks,
                command_only: r.command_only,
            })
        })
        .collect()
}

/// Replace a leading `~` with the home folder.
/// The per-user temp area (`/var/folders/xx/yyy`), parent of `$TMPDIR`.
/// Rules reach it as `$USERTMP/...`. None if `$TMPDIR` isn't the usual
/// macOS one, so a custom `TMPDIR=/tmp` can never make `/` a target.
pub fn user_tmp_root() -> Option<PathBuf> {
    let t = std::env::temp_dir();
    let ok = (t.starts_with("/var/folders") || t.starts_with("/private/var/folders")) && t.file_name()? == "T";
    if ok { t.parent().map(Path::to_path_buf) } else { None }
}

pub fn expand_home(s: &str, home: &Path) -> PathBuf {
    if s == "~" {
        home.to_path_buf()
    } else if let Some(rest) = s.strip_prefix("~/") {
        home.join(rest)
    } else {
        PathBuf::from(s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_finder_rule() {
        let t = r#"
[[rule]]
id = "apps"
category = "apps"
risk = "review"
explain = "e"
match = { finder = "unused-apps", idle_days = 120 }
"#;
        let r = &parse_rules(t).unwrap()[0];
        assert_eq!(r.target, Target::Finder { kind: FinderKind::UnusedApps, idle_days: 120, min_mb: 0 });
        assert!(!r.command_only);
    }

    #[test]
    fn finder_defaults_and_unknown() {
        let ok = r#"
[[rule]]
id = "g"
category = "c"
risk = "safe"
explain = "e"
command_only = true
match = { finder = "git-garbage", min_mb = 50 }
"#;
        let r = &parse_rules(ok).unwrap()[0];
        assert_eq!(r.target, Target::Finder { kind: FinderKind::GitGarbage, idle_days: 0, min_mb: 50 });
        assert!(r.command_only);
        let bad = ok.replace("git-garbage", "git-garbag");
        assert!(parse_rules(&bad).unwrap_err().contains("unknown finder"));
        let mixed = ok.replace("min_mb = 50", "min_mb = 50, path = \"~/x\"");
        assert!(parse_rules(&mixed).is_err());
    }

    #[test]
    fn parses_older_than_days_and_project_idle() {
        let t = r#"
[[rule]]
id = "dl"
category = "c"
risk = "review"
explain = "e"
match = { path = "~/Downloads/*.dmg", older_than_days = 14 }
verify = ["project-idle:7"]
"#;
        let r = &parse_rules(t).unwrap()[0];
        assert_eq!(
            r.target,
            Target::Paths { patterns: vec!["~/Downloads/*.dmg".into()], keep_newest: None, older_than_days: Some(14) }
        );
        assert_eq!(r.checks, vec![Check::ProjectIdle(7)]);
        assert!(Check::parse("project-idle:x").is_err());
    }

    #[test]
    fn default_rules_parse() {
        let rules = parse_rules(DEFAULT_RULES).expect("built-in rules must parse");
        assert!(rules.len() > 30);
        assert!(rules.iter().any(|r| r.id == "rust-target"));
    }

    #[test]
    fn rejects_unknown_check() {
        let t = r#"
[[rule]]
id = "x"
category = "c"
risk = "safe"
explain = "e"
match = { path = "~/x" }
verify = ["git-ignord"]
"#;
        let err = parse_rules(t).unwrap_err();
        assert!(err.contains("unknown check"), "{err}");
    }

    #[test]
    fn rejects_both_path_and_dir_name() {
        let t = r#"
[[rule]]
id = "x"
category = "c"
risk = "safe"
explain = "e"
match = { path = "~/x", dir_name = "y" }
"#;
        assert!(parse_rules(t).is_err());
    }

    #[test]
    fn rejects_duplicate_ids() {
        let one = r#"
[[rule]]
id = "x"
category = "c"
risk = "safe"
explain = "e"
match = { path = "~/x" }
"#;
        assert!(parse_rules(&format!("{one}{one}")).unwrap_err().contains("duplicate"));
    }

    #[test]
    fn path_accepts_list() {
        let t = r#"
[[rule]]
id = "x"
category = "c"
risk = "safe"
explain = "e"
match = { path = ["~/a", "~/b"] }
"#;
        let r = &parse_rules(t).unwrap()[0];
        assert_eq!(
            r.target,
            Target::Paths { patterns: vec!["~/a".into(), "~/b".into()], keep_newest: None, older_than_days: None }
        );
    }

    #[test]
    fn expands_home() {
        let h = Path::new("/Users/me");
        assert_eq!(expand_home("~/x/y", h), PathBuf::from("/Users/me/x/y"));
        assert_eq!(expand_home("~", h), PathBuf::from("/Users/me"));
        assert_eq!(expand_home("/abs", h), PathBuf::from("/abs"));
    }

    #[test]
    fn name_falls_back_to_id() {
        let r = parse_rules(
            r#"
[[rule]]
id = "x"
category = "c"
risk = "safe"
explain = "e"
match = { path = "~/x" }
"#,
        )
        .unwrap();
        assert_eq!(r[0].name, "x");
    }

    #[test]
    fn default_rules_have_names() {
        for r in parse_rules(DEFAULT_RULES).unwrap() {
            assert_ne!(r.name, r.id, "rule `{}` needs a readable name", r.id);
        }
    }

    #[test]
    fn parses_app_not_running() {
        assert_eq!(Check::parse("app-not-running"), Ok(Check::AppNotRunning));
    }
}
