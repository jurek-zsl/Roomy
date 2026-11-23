//! The JSON the app reads: `scan --json` and `clean --json`.
//! The app shows these decisions as they are and never works them out itself.

use crate::clean::{Method, Outcome, choose_method};
use crate::rules::Rule;
use crate::{Finding, Section};
use serde::Serialize;
use std::path::Path;

/// `scan --json`.
#[derive(Serialize)]
pub struct ScanDocument<'a> {
    pub free_bytes: Option<u64>,
    pub elapsed_ms: u64,
    pub findings: Vec<FindingJson<'a>>,
}

/// One finding plus what the report and the cleaner would do with it.
#[derive(Serialize)]
pub struct FindingJson<'a> {
    #[serde(flatten)]
    pub finding: &'a Finding,
    pub name: String,
    pub section: Section,
    /// What `clean` would do, without `--trash`.
    pub method: Method,
    /// What it would do with `--trash` ("Move to the Trash instead").
    pub trash_method: Method,
}

pub fn scan_document<'a>(
    findings: &'a [Finding],
    rules: &'a [Rule],
    free_bytes: Option<u64>,
    elapsed_ms: u64,
) -> ScanDocument<'a> {
    let findings = findings
        .iter()
        .map(|f| {
            let rule = rules.iter().find(|r| r.id == f.rule);
            FindingJson {
                finding: f,
                name: display_name(rule, f),
                section: f.section(),
                method: choose_method(f, rule, false),
                trash_method: choose_method(f, rule, true),
            }
        })
        .collect();
    ScanDocument {
        free_bytes,
        elapsed_ms,
        findings,
    }
}

/// The rule's name, with the app in front for per-app rules ("Claude web cache").
pub fn display_name(rule: Option<&Rule>, f: &Finding) -> String {
    if let Some(label) = &f.label {
        return label.clone();
    }
    let Some(rule) = rule else {
        return f.rule.clone();
    };
    if rule.checks.contains(&crate::rules::Check::AppNotRunning)
        && let Some(app) = crate::verify::app_owner(&f.path)
    {
        return format!("{app} {}", rule.name);
    }
    rule.name.clone()
}

/// `clean --json`: one of these per line, as it goes.
#[derive(Serialize)]
#[serde(tag = "event", rename_all = "kebab-case")]
pub enum CleanEvent<'a> {
    /// What's about to happen. `items` counts acted and skipped entries.
    Plan {
        items: usize,
        bytes: u64,
    },
    /// One item done (or skipped). `index` counts from 1 up to `items`.
    Item {
        index: usize,
        path: &'a Path,
        rule: &'a str,
        name: &'a str,
        bytes: u64,
        outcome: &'a Outcome,
    },
    Done {
        cleaned: usize,
        skipped: usize,
        failed: usize,
        free_before: Option<u64>,
        free_after: Option<u64>,
        trashed_bytes: u64,
    },
    Error {
        message: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clean::Outcome;
    use crate::rules::{Risk, Rule, Target};
    use crate::verify::Status;
    use crate::{Finding, fill_command};
    use std::path::{Path, PathBuf};

    fn rule(id: &str, risk: Risk, clean: &str) -> Rule {
        Rule {
            id: id.into(),
            name: format!("{id} name"),
            category: "c".into(),
            risk,
            explain: "e".into(),
            clean: Some(clean.into()),
            target: Target::Paths {
                patterns: vec![],
                keep_newest: None,
                older_than_days: None,
            },
            checks: vec![],
            command_only: false,
            auto: false,
        }
    }

    fn finding(r: &Rule, path: &str) -> Finding {
        Finding {
            rule: r.id.clone(),
            category: r.category.clone(),
            risk: r.risk,
            status: Status::Ready,
            reason: None,
            path: PathBuf::from(path),
            bytes_on_disk: 10,
            bytes_freed: 7,
            files: 1,
            clean: r.clean.as_deref().map(|t| fill_command(t, Path::new(path))),
            explain: r.explain.clone(),
            detail: None,
            label: None,
        }
    }

    #[test]
    fn scan_document_has_section_method_name() {
        let rules = vec![
            rule("old", Risk::Review, "rm -rf {path}"),
            rule("brew", Risk::Safe, "brew cleanup"),
        ];
        let found = vec![finding(&rules[0], "/h/old"), finding(&rules[1], "/h/brew")];
        let doc = scan_document(&found, &rules, Some(99), 1234);
        let v = serde_json::to_value(&doc).unwrap();
        assert_eq!(v["free_bytes"], 99);
        assert_eq!(v["elapsed_ms"], 1234);
        let f = &v["findings"];
        assert_eq!(f[0]["section"], "review");
        assert_eq!(f[0]["method"]["kind"], "trash");
        assert_eq!(f[0]["name"], "old name");
        assert_eq!(f[0]["bytes_freed"], 7);
        assert_eq!(f[1]["section"], "safe-now");
        assert_eq!(f[1]["method"]["kind"], "command");
        assert_eq!(f[1]["method"]["command"], "brew cleanup");
        assert_eq!(f[1]["trash_method"]["kind"], "trash");
    }

    #[test]
    fn clean_events_serialize() {
        let plan = serde_json::to_string(&CleanEvent::Plan { items: 2, bytes: 5 }).unwrap();
        assert_eq!(plan, r#"{"event":"plan","items":2,"bytes":5}"#);
        let out = Outcome::Skipped {
            reason: "busy".into(),
        };
        let item = CleanEvent::Item {
            index: 1,
            path: Path::new("/h/x"),
            rule: "r",
            name: "R",
            bytes: 3,
            outcome: &out,
        };
        let v = serde_json::to_value(&item).unwrap();
        assert_eq!(v["event"], "item");
        assert_eq!(v["outcome"]["result"], "skipped");
        assert_eq!(v["outcome"]["reason"], "busy");
        let done = CleanEvent::Done {
            cleaned: 1,
            skipped: 2,
            failed: 0,
            free_before: Some(1),
            free_after: None,
            trashed_bytes: 4,
        };
        let v = serde_json::to_value(&done).unwrap();
        assert_eq!(v["event"], "done");
        assert_eq!(v["trashed_bytes"], 4);
        let e = serde_json::to_value(&CleanEvent::Error {
            message: "x".into(),
        })
        .unwrap();
        assert_eq!(e["event"], "error");
    }

    #[test]
    fn per_app_rules_name_the_app() {
        let mut r = rule("electron-cache", Risk::Safe, "rm -rf {path}");
        r.name = "web cache".into();
        r.checks = vec![crate::rules::Check::AppNotRunning];
        let f = finding(&r, "/h/Library/Application Support/Claude/Code Cache");
        assert_eq!(display_name(Some(&r), &f), "Claude web cache");
    }
}
