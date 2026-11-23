//! Runs the real binary, the way the app does.

use std::process::Command;

#[test]
fn json_clean_reports_unmatched_paths_as_skipped() {
    let home = tempfile::tempdir().unwrap();
    let h = home.path().to_str().unwrap();
    let gone = format!("{h}/nope");
    let out = Command::new(env!("CARGO_BIN_EXE_roomy"))
        .args(["clean", "--json", "--root", h, &gone])
        .env("HOME", h)
        .env("TMPDIR", h)
        .env("ROOMY_APPS_DIR", format!("{h}/Applications"))
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "exit {:?}: {}",
        out.status,
        String::from_utf8_lossy(&out.stderr)
    );
    let lines: Vec<serde_json::Value> = String::from_utf8(out.stdout)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).expect(l))
        .collect();
    let events: Vec<&str> = lines.iter().map(|v| v["event"].as_str().unwrap()).collect();
    assert_eq!(events, ["plan", "item", "done"]);
    assert_eq!(lines[1]["path"], gone.as_str());
    assert_eq!(lines[1]["outcome"]["result"], "skipped");
    assert_eq!(
        lines[1]["outcome"]["reason"],
        "the scan doesn't find it anymore"
    );
    assert_eq!(lines[2]["skipped"], 1);
    assert_eq!(lines[2]["cleaned"], 0);
}

#[test]
fn json_scan_is_a_document() {
    let home = tempfile::tempdir().unwrap();
    let h = home.path().to_str().unwrap();
    std::fs::create_dir_all(format!("{h}/.bun/install/cache")).unwrap();
    std::fs::write(format!("{h}/.bun/install/cache/x"), vec![1u8; 50_000]).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_roomy"))
        .args(["scan", "--json", "--root", h])
        .env("HOME", h)
        .env("TMPDIR", h)
        .env("ROOMY_APPS_DIR", format!("{h}/Applications"))
        .output()
        .unwrap();
    assert!(out.status.success());
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert!(v["free_bytes"].as_u64().unwrap() > 0);
    let f = &v["findings"][0];
    assert_eq!(f["rule"], "bun-cache");
    assert_eq!(f["name"], "Bun cache");
    assert_eq!(f["section"], "safe-now");
    assert_eq!(f["method"]["command"], "bun pm cache rm");
}

#[test]
fn json_map_shows_folders_and_what_can_be_freed() {
    let home = tempfile::tempdir().unwrap();
    let h = home.path().to_str().unwrap();
    std::fs::create_dir_all(format!("{h}/.bun/install/cache")).unwrap();
    std::fs::write(format!("{h}/.bun/install/cache/x"), vec![1u8; 60_000_000]).unwrap();
    std::fs::create_dir_all(format!("{h}/Applications/Tool.app")).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_roomy"))
        .args(["map", "--json"])
        .env("HOME", h)
        .env("TMPDIR", h)
        .env("ROOMY_APPS_DIR", format!("{h}/Applications"))
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert!(v["used_bytes"].as_u64().unwrap() > 0);
    let home_node = &v["roots"][0];
    assert_eq!(home_node["path"], h);
    assert!(
        home_node["cleanable"].as_u64().unwrap() >= 60_000_000,
        "{home_node}"
    );
    let bun = home_node["children"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == ".bun")
        .expect("lists .bun");
    assert_eq!(bun["kind"], "folder");
    assert_eq!(bun["cleanable"], bun["children"][0]["cleanable"]);
    assert_eq!(
        v["roots"].as_array().unwrap().len(),
        2,
        "home and the apps folder only, in tests"
    );
}

#[test]
fn json_inspect_gives_clues() {
    let home = tempfile::tempdir().unwrap();
    let h = home.path().to_str().unwrap();
    let dir = format!("{h}/Library/Application Support/OldApp");
    std::fs::create_dir_all(format!("{dir}/Cache")).unwrap();
    std::fs::write(format!("{dir}/Cache/x.bin"), vec![1u8; 10_000]).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_roomy"))
        .args(["inspect", "--json", &dir])
        .env("HOME", h)
        .env("ROOMY_APPS_DIR", format!("{h}/Applications"))
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["name"], "OldApp");
    assert_eq!(v["owner"]["name"], "OldApp");
    assert_eq!(v["owner"]["installed"], false, "an app that is missing");
    assert_eq!(v["biggest"][0]["name"], "Cache");
    let bad = Command::new(env!("CARGO_BIN_EXE_roomy"))
        .args(["inspect", "--json", "/nonexistent"])
        .output()
        .unwrap();
    assert!(!bad.status.success());
}

#[test]
fn map_uses_extra_rules() {
    let home = tempfile::tempdir().unwrap();
    let h = home.path().to_str().unwrap();
    std::fs::create_dir_all(format!("{h}/stuff/junk")).unwrap();
    std::fs::write(format!("{h}/stuff/junk/x"), vec![1u8; 60_000_000]).unwrap();
    let rules = format!("{h}/rules.toml");
    std::fs::write(&rules, "[[rule]]\nid = \"user-junk\"\ncategory = \"ai\"\nrisk = \"review\"\nexplain = \"e\"\nmatch = { path = \"~/stuff/junk\" }\n").unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_roomy"))
        .args(["map", "--json", "--rules", &rules])
        .env("HOME", h)
        .env("TMPDIR", h)
        .env("ROOMY_APPS_DIR", format!("{h}/Applications"))
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert!(
        v["cleanable_bytes"].as_u64().unwrap() >= 60_000_000,
        "{}",
        v["cleanable_bytes"]
    );
}
