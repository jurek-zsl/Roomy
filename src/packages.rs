//! Things package managers installed: Homebrew formulae and casks, and
//! global npm, uv and pipx tools. Each is removed with its own manager's
//! uninstall command, so the manager's records stay right, and Homebrew
//! packages other packages need are never offered.

use crate::finders::{ToolInstall, npm_tools, pipx_tools, uv_tools};
use rayon::prelude::*;
use serde::Serialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Package {
    /// brew, cask, npm, uv or pipx.
    pub manager: String,
    pub name: String,
    pub version: Option<String>,
    pub description: Option<String>,
    pub path: PathBuf,
    pub bytes: u64,
    /// You installed it yourself (not only as something else's dependency).
    pub requested: bool,
    /// Installed packages that need this one; while any do, it stays.
    pub needed_by: Vec<String>,
    /// Days since one of its commands last ran, when that can be told.
    pub last_used_days: Option<u64>,
    /// Apps a cask put in /Applications; they're part of its size.
    pub apps: Vec<PathBuf>,
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct Packages {
    pub packages: Vec<Package>,
    /// Dependencies nothing needs anymore (`brew autoremove --dry-run`).
    pub autoremove: Vec<String>,
}

/// The command that removes one package, as program and arguments.
pub fn uninstall_command(manager: &str, name: &str) -> Option<Vec<String>> {
    let args: &[&str] = match manager {
        "brew" => &["brew", "uninstall"],
        "cask" => &["brew", "uninstall", "--cask"],
        "npm" => &["npm", "uninstall", "-g"],
        "uv" => &["uv", "tool", "uninstall"],
        "pipx" => &["pipx", "uninstall"],
        _ => return None,
    };
    // A name is one word; anything else can't be a package.
    if name.is_empty() || name.starts_with('-') || !name.chars().all(|c| c.is_ascii_alphanumeric() || "@/._+-".contains(c)) {
        return None;
    }
    Some(args.iter().map(|s| s.to_string()).chain([name.to_string()]).collect())
}

/// Homebrew's packages from `brew info --json=v2 --installed`.
pub fn brew(info_json: &str, prefix: &Path) -> Vec<Package> {
    let v: serde_json::Value = serde_json::from_str(info_json).unwrap_or_default();
    let empty = vec![];
    let formulae = v["formulae"].as_array().unwrap_or(&empty);
    let casks = v["casks"].as_array().unwrap_or(&empty);
    // Who needs whom: invert every installed package's direct dependencies.
    let mut needed_by: HashMap<String, Vec<String>> = HashMap::new();
    for f in formulae {
        let me = f["name"].as_str().unwrap_or_default();
        for d in f["dependencies"].as_array().unwrap_or(&empty).iter().filter_map(|d| d.as_str()) {
            needed_by.entry(d.to_string()).or_default().push(me.to_string());
        }
    }
    for c in casks {
        let me = c["token"].as_str().unwrap_or_default();
        for d in c["depends_on"]["formula"].as_array().unwrap_or(&empty).iter().filter_map(|d| d.as_str()) {
            needed_by.entry(d.to_string()).or_default().push(me.to_string());
        }
    }
    let mut out: Vec<Package> = formulae
        .iter()
        .filter_map(|f| {
            let name = f["name"].as_str()?.to_string();
            let installed = f["installed"].as_array()?.last()?;
            let mut needs = needed_by.remove(&name).unwrap_or_default();
            needs.sort();
            Some(Package {
                manager: "brew".into(),
                version: installed["version"].as_str().map(String::from),
                description: f["desc"].as_str().map(String::from),
                path: prefix.join("Cellar").join(&name),
                bytes: 0,
                requested: installed["installed_on_request"].as_bool().unwrap_or(false),
                needed_by: needs,
                last_used_days: None,
                apps: vec![],
                name,
            })
        })
        .collect();
    out.extend(casks.iter().filter_map(|c| {
        let name = c["token"].as_str()?.to_string();
        Some(Package {
            manager: "cask".into(),
            version: c["installed"].as_str().map(String::from),
            description: c["desc"].as_str().or_else(|| c["name"][0].as_str()).map(String::from),
            path: prefix.join("Caskroom").join(&name),
            bytes: 0,
            requested: true,
            needed_by: vec![],
            last_used_days: None,
            apps: c["artifacts"]
                .as_array()
                .unwrap_or(&empty)
                .iter()
                .filter_map(|a| a["app"].as_array())
                .flatten()
                .filter_map(|a| a.as_str())
                .map(|a| PathBuf::from("/Applications").join(a))
                .collect(),
            name,
        })
    }));
    out
}

/// Global tools of npm, uv and pipx, with when their commands last ran.
pub fn tools(manager: &str, found: &[ToolInstall], now: SystemTime) -> Vec<Package> {
    found
        .iter()
        .map(|t| {
            let last = t.commands.iter().filter_map(|c| std::fs::metadata(c).ok()?.accessed().ok()).max();
            Package {
                manager: manager.into(),
                name: t.name.clone(),
                version: None,
                description: Some(format!("Commands: {}", t.names.join(", "))),
                path: t.dir.clone(),
                bytes: 0,
                requested: true,
                needed_by: vec![],
                last_used_days: last.map(|l| now.duration_since(l).unwrap_or_default().as_secs() / 86400),
                apps: vec![],
            }
        })
        .collect()
}

/// The names `brew autoremove --dry-run` would remove.
pub fn autoremove_names(dry_run: &str) -> Vec<String> {
    let mut lines = dry_run.lines().skip_while(|l| !l.starts_with("==>"));
    lines.next();
    lines.map(str::trim).filter(|l| !l.is_empty() && !l.starts_with("==>")).map(String::from).collect()
}

/// Everything installed, measured. Runs the managers that are installed.
pub fn list() -> Packages {
    let now = SystemTime::now();
    let mut out = Packages::default();
    if let Some(prefix) = crate::tool_output("brew", &["--prefix"]) {
        let info = std::process::Command::new("brew").args(["info", "--json=v2", "--installed"]).output();
        if let Ok(o) = info {
            out.packages.extend(brew(&String::from_utf8_lossy(&o.stdout), Path::new(&prefix)));
        }
        if let Ok(o) = std::process::Command::new("brew").args(["autoremove", "--dry-run"]).output() {
            out.autoremove = autoremove_names(&String::from_utf8_lossy(&o.stdout));
        }
    }
    if let Some(root) = crate::tool_output("npm", &["root", "-g"]) {
        out.packages.extend(tools("npm", &npm_tools(Path::new(&root)), now));
    }
    if let Some(dir) = crate::tool_output("uv", &["tool", "dir"]) {
        out.packages.extend(tools("uv", &uv_tools(Path::new(&dir)), now));
    }
    if let Some(dir) = crate::tool_output("pipx", &["environment", "--value", "PIPX_LOCAL_VENVS"]) {
        out.packages.extend(tools("pipx", &pipx_tools(Path::new(&dir)), now));
    }
    out.packages.par_iter_mut().for_each(|p| {
        p.bytes = std::iter::once(&p.path).chain(&p.apps).map(|x| crate::size::measure(x).on_disk).sum();
    });
    out.packages.sort_by(|a, b| b.bytes.cmp(&a.bytes).then(a.name.cmp(&b.name)));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const INFO: &str = r#"{"formulae":[
      {"name":"llvm","desc":"Compilers","dependencies":["z3"],"installed":[{"version":"23.1","installed_on_request":true}]},
      {"name":"z3","desc":"Solver","dependencies":[],"installed":[{"version":"4.15","installed_on_request":false}]},
      {"name":"ffmpeg","desc":"Video","dependencies":["z3"],"installed":[{"version":"8.0","installed_on_request":true}]}
    ],"casks":[{"token":"iterm2","name":["iTerm2"],"desc":null,"installed":"3.6","depends_on":{},"artifacts":[{"app":["iTerm.app"]},{"zap":[]}]}]}"#;

    #[test]
    fn reads_homebrew_and_who_needs_what() {
        let p = brew(INFO, Path::new("/opt/homebrew"));
        assert_eq!(p.len(), 4);
        let z3 = p.iter().find(|x| x.name == "z3").unwrap();
        assert_eq!(z3.needed_by, ["ffmpeg", "llvm"]);
        assert!(!z3.requested);
        let llvm = p.iter().find(|x| x.name == "llvm").unwrap();
        assert!(llvm.requested && llvm.needed_by.is_empty());
        assert_eq!(llvm.path, PathBuf::from("/opt/homebrew/Cellar/llvm"));
        let cask = p.iter().find(|x| x.manager == "cask").unwrap();
        assert_eq!((cask.name.as_str(), cask.description.as_deref()), ("iterm2", Some("iTerm2")));
        assert_eq!(cask.path, PathBuf::from("/opt/homebrew/Caskroom/iterm2"));
        assert_eq!(cask.apps, [PathBuf::from("/Applications/iTerm.app")]);
        assert!(brew("not json", Path::new("/x")).is_empty());
    }

    #[test]
    fn uninstall_commands_take_only_plain_names() {
        assert_eq!(uninstall_command("cask", "iterm2").unwrap(), ["brew", "uninstall", "--cask", "iterm2"]);
        assert_eq!(uninstall_command("npm", "@slidev/cli").unwrap(), ["npm", "uninstall", "-g", "@slidev/cli"]);
        assert_eq!(uninstall_command("uv", "docling").unwrap(), ["uv", "tool", "uninstall", "docling"]);
        assert!(uninstall_command("brew", "--force").is_none());
        assert!(uninstall_command("brew", "a b").is_none());
        assert!(uninstall_command("brew", "x;rm").is_none());
        assert!(uninstall_command("apt", "x").is_none());
    }

    #[test]
    fn reads_autoremove_dry_run() {
        let out = "==> Would autoremove 2 unneeded formulae:\nlibfoo\nlibbar\n";
        assert_eq!(autoremove_names(out), ["libfoo", "libbar"]);
        assert!(autoremove_names("").is_empty());
    }
}
