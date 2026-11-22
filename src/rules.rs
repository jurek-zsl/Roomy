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
            _ => Err(format!("unknown check `{s}`")),
        }
    }
}

/// Where a rule looks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    /// Fixed locations (glob patterns, `~` allowed).
    Paths { patterns: Vec<String>, keep_newest: Option<usize> },
    /// A folder name found while walking, with a marker file next to it.
    Project { dir_name: String, sibling: Vec<String> },
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
            let target = match (m.path, m.dir_name) {
                (Some(p), None) => {
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
                    Target::Paths { patterns, keep_newest: m.keep_newest }
                }
                (None, Some(dir_name)) => {
                    if m.keep_newest.is_some() {
                        return Err(format!("rule `{id}`: `keep_newest` only works with `path`"));
                    }
                    Target::Project { dir_name, sibling: m.sibling }
                }
                _ => return Err(format!("rule `{id}`: match needs exactly one of `path` or `dir_name`")),
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
            Target::Paths { patterns: vec!["~/a".into(), "~/b".into()], keep_newest: None }
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
