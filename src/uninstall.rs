//! Uninstall an app with everything it left around your Mac: its support
//! files, caches, containers, settings, saved state, logs and login items.
//! Also finds leftovers of apps that are already gone. Matching goes by the
//! app's bundle id (`com.tinyspeck.slackmacgap`) and its exact name, never
//! by a loose guess, and Apple's own apps are never touched.

use serde::Serialize;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Item {
    pub path: PathBuf,
    pub bytes: u64,
    /// What kind of file it is: "Support files", "Caches", "Settings"…
    pub what: String,
    /// It's in /Library, so removing it needs an administrator.
    pub admin: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct Plan {
    pub app: PathBuf,
    pub name: String,
    pub bundle_id: Option<String>,
    pub app_bytes: u64,
    /// The app is open right now; quit it before uninstalling.
    pub running: bool,
    pub items: Vec<Item>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Orphan {
    /// The bundle id the files are named after.
    pub bundle_id: String,
    pub items: Vec<Item>,
}

/// Where apps keep files, the kind of file, how entries are named there, and
/// whether it's the shared (admin) library.
struct Place {
    dir: &'static str,
    what: &'static str,
    by_name: bool,
    system: bool,
}

const PLACES: &[Place] = &[
    Place {
        dir: "Library/Application Support",
        what: "Support files",
        by_name: true,
        system: false,
    },
    Place {
        dir: "Library/Caches",
        what: "Caches",
        by_name: true,
        system: false,
    },
    Place {
        dir: "Library/Containers",
        what: "Sandbox container",
        by_name: false,
        system: false,
    },
    Place {
        dir: "Library/Group Containers",
        what: "Shared container",
        by_name: false,
        system: false,
    },
    Place {
        dir: "Library/Preferences",
        what: "Settings",
        by_name: false,
        system: false,
    },
    Place {
        dir: "Library/Preferences/ByHost",
        what: "Settings",
        by_name: false,
        system: false,
    },
    Place {
        dir: "Library/Saved Application State",
        what: "Saved windows",
        by_name: false,
        system: false,
    },
    Place {
        dir: "Library/HTTPStorages",
        what: "Web data",
        by_name: false,
        system: false,
    },
    Place {
        dir: "Library/WebKit",
        what: "Web data",
        by_name: false,
        system: false,
    },
    Place {
        dir: "Library/Cookies",
        what: "Cookies",
        by_name: false,
        system: false,
    },
    Place {
        dir: "Library/Logs",
        what: "Logs",
        by_name: true,
        system: false,
    },
    Place {
        dir: "Library/LaunchAgents",
        what: "Login item",
        by_name: false,
        system: false,
    },
    Place {
        dir: "Library/Application Scripts",
        what: "Scripts",
        by_name: false,
        system: false,
    },
    Place {
        dir: "Library/Application Support",
        what: "Support files (all users)",
        by_name: true,
        system: true,
    },
    Place {
        dir: "Library/Caches",
        what: "Caches (all users)",
        by_name: false,
        system: true,
    },
    Place {
        dir: "Library/Preferences",
        what: "Settings (all users)",
        by_name: false,
        system: true,
    },
    Place {
        dir: "Library/LaunchAgents",
        what: "Login item (all users)",
        by_name: false,
        system: true,
    },
    Place {
        dir: "Library/LaunchDaemons",
        what: "Background service",
        by_name: false,
        system: true,
    },
    Place {
        dir: "Library/PrivilegedHelperTools",
        what: "Helper tool",
        by_name: false,
        system: true,
    },
];

/// Names too common to match a folder by.
const GENERIC: &[&str] = &[
    "electron",
    "helper",
    "app",
    "setup",
    "updater",
    "installer",
    "launcher",
    "default",
    "google",
    "microsoft",
    "adobe",
    "apple",
];

fn squash(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect::<String>()
        .to_lowercase()
}

/// One value from an app's Info.plist.
pub fn info(app: &Path, key: &str) -> Option<String> {
    let plist = app.join("Contents/Info.plist");
    let out = Command::new("/usr/bin/plutil")
        .args(["-extract", key, "raw", "-o", "-"])
        .arg(&plist)
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let v = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && !v.is_empty()).then_some(v)
}

/// Does a file name belong to this bundle id? `com.x.app`, `com.x.app.plist`,
/// `com.x.app.helper`, `TEAM.com.x.app`, `group.com.x.app` all do;
/// `com.x.application` doesn't.
pub fn named_after(entry: &str, id: &str) -> bool {
    let e = entry.to_lowercase();
    let id = id.to_lowercase();
    let at = |i: usize| e.len() == i || e[i..].starts_with('.');
    if e.starts_with(&id) && at(id.len()) {
        return true;
    }
    // A team or "group." prefix in front.
    e.match_indices(&format!(".{id}"))
        .any(|(i, _)| at(i + 1 + id.len()))
}

/// The names an app's folders may carry: its file name and CFBundleName.
fn app_names(app: &Path) -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    if let Some(stem) = app.file_stem() {
        names.push(stem.to_string_lossy().into_owned());
    }
    if let Some(n) = info(app, "CFBundleName") {
        names.push(n);
    }
    names.retain(|n| squash(n).len() >= 4 && !GENERIC.contains(&squash(n).as_str()));
    names.dedup();
    names
}

