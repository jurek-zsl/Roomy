//! Finders: built-in code for things a path pattern can't find. Apps you
//! stopped opening, projects you stopped working on, simulator runtimes
//! nothing uses. Each one only finds and explains; the usual checks and the
//! cleaner's guard still decide what can be touched.

use crate::verify::{Env, project_last_touched};
use rayon::prelude::*;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// What a finder found, on top of the path.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Found {
    pub path: PathBuf,
    /// A name for this one item ("iOS 27.2 Simulator runtime").
    pub label: Option<String>,
    /// Size when the finder already knows it (simulator runtimes); otherwise
    /// the folder is measured like any other.
    pub bytes: Option<u64>,
    /// One or two sentences of context ("Last opened 7 months ago.").
    pub detail: Option<String>,
    /// Fills `{id}` in the rule's clean command.
    pub id: Option<String>,
    /// Why it can't be cleaned right now.
    pub blocked: Option<String>,
}

const DAY: u64 = 86400;

fn days_since(t: SystemTime, now: SystemTime) -> u64 {
    now.duration_since(t).unwrap_or_default().as_secs() / DAY
}

/// "3 days", "5 months", "2 years".
pub fn span(days: u64) -> String {
    let (n, unit) = match days {
        0..=1 => return "a day".into(),
        2..=59 => (days, "day"),
        60..=729 => (days / 30, "month"),
        _ => (days / 365, "year"),
    };
    format!("{n} {unit}{}", if n == 1 { "" } else { "s" })
}

// ---------------------------------------------------------------- apps

/// What Spotlight knows about an app.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AppUsage {
    pub last_used: Option<SystemTime>,
    pub added: Option<SystemTime>,
}

/// Apps directly in `apps_dir` not opened for `idle_days`. An app never
/// opened counts from the day it was added. Apps with no dates at all are
/// left alone: we can't tell, so we don't guess.
pub fn unused_apps(
    apps_dir: &Path,
    usage: &dyn Fn(&[PathBuf]) -> Vec<AppUsage>,
    env: &Env,
    now: SystemTime,
    idle_days: u64,
) -> Vec<Found> {
    let Ok(rd) = fs::read_dir(apps_dir) else { return Vec::new() };
    let mut apps: Vec<PathBuf> = rd
        .flatten()
        .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "app"))
        .collect();
    apps.sort();
    let info = usage(&apps);
    apps.into_iter()
        .zip(info)
        .filter_map(|(path, u)| {
            let name = path.file_stem()?.to_string_lossy().into_owned();
            if name == "Roomy" {
                return None;
            }
            let detail = match (u.last_used, u.added) {
                (Some(t), _) if days_since(t, now) >= idle_days => {
                    format!("Last opened {} ago.", span(days_since(t, now)))
                }
                (None, Some(t)) if days_since(t, now) >= idle_days => {
                    format!("Never opened since it was installed {} ago.", span(days_since(t, now)))
                }
                _ => return None,
            };
            let bundle = format!("{}/", path.to_string_lossy().to_lowercase());
            let running = env.is_running(&name) || env.args.iter().any(|a| a.to_lowercase().starts_with(&bundle));
            Some(Found {
                label: Some(name.clone()),
                detail: Some(format!("{detail} Its settings stay, so it works the same if you install it again.")),
                blocked: running.then(|| format!("{name} is open")),
                path,
                ..Found::default()
            })
        })
        .collect()
}

/// Ask Spotlight (`mdls`) when each app was last opened and added.
pub fn spotlight_usage(apps: &[PathBuf]) -> Vec<AppUsage> {
    let read = |attr: &str| -> Vec<Option<SystemTime>> {
        if apps.is_empty() {
            return Vec::new();
        }
        let out = Command::new("mdls").args(["-raw", "-nullMarker", "-", "-name", attr]).args(apps).stderr(Stdio::null()).output();
        let text = out.map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default();
        let mut v: Vec<Option<SystemTime>> = text.split('\0').map(parse_mdls_date).collect();
        v.resize(apps.len(), None);
        v
    };
    let used = read("kMDItemLastUsedDate");
    let added = read("kMDItemDateAdded");
    used.into_iter().zip(added).map(|(last_used, added)| AppUsage { last_used, added }).collect()
}

/// "2026-11-17 21:27:51 +0000" → time. Anything else → None.
fn parse_mdls_date(s: &str) -> Option<SystemTime> {
    let s = s.trim();
    if s.len() < 19 || !s.ends_with("+0000") {
        return None;
    }
    parse_utc(&s[..10], &s[11..19])
}

/// ISO 8601 like "2026-01-10T12:00:00Z" → time.
fn parse_iso(s: &str) -> Option<SystemTime> {
    let s = s.trim();
    if s.len() < 19 {
        return None;
    }
    parse_utc(&s[..10], &s[11..19])
}

fn parse_utc(date: &str, time: &str) -> Option<SystemTime> {
    let d: Vec<i64> = date.split('-').map(|x| x.parse().ok()).collect::<Option<_>>()?;
    let t: Vec<u64> = time.split(':').map(|x| x.parse().ok()).collect::<Option<_>>()?;
    if d.len() != 3 || t.len() != 3 {
        return None;
    }
    // Days from 1970-01-01 (Howard Hinnant's days_from_civil).
    let (y, m, day) = (if d[1] <= 2 { d[0] - 1 } else { d[0] }, d[1], d[2]);
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    let secs = u64::try_from(days).ok()? * DAY + t[0] * 3600 + t[1] * 60 + t[2];
    Some(UNIX_EPOCH + Duration::from_secs(secs))
}

// ---------------------------------------------------------------- git

