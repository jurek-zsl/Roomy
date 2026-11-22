//! Runs the real binary, the way the app does.

use std::process::Command;

#[test]
fn json_clean_reports_unmatched_paths_as_skipped() {
    let home = tempfile::tempdir().unwrap();
    let h = home.path().to_str().unwrap();
    let gone = format!("{h}/nope");
    let out = Command::new(env!("CARGO_BIN_EXE_mac-cleaner"))
        .args(["clean", "--json", "--root", h, &gone])
        .env("HOME", h)
        .env("TMPDIR", h)
        .output()
        .unwrap();
    assert!(out.status.success(), "exit {:?}: {}", out.status, String::from_utf8_lossy(&out.stderr));
    let lines: Vec<serde_json::Value> = String::from_utf8(out.stdout)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).expect(l))
        .collect();
    let events: Vec<&str> = lines.iter().map(|v| v["event"].as_str().unwrap()).collect();
    assert_eq!(events, ["plan", "item", "done"]);
    assert_eq!(lines[1]["path"], gone.as_str());
    assert_eq!(lines[1]["outcome"]["result"], "skipped");
    assert_eq!(lines[1]["outcome"]["reason"], "the scan doesn't find it anymore");
    assert_eq!(lines[2]["skipped"], 1);
    assert_eq!(lines[2]["cleaned"], 0);
}

#[test]
fn json_scan_is_a_document() {
    let home = tempfile::tempdir().unwrap();
    let h = home.path().to_str().unwrap();
    std::fs::create_dir_all(format!("{h}/.bun/install/cache")).unwrap();
    std::fs::write(format!("{h}/.bun/install/cache/x"), vec![1u8; 50_000]).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_mac-cleaner"))
        .args(["scan", "--json", "--root", h])
        .env("HOME", h)
        .env("TMPDIR", h)
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