fn entries(dir: &Path) -> Vec<(String, PathBuf)> {
    fs::read_dir(dir)
        .map(|rd| {
            rd.flatten()
                .map(|e| (e.file_name().to_string_lossy().into_owned(), e.path()))
                .collect()
        })
        .unwrap_or_default()
}

/// Every file and folder that belongs to an app, in your library and the
/// shared one (`system_root`, normally `/`).
pub fn related(
    home: &Path,
    system_root: &Path,
    bundle_id: Option<&str>,
    names: &[String],
) -> Vec<Item> {
    let squashed: Vec<String> = names.iter().map(|n| squash(n)).collect();
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for place in PLACES {
        let root = if place.system { system_root } else { home };
        for (entry, path) in entries(&root.join(place.dir)) {
            let by_id = bundle_id.is_some_and(|id| named_after(&entry, id));
            let stem = entry.strip_suffix(".plist").unwrap_or(&entry);
            let by_name = place.by_name && squashed.contains(&squash(stem));
            if (by_id || by_name) && seen.insert(path.clone()) {
                out.push(Item {
                    bytes: crate::size::measure(&path).on_disk,
                    path,
                    what: place.what.into(),
                    admin: place.system,
                });
            }
        }
    }
    out.sort_by(|a, b| b.bytes.cmp(&a.bytes).then(a.path.cmp(&b.path)));
    out
}

/// What uninstalling this app would remove.
pub fn plan(app: &Path, home: &Path, system_root: &Path, env: &crate::verify::Env) -> Plan {
    let bundle_id = info(app, "CFBundleIdentifier");
    let names = app_names(app);
    let exe = info(app, "CFBundleExecutable");
    let items = if bundle_id
        .as_deref()
        .is_some_and(|id| id.starts_with("com.apple."))
    {
        Vec::new()
    } else {
        related(home, system_root, bundle_id.as_deref(), &names)
    };
    let name = app
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    Plan {
        running: exe.as_deref().is_some_and(|e| env.is_running(e)) || env.is_running(&name),
        app_bytes: crate::size::measure(app).on_disk,
        app: app.to_path_buf(),
        name,
        bundle_id,
        items,
    }
}

/// Bundle ids of every app on this Mac: in the app folders, and anywhere
/// else Spotlight knows of one (a build folder, Downloads, Setapp).
pub fn installed_ids(app_dirs: &[PathBuf]) -> HashSet<String> {
    let mut ids = HashSet::new();
    if let Ok(out) = Command::new("/usr/bin/mdfind")
        .args(["-0", "kMDItemContentType == 'com.apple.application-bundle'"])
        .stderr(Stdio::null())
        .output()
    {
        let apps: Vec<String> = String::from_utf8_lossy(&out.stdout)
            .split('\0')
            .filter(|p| !p.is_empty())
            .map(String::from)
            .collect();
        for chunk in apps.chunks(200) {
            let Ok(o) = Command::new("/usr/bin/mdls")
                .args([
                    "-raw",
                    "-nullMarker",
                    "",
                    "-name",
                    "kMDItemCFBundleIdentifier",
                ])
                .args(chunk)
                .stderr(Stdio::null())
                .output()
            else {
                continue;
            };
            ids.extend(
                String::from_utf8_lossy(&o.stdout)
                    .split('\0')
                    .filter(|s| !s.is_empty())
                    .map(|s| s.to_lowercase()),
            );
        }
    }
    let mut stack: Vec<(PathBuf, usize)> = app_dirs.iter().map(|d| (d.clone(), 0)).collect();
    while let Some((dir, depth)) = stack.pop() {
        for (name, path) in entries(&dir) {
            if name.ends_with(".app") {
                if let Some(id) = info(&path, "CFBundleIdentifier") {
                    ids.insert(id.to_lowercase());
                }
            } else if depth < 2 && path.is_dir() {
                stack.push((path, depth + 1));
            }
        }
    }
    ids
}