fn git(repo: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git").arg("-C").arg(repo).args(args).stderr(Stdio::null()).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Ignored files that are plainly build output or junk; anything else that
/// git ignores (like `.env`) is not on the remote and is called out.
const REBUILDABLE: &[&str] = &[
    "node_modules", "target", ".build", "build", "dist", ".next", ".nuxt", ".svelte-kit", ".turbo", ".venv", "venv",
    "Pods", ".gradle", ".godot", "__pycache__", ".parcel-cache", ".DS_Store", "DerivedData", ".cache",
];

/// `https://user:token@github.com/a/b.git` → `github.com/a/b`.
fn clean_remote(url: &str) -> String {
    let s = url.trim();
    let s = s.split_once("://").map(|(_, r)| r).unwrap_or(s);
    let s = s.rsplit_once('@').map(|(_, r)| r).unwrap_or(s);
    let s = s.replacen(':', "/", if s.contains('/') && !s.contains(":/") && s.find(':') < s.find('/') { 1 } else { 0 });
    s.trim_end_matches(".git").trim_end_matches('/').to_string()
}

/// Whole git projects with no commit and no edits for `idle_days`, where
/// everything is safely on a remote: a clean working tree, no unpushed
/// commits, no stashes. You can clone them again any time.
pub fn stale_projects(repos: &[PathBuf], now: SystemTime, idle_days: u64) -> Vec<Found> {
    repos
        .par_iter()
        .filter_map(|repo| {
            let last: u64 = git(repo, &["log", "-1", "--format=%ct"])?.parse().ok()?;
            let commit_days = days_since(UNIX_EPOCH + Duration::from_secs(last), now);
            if commit_days < idle_days {
                return None;
            }
            let touched = project_last_touched(&repo.join(".git")).map(|t| days_since(t, now)).unwrap_or(commit_days);
            if touched < idle_days {
                return None;
            }
            if !git(repo, &["status", "--porcelain"])?.is_empty() {
                return None;
            }
            if git(repo, &["rev-list", "--branches", "--not", "--remotes", "--count"])? != "0" {
                return None;
            }
            if !git(repo, &["stash", "list"])?.is_empty() {
                return None;
            }
            let remote = git(repo, &["remote"])?;
            let name = remote.lines().find(|r| *r == "origin").or_else(|| remote.lines().next())?.to_string();
            let url = git(repo, &["remote", "get-url", &name]).map(|u| clean_remote(&u)).unwrap_or(name);
            let ignored = git(repo, &["ls-files", "--others", "--ignored", "--exclude-standard", "--directory"])
                .unwrap_or_default();
            let mut extra: Vec<String> = ignored
                .lines()
                .map(|l| l.trim_end_matches('/'))
                .filter(|l| !l.split('/').any(|part| REBUILDABLE.contains(&part)) && !l.ends_with(".log"))
                .map(str::to_string)
                .collect();
            let mut detail = format!(
                "Last commit {} ago. Everything is pushed to {url}, so you can clone it again.",
                span(commit_days)
            );
            if !extra.is_empty() {
                let more = extra.len().saturating_sub(3);
                extra.truncate(3);
                let list = extra.join(", ");
                let tail = if more > 0 { format!(" and {more} more") } else { String::new() };
                detail.push_str(&format!(" Not on the remote: {list}{tail} (git ignores them)."));
            }
            let name = repo.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            Some(Found { path: repo.clone(), label: Some(format!("{name} project")), detail: Some(detail), ..Found::default() })
        })
        .collect()
}

/// Repos with at least `min_bytes` of loose objects and garbage that
/// `git gc` would pack or drop.
pub fn git_garbage(repos: &[PathBuf], min_bytes: u64) -> Vec<Found> {
    repos
        .par_iter()
        .filter_map(|repo| {
            if repo.join(".git/index.lock").exists() || repo.join(".git/gc.pid").exists() {
                return None;
            }
            let out = git(repo, &["count-objects", "-v"])?;
            let kib = |key: &str| -> u64 {
                out.lines()
                    .find_map(|l| l.strip_prefix(key).and_then(|v| v.strip_prefix(": ")))
                    .and_then(|v| v.trim().parse().ok())
                    .unwrap_or(0)
            };
            let bytes = (kib("size") + kib("size-garbage")) * 1024;
            let name = repo.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            (bytes >= min_bytes.max(1)).then(|| Found {
                label: Some(format!("{name} git objects")),
                path: repo.join(".git"),
                bytes: Some(bytes),
                detail: Some(format!("{} loose objects that `git gc` packs together.", kib("count"))),
                ..Found::default()
            })
        })
        .collect()
}

// ---------------------------------------------------------------- simulators

/// Is Xcode installed? Without it `xcrun` pops up an install dialog, so the
/// simulator finders don't run at all.
pub fn has_xcode(apps_dir: &Path) -> bool {
    fs::read_dir(apps_dir)
        .map(|rd| rd.flatten().any(|e| e.file_name().to_string_lossy().starts_with("Xcode") && e.path().extension().is_some_and(|x| x == "app")))
        .unwrap_or(false)
}

pub fn simctl(args: &[&str]) -> Option<String> {
    let out = Command::new("xcrun").arg("simctl").args(args).stderr(Stdio::null()).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

fn version_key(v: &str) -> Vec<u64> {
    v.split('.').map(|p| p.parse().unwrap_or(0)).collect()
}

fn platform_name(id: &str) -> &str {
    match id {
        "com.apple.platform.iphonesimulator" => "iOS",
        "com.apple.platform.appletvsimulator" => "tvOS",
        "com.apple.platform.watchsimulator" => "watchOS",
        "com.apple.platform.xrsimulator" => "visionOS",
        _ => "Simulator",
    }
}

/// Simulator runtimes (`simctl runtime list -j`) that a newer one of the
/// same platform replaced, or that no simulator (`simctl list devices -j`)
/// booted in `idle_days`.
pub fn simulator_runtimes(runtimes_json: &str, devices_json: &str, now: SystemTime, idle_days: u64) -> Vec<Found> {
    let Ok(serde_json::Value::Object(rts)) = serde_json::from_str::<serde_json::Value>(runtimes_json) else {
        return Vec::new();
    };
    let devices: serde_json::Value = serde_json::from_str(devices_json).unwrap_or_default();
    let last_boot = |runtime_id: &str| -> Option<SystemTime> {
        devices["devices"][runtime_id]
            .as_array()?
            .iter()
            .filter_map(|d| d["lastBootedAt"].as_str().and_then(parse_iso))
            .max()
    };
    let str_of = |v: &serde_json::Value, k: &str| v[k].as_str().unwrap_or("").to_string();
    // Apple's beta builds end in a letter (24B91016s); releases don't (24B8117).
    let is_beta = |rt: &serde_json::Value| str_of(rt, "build").ends_with(|c: char| c.is_ascii_lowercase());
    // The newest final release of each platform.
    let mut final_release: HashMap<String, Vec<u64>> = HashMap::new();
    for rt in rts.values().filter(|rt| !is_beta(rt)) {
        let key = version_key(&str_of(rt, "version"));
        let e = final_release.entry(str_of(rt, "platformIdentifier")).or_default();
        if key > *e {
            *e = key;
        }
    }
    let mut out: Vec<Found> = rts
        .values()
        .filter(|rt| rt["deletable"].as_bool() == Some(true))
        .filter_map(|rt| {
            let platform = str_of(rt, "platformIdentifier");
            let version = str_of(rt, "version");
            let beta = is_beta(rt);
            let label = format!("{} {version}{}", platform_name(&platform), if beta { " beta" } else { "" });
            // A beta whose final release (or a later one) is installed too.
            let beta_done = beta && final_release.get(&platform).is_some_and(|n| *n >= version_key(&version));
            // Only a final release replaces a runtime; a newer beta doesn't.
            let replaced = final_release.get(&platform).is_some_and(|n| *n > version_key(&version));
            let booted = last_boot(&str_of(rt, "runtimeIdentifier"));
            let idle = booted.is_none_or(|t| days_since(t, now) >= idle_days);
            let used = match booted {
                Some(t) => format!("a simulator last ran on it {} ago", span(days_since(t, now))),
                None => "there's no record of a simulator running on it".into(),
            };
            let detail = if beta_done {
                format!("{label} ({}): the final {} {version} is installed too, so the beta isn't needed.", str_of(rt, "build"), platform_name(&platform))
            } else if replaced {
                format!("{label}: a newer {} runtime is installed, and {used}.", platform_name(&platform))
            } else if idle {
                format!("{label}: {used}. Xcode downloads it again if you need it.")
            } else {
                return None;
            };
            Some(Found {
                label: Some(format!("{label} Simulator runtime")),
                path: PathBuf::from(str_of(rt, "path")),
                bytes: rt["sizeBytes"].as_u64(),
                detail: Some(detail),
                id: Some(str_of(rt, "identifier")),
                blocked: None,
            })
        })
        .collect();
    out.sort_by(|a, b| a.path.cmp(&b.path));
    out
}

/// Simulators whose runtime is gone: they can never start again.
pub fn unavailable_simulators(devices_json: &str) -> Vec<Found> {
    let devices: serde_json::Value = serde_json::from_str(devices_json).unwrap_or_default();
    let Some(map) = devices["devices"].as_object() else { return Vec::new() };
    let mut out: Vec<Found> = map
        .values()
        .filter_map(|v| v.as_array())
        .flatten()
        .filter(|d| d["isAvailable"].as_bool() == Some(false))
        .filter_map(|d| {
            let data = PathBuf::from(d["dataPath"].as_str()?);
            let name = d["name"].as_str().unwrap_or("A simulator");
            Some(Found {
                label: Some(format!("{name} simulator (broken)")),
                path: data.parent()?.to_path_buf(),
                detail: Some(format!("{name}: its runtime isn't installed anymore, so it can't start.")),
                id: Some(d["udid"].as_str()?.to_string()),
                ..Found::default()
            })
        })
        .collect();
    out.sort_by(|a, b| a.path.cmp(&b.path));
    out
}

// ---------------------------------------------------------------- big old files

/// Where to look, relative to home, and whether any file counts or only
/// throwaway kinds (disk images, installers, archives).
const FILE_PLACES: &[(&str, bool)] = &[("Downloads", true), ("Desktop", false), ("Documents", false)];

/// Bundles and libraries that are one thing to the person; never looked into.
const PACKAGE_EXTS: &[&str] = &[
    "app", "photoslibrary", "fcpbundle", "logicx", "band", "xcarchive", "bundle", "framework", "imovielibrary",
    "musiclibrary", "tvlibrary", "lrlibrary", "lrdata", "aplibrary", "playgroundbook", "sparsebundle", "pages", "key", "numbers",
];

/// Folders inside projects that other rules already handle.
const SKIP_DIRS: &[&str] = &["node_modules", "target", "build", "dist", "Pods", "DerivedData", "venv", "__pycache__"];

/// What a file is, by its extension: (description, throwaway kind).
fn file_kind(ext: &str) -> (&'static str, bool) {
    match ext {
        "dmg" | "iso" | "img" | "cdr" | "toast" => ("a disk image", true),
        "pkg" | "mpkg" | "xip" => ("an installer", true),
        "ipa" | "apk" | "aab" | "xapk" => ("an app package", true),
        "zip" | "tar" | "gz" | "tgz" | "bz2" | "xz" | "7z" | "rar" | "zst" => ("an archive", true),
        "vmdk" | "vdi" | "qcow2" | "vhd" | "vhdx" | "ova" | "ovf" => ("a virtual machine disk", true),
        "mp4" | "mov" | "mkv" | "avi" | "webm" | "m4v" => ("a video", false),
        "mp3" | "wav" | "flac" | "m4a" | "aiff" => ("an audio file", false),
        "pdf" | "epub" => ("a document", false),
        _ => ("a file", false),
    }
}

/// Big files nobody opened for `idle_days`: anything in Downloads, and disk
/// images, installers and archives in Desktop and Documents. Your own
/// documents, photos and videos elsewhere are never listed. Spotlight's
/// last-opened date counts when it has one, then the file's own dates.
pub fn large_files(home: &Path, usage: &dyn Fn(&[PathBuf]) -> Vec<AppUsage>, now: SystemTime, idle_days: u64, min_bytes: u64) -> Vec<Found> {
    use std::os::unix::fs::MetadataExt;
    let mut hits: Vec<(PathBuf, u64, &'static str, SystemTime)> = Vec::new();
    for (place, any) in FILE_PLACES {
        let mut stack = vec![(home.join(place), 0usize)];
        while let Some((dir, depth)) = stack.pop() {
            let Ok(rd) = fs::read_dir(&dir) else { continue };
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                if name.starts_with('.') {
                    continue;
                }
                let Ok(m) = e.metadata() else { continue };
                let path = e.path();
                let ext = path.extension().map(|x| x.to_string_lossy().to_lowercase()).unwrap_or_default();
                if m.is_dir() {
                    if depth < 8 && !PACKAGE_EXTS.contains(&ext.as_str()) && !SKIP_DIRS.contains(&name.as_str()) && !e.file_type().is_ok_and(|t| t.is_symlink()) {
                        stack.push((path, depth + 1));
                    }
                    continue;
                }
                let bytes = m.blocks() * 512;
                let (what, throwaway) = file_kind(&ext);
                if !m.is_file() || bytes < min_bytes || !(*any || throwaway) {
                    continue;
                }
                // The latest sign of use the file itself carries.
                let touched = [m.modified().ok(), m.accessed().ok()].into_iter().flatten().max().unwrap_or(now);
                hits.push((path, bytes, what, touched));
            }
        }
    }
    hits.retain(|h| days_since(h.3, now) >= idle_days);
    let paths: Vec<PathBuf> = hits.iter().map(|h| h.0.clone()).collect();
    let spotlight = usage(&paths);
    let mut out: Vec<Found> = hits
        .into_iter()
        .zip(spotlight.into_iter().chain(std::iter::repeat(AppUsage::default())))
        .filter_map(|((path, bytes, what, touched), u)| {
            let last = [Some(touched), u.last_used].into_iter().flatten().max()?;
            let days = days_since(last, now);
            if days < idle_days {
                return None;
            }
            let folder = path.parent()?.strip_prefix(home).ok()?.display().to_string();
            let what = what.strip_prefix("a ").or_else(|| what.strip_prefix("an ")).map(|w| {
                let article = if w.starts_with(['a', 'e', 'i', 'o', 'u']) { "An" } else { "A" };
                format!("{article} {w}")
            })?;
            Some(Found {
                label: Some(path.file_name()?.to_string_lossy().into_owned()),
                bytes: Some(bytes),
                detail: Some(format!("{what} in {folder}, not opened in {}.", span(days))),
                path,
                ..Found::default()
            })
        })
        .collect();
    out.sort_by(|a, b| a.path.cmp(&b.path));
    out
}

// ---------------------------------------------------------------- unused tools

/// A command-line tool a package manager installed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToolInstall {
    /// The name its manager knows it by (what `uninstall` takes).
    pub name: String,
    pub dir: PathBuf,
    /// The files its commands run; each run updates their last-access time.
    pub commands: Vec<PathBuf>,
    /// The commands' names, as you type them.
    pub names: Vec<String>,
}

/// Global npm packages (`npm root -g`) that have commands. npm and corepack
/// themselves are left out.
pub fn npm_tools(root: &Path) -> Vec<ToolInstall> {
    let mut dirs = Vec::new();
    for e in fs::read_dir(root).into_iter().flatten().flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if name.starts_with('@') {
            dirs.extend(fs::read_dir(e.path()).into_iter().flatten().flatten().map(|s| s.path()));
        } else if !name.starts_with('.') {
            dirs.push(e.path());
        }
    }
    let mut out: Vec<ToolInstall> = dirs
        .into_iter()
        .filter_map(|dir| {
            let pkg: serde_json::Value = serde_json::from_str(&fs::read_to_string(dir.join("package.json")).ok()?).ok()?;
            let name = pkg["name"].as_str()?.to_string();
            if matches!(name.as_str(), "npm" | "corepack") {
                return None;
            }
            // "bin": "cli.js" is named after the package (without its @scope/).
            let bins: Vec<(String, &str)> = match &pkg["bin"] {
                serde_json::Value::String(s) => vec![(name.rsplit('/').next().unwrap_or(&name).to_string(), s.as_str())],
                serde_json::Value::Object(m) => m.iter().filter_map(|(k, v)| Some((k.clone(), v.as_str()?))).collect(),
                _ => vec![],
            };
            let (names, commands): (Vec<String>, Vec<PathBuf>) =
                bins.into_iter().map(|(n, b)| (n, dir.join(b))).filter(|(_, p)| p.is_file()).unzip();
            (!commands.is_empty()).then_some(ToolInstall { name, dir, commands, names })
        })
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// Tools installed with `uv tool install` (their `uv-receipt.toml` lists the commands).
pub fn uv_tools(tools_dir: &Path) -> Vec<ToolInstall> {
    let mut out: Vec<ToolInstall> = fs::read_dir(tools_dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let dir = e.path();
            let receipt: toml::Value = toml::from_str(&fs::read_to_string(dir.join("uv-receipt.toml")).ok()?).ok()?;
            let commands: Vec<PathBuf> = receipt["tool"]["entrypoints"]
                .as_array()?
                .iter()
                .filter_map(|ep| ep.get("name")?.as_str().map(|n| dir.join("bin").join(n)))
                .filter(|p| p.is_file())
                .collect();
            let name = e.file_name().to_string_lossy().into_owned();
            let names = commands.iter().filter_map(|c| Some(c.file_name()?.to_string_lossy().into_owned())).collect();
            (!commands.is_empty()).then_some(ToolInstall { name, dir, commands, names })
        })
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// Tools installed with pipx (`pipx_metadata.json` lists the commands).
pub fn pipx_tools(venvs: &Path) -> Vec<ToolInstall> {
    let mut out: Vec<ToolInstall> = fs::read_dir(venvs)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let dir = e.path();
            let meta: serde_json::Value = serde_json::from_str(&fs::read_to_string(dir.join("pipx_metadata.json")).ok()?).ok()?;
            let main = &meta["main_package"];
            let commands: Vec<PathBuf> = main["apps"]
                .as_array()?
                .iter()
                .filter_map(|a| a.as_str().map(|n| dir.join("bin").join(n)))
                .filter(|p| p.is_file())
                .collect();
            let name = main["package"].as_str().map(String::from).unwrap_or_else(|| e.file_name().to_string_lossy().into_owned());
            let names = commands.iter().filter_map(|c| Some(c.file_name()?.to_string_lossy().into_owned())).collect();
            (!commands.is_empty()).then_some(ToolInstall { name, dir, commands, names })
        })
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// When a folder was made (its birth time), for "installed N days ago".
pub fn created(path: &Path) -> Option<SystemTime> {
    fs::metadata(path).ok()?.created().ok()
}

