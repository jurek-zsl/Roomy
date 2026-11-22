//! Known folders: a built-in list of what the big folders on a Mac are,
//! so Roomy can explain most of them at once, offline, without an AI.
//! The list is `rules/known.toml`; anyone can add to it, and a person can
//! add their own in `~/Library/Application Support/Roomy/known.toml`.

use glob::{MatchOptions, Pattern};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;

pub const BUILT_IN: &str = include_str!("../rules/known.toml");

/// The kinds the app understands (its `FolderKind`).
pub const KINDS: &[&str] = &["cache", "appData", "userFiles", "buildOutput", "aiModels", "toolchain", "installers", "logs", "system"];
pub const REGROWS: &[&str] = &["yes", "no", "unsure"];

/// What Roomy knows about one folder.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Known {
    /// A short name: "uv cache".
    pub name: String,
    /// The app or tool it belongs to: "uv".
    pub owner: String,
    /// One or two plain sentences on what it is.
    pub what: String,
    pub kind: String,
    /// Does it come back by itself when it's removed?
    pub regrows: String,
    /// The proper way to free it, when there is one ("uv cache clean").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub how: Option<String>,
    /// The folder is inside the known one, not the known one itself.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub inside: bool,
    /// Its owner is running right now (set when a folder is inspected).
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub running: bool,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Paths {
    One(String),
    Many(Vec<String>),
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    path: Paths,
    name: String,
    owner: String,
    what: String,
    kind: String,
    regrows: String,
    how: Option<String>,
    /// It says what the folder itself is, not what's inside it (your home, ~/Library).
    #[serde(default)]
    broad: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct File {
    #[serde(default)]
    folder: Vec<Entry>,
}

/// The loaded list, ready to look paths up in.
#[derive(Debug)]
pub struct Catalog {
    /// Each pattern, its entry, and whether it's a project pattern (`/**/name`).
    patterns: Vec<(Pattern, usize, bool)>,
    entries: Vec<Known>,
    /// Entries that don't explain the folders inside them.
    broad: Vec<bool>,
    /// Patterns whose last part is plain text, by that text.
    by_name: HashMap<String, Vec<usize>>,
    /// Patterns whose last part has a wildcard.
    wild: Vec<usize>,
}

const OPTS: MatchOptions = MatchOptions { case_sensitive: true, require_literal_separator: true, require_literal_leading_dot: false };

fn has_wildcard(s: &str) -> bool {
    s.contains(['*', '?', '['])
}

impl Catalog {
    /// Load lists in order; the first one that matches a folder wins, so a
    /// person's own list goes first.
    pub fn parse(texts: &[&str], home: &Path) -> Result<Catalog, String> {
        let mut c = Catalog { patterns: vec![], entries: vec![], broad: vec![], by_name: HashMap::new(), wild: vec![] };
        for text in texts {
            let file: File = toml::from_str(text).map_err(|e| e.to_string())?;
            for e in file.folder {
                if !KINDS.contains(&e.kind.as_str()) {
                    return Err(format!("{}: unknown kind \"{}\"", e.name, e.kind));
                }
                if !REGROWS.contains(&e.regrows.as_str()) {
                    return Err(format!("{}: regrows must be yes, no or unsure", e.name));
                }
                let paths = match e.path {
                    Paths::One(p) => vec![p],
                    Paths::Many(v) => v,
                };
                let idx = c.entries.len();
                c.broad.push(e.broad);
                c.entries.push(Known { name: e.name, owner: e.owner, what: e.what, kind: e.kind, regrows: e.regrows, how: e.how, inside: false, running: false });
                for p in paths {
                    let full = crate::rules::expand_home(&p, home).to_string_lossy().trim_end_matches('/').to_string();
                    let pat = Pattern::new(&full).map_err(|err| format!("{p}: {err}"))?;
                    let last = full.rsplit('/').next().unwrap_or_default().to_string();
                    let i = c.patterns.len();
                    c.patterns.push((pat, idx, p.starts_with("/**/")));
                    if has_wildcard(&last) {
                        c.wild.push(i);
                    } else {
                        c.by_name.entry(last).or_default().push(i);
                    }
                }
            }
        }
        Ok(c)
    }

    /// The built-in list, after the person's own one if they have it.
    pub fn standard(home: &Path) -> Catalog {
        let own = home.join("Library/Application Support/Roomy/known.toml");
        if let Ok(text) = std::fs::read_to_string(&own) {
            match Catalog::parse(&[&text, BUILT_IN], home) {
                Ok(c) => return c,
                Err(e) => eprintln!("warning: {} ignored: {e}", own.display()),
            }
        }
        Catalog::parse(&[BUILT_IN], home).expect("built-in known.toml parses")
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// The entry for exactly this folder.
    pub fn lookup(&self, path: &Path) -> Option<Known> {
        self.find(path, true).map(|i| self.entries[i].clone())
    }

    /// The winning entry's index. A specific path beats a project pattern
    /// like `/**/node_modules`, and a project pattern only counts outside
    /// installed tools, app data and macOS (a global npm package has its
    /// own node_modules, and that's not a project's build output).
    fn find(&self, path: &Path, projects: bool) -> Option<usize> {
        let name = path.file_name()?.to_string_lossy();
        let named = self.by_name.get(name.as_ref()).map(Vec::as_slice).unwrap_or(&[]);
        let mut hits: Vec<usize> =
            named.iter().chain(self.wild.iter()).copied().filter(|&i| self.patterns[i].0.matches_path_with(path, OPTS)).collect();
        hits.sort_unstable();
        if let Some(&i) = hits.iter().find(|&&i| !self.patterns[i].2) {
            return Some(self.patterns[i].1);
        }
        let i = *hits.first().filter(|_| projects)?;
        let inside_tool = path.ancestors().skip(1).filter_map(|a| self.find(a, false)).any(|e| {
            matches!(self.entries[e].kind.as_str(), "toolchain" | "appData" | "system" | "cache" | "aiModels")
        });
        (!inside_tool).then_some(self.patterns[i].1)
    }

    /// The entry for this folder, or for the nearest known folder it's in.
    pub fn lookup_within(&self, path: &Path) -> Option<Known> {
        if let Some(k) = self.lookup(path) {
            return Some(k);
        }
        // The nearest known folder above, unless it's a broad one like ~/Library.
        let i = path.ancestors().skip(1).find_map(|a| self.find(a, true))?;
        (!self.broad[i]).then(|| Known { inside: true, ..self.entries[i].clone() })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    const LIST: &str = r#"
[[folder]]
path = "~/.cache/uv"
name = "uv cache"
owner = "uv"
what = "Packages uv downloaded."
kind = "cache"
regrows = "yes"
how = "uv cache clean"

[[folder]]
path = ["~/Library/Developer/Xcode/DerivedData", "~/Library/Developer/Xcode/*.noindex"]
name = "Xcode build data"
owner = "Xcode"
what = "Builds and indexes."
kind = "buildOutput"
regrows = "yes"

[[folder]]
path = "/private/var/folders/*/*/C"
name = "Per-user caches"
owner = "macOS"
what = "Caches macOS keeps for you."
kind = "cache"
regrows = "yes"
"#;

    fn cat() -> Catalog {
        Catalog::parse(&[LIST], Path::new("/Users/me")).unwrap()
    }

    #[test]
    fn finds_exact_folders() {
        let c = cat();
        let uv = c.lookup(Path::new("/Users/me/.cache/uv")).unwrap();
        assert_eq!(uv.name, "uv cache");
        assert_eq!(uv.how.as_deref(), Some("uv cache clean"));
        assert!(!uv.inside);
        assert_eq!(c.lookup(Path::new("/Users/me/Library/Developer/Xcode/Products.noindex")).unwrap().owner, "Xcode");
        assert_eq!(c.lookup(Path::new("/private/var/folders/77/abc_0000gn/C")).unwrap().name, "Per-user caches");
        assert!(c.lookup(Path::new("/Users/me/.cache")).is_none());
        assert!(c.lookup(Path::new("/Users/other/.cache/uv")).is_none(), "~ is this home");
    }

    #[test]
    fn wildcards_stay_inside_one_folder() {
        let c = cat();
        assert!(c.lookup(Path::new("/private/var/folders/77/a/b/C")).is_none());
    }

    #[test]
    fn folders_inside_a_known_one() {
        let c = cat();
        let k = c.lookup_within(Path::new("/Users/me/.cache/uv/archive-v0/x")).unwrap();
        assert_eq!(k.name, "uv cache");
        assert!(k.inside);
        assert!(c.lookup_within(Path::new("/Users/me/Documents")).is_none());
    }

    #[test]
    fn project_patterns_skip_installed_tools() {
        let list = r#"
[[folder]]
path = "~/.npm-global"
name = "Global npm packages"
owner = "npm"
what = "Tools."
kind = "toolchain"
regrows = "no"

[[folder]]
path = "/**/node_modules"
name = "node_modules"
owner = "npm"
what = "Packages."
kind = "buildOutput"
regrows = "yes"

[[folder]]
path = "~/.npm-global/lib/node_modules"
name = "Global packages folder"
owner = "npm"
what = "Tools."
kind = "toolchain"
regrows = "no"
"#;
        let c = Catalog::parse(&[list], Path::new("/Users/me")).unwrap();
        assert_eq!(c.lookup(Path::new("/Users/me/code/app/node_modules")).unwrap().name, "node_modules");
        assert!(c.lookup(Path::new("/Users/me/.npm-global/lib/node_modules/x/node_modules")).is_none(), "part of an installed tool");
        assert_eq!(c.lookup(Path::new("/Users/me/.npm-global/lib/node_modules")).unwrap().name, "Global packages folder", "a specific path beats a pattern listed before it");
    }

    #[test]
    fn broad_folders_dont_explain_whats_inside() {
        let list = "[[folder]]\npath = \"~/Library/Application Support/*\"\nname = \"An app's data\"\nowner = \"An app\"\nwhat = \"x.\"\nkind = \"appData\"\nregrows = \"no\"\nbroad = true\n";
        let c = Catalog::parse(&[list], Path::new("/Users/me")).unwrap();
        assert_eq!(c.lookup(Path::new("/Users/me/Library/Application Support/Foo")).unwrap().name, "An app's data");
        assert!(c.lookup_within(Path::new("/Users/me/Library/Application Support/Foo/models")).is_none());
    }

    #[test]
    fn own_list_wins() {
        let own = "[[folder]]\npath = \"~/.cache/uv\"\nname = \"Mine\"\nowner = \"me\"\nwhat = \"x.\"\nkind = \"appData\"\nregrows = \"no\"\n";
        let c = Catalog::parse(&[own, LIST], Path::new("/Users/me")).unwrap();
        assert_eq!(c.lookup(Path::new("/Users/me/.cache/uv")).unwrap().name, "Mine");
    }

    #[test]
    fn rejects_bad_entries() {
        let bad = LIST.replacen("kind = \"cache\"", "kind = \"stuff\"", 1);
        assert!(Catalog::parse(&[&bad], Path::new("/h")).unwrap_err().contains("unknown kind"));
        let bad = LIST.replacen("regrows = \"yes\"", "regrows = \"maybe\"", 1);
        assert!(Catalog::parse(&[&bad], Path::new("/h")).is_err());
        let bad = LIST.replacen("owner = \"uv\"", "owner = \"uv\"\ncolour = \"red\"", 1);
        assert!(Catalog::parse(&[&bad], Path::new("/h")).is_err(), "typos in field names are caught");
    }

    #[test]
    fn built_in_list_is_sound() {
        let home = Path::new("/Users/me");
        let c = Catalog::parse(&[BUILT_IN], home).unwrap();
        assert!(c.len() >= 300, "only {} known folders", c.len());
        let file: File = toml::from_str(BUILT_IN).unwrap();
        let mut seen = HashSet::new();
        for e in &file.folder {
            assert!(e.what.ends_with('.'), "{}: what should be sentences", e.name);
            assert!(e.what.len() <= 260, "{}: what is too long", e.name);
            assert!(!e.name.is_empty() && !e.owner.is_empty(), "{}", e.name);
            if e.kind == "userFiles" {
                assert_eq!(e.regrows, "no", "{}: your files never come back", e.name);
            }
            let paths = match &e.path {
                Paths::One(p) => vec![p.clone()],
                Paths::Many(v) => v.clone(),
            };
            for p in paths {
                assert!(p == "~" || p.starts_with("~/") || p.starts_with('/'), "{p}: absolute or ~/");
                assert!(!p.ends_with('/'), "{p}: no trailing slash");
                assert!(seen.insert(p.clone()), "{p} is listed twice");
            }
        }
    }

    #[test]
    fn built_in_list_knows_the_usual_suspects() {
        let home = Path::new("/Users/me");
        let c = Catalog::parse(&[BUILT_IN], home).unwrap();
        for p in [
            "~/.cache/uv",
            "~/.cache/huggingface",
            "~/.ollama/models",
            "~/Library/Developer/Xcode/DerivedData",
            "~/Library/Developer/CoreSimulator/Devices",
            "~/Library/Containers/com.docker.docker",
            "~/.npm",
            "~/.cargo/registry",
            "~/.rustup/toolchains",
            "~/.gradle/caches",
            "~/Library/Caches/Homebrew",
            "/opt/homebrew/Cellar",
            "~/Library/Application Support/Claude/vm_bundles",
            "~/.local/share/claude/versions",
            "~/.codex/sessions",
            "~/.gemini/antigravity/conversations",
            "~/Library/Application Support/Google/Chrome",
            "~/Library/Application Support/Slack/Cache",
            "~/Library/Application Support/MobileSync/Backup",
            "/private/var/vm",
            "/System/Library/AssetsV2",
            "~/Library/Mail",
            "~/Library/Application Support/Steam/steamapps",
        ] {
            let path = crate::rules::expand_home(p, home);
            assert!(c.lookup(&path).is_some(), "{p} isn't known");
        }
    }
}