/// The bundle id a leftover is named after, if it looks like one:
/// `com.x.app.plist` → `com.x.app`, `TEAMID.com.x.app` → `com.x.app`.
fn id_in(entry: &str) -> Option<String> {
    let e = entry
        .strip_suffix(".plist")
        .or_else(|| entry.strip_suffix(".savedState"))
        .or_else(|| entry.strip_suffix(".binarycookies"))
        .unwrap_or(entry);
    let parts: Vec<&str> = e.split('.').collect();
    let start = parts.iter().position(|p| {
        matches!(
            p.to_lowercase().as_str(),
            "com" | "org" | "net" | "io" | "dev" | "app" | "co" | "me" | "ai" | "us" | "de" | "uk"
        )
    })?;
    let id: Vec<&str> = parts[start..].to_vec();
    (id.len() >= 3 && id.iter().all(|p| !p.is_empty())).then(|| id.join(".").to_lowercase())
}

/// Libraries apps build in and system parts: their files belong to other
/// apps, not to an app of their own.
const NOT_APPS: &[&str] = &[
    "org.swift",
    "org.cups",
    "org.python",
    "org.sparkle-project",
    "io.branch",
    "io.sentry",
    "io.realm",
    "io.flutter",
    "com.plausiblelabs",
    "com.telemetrydeck",
    "com.crashlytics",
    "com.google.firebase",
    "com.google.gtm",
    "com.google.keystone",
    "com.microsoft.appcenter",
    "com.segment",
    "com.mixpanel",
    "com.amplitude",
    "com.bugsnag",
    "com.github.electron",
    "com.squirrel",
    "org.chromium",
    "com.apple",
];

