//! Finding candidates: fixed locations from path rules, and build folders
//! found by walking the user's folders.

use crate::rules::{Rule, Target, expand_home};
use rayon::prelude::*;
use std::collections::HashSet;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    /// Index into the rule list.
    pub rule: usize,
    pub path: PathBuf,
    /// Set when a finder produced this, with what it already knows.
    pub found: Option<crate::finders::Found>,
}

impl Candidate {
    pub fn new(rule: usize, path: PathBuf) -> Candidate {
        Candidate {
            rule,
            path,
            found: None,
        }
    }
}

/// Check every path rule's locations.
pub fn path_candidates(rules: &[Rule], home: &Path) -> Vec<Candidate> {
    path_candidates_in(rules, home, crate::rules::user_tmp_root().as_deref())
}

/// Like `path_candidates`, with the `$USERTMP` folder given (None skips those rules).
pub fn path_candidates_in(rules: &[Rule], home: &Path, user_tmp: Option<&Path>) -> Vec<Candidate> {
    let home_pat = glob::Pattern::escape(&home.to_string_lossy());
    let mut out = Vec::new();
    for (i, r) in rules.iter().enumerate() {
        let Target::Paths {
            patterns,
            keep_newest,
            older_than_days,
        } = &r.target
        else {
            continue;
        };
        let cutoff =
            older_than_days.map(|d| SystemTime::now() - std::time::Duration::from_secs(d * 86400));
        let mut found: Vec<(PathBuf, SystemTime)> = Vec::new();
        for pattern in patterns {
            let full = if let Some(rest) = pattern.strip_prefix("$USERTMP/") {
                let Some(t) = user_tmp else { continue };
                format!("{}/{rest}", glob::Pattern::escape(&t.to_string_lossy()))
            } else if let Some(rest) = pattern.strip_prefix("~/") {
                format!("{home_pat}/{rest}")
            } else {
                expand_home(pattern, home).to_string_lossy().into_owned()
            };
            let Ok(paths) = glob::glob(&full) else {
                continue;
            };
            for p in paths.flatten() {
                let Ok(md) = fs::symlink_metadata(&p) else {
                    continue;
                };
                if md.file_type().is_symlink() || is_roomys_own(&p, home) {
                    continue;
                }
                let modified = md.modified().unwrap_or(SystemTime::UNIX_EPOCH);
                if cutoff.is_some_and(|c| modified > c) {
                    continue;
                }
                found.push((p, modified));
            }
        }
        if let Some(n) = keep_newest {
            found.sort_by(|a, b| b.1.cmp(&a.1));
            found.drain(..(*n).min(found.len()));
        }
        out.extend(found.into_iter().map(|(path, _)| Candidate::new(i, path)));
    }
    out
}

/// Roomy's own logs (the record of what it cleaned), settings and cache.
pub fn is_roomys_own(path: &Path, home: &Path) -> bool {
    [
        "Library/Logs/Roomy",
        "Library/Application Support/Roomy",
        "Library/Caches/dev.roomy.app",
    ]
    .iter()
    .any(|own| path.starts_with(home.join(own)))
}

pub struct WalkOptions {
    pub roots: Vec<PathBuf>,
    /// Folders never entered (for example `~/Library`, which path rules cover).
    pub skip: Vec<PathBuf>,
    /// Skip hidden folders directly inside each root. Used for the home
    /// folder: `~/.npm-global/lib/node_modules` is installed tools, not junk.
    pub skip_hidden_top: bool,
}

/// Never descend into these: they are huge and never hold projects.
const PRUNE: &[&str] = &[".git", "node_modules", ".Trash", ".hg", ".svn"];
/// macOS packages that look like folders.
const PRUNE_SUFFIX: &[&str] = &[
    ".app",
    ".photoslibrary",
    ".framework",
    ".xcarchive",
    ".bundle",
    ".musiclibrary",
    ".tvlibrary",
    ".fcpbundle",
];

struct ProjectRule<'a> {
    idx: usize,
    dir_name: &'a str,
    sibling: &'a [String],
}

struct Ctx<'a> {
    rules: Vec<ProjectRule<'a>>,
    opts: &'a WalkOptions,
    repos: Option<Mutex<Vec<PathBuf>>>,
}

/// What a walk of the user's folders found.
#[derive(Debug, Default)]
pub struct Walked {
    pub candidates: Vec<Candidate>,
    /// Folders with a `.git` folder inside (only when asked for).
    pub repos: Vec<PathBuf>,
}

/// Walk the roots in parallel and collect build folders. Once a folder
/// matches, it is not entered, so `node_modules` inside `node_modules` is
/// never reported twice. Does not cross into other volumes.
pub fn project_candidates(rules: &[Rule], opts: &WalkOptions) -> Vec<Candidate> {
    walk_projects(rules, opts, false).candidates
}