/// Tools none of whose commands ran for `idle_days`, going by when their
/// files were last read (running a command reads it). A tool installed
/// within `idle_days`, or with a command running now, is left out.
pub fn unused_tools(tools: &[ToolInstall], env: &Env, now: SystemTime, idle_days: u64, installed: impl Fn(&Path) -> Option<SystemTime>) -> Vec<Found> {
    let mut out: Vec<Found> = tools
        .iter()
        .filter_map(|t| {
            if installed(&t.dir).is_none_or(|i| days_since(i, now) < idle_days) {
                return None;
            }
            let names = &t.names;
            if names.iter().any(|n| env.is_running(n)) {
                return None;
            }
            let last = t.commands.iter().filter_map(|c| fs::metadata(c).ok()?.accessed().ok()).max()?;
            let days = days_since(last, now);
            if days < idle_days {
                return None;
            }
            let list = match names.as_slice() {
                [one] => format!("Its command {one}"),
                [first @ .., last] => format!("Its commands {} and {last}", first.join(", ")),
                [] => return None,
            };
            Some(Found {
                path: t.dir.clone(),
                label: Some(t.name.clone()),
                detail: Some(format!("{list} last ran {} ago.", span(days))),
                id: Some(t.name.clone()),
                ..Found::default()
            })
        })
        .collect();
    out.sort_by(|a, b| a.id.cmp(&b.id));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn days_ago(now: SystemTime, d: u64) -> SystemTime {
        now - Duration::from_secs(d * DAY)
    }

    #[test]
    fn spans_read_naturally() {
        assert_eq!(span(1), "a day");
        assert_eq!(span(12), "12 days");
        assert_eq!(span(95), "3 months");
        assert_eq!(span(800), "2 years");
    }

    #[test]
    fn parses_dates() {
        let t = parse_mdls_date("2026-11-17 21:27:51 +0000").unwrap();
        assert_eq!(t, parse_iso("2026-11-17T21:27:51Z").unwrap());
        assert_eq!(t.duration_since(UNIX_EPOCH).unwrap().as_secs(), 1_794_950_871);
        assert!(parse_mdls_date("-").is_none());
        assert!(parse_mdls_date("").is_none());
    }

    #[test]
    fn unused_apps_by_last_open_or_install() {
        let d = tempfile::tempdir().unwrap();
        for a in ["Old.app", "Fresh.app", "Never.app", "Unknown.app", "Open.app", "Roomy.app"] {
            fs::create_dir(d.path().join(a)).unwrap();
        }
        fs::write(d.path().join("notes.txt"), "x").unwrap();
        let now = SystemTime::now();
        let usage = |apps: &[PathBuf]| -> Vec<AppUsage> {
            apps.iter()
                .map(|p| match p.file_stem().unwrap().to_str().unwrap() {
                    "Old" | "Open" | "Roomy" => AppUsage { last_used: Some(days_ago(now, 200)), added: None },
                    "Fresh" => AppUsage { last_used: Some(days_ago(now, 3)), added: Some(days_ago(now, 900)) },
                    "Never" => AppUsage { last_used: None, added: Some(days_ago(now, 400)) },
                    _ => AppUsage::default(),
                })
                .collect()
        };
        let env = Env::from_parts(&["open"], &[]);
        let found = unused_apps(d.path(), &usage, &env, now, 90);
        let names: Vec<_> = found.iter().map(|f| f.path.file_name().unwrap().to_str().unwrap()).collect();
        assert_eq!(names, ["Never.app", "Old.app", "Open.app"]);
        assert!(found[0].detail.as_ref().unwrap().starts_with("Never opened since it was installed 13 months ago."));
        assert!(found[1].detail.as_ref().unwrap().starts_with("Last opened 6 months ago."));
        assert_eq!(found[1].blocked, None);
        assert_eq!(found[2].blocked.as_deref(), Some("Open is open"));
    }

    fn sh(dir: &Path, args: &[&str], date: Option<&str>) {
        let mut c = Command::new("git");
        c.arg("-C").arg(dir).args(args).env("GIT_CONFIG_GLOBAL", "/dev/null").env("GIT_CONFIG_SYSTEM", "/dev/null");
        c.env("GIT_AUTHOR_NAME", "t").env("GIT_AUTHOR_EMAIL", "t@t").env("GIT_COMMITTER_NAME", "t").env("GIT_COMMITTER_EMAIL", "t@t");
        if let Some(d) = date {
            c.env("GIT_AUTHOR_DATE", d).env("GIT_COMMITTER_DATE", d);
        }
        assert!(c.output().unwrap().status.success(), "git {args:?}");
    }

    /// A project last committed 300 days ago, pushed to a local bare remote,
    /// with every file aged too.
    fn old_pushed_repo(root: &Path, name: &str) -> PathBuf {
        let remote = root.join(format!("{name}.git"));
        let repo = root.join(name);
        fs::create_dir_all(&repo).unwrap();
        sh(root, &["init", "-q", "--bare", remote.to_str().unwrap()], None);
        sh(&repo, &["init", "-q", "-b", "main"], None);
        fs::write(repo.join("README"), "hi").unwrap();
        fs::write(repo.join(".gitignore"), "node_modules\n.env\n").unwrap();
        sh(&repo, &["add", "."], None);
        // A few days past 300, so the test's own `now` (taken earlier) still sees 10 months.
        let when = SystemTime::now() - Duration::from_secs(305 * DAY);
        let stamp = format!("@{} +0000", when.duration_since(UNIX_EPOCH).unwrap().as_secs());
        sh(&repo, &["commit", "-q", "-m", "first"], Some(&stamp));
        sh(&repo, &["remote", "add", "origin", remote.to_str().unwrap()], None);
        sh(&repo, &["push", "-q", "-u", "origin", "main"], None);
        age_tree(&repo, when);
        repo
    }

    fn age_tree(dir: &Path, t: SystemTime) {
        for e in fs::read_dir(dir).unwrap().flatten() {
            let p = e.path();
            if e.file_type().unwrap().is_dir() {
                age_tree(&p, t);
            }
            let _ = fs::File::options().read(true).open(&p).and_then(|f| f.set_modified(t));
        }
        let _ = fs::File::options().read(true).open(dir).and_then(|f| f.set_modified(t));
    }

    #[test]
    fn stale_projects_need_everything_pushed() {
        let d = tempfile::tempdir().unwrap();
        let now = SystemTime::now();
        let clean = old_pushed_repo(d.path(), "clean");
        let dirty = old_pushed_repo(d.path(), "dirty");
        fs::write(dirty.join("README"), "edited").unwrap();
        age_tree(&dirty, days_ago(now, 300));
        let secret = old_pushed_repo(d.path(), "secret");
        fs::write(secret.join(".env"), "KEY=1").unwrap();
        fs::create_dir_all(secret.join("node_modules/x")).unwrap();
        age_tree(&secret, days_ago(now, 300));
        let recent = old_pushed_repo(d.path(), "recent");
        fs::write(recent.join("new.txt"), "x").unwrap();
        sh(&recent, &["add", "."], None);
        sh(&recent, &["commit", "-q", "-m", "new"], None);
        sh(&recent, &["push", "-q"], None);

        let found = stale_projects(&[clean.clone(), dirty, secret.clone(), recent], now, 180);
        let mut paths: Vec<_> = found.iter().map(|f| f.path.clone()).collect();
        paths.sort();
        assert_eq!(paths, [clean.clone(), secret.clone()]);
        let detail = |p: &Path| found.iter().find(|f| f.path == p).unwrap().detail.clone().unwrap();
        assert!(detail(&clean).starts_with("Last commit 10 months ago. Everything is pushed to"), "{}", detail(&clean));
        assert!(!detail(&clean).contains("Not on the remote"));
        assert!(detail(&secret).contains("Not on the remote: .env (git ignores them)."), "{}", detail(&secret));

        // A commit that only exists locally keeps the project.
        fs::write(clean.join("more.txt"), "x").unwrap();
        sh(&clean, &["add", "."], None);
        let old = format!("@{} +0000", days_ago(now, 250).duration_since(UNIX_EPOCH).unwrap().as_secs());
        sh(&clean, &["commit", "-q", "-m", "local"], Some(&old));
        age_tree(&clean, days_ago(now, 250));
        assert!(stale_projects(&[clean], now, 180).is_empty());
    }

    #[test]
    fn remotes_lose_credentials() {
        assert_eq!(clean_remote("https://user:tok@github.com/a/b.git"), "github.com/a/b");
        assert_eq!(clean_remote("git@github.com:a/b.git"), "github.com/a/b");
        assert_eq!(clean_remote("/tmp/x/b.git"), "/tmp/x/b");
    }

    #[test]
    fn git_garbage_counts_loose_objects() {
        let d = tempfile::tempdir().unwrap();
        let repo = old_pushed_repo(d.path(), "r");
        let found = git_garbage(std::slice::from_ref(&repo), 0);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].path, repo.join(".git"));
        assert!(found[0].bytes.unwrap() > 0);
        assert!(git_garbage(&[repo], 1 << 30).is_empty());
    }

    const RUNTIMES: &str = r#"{
      "A": {"identifier": "A", "deletable": true, "path": "/Sys/a", "platformIdentifier": "com.apple.platform.iphonesimulator",
            "runtimeIdentifier": "rt.iOS-26-0", "sizeBytes": 8000, "version": "26.0"},
      "B": {"identifier": "B", "deletable": true, "path": "/Sys/b", "platformIdentifier": "com.apple.platform.iphonesimulator",
            "runtimeIdentifier": "rt.iOS-27-2", "sizeBytes": 9000, "version": "27.2"},
      "C": {"identifier": "C", "deletable": true, "path": "/Sys/c", "platformIdentifier": "com.apple.platform.watchsimulator",
            "runtimeIdentifier": "rt.watchOS-12", "sizeBytes": 3000, "version": "12.0"},
      "D": {"identifier": "D", "deletable": false, "path": "/Sys/d", "platformIdentifier": "com.apple.platform.appletvsimulator",
            "runtimeIdentifier": "rt.tvOS-1", "sizeBytes": 1, "version": "1.0"}
    }"#;

    fn devices(boot: &str) -> String {
        format!(
            r#"{{"devices": {{
              "rt.iOS-27-2": [{{"name": "iPhone", "udid": "U1", "isAvailable": true, "lastBootedAt": "{boot}", "dataPath": "/H/Devices/U1/data"}}],
              "rt.gone": [{{"name": "Old iPhone", "udid": "U2", "isAvailable": false, "dataPath": "/H/Devices/U2/data"}}]
            }}}}"#
        )
    }

    #[test]
    fn simulator_runtimes_replaced_or_idle() {
        let now = parse_iso("2026-11-22T00:00:00Z").unwrap();
        let found = simulator_runtimes(RUNTIMES, &devices("2026-11-20T10:00:00Z"), now, 90);
        let ids: Vec<_> = found.iter().map(|f| f.id.clone().unwrap()).collect();
        assert_eq!(ids, ["A", "C"], "B is newest and used; D can't be deleted");
        assert_eq!(found[0].bytes, Some(8000));
        assert_eq!(found[0].label.as_deref(), Some("iOS 26.0 Simulator runtime"));
        assert_eq!(found[0].detail.as_deref(), Some("iOS 26.0: a newer iOS runtime is installed, and there's no record of a simulator running on it."));
        assert_eq!(found[1].detail.as_deref(), Some("watchOS 12.0: there's no record of a simulator running on it. Xcode downloads it again if you need it."));

        let found = simulator_runtimes(RUNTIMES, &devices("2026-01-01T10:00:00Z"), now, 90);
        assert!(found.iter().any(|f| f.id.as_deref() == Some("B")
            && f.detail.as_deref() == Some("iOS 27.2: a simulator last ran on it 10 months ago. Xcode downloads it again if you need it.")));
        assert!(simulator_runtimes("not json", "", now, 90).is_empty());
    }

    #[test]
    fn unavailable_simulators_found() {
        let found = unavailable_simulators(&devices("2026-11-20T10:00:00Z"));
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].path, PathBuf::from("/H/Devices/U2"));
        assert_eq!(found[0].id.as_deref(), Some("U2"));
        assert_eq!(found[0].label.as_deref(), Some("Old iPhone simulator (broken)"));
    }

    #[test]
    fn beta_runtime_next_to_the_final_one() {
        let now = parse_iso("2026-11-22T00:00:00Z").unwrap();
        let json = r#"{
          "F": {"identifier": "F", "deletable": true, "path": "/Sys/f", "platformIdentifier": "com.apple.platform.iphonesimulator",
                "runtimeIdentifier": "rt.iOS-27-2", "sizeBytes": 8000, "version": "27.2", "build": "24B8117"},
          "BETA": {"identifier": "BETA", "deletable": true, "path": "/Sys/beta", "platformIdentifier": "com.apple.platform.iphonesimulator",
                "runtimeIdentifier": "rt.iOS-27-2", "sizeBytes": 7700, "version": "27.2", "build": "24B91016s"},
          "NEXT": {"identifier": "NEXT", "deletable": true, "path": "/Sys/next", "platformIdentifier": "com.apple.platform.iphonesimulator",
                "runtimeIdentifier": "rt.iOS-28-0", "sizeBytes": 7000, "version": "28.0", "build": "25A5279m"}
        }"#;
        let dev = r#"{"devices": {"rt.iOS-27-2": [{"name": "i", "udid": "U", "isAvailable": true, "lastBootedAt": "2026-11-21T10:00:00Z", "dataPath": "/d/U/data"}],
                                  "rt.iOS-28-0": [{"name": "j", "udid": "V", "isAvailable": true, "lastBootedAt": "2026-11-21T10:00:00Z", "dataPath": "/d/V/data"}]}}"#;
        let found = simulator_runtimes(json, dev, now, 90);
        let ids: Vec<_> = found.iter().map(|f| f.id.clone().unwrap()).collect();
        assert_eq!(ids, ["BETA"], "the final 27.2 and the newer 28.0 beta stay");
        assert_eq!(found[0].label.as_deref(), Some("iOS 27.2 beta Simulator runtime"));
        assert_eq!(found[0].detail.as_deref(), Some("iOS 27.2 beta (24B91016s): the final iOS 27.2 is installed too, so the beta isn't needed."));
    }

    fn touch(p: &Path, bytes: usize, days_old: u64, now: SystemTime) {
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, vec![7u8; bytes]).unwrap();
        let t = days_ago(now, days_old);
        let f = fs::File::options().write(true).open(p).unwrap();
        f.set_times(fs::FileTimes::new().set_accessed(t).set_modified(t)).unwrap();
    }

    #[test]
    fn big_old_files_in_your_folders() {
        let home = tempfile::tempdir().unwrap();
        let h = home.path();
        let now = SystemTime::now();
        touch(&h.join("Downloads/movie.mp4"), 300_000, 400, now);
        touch(&h.join("Downloads/new.mp4"), 300_000, 10, now);
        touch(&h.join("Downloads/small.zip"), 1_000, 400, now);
        touch(&h.join("Documents/T5/lineage-2021.img"), 300_000, 700, now);
        touch(&h.join("Documents/thesis.pdf"), 300_000, 700, now);
        touch(&h.join("Desktop/old.dmg"), 300_000, 300, now);
        touch(&h.join("Documents/.hidden/x.zip"), 300_000, 700, now);
        touch(&h.join("Documents/app/node_modules/big.tgz"), 300_000, 700, now);
        touch(&h.join("Documents/Photos.photoslibrary/x.zip"), 300_000, 700, now);
        touch(&h.join("Movies/holiday.mov"), 300_000, 700, now);
        // Spotlight says the Desktop image was opened last week.
        let usage = |paths: &[PathBuf]| -> Vec<AppUsage> {
            paths.iter().map(|p| AppUsage {
                last_used: p.ends_with("Desktop/old.dmg").then(|| days_ago(now, 7)),
                added: None,
            }).collect()
        };
        let found = large_files(h, &usage, now, 180, 100_000);
        let names: Vec<_> = found.iter().map(|f| f.path.strip_prefix(h).unwrap().to_str().unwrap().to_string()).collect();
        assert_eq!(names, ["Documents/T5/lineage-2021.img", "Downloads/movie.mp4"],
                   "not new, small, recently opened, hidden, inside projects or libraries, your documents or Movies");
        assert_eq!(found[0].label.as_deref(), Some("lineage-2021.img"));
        assert_eq!(found[0].detail.as_deref(), Some("A disk image in Documents/T5, not opened in 23 months."));
        assert_eq!(found[1].detail.as_deref(), Some("A video in Downloads, not opened in 13 months."));
    }

    #[test]
    fn tools_whose_commands_never_run() {
        let d = tempfile::tempdir().unwrap();
        let now = SystemTime::now();
        let npm = d.path().join("lib/node_modules");
        touch(&npm.join("old-tool/cli.js"), 10, 200, now);
        fs::write(npm.join("old-tool/package.json"), r#"{"name":"old-tool","bin":{"old":"cli.js"}}"#).unwrap();
        touch(&npm.join("@scope/used/bin/run.js"), 10, 3, now);
        fs::write(npm.join("@scope/used/package.json"), r#"{"name":"@scope/used","bin":"bin/run.js"}"#).unwrap();
        touch(&npm.join("lib-only/index.js"), 10, 200, now);
        fs::write(npm.join("lib-only/package.json"), r#"{"name":"lib-only"}"#).unwrap();
        touch(&npm.join("npm/bin/npm-cli.js"), 10, 200, now);
        fs::write(npm.join("npm/package.json"), r#"{"name":"npm","bin":{"npm":"bin/npm-cli.js"}}"#).unwrap();
        let tools = npm_tools(&npm);
        let mut names: Vec<_> = tools.iter().map(|t| t.name.as_str()).collect();
        names.sort();
        assert_eq!(names, ["@scope/used", "old-tool"], "libraries without commands and npm itself are left out");

        let uv = d.path().join("uv/tools");
        touch(&uv.join("docling/bin/docling"), 10, 100, now);
        fs::write(uv.join("docling/uv-receipt.toml"), "[tool]\nrequirements = [{ name = \"docling\" }]\nentrypoints = [\n  { name = \"docling\", install-path = \"/x/docling\", from = \"docling\" },\n]\n").unwrap();
        let uv_tools = uv_tools(&uv);
        assert_eq!(uv_tools.len(), 1);
        assert_eq!(uv_tools[0].commands, [uv.join("docling/bin/docling")]);

        let pipx = d.path().join("pipx/venvs");
        touch(&pipx.join("black/bin/black"), 10, 100, now);
        fs::write(pipx.join("black/pipx_metadata.json"), r#"{"main_package":{"package":"black","apps":["black","blackd"]}}"#).unwrap();
        let pipx_tools = pipx_tools(&pipx);
        assert_eq!(pipx_tools[0].name, "black");

        let env = Env::from_parts(&[], &[]);
        // Installed long ago: set the folders' own times back too.
        let all: Vec<ToolInstall> = tools.into_iter().chain(uv_tools).chain(pipx_tools).collect();
        let found = unused_tools(&all, &env, now, 60, |_| Some(days_ago(now, 300)));
        let ids: Vec<_> = found.iter().map(|f| f.id.clone().unwrap()).collect();
        assert_eq!(ids, ["black", "docling", "old-tool"]);
        let old = found.iter().find(|f| f.id.as_deref() == Some("old-tool")).unwrap();
        assert_eq!(old.label.as_deref(), Some("old-tool"));
        assert_eq!(old.detail.as_deref(), Some("Its command old last ran 6 months ago."));
        assert!(unused_tools(&all, &env, now, 60, |_| Some(days_ago(now, 20))).is_empty(), "installed recently");
        let running = Env::from_parts(&["old"], &[]);
        assert!(unused_tools(&all, &running, now, 60, |_| Some(days_ago(now, 300))).iter().all(|f| f.id.as_deref() != Some("old-tool")));
    }
}
