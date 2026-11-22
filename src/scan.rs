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
        let Target::Paths { patterns, keep_newest } = &r.target else { continue };
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
            let Ok(paths) = glob::glob(&full) else { continue };
            for p in paths.flatten() {
                let Ok(md) = fs::symlink_metadata(&p) else { continue };
                if md.file_type().is_symlink() {
                    continue;
                }
                found.push((p, md.modified().unwrap_or(SystemTime::UNIX_EPOCH)));
            }
        }
        if let Some(n) = keep_newest {
            found.sort_by(|a, b| b.1.cmp(&a.1));
            found.drain(..(*n).min(found.len()));
        }
        out.extend(found.into_iter().map(|(path, _)| Candidate { rule: i, path }));
    }
    out
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
const PRUNE_SUFFIX: &[&str] =
    &[".app", ".photoslibrary", ".framework", ".xcarchive", ".bundle", ".musiclibrary", ".tvlibrary", ".fcpbundle"];

struct ProjectRule<'a> {
    idx: usize,
    dir_name: &'a str,
    sibling: &'a [String],
}

struct Ctx<'a> {
    rules: Vec<ProjectRule<'a>>,
    opts: &'a WalkOptions,
}

/// Walk the roots in parallel and collect build folders. Once a folder
/// matches, it is not entered, so `node_modules` inside `node_modules` is
/// never reported twice. Does not cross into other volumes.
pub fn project_candidates(rules: &[Rule], opts: &WalkOptions) -> Vec<Candidate> {
    let project: Vec<ProjectRule> = rules
        .iter()
        .enumerate()
        .filter_map(|(idx, r)| match &r.target {
            Target::Project { dir_name, sibling } => {
                Some(ProjectRule { idx, dir_name: dir_name.as_str(), sibling: sibling.as_slice() })
            }
            _ => None,
        })
        .collect();
    if project.is_empty() {
        return Vec::new();
    }
    let ctx = Ctx { rules: project, opts };
    let out = Mutex::new(Vec::new());
    opts.roots.par_iter().for_each(|root| {
        if let Ok(md) = fs::metadata(root) {
            if md.is_dir() {
                walk(root, md.dev(), 0, &ctx, &out);
            }
        }
    });
    out.into_inner().unwrap()
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
    subdirs.par_iter().for_each(|name| {
        if depth == 0 && ctx.opts.skip_hidden_top && name.starts_with('.') {
            return;
        }
        let path = dir.join(name);
        if ctx.opts.skip.iter().any(|s| s == &path) {
            return;
        }
        let hit = ctx.rules.iter().find(|r| {
            r.dir_name == name.as_str() && (r.sibling.is_empty() || r.sibling.iter().any(|s| names.contains(s)))
        });
        if let Some(r) = hit {
            out.lock().unwrap().push(Candidate { rule: r.idx, path });
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
            .map(|c| (rules[c.rule].id.clone(), c.path.strip_prefix(root).unwrap().display().to_string()))
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
        let opts = WalkOptions { roots: vec![root.into()], skip: vec![], skip_hidden_top: true };
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
        let opts = WalkOptions { roots: vec![root.into()], skip: vec![root.join("Library")], skip_hidden_top: true };
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
            let when = SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_000_000 + i as u64 * 1000);
            fs::File::options().write(true).open(&p).unwrap().set_modified(when).unwrap();
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
}