/// Walk once for build folders and, with `want_repos`, git repos too.
pub fn walk_projects(rules: &[Rule], opts: &WalkOptions, want_repos: bool) -> Walked {
    let project: Vec<ProjectRule> = rules
        .iter()
        .enumerate()
        .filter_map(|(idx, r)| match &r.target {
            Target::Project { dir_name, sibling } => Some(ProjectRule {
                idx,
                dir_name: dir_name.as_str(),
                sibling: sibling.as_slice(),
            }),
            _ => None,
        })
        .collect();
    if project.is_empty() && !want_repos {
        return Walked::default();
    }
    let ctx = Ctx {
        rules: project,
        opts,
        repos: want_repos.then(|| Mutex::new(Vec::new())),
    };
    let out = Mutex::new(Vec::new());
    opts.roots.par_iter().for_each(|root| {
        if let Ok(md) = fs::metadata(root) {
            if md.is_dir() {
                walk(root, md.dev(), 0, &ctx, &out);
            }
        }
    });
    let mut repos = ctx
        .repos
        .map(|r| r.into_inner().unwrap())
        .unwrap_or_default();
    repos.sort();
    Walked {
        candidates: out.into_inner().unwrap(),
        repos,
    }
}

fn walk(dir: &Path, dev: u64, depth: usize, ctx: &Ctx, out: &Mutex<Vec<Candidate>>) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    let mut names = HashSet::new();
    let mut subdirs = Vec::new();
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        // DirEntry::file_type does not follow symlinks, so linked folders are skipped.
        if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            subdirs.push(name.clone());
        }
        names.insert(name);
    }
    if let Some(repos) = &ctx.repos {
        if names.contains(".git") && dir.join(".git").is_dir() {
            repos.lock().unwrap().push(dir.to_path_buf());
        }
    }
    subdirs.par_iter().for_each(|name| {
        if depth == 0 && ctx.opts.skip_hidden_top && name.starts_with('.') {
            return;
        }
        let path = dir.join(name);
        if ctx.opts.skip.iter().any(|s| s == &path) {
            return;
        }
        let hit = ctx.rules.iter().find(|r| {
            r.dir_name == name.as_str()
                && (r.sibling.is_empty() || r.sibling.iter().any(|s| names.contains(s)))
        });
        if let Some(r) = hit {
            out.lock().unwrap().push(Candidate::new(r.idx, path));
            return;
        }
        if PRUNE.contains(&name.as_str()) || PRUNE_SUFFIX.iter().any(|s| name.ends_with(s)) {
            return;
        }
        match fs::symlink_metadata(&path) {
            Ok(md) if md.dev() == dev => walk(&path, dev, depth + 1, ctx, out),
            _ => {}
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rules::parse_rules;

    fn rules() -> Vec<Rule> {
        parse_rules(
            r#"
[[rule]]
id = "rust-target"
category = "build-output"
risk = "safe"
explain = "e"
match = { dir_name = "target", sibling = ["Cargo.toml"] }

[[rule]]
id = "node-modules"
category = "build-output"
risk = "safe"
explain = "e"
match = { dir_name = "node_modules", sibling = ["package.json"] }

[[rule]]
id = "old-bin"
category = "leftover"
risk = "safe"
explain = "e"
match = { path = "~/bin/*.old" }

[[rule]]
id = "versions"
category = "leftover"
risk = "review"
explain = "e"
match = { path = "~/versions/*", keep_newest = 2 }
"#,
        )
        .unwrap()
    }

    fn mk(p: &Path) {
        fs::create_dir_all(p).unwrap();
    }
    fn touch(p: &Path) {
        fs::write(p, b"x").unwrap();
    }

    fn ids(rules: &[Rule], c: &[Candidate], root: &Path) -> Vec<(String, String)> {
        let mut v: Vec<_> = c
            .iter()
            .map(|c| {
                (
                    rules[c.rule].id.clone(),
                    c.path.strip_prefix(root).unwrap().display().to_string(),
                )
            })
            .collect();
        v.sort();
        v
    }

    #[test]
    fn finds_build_folders_only_next_to_marker() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path();
        mk(&root.join("rusty/target/debug"));
        touch(&root.join("rusty/Cargo.toml"));
        mk(&root.join("notrust/target")); // no Cargo.toml: someone's real folder
        mk(&root.join("web/node_modules/dep/node_modules")); // nested: report once
        touch(&root.join("web/package.json"));
        mk(&root.join(".hidden/tool/node_modules")); // hidden at top: skipped
        touch(&root.join(".hidden/tool/package.json"));

        let r = rules();
        let opts = WalkOptions {
            roots: vec![root.into()],
            skip: vec![],
            skip_hidden_top: true,
        };
        let found = project_candidates(&r, &opts);
        assert_eq!(
            ids(&r, &found, root),
            vec![
                ("node-modules".into(), "web/node_modules".into()),
                ("rust-target".into(), "rusty/target".into()),
            ]
        );
    }

    #[test]
    fn skip_list_is_respected() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path();
        mk(&root.join("Library/x/target"));
        touch(&root.join("Library/x/Cargo.toml"));
        let r = rules();
        let opts = WalkOptions {
            roots: vec![root.into()],
            skip: vec![root.join("Library")],
            skip_hidden_top: true,
        };
        assert!(project_candidates(&r, &opts).is_empty());
    }

    #[test]
    fn path_rules_glob_and_keep_newest() {
        let t = tempfile::tempdir().unwrap();
        let home = t.path();
        mk(&home.join("bin"));
        touch(&home.join("bin/tool"));
        touch(&home.join("bin/tool.123.old"));
        mk(&home.join("versions"));
        for (i, v) in ["1.0", "1.1", "1.2", "1.3"].iter().enumerate() {
            let p = home.join("versions").join(v);
            touch(&p);
            let when = SystemTime::UNIX_EPOCH
                + std::time::Duration::from_secs(1_000_000 + i as u64 * 1000);
            fs::File::options()
                .write(true)
                .open(&p)
                .unwrap()
                .set_modified(when)
                .unwrap();
        }
        let r = rules();
        let found = path_candidates(&r, home);
        assert_eq!(
            ids(&r, &found, home),
            vec![
                ("old-bin".into(), "bin/tool.123.old".into()),
                ("versions".into(), "versions/1.0".into()),
                ("versions".into(), "versions/1.1".into()),
            ]
        );
    }

    #[test]
    fn user_tmp_patterns_expand() {
        let home = tempfile::tempdir().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(tmp.path().join("C/clang/ModuleCache")).unwrap();
        let rules = crate::rules::parse_rules(
            r#"
[[rule]]
id = "clang"
category = "c"
risk = "safe"
explain = "e"
match = { path = "$USERTMP/C/clang/ModuleCache" }
"#,
        )
        .unwrap();
        let c = path_candidates_in(&rules, home.path(), Some(tmp.path()));
        assert_eq!(c.len(), 1);
        assert_eq!(c[0].path, tmp.path().join("C/clang/ModuleCache"));
        assert!(path_candidates_in(&rules, home.path(), None).is_empty());
    }

    #[test]
    fn never_offers_roomys_own_folders() {
        let home = tempfile::tempdir().unwrap();
        for d in ["Library/Logs/Roomy", "Library/Logs/Other"] {
            mk(&home.path().join(d));
        }
        let rules = parse_rules(
            r#"
[[rule]]
id = "logs"
category = "c"
risk = "safe"
explain = "e"
match = { path = "~/Library/Logs/*" }
"#,
        )
        .unwrap();
        let found: Vec<_> = path_candidates_in(&rules, home.path(), None)
            .into_iter()
            .map(|c| c.path)
            .collect();
        assert_eq!(found, [home.path().join("Library/Logs/Other")]);
    }

    #[test]
    fn older_than_days_skips_new_files() {
        let home = tempfile::tempdir().unwrap();
        let dl = home.path().join("Downloads");
        mk(&dl);
        for f in ["old.dmg", "new.dmg"] {
            touch(&dl.join(f));
        }
        let old = SystemTime::now() - std::time::Duration::from_secs(30 * 86400);
        fs::File::options()
            .write(true)
            .open(dl.join("old.dmg"))
            .unwrap()
            .set_modified(old)
            .unwrap();
        let rules = parse_rules(
            r#"
[[rule]]
id = "dmg"
category = "c"
risk = "review"
explain = "e"
match = { path = "~/Downloads/*.dmg", older_than_days = 14 }
"#,
        )
        .unwrap();
        let c = path_candidates_in(&rules, home.path(), None);
        assert_eq!(
            c.iter().map(|c| c.path.clone()).collect::<Vec<_>>(),
            vec![dl.join("old.dmg")]
        );
    }

    #[test]
    fn walk_collects_repos() {
        let d = tempfile::tempdir().unwrap();
        let root = d.path();
        mk(&root.join("code/a/.git"));
        mk(&root.join("code/a/sub/.git"));
        mk(&root.join("code/b"));
        touch(&root.join("code/b/.git"));
        let opts = WalkOptions {
            roots: vec![root.to_path_buf()],
            skip: vec![],
            skip_hidden_top: true,
        };
        let w = walk_projects(&rules(), &opts, true);
        assert_eq!(
            w.repos,
            [root.join("code/a"), root.join("code/a/sub")],
            "a .git file is a worktree, not a repo"
        );
        assert!(walk_projects(&rules(), &opts, false).repos.is_empty());
    }

    /// The app writes user rules for exact folders with glob characters
    /// escaped as `[x]`; such a pattern must match that folder only.
    #[test]
    fn escaped_patterns_match_one_folder() {
        let home = tempfile::tempdir().unwrap();
        mk(&home.path().join("a [b] *c?"));
        mk(&home.path().join("a b xcy"));
        let rules = parse_rules(
            r#"
[[rule]]
id = "user-x"
category = "ai"
risk = "review"
explain = "e"
match = { path = "~/a [[]b[]] [*]c[?]" }
"#,
        )
        .unwrap();
        let c = path_candidates_in(&rules, home.path(), None);
        assert_eq!(
            c.iter().map(|c| c.path.clone()).collect::<Vec<_>>(),
            vec![home.path().join("a [b] *c?")]
        );
    }
}
