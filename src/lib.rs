//! Mac Cleaner: finds space you can free, explains it, and says how to
//! clean it. This crate only scans. It never deletes anything.

pub mod clean;
pub mod json;
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
}

/// Find, measure and check everything. Sorted biggest first.
pub fn run(opts: &ScanOptions) -> Vec<Finding> {
    let mut cands = scan::path_candidates(&opts.rules, &opts.home);
    cands.extend(scan::project_candidates(&opts.rules, &opts.walk));
    let mut seen = HashSet::new();
    cands.retain(|c| seen.insert(c.path.clone()));

    let env = Env::capture();
    let mut findings: Vec<Finding> = cands
        .par_iter()
        .map(|c| {
            let r = &opts.rules[c.rule];
            let size = size::measure(&c.path);
            let verdict = verify::verify(&r.checks, &c.path, &env, &opts.home);
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
                clean: r.clean.as_deref().map(|t| fill_command(t, &c.path)),
                explain: r.explain.clone(),
            }
        })
        .filter(|f| f.bytes_on_disk > 0)
        .collect();
    findings.sort_by(|a, b| b.bytes_freed.cmp(&a.bytes_freed).then(a.path.cmp(&b.path)));
    findings
}

/// Fill `{path}` and `{parent}` in a clean command, shell-quoted.
pub fn fill_command(template: &str, path: &Path) -> String {
    let parent = path.parent().unwrap_or(Path::new("/"));
    template.replace("{path}", &shell_quote(path)).replace("{parent}", &shell_quote(parent))
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
    }
}