/// Files in your library named after apps that aren't installed. Careful on
/// purpose: Apple's ids are skipped, and so is anything from a company that
/// still has an app installed (a helper or updater of that app).
pub fn orphans(home: &Path, installed: &HashSet<String>) -> Vec<Orphan> {
    let companies: HashSet<String> = installed
        .iter()
        .map(|id| id.split('.').take(2).collect::<Vec<_>>().join("."))
        .collect();
    let mut by_id: std::collections::BTreeMap<String, Vec<Item>> = Default::default();
    // Login items can belong to command-line tools, which have no app.
    for place in PLACES
        .iter()
        .filter(|p| !p.system && p.dir != "Library/LaunchAgents")
    {
        for (entry, path) in entries(&home.join(place.dir)) {
            let Some(id) = id_in(&entry) else { continue };
            let company = id.split('.').take(2).collect::<Vec<_>>().join(".");
            if NOT_APPS
                .iter()
                .any(|n| id == *n || id.starts_with(&format!("{n}.")))
                || companies.contains(&company)
            {
                continue;
            }
            if installed
                .iter()
                .any(|i| named_after(&id, i) || named_after(i, &id))
            {
                continue;
            }
            by_id.entry(id).or_default().push(Item {
                bytes: crate::size::measure(&path).on_disk,
                path,
                what: place.what.into(),
                admin: false,
            });
        }
    }
    let mut out: Vec<Orphan> = by_id
        .into_iter()
        .map(|(bundle_id, items)| Orphan { bundle_id, items })
        .collect();
    out.sort_by_key(|o| std::cmp::Reverse(o.items.iter().map(|i| i.bytes).sum::<u64>()));
    out
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Removed {
    pub path: PathBuf,
    /// Where it went in the Trash; None when it wasn't moved.
    pub trashed: Option<PathBuf>,
    pub error: Option<String>,
}

/// Move the chosen paths to the Trash. Only paths from `allowed` (the plan
/// Roomy just made) are touched, apps only from an Applications folder, and
/// files in the shared /Library are left for you (they need an administrator).
pub fn remove(
    chosen: &[PathBuf],
    allowed: &[Item],
    app: Option<&Path>,
    home: &Path,
    trash_dir: &Path,
) -> Vec<Removed> {
    chosen
        .iter()
        .map(|path| {
            let fail = |e: &str| Removed { path: path.clone(), trashed: None, error: Some(e.into()) };
            let is_app = app == Some(path.as_path());
            if !is_app {
                match allowed.iter().find(|i| i.path == *path) {
                    None => return fail("isn't one of this app's files"),
                    Some(i) if i.admin => return fail("is shared by all users, so removing it needs an administrator; Show in Finder to remove it yourself"),
                    _ => {}
                }
            }
            let check = if is_app {
                let parent = path.parent().unwrap_or(Path::new("/"));
                let apps_dir = if parent == Path::new("/Applications") || parent == home.join("Applications") { parent } else { Path::new("/Applications") };
                crate::clean::guard_app(path, apps_dir)
            } else {
                crate::clean::guard(path, home, None)
            };
            if let Err(e) = check {
                return fail(&e);
            }
            match crate::clean::trash(path, trash_dir) {
                Ok(to) => Removed { path: path.clone(), trashed: Some(to), error: None },
                Err(e) => fail(&e),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app(dir: &Path, name: &str, id: &str, bundle_name: &str) -> PathBuf {
        let a = dir.join(format!("{name}.app"));
        fs::create_dir_all(a.join("Contents")).unwrap();
        fs::write(a.join("Contents/Info.plist"), format!(r#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>{id}</string><key>CFBundleName</key><string>{bundle_name}</string><key>CFBundleExecutable</key><string>{bundle_name}</string></dict></plist>"#)).unwrap();
        a
    }

    fn put(p: &Path) {
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, vec![1u8; 5000]).unwrap();
    }

    #[test]
    fn names_belong_to_a_bundle_id() {
        let id = "com.tinyspeck.slackmacgap";
        assert!(named_after("com.tinyspeck.slackmacgap", id));
        assert!(named_after("com.tinyspeck.slackmacgap.plist", id));
        assert!(named_after("com.tinyspeck.slackmacgap.ShipIt", id));
        assert!(named_after("BQR82RBBHL.com.tinyspeck.slackmacgap", id));
        assert!(named_after("group.com.tinyspeck.slackmacgap", id));
        assert!(!named_after("com.tinyspeck.slackmacgapx", id));
        assert!(!named_after("com.tinyspeck", id));
        assert_eq!(
            id_in("BQR82RBBHL.com.tinyspeck.slackmacgap"),
            Some(id.into())
        );
        assert_eq!(id_in("com.x.app.savedState"), Some("com.x.app".into()));
        assert_eq!(id_in("Slack"), None);
    }

    #[test]
    fn finds_an_apps_files_by_id_and_name() {
        let d = tempfile::tempdir().unwrap();
        let home = d.path().join("home");
        let sys = d.path().join("sys");
        let a = app(
            &d.path().join("Applications"),
            "Slack",
            "com.tinyspeck.slackmacgap",
            "Slack",
        );
        put(&home.join("Library/Application Support/Slack/x"));
        put(&home.join("Library/Caches/com.tinyspeck.slackmacgap/x"));
        put(&home.join("Library/Caches/com.tinyspeck.slackmacgap.ShipIt/x"));
        put(&home.join("Library/Containers/com.tinyspeck.slackmacgap/x"));
        put(&home.join("Library/Group Containers/BQR82RBBHL.com.tinyspeck.slackmacgap/x"));
        put(&home.join("Library/Preferences/com.tinyspeck.slackmacgap.plist"));
        put(&home.join("Library/Saved Application State/com.tinyspeck.slackmacgap.savedState/x"));
        put(&home.join("Library/Logs/Slack/x"));
        put(&home.join("Library/Application Support/Slacker/x"));
        put(&home.join("Library/Preferences/Slack.plist"));
        put(&sys.join("Library/LaunchDaemons/com.tinyspeck.slackmacgap.helper.plist"));
        let env = crate::verify::Env::from_parts(&[], &[]);
        let p = plan(&a, &home, &sys, &env);
        assert_eq!(p.bundle_id.as_deref(), Some("com.tinyspeck.slackmacgap"));
        assert!(!p.running);
        let mut got: Vec<String> = p
            .items
            .iter()
            .map(|i| i.path.strip_prefix(d.path()).unwrap().display().to_string())
            .collect();
        got.sort();
        assert_eq!(
            got,
            [
                "home/Library/Application Support/Slack",
                "home/Library/Caches/com.tinyspeck.slackmacgap",
                "home/Library/Caches/com.tinyspeck.slackmacgap.ShipIt",
                "home/Library/Containers/com.tinyspeck.slackmacgap",
                "home/Library/Group Containers/BQR82RBBHL.com.tinyspeck.slackmacgap",
                "home/Library/Logs/Slack",
                "home/Library/Preferences/com.tinyspeck.slackmacgap.plist",
                "home/Library/Saved Application State/com.tinyspeck.slackmacgap.savedState",
                "sys/Library/LaunchDaemons/com.tinyspeck.slackmacgap.helper.plist",
            ],
            "not Slacker, and Preferences match by id only"
        );
        assert!(
            p.items
                .iter()
                .find(|i| i.path.ends_with("com.tinyspeck.slackmacgap.helper.plist"))
                .unwrap()
                .admin
        );
        let running = crate::verify::Env::from_parts(&["slack"], &[]);
        assert!(plan(&a, &home, &sys, &running).running);
    }

    #[test]
    fn apple_apps_and_generic_names_are_left_alone() {
        let d = tempfile::tempdir().unwrap();
        let home = d.path().join("home");
        let a = app(&d.path(), "Safari", "com.apple.Safari", "Safari");
        put(&home.join("Library/Caches/com.apple.Safari/x"));
        let env = crate::verify::Env::from_parts(&[], &[]);
        assert!(plan(&a, &home, d.path(), &env).items.is_empty());
        let e = app(&d.path(), "Electron", "com.github.Electron", "Electron");
        put(&home.join("Library/Application Support/Electron/x"));
        assert!(
            plan(&e, &home, d.path(), &env).items.is_empty(),
            "Electron is every Electron app's name"
        );
    }

    #[test]
    fn removes_only_whats_in_the_plan() {
        let d = tempfile::tempdir().unwrap();
        let home = d.path().join("home");
        let trash = home.join(".Trash");
        let cache = home.join("Library/Caches/com.x.app");
        put(&cache.join("a"));
        let other = home.join("Library/Caches/com.y.app");
        put(&other.join("a"));
        let shared = d.path().join("sys/Library/LaunchDaemons/com.x.app.plist");
        put(&shared);
        let allowed = vec![
            Item {
                path: cache.clone(),
                bytes: 1,
                what: "Caches".into(),
                admin: false,
            },
            Item {
                path: shared.clone(),
                bytes: 1,
                what: "Background service".into(),
                admin: true,
            },
        ];
        let r = remove(
            &[cache.clone(), other.clone(), shared.clone()],
            &allowed,
            None,
            &home,
            &trash,
        );
        assert!(r[0].trashed.is_some() && !cache.exists());
        assert_eq!(r[1].error.as_deref(), Some("isn't one of this app's files"));
        assert!(other.exists());
        assert!(r[2].error.as_deref().unwrap().contains("administrator"));
        assert!(shared.exists());
    }

    #[test]
    fn leftovers_of_removed_apps() {
        let d = tempfile::tempdir().unwrap();
        let home = d.path();
        put(&home.join("Library/Caches/com.gone.app/x"));
        put(&home.join("Library/Preferences/com.gone.app.plist"));
        put(&home.join("Library/Containers/com.here.app/x"));
        put(&home.join("Library/Caches/com.here.updater/x"));
        put(&home.join("Library/Caches/com.apple.Safari/x"));
        put(&home.join("Library/Application Support/Gone/x"));
        put(&home.join("Library/Caches/org.swift.swiftpm/x"));
        put(&home.join("Library/LaunchAgents/com.tool.agent.plist"));
        let installed: HashSet<String> = ["com.here.app".to_string()].into();
        let o = orphans(home, &installed);
        assert_eq!(
            o.len(),
            1,
            "installed, same company, Apple and plain names are skipped: {o:?}"
        );
        assert_eq!(o[0].bundle_id, "com.gone.app");
        assert_eq!(o[0].items.len(), 2);
    }
}
