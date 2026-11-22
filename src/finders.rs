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
    let mut newest: HashMap<String, Vec<u64>> = HashMap::new();
    for rt in rts.values() {
        let key = version_key(&str_of(rt, "version"));
        let e = newest.entry(str_of(rt, "platformIdentifier")).or_default();
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
            let label = format!("{} {version}", platform_name(&platform));
            let replaced = newest.get(&platform).is_some_and(|n| *n > version_key(&version));
            let booted = last_boot(&str_of(rt, "runtimeIdentifier"));
            let idle = booted.is_none_or(|t| days_since(t, now) >= idle_days);
            let used = match booted {
                Some(t) => format!("a simulator last ran on it {} ago", span(days_since(t, now))),
                None => "there's no record of a simulator running on it".into(),
            };
            let detail = if replaced {
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
        let when = SystemTime::now() - Duration::from_secs(300 * DAY);
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
}
