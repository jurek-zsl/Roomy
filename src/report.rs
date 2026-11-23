//! Human-readable report.

use crate::{Finding, Section};
use std::fmt::Write;
use std::path::Path;
use std::time::Duration;

/// Sizes in decimal units, like Finder.
pub fn human_bytes(b: u64) -> String {
    let b = b as f64;
    if b >= 1e9 {
        format!("{:.1} GB", b / 1e9)
    } else if b >= 1e6 {
        format!("{:.0} MB", b / 1e6)
    } else if b >= 1e3 {
        format!("{:.0} KB", b / 1e3)
    } else {
        format!("{b} B")
    }
}

/// Show paths under home as `~/...`.
pub fn tilde(p: &Path, home: &Path) -> String {
    match p.strip_prefix(home) {
        Ok(rest) if rest.as_os_str().is_empty() => "~".into(),
        Ok(rest) => format!("~/{}", rest.display()),
        Err(_) => p.display().to_string(),
    }
}

pub struct ReportInfo<'a> {
    pub home: &'a Path,
    pub roots: &'a [std::path::PathBuf],
    pub elapsed: Duration,
    pub min_bytes: u64,
    pub free_now: Option<u64>,
}

pub fn render(findings: &[Finding], info: &ReportInfo) -> String {
    let mut s = String::new();
    let roots: Vec<String> = info.roots.iter().map(|r| tilde(r, info.home)).collect();
    let _ = writeln!(s, "Roomy scan (dry run: nothing was deleted)");
    let _ = writeln!(
        s,
        "Walked {} for build folders, checked known cache locations. Took {:.1}s.",
        roots.join(", "),
        info.elapsed.as_secs_f64()
    );
    if let Some(free) = info.free_now {
        let _ = writeln!(s, "Free space right now: {}", human_bytes(free));
    }

    let sections = [
        (Section::SafeNow, "SAFE TO CLEAN NOW"),
        (Section::Review, "REVIEW FIRST"),
        (Section::Blocked, "BLOCKED RIGHT NOW (try again later)"),
    ];
    let mut totals = Vec::new();
    for (sec, title) in sections {
        let items: Vec<&Finding> = findings.iter().filter(|f| f.section() == sec).collect();
        let total: u64 = items.iter().map(|f| f.bytes_freed).sum();
        totals.push((sec, total));
        if items.is_empty() {
            continue;
        }
        let _ = writeln!(s, "\n{title}  ·  {}", human_bytes(total));
        let mut hidden = (0usize, 0u64);
        for f in &items {
            if f.bytes_freed < info.min_bytes {
                hidden.0 += 1;
                hidden.1 += f.bytes_freed;
                continue;
            }
            let _ = writeln!(
                s,
                "  {:>8}  {:<24} {}",
                human_bytes(f.bytes_freed),
                f.rule,
                tilde(&f.path, info.home)
            );
            if f.bytes_on_disk > f.bytes_freed + f.bytes_freed / 10
                && f.bytes_on_disk > info.min_bytes
            {
                let _ = writeln!(
                    s,
                    "            {} on disk, the rest is shared with copies elsewhere",
                    human_bytes(f.bytes_on_disk)
                );
            }
            if let Some(r) = &f.reason {
                let _ = writeln!(s, "            why: {r}");
            }
            if sec != Section::Blocked {
                if let Some(c) = &f.clean {
                    let home = info.home.to_string_lossy();
                    // `'/Users/me/My App'` → `~/'My App'`, so the shown command still works.
                    let shown = c.replace(&format!("'{home}/"), "~/'").replace(&*home, "~");
                    let _ = writeln!(s, "            run: {shown}");
                }
            }
        }
        if hidden.0 > 0 {
            let _ = writeln!(
                s,
                "  {:>8}  + {} smaller items",
                human_bytes(hidden.1),
                hidden.0
            );
        }
    }

    let get = |sec| {
        totals
            .iter()
            .find(|(s, _)| *s == sec)
            .map(|t| t.1)
            .unwrap_or(0)
    };
    let _ = writeln!(
        s,
        "\nYou can free {} now.",
        human_bytes(get(Section::SafeNow))
    );
    if get(Section::Review) > 0 {
        let _ = writeln!(
            s,
            "{} more if you agree to the review items.",
            human_bytes(get(Section::Review))
        );
    }
    if get(Section::Blocked) > 0 {
        let _ = writeln!(
            s,
            "{} more once the blocked items are free.",
            human_bytes(get(Section::Blocked))
        );
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bytes_are_decimal() {
        assert_eq!(human_bytes(999), "999 B");
        assert_eq!(human_bytes(1_500), "2 KB");
        assert_eq!(human_bytes(25_000_000), "25 MB");
        assert_eq!(human_bytes(2_900_000_000), "2.9 GB");
    }

    #[test]
    fn tilde_paths() {
        let h = Path::new("/Users/me");
        assert_eq!(tilde(Path::new("/Users/me/x"), h), "~/x");
        assert_eq!(tilde(Path::new("/Users/me"), h), "~");
        assert_eq!(tilde(Path::new("/opt/x"), h), "/opt/x");
    }
}
