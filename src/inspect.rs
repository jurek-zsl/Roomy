//! Clues about one folder, for a person or an AI to judge what it is:
//! what kinds of files it holds, when it last changed, its biggest items,
//! and which app or tool it belongs to (and whether that is still
//! installed). Read-only: nothing here changes the disk.

use crate::verify::Env;
use serde::Serialize;
use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct TypeShare {
    /// Lowercase extension without the dot; empty for files without one.
    pub ext: String,
    pub bytes: u64,
    pub files: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Item {
    pub name: String,
    pub bytes: u64,
    pub folder: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Owner {
    /// The app or tool the folder is named after ("Slack", "uv").
    pub name: String,
    /// "app" when it lives under Application Support and friends, "tool" for dot-folders.
    pub kind: String,
    /// The app was found (or not) on this Mac. For a tool, only a command
    /// with its name counts as found; not finding one proves nothing (the
    /// Hugging Face tool is `hf`), so then it's unknown.
    pub installed: Option<bool>,
    pub running: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct Clues {
    pub path: PathBuf,
    pub name: String,
    pub bytes: u64,
    pub files: u64,
    pub folders: u64,
    /// Days since anything inside last changed.
    pub newest_days: Option<u64>,
    /// Biggest file types, at most 8.
    pub types: Vec<TypeShare>,
    /// Biggest things directly inside, at most 10.
    pub biggest: Vec<Item>,
    pub owner: Option<Owner>,
    /// Plain-language facts that help tell what this is.
    pub markers: Vec<String>,
    /// What Roomy's list of known folders says it is (or the known folder it's in).
    pub known: Option<crate::known::Known>,
}

/// Where apps keep their data; the next path part names the app.
const APP_AREAS: &[&str] = &[
    "Application Support",
    "Caches",
    "Containers",
    "Group Containers",
    "Logs",
    "HTTPStorages",
    "WebKit",
];

/// Which app or tool a folder belongs to, going by where it is.
pub fn owner_name(path: &Path, home: &Path) -> Option<(String, &'static str)> {
    let rest = path.strip_prefix(home).ok()?;
    let parts: Vec<String> = rest
        .components()
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .collect();
    if parts.first().map(String::as_str) == Some("Library") {
        let i = parts.iter().position(|p| APP_AREAS.contains(&p.as_str()))?;
        return parts.get(i + 1).map(|n| (n.clone(), "app"));
    }
    let first = parts.first()?;
    if let Some(tool) = first.strip_prefix('.') {
        // ~/.cache/<tool>, ~/.local/share/<tool>, ~/.config/<tool>: the next part is the tool.
        let shared = matches!(tool, "cache" | "local" | "config");
        let name = if shared {
            parts
                .iter()
                .skip(1)
                .find(|p| *p != "share" && *p != "state")
                .cloned()?
        } else {
            tool.to_string()
        };
        return Some((name, "tool"));
    }
    None
}

fn squash(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect::<String>()
        .to_lowercase()
}

/// Is an app with this name (or bundle id) in the apps folder?
pub fn app_installed(name: &str, apps_dir: &Path) -> bool {
    // "com.tinyspeck.slackmacgap" → try "slackmacgap", "tinyspeck" and the whole thing.
    let mut wanted: Vec<String> = vec![squash(name)];
    if name.matches('.').count() >= 2 {
        wanted.extend(name.split('.').skip(1).map(squash));
    }
    wanted.retain(|w| w.len() >= 3);
    let Ok(rd) = fs::read_dir(apps_dir) else {
        return false;
    };
    rd.flatten().any(|e| {
        let file = e.file_name().to_string_lossy().into_owned();
        let Some(stem) = file.strip_suffix(".app") else {
            return false;
        };
        let app = squash(stem);
        app.len() >= 3
            && wanted
                .iter()
                .any(|w| app == *w || w.contains(&app) || app.contains(w.as_str()))
    })
}

/// Is a command with this name on the PATH?
pub fn command_installed(name: &str, path_var: &str) -> bool {
    !name.is_empty() && std::env::split_paths(path_var).any(|d| d.join(name).is_file())
}

/// Facts that help an AI tell what a folder is.
fn markers(
    root: &Path,
    types: &HashMap<String, (u64, u64)>,
    bytes: u64,
    names: &HashMap<String, u64>,
) -> Vec<String> {
    let mut out = Vec::new();
    let share = |exts: &[&str]| -> u64 {
        let b: u64 = exts.iter().filter_map(|e| types.get(*e)).map(|t| t.0).sum();
        if bytes == 0 { 0 } else { b * 100 / bytes }
    };
    let has = |n: &str| names.contains_key(n);
    if root.join(".git").is_dir() {
        out.push("It is a git repository.".into());
    }
    for (file, what) in [
        ("package.json", "a JavaScript project"),
        ("Cargo.toml", "a Rust project"),
        ("pyproject.toml", "a Python project"),
        ("Info.plist", "an app bundle part"),
    ] {
        if root.join(file).is_file() {
            out.push(format!("It has {file}, so it is {what}."));
        }
    }
    let models = share(&[
        "safetensors",
        "gguf",
        "bin",
        "pt",
        "pth",
        "onnx",
        "mlmodel",
        "ckpt",
    ]);
    if models >= 30 {
        out.push(format!("{models}% of it is AI model weight files (.safetensors, .gguf, .bin, ...); they download again when needed."));
    }
    let images = share(&["dmg", "iso", "img", "pkg", "xip", "zip"]);
    if images >= 30 {
        out.push(format!(
            "{images}% of it is installers, disk images or archives."
        ));
    }
    let dbs = share(&["sqlite", "db", "sqlite3", "realm", "ldb", "leveldb"]);
    if dbs >= 10 {
        out.push(format!("{dbs}% of it is databases, which usually hold the app's own data (messages, settings, history)."));
    }
    let logs = share(&["log", "trace", "crash", "ips"]);
    if logs >= 30 {
        out.push(format!("{logs}% of it is logs or crash reports."));
    }
    let media = share(&[
        "jpg", "jpeg", "png", "heic", "mov", "mp4", "mp3", "wav", "m4a", "pdf", "docx", "psd",
        "blend",
    ]);
    if media >= 30 {
        out.push(format!("{media}% of it is photos, videos, audio or documents, which may be the user's own files."));
    }
    let cachey: Vec<&str> = [
        "Cache",
        "Caches",
        "cache",
        "Code Cache",
        "GPUCache",
        "CachedData",
        "tmp",
        "temp",
        "Crashpad",
        "blob_storage",
    ]
    .into_iter()
    .filter(|n| has(n))
    .collect();
    if !cachey.is_empty() {
        out.push(format!(
            "It has cache or temp folders inside: {}.",
            cachey.join(", ")
        ));
    }
    out
}

/// Gather the clues for one folder. `now` and `apps_dir`/`path_var` make it testable.
pub fn inspect(
    path: &Path,
    home: &Path,
    apps_dir: &Path,
    path_var: &str,
    env: &Env,
    now: SystemTime,
) -> Option<Clues> {
    let md = fs::symlink_metadata(path).ok()?;
    if !md.is_dir() {
        return None;
    }
    let dev = md.dev();
    let mut types: HashMap<String, (u64, u64)> = HashMap::new();
    let mut names: HashMap<String, u64> = HashMap::new();
    let (mut bytes, mut files, mut folders) = (0u64, 0u64, 0u64);
    let mut newest: Option<SystemTime> = None;
    let mut top: HashMap<String, (u64, bool)> = HashMap::new();
    let mut stack: Vec<(PathBuf, Option<String>)> = vec![(path.to_path_buf(), None)];
    while let Some((dir, top_name)) = stack.pop() {
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        for e in rd.flatten() {
            let Ok(m) = e.metadata() else { continue };
            let name = e.file_name().to_string_lossy().into_owned();
            let here = top_name.clone().unwrap_or_else(|| name.clone());
            if let Ok(t) = m.modified() {
                newest = newest.max(Some(t));
            }
            if m.is_dir() {
                folders += 1;
                *names.entry(name).or_default() += 1;
                top.entry(here.clone()).or_insert((0, true));
                if m.dev() == dev && !m.file_type().is_symlink() {
                    stack.push((e.path(), Some(here)));
                }
            } else if m.is_file() {
                let b = m.blocks() * 512;
                bytes += b;
                files += 1;
                let ext = Path::new(&name)
                    .extension()
                    .map(|x| x.to_string_lossy().to_lowercase())
                    .unwrap_or_default();
                let t = types.entry(ext).or_default();
                t.0 += b;
                t.1 += 1;
                top.entry(here).or_insert((0, false)).0 += b;
            }
        }
    }
    let mut type_list: Vec<TypeShare> = types
        .iter()
        .map(|(ext, (b, n))| TypeShare {
            ext: ext.clone(),
            bytes: *b,
            files: *n,
        })
        .collect();
    type_list.sort_by(|a, b| b.bytes.cmp(&a.bytes).then(a.ext.cmp(&b.ext)));
    type_list.truncate(8);
    let mut biggest: Vec<Item> = top
        .into_iter()
        .map(|(name, (bytes, folder))| Item {
            name,
            bytes,
            folder,
        })
        .collect();
    biggest.sort_by(|a, b| b.bytes.cmp(&a.bytes).then(a.name.cmp(&b.name)));
    biggest.truncate(10);
    let owner = owner_name(path, home).map(|(name, kind)| {
        let installed = if kind == "app" {
            Some(app_installed(&name, apps_dir))
        } else {
            (command_installed(&name, path_var) || app_installed(&name, apps_dir)).then_some(true)
        };
        let running = env.is_running(&name);
        Owner {
            name,
            kind: kind.into(),
            installed,
            running,
        }
    });
    Some(Clues {
        name: path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default(),
        path: path.to_path_buf(),
        bytes,
        files,
        folders,
        newest_days: newest.map(|t| now.duration_since(t).unwrap_or_default().as_secs() / 86400),
        markers: markers(path, &types, bytes, &names),
        types: type_list,
        biggest,
        owner,
        known: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn file(p: &Path, n: usize) {
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, vec![1u8; n]).unwrap();
    }

    #[test]
    fn owners_from_location() {
        let h = Path::new("/Users/me");
        let o = |p: &str| owner_name(&h.join(p), h);
        assert_eq!(
            o("Library/Application Support/Slack/Cache"),
            Some(("Slack".into(), "app"))
        );
        assert_eq!(
            o("Library/Containers/com.tinyspeck.slackmacgap/Data"),
            Some(("com.tinyspeck.slackmacgap".into(), "app"))
        );
        assert_eq!(
            o(".cache/huggingface"),
            Some(("huggingface".into(), "tool"))
        );
        assert_eq!(o(".local/share/claude"), Some(("claude".into(), "tool")));
        assert_eq!(o(".rustup/toolchains"), Some(("rustup".into(), "tool")));
        assert_eq!(o("Documents/code"), None);
        assert_eq!(owner_name(Path::new("/opt/homebrew"), h), None);
    }

    #[test]
    fn finds_installed_apps_and_commands() {
        let apps = tempfile::tempdir().unwrap();
        fs::create_dir(apps.path().join("Slack.app")).unwrap();
        fs::create_dir(apps.path().join("Visual Studio Code.app")).unwrap();
        assert!(app_installed("Slack", apps.path()));
        assert!(
            app_installed("com.tinyspeck.slackmacgap", apps.path()),
            "bundle id part contains the app name"
        );
        assert!(!app_installed("Discord", apps.path()));
        assert!(!app_installed("x", apps.path()), "too short to match");
        let bin = tempfile::tempdir().unwrap();
        file(&bin.path().join("uv"), 1);
        let path_var = format!("/nonexistent:{}", bin.path().display());
        assert!(command_installed("uv", &path_var));
        assert!(!command_installed("pip", &path_var));
    }

    #[test]
    fn gathers_types_biggest_and_markers() {
        let home = tempfile::tempdir().unwrap();
        let h = home.path();
        let dir = h.join("Library/Application Support/Gone App");
        file(&dir.join("models/llama.gguf"), 600_000);
        file(&dir.join("Cache/a"), 100_000);
        file(&dir.join("Cache/b"), 100_000);
        file(&dir.join("state.sqlite"), 50_000);
        file(&dir.join("notes.txt"), 1_000);
        let apps = tempfile::tempdir().unwrap();
        let env = Env::from_parts(&[], &[]);
        let later = SystemTime::now() + Duration::from_secs(3 * 86400);
        let c = inspect(&dir, h, apps.path(), "", &env, later).unwrap();
        assert_eq!(c.name, "Gone App");
        assert_eq!(c.files, 5);
        assert_eq!(c.folders, 2);
        assert_eq!(c.newest_days, Some(3));
        assert_eq!(c.types[0].ext, "gguf");
        assert_eq!(c.types.iter().find(|t| t.ext == "txt").unwrap().files, 1);
        assert_eq!(
            c.biggest[0],
            Item {
                name: "models".into(),
                bytes: c.types[0].bytes,
                folder: true
            }
        );
        assert_eq!(c.biggest[1].name, "Cache");
        assert_eq!(
            c.owner,
            Some(Owner {
                name: "Gone App".into(),
                kind: "app".into(),
                installed: Some(false),
                running: false
            })
        );
        assert!(
            c.markers
                .iter()
                .any(|m| m.contains("AI model weight files")),
            "{:?}",
            c.markers
        );
        assert!(
            c.markers
                .iter()
                .any(|m| m == "It has cache or temp folders inside: Cache."),
            "{:?}",
            c.markers
        );
        assert!(
            inspect(&dir.join("notes.txt"), h, apps.path(), "", &env, later).is_none(),
            "files aren't inspected"
        );
    }

    #[test]
    fn missing_tool_command_is_unknown_not_uninstalled() {
        let home = tempfile::tempdir().unwrap();
        let dir = home.path().join(".cache/huggingface");
        file(&dir.join("x"), 10);
        let env = Env::from_parts(&[], &[]);
        let c = inspect(&dir, home.path(), home.path(), "", &env, SystemTime::now()).unwrap();
        assert_eq!(c.owner.unwrap().installed, None);
    }
}
