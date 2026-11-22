use clap::{Args, Parser, Subcommand};
use roomy::clean::{self, CleanOptions, LogEntry, Method, Outcome, Pick};
use roomy::json::{self, CleanEvent};
use roomy::Finding;
use roomy::report::{self, ReportInfo, human_bytes, tilde};
use roomy::verify::Env;
use std::io::{IsTerminal, Write};
use std::time::Duration;
use roomy::rules::{self, Target};
use roomy::scan::WalkOptions;
use roomy::{ScanOptions, run};
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Instant;

#[derive(Parser)]
#[command(name = "roomy", version, about = "Find space you can free on your Mac, and clean it safely.")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Scan and report what can be cleaned.
    Scan(ScanArgs),
    /// List the rules the scanner uses.
    Rules(RulesArgs),
    /// Clean what the scanner found. Shows the plan and asks first.
    Clean(CleanArgs),
    /// Show where your disk space goes, and how much of each folder can be freed.
    Map(MapArgs),
    /// Gather clues about one folder: file types, last change, biggest items, owner app.
    Inspect(InspectArgs),
    /// Say what Roomy's list of known folders knows about folders (they don't have to exist).
    Known(KnownArgs),
}

#[derive(Args)]
struct KnownArgs {
    /// The folders to look up.
    paths: Vec<PathBuf>,
    /// Print JSON (one entry or null per folder) instead of text.
    #[arg(long)]
    json: bool,
}

fn run_known(a: KnownArgs, home: &std::path::Path) -> ExitCode {
    let catalog = roomy::known::Catalog::standard(home);
    let expand = |p: &PathBuf| if let Ok(rest) = p.strip_prefix("~") { home.join(rest) } else { p.clone() };
    let found: Vec<Option<roomy::known::Known>> = a.paths.iter().map(|p| catalog.lookup_within(&expand(p))).collect();
    if a.json {
        println!("{}", serde_json::to_string(&found).unwrap());
        return ExitCode::SUCCESS;
    }
    if a.paths.is_empty() {
        println!("Roomy knows {} kinds of folders.", catalog.len());
    }
    for (p, k) in a.paths.iter().zip(&found) {
        match k {
            Some(k) => println!("{}: {}{} ({}, {}). {}", p.display(), if k.inside { "inside " } else { "" }, k.name, k.owner, k.kind, k.what),
            None => println!("{}: not on the list", p.display()),
        }
    }
    ExitCode::SUCCESS
}

#[derive(Args)]
struct InspectArgs {
    /// The folder to look at.
    path: PathBuf,
    /// Print JSON instead of text (for the app).
    #[arg(long)]
    json: bool,
}

fn run_inspect(a: InspectArgs, home: &std::path::Path) -> ExitCode {
    let path = if let Ok(rest) = a.path.strip_prefix("~") { home.join(rest) } else { a.path.clone() };
    let path_var = std::env::var("PATH").unwrap_or_default();
    let env = Env::capture();
    let Some(mut c) = roomy::inspect::inspect(&path, home, &apps_dir(), &path_var, &env, std::time::SystemTime::now()) else {
        eprintln!("error: {} isn't a folder", path.display());
        return ExitCode::FAILURE;
    };
    c.known = roomy::known::Catalog::standard(home).lookup_within(&path).map(|k| roomy::known::Known { running: env.is_running(&k.owner), ..k });
    if a.json {
        println!("{}", serde_json::to_string(&c).unwrap());
        return ExitCode::SUCCESS;
    }
    if let Some(k) = &c.known {
        println!("{}{} ({}): {}", if k.inside { "Inside " } else { "" }, k.name, k.owner, k.what);
        if let Some(how) = &k.how {
            println!("How to free it: {how}");
        }
    }
    println!("{}  {}  ({} files, {} folders)", tilde(&c.path, home), human_bytes(c.bytes), c.files, c.folders);
    if let Some(d) = c.newest_days {
        println!("Last change: {d} days ago");
    }
    if let Some(o) = &c.owner {
        let state = match (o.installed, o.running) {
            (_, true) => "running",
            (Some(true), false) => "installed",
            (Some(false), false) => "not installed",
            (None, false) => "can't tell if installed",
        };
        println!("Belongs to: {} ({} {state})", o.name, o.kind);
    }
    let types: Vec<String> = c.types.iter().map(|t| format!(".{} {}", if t.ext.is_empty() { "?" } else { &t.ext }, human_bytes(t.bytes))).collect();
    println!("File types: {}", types.join(", "));
    for i in &c.biggest {
        println!("  {:>9}  {}{}", human_bytes(i.bytes), i.name, if i.folder { "/" } else { "" });
    }
    for m in &c.markers {
        println!("- {m}");
    }
    ExitCode::SUCCESS
}

#[derive(Args)]
struct MapArgs {
    /// Print JSON instead of a tree (for the app).
    #[arg(long)]
    json: bool,
    /// How many levels the text tree shows.
    #[arg(long, default_value_t = 3)]
    depth: usize,
    /// Extra rules file, added to the built-in rules.
    #[arg(long)]
    rules: Option<PathBuf>,
}

/// Where apps are installed. `ROOMY_APPS_DIR` overrides it for tests.
fn apps_dir() -> PathBuf {
    std::env::var_os("ROOMY_APPS_DIR").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/Applications"))
}

fn disk_space(path: &std::path::Path) -> Option<(u64, u64)> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut st: libc::statfs = unsafe { std::mem::zeroed() };
    // SAFETY: valid C string and a zeroed statfs struct to fill.
    if unsafe { libc::statfs(c.as_ptr(), &mut st) } != 0 {
        return None;
    }
    Some((st.f_blocks * st.f_bsize as u64, st.f_bavail * st.f_bsize as u64))
}

fn run_map(a: MapArgs, home: &std::path::Path) -> ExitCode {
    use roomy::map;
    let rules = match load_rules(a.rules.as_ref()) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    let start = Instant::now();
    if !a.json {
        eprintln!("Mapping your disk (this can take a minute)...");
    }
    let apps = apps_dir();
    let findings = run(&ScanOptions { home: home.to_path_buf(), rules, walk: walk_options(home, &[]), apps_dir: apps.clone() });
    // The whole disk; tests (ROOMY_APPS_DIR) map just home and their apps folder.
    let testing = std::env::var_os("ROOMY_APPS_DIR").is_some();
    let mut roots = map::disk_roots(!testing && std::path::Path::new(map::DATA_VOLUME).is_dir());
    if roots.is_empty() {
        roots = vec![home.to_path_buf(), apps];
    }
    let mut nodes = map::build(&roots, &findings, &map::MapOptions::new(home));
    let catalog = roomy::known::Catalog::standard(home);
    for n in &mut nodes {
        map::label(n, &catalog);
    }
    let space = disk_space(home);
    let doc = map::MapDocument {
        total_bytes: space.map(|s| s.0),
        used_bytes: space.map(|(t, f)| t.saturating_sub(f)),
        free_bytes: space.map(|s| s.1),
        mapped_bytes: nodes.iter().map(|n| n.bytes).sum(),
        cleanable_bytes: nodes.iter().map(|n| n.cleanable).sum(),
        elapsed_ms: start.elapsed().as_millis() as u64,
        roots: nodes,
    };
    if a.json {
        println!("{}", serde_json::to_string(&doc).unwrap());
    } else {
        print!("{}", map::render(&doc, home, a.depth));
    }
    ExitCode::SUCCESS
}

#[derive(Args)]
struct CleanArgs {
    /// Rule ids (`node-modules`) or paths (`~/code/app/target`). A folder
    /// cleans the safe items inside it.
    targets: Vec<String>,
    /// Clean everything in "Safe to clean now".
    #[arg(long)]
    safe: bool,
    /// Move everything to the Trash instead of deleting (you can get it back;
    /// space is freed when you empty the Trash).
    #[arg(long)]
    trash: bool,
    /// Don't ask, just clean. Without it, the plan is shown first.
    #[arg(long, short)]
    yes: bool,
    /// Folders to walk for build output (same as `scan --root`).
    #[arg(long)]
    root: Vec<PathBuf>,
    /// Extra rules file, added to the built-in rules.
    #[arg(long)]
    rules: Option<PathBuf>,
    /// Stop a tool's clean command after this many seconds.
    #[arg(long, default_value_t = 300)]
    timeout: u64,
    /// Group items smaller than this many MB into one line (0 lists all).
    #[arg(long, default_value_t = 10)]
    min_mb: u64,
    /// Print one JSON event per line instead of a report (for the app).
    /// Implies --yes: the app asks before it calls this.
    #[arg(long)]
    json: bool,
}

/// "140 smaller items (python-bytecode 120, dist-output 9, ...)"
fn smaller_items(findings: &[roomy::Finding], idx: &[usize]) -> String {
    let mut by_rule: Vec<(String, usize)> = Vec::new();
    for &i in idx {
        match by_rule.iter_mut().find(|(r, _)| *r == findings[i].rule) {
            Some(e) => e.1 += 1,
            None => by_rule.push((findings[i].rule.clone(), 1)),
        }
    }
    by_rule.sort_by(|a, b| b.1.cmp(&a.1));
    let mut parts: Vec<String> = by_rule.iter().take(3).map(|(r, n)| format!("{r} {n}")).collect();
    if by_rule.len() > 3 {
        parts.push("...".into());
    }
    format!("{} smaller item{} ({})", idx.len(), if idx.len() == 1 { "" } else { "s" }, parts.join(", "))
}

#[derive(Args)]
struct ScanArgs {
    /// Folders to walk for build output (default: your home folder,
    /// skipping ~/Library and hidden folders at the top).
    #[arg(long)]
    root: Vec<PathBuf>,
    /// Extra rules file, added to the built-in rules.
    #[arg(long)]
    rules: Option<PathBuf>,
    /// Print JSON instead of a report.
    #[arg(long)]
    json: bool,
    /// Hide items smaller than this many MB in the report (they still count in totals).
    #[arg(long, default_value_t = 10)]
    min_mb: u64,
}

#[derive(Args)]
struct RulesArgs {
    /// Extra rules file, added to the built-in rules.
    #[arg(long)]
    rules: Option<PathBuf>,
}

fn load_rules(extra: Option<&PathBuf>) -> Result<Vec<rules::Rule>, String> {
    let mut all = rules::parse_rules(rules::DEFAULT_RULES).map_err(|e| format!("built-in rules: {e}"))?;
    if let Some(p) = extra {
        let text = std::fs::read_to_string(p).map_err(|e| format!("{}: {e}", p.display()))?;
        let more = rules::parse_rules(&text).map_err(|e| format!("{}: {e}", p.display()))?;
        for r in more {
            if all.iter().any(|a| a.id == r.id) {
                return Err(format!("{}: rule id `{}` already exists", p.display(), r.id));
            }
            all.push(r);
        }
    }
    Ok(all)
}

fn free_space(path: &std::path::Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut st: libc::statfs = unsafe { std::mem::zeroed() };
    // SAFETY: valid C string and a zeroed statfs struct to fill.
    if unsafe { libc::statfs(c.as_ptr(), &mut st) } != 0 {
        return None;
    }
    Some(st.f_bavail * st.f_bsize as u64)
}

fn main() -> ExitCode {
    // Exit quietly when output is piped into `head` and the pipe closes.
    // SAFETY: resetting a signal to its default before any threads start.
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL) };
    let cli = Cli::parse();
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        eprintln!("HOME is not set");
        return ExitCode::FAILURE;
    };
    match cli.cmd {
        Cmd::Rules(a) => match load_rules(a.rules.as_ref()) {
            Ok(rules) => {
                for r in rules {
                    let target = match &r.target {
                        Target::Paths { patterns, .. } => patterns.join(", "),
                        Target::Project { dir_name, sibling } if sibling.is_empty() => format!("{dir_name}/ anywhere"),
                        Target::Project { dir_name, sibling } => format!("{dir_name}/ next to {}", sibling.join(" | ")),
                        Target::Finder { kind, .. } => format!("finder: {kind:?}"),
                    };
                    println!("{:<26} {:<14} {:<8} {}", r.id, r.category, format!("{:?}", r.risk).to_lowercase(), target);
                }
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("error: {e}");
                ExitCode::FAILURE
            }
        },
        Cmd::Scan(a) => {
            let rules = match load_rules(a.rules.as_ref()) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("error: {e}");
                    return ExitCode::FAILURE;
                }
            };
            let walk = walk_options(&home, &a.root);
            let roots = walk.roots.clone();
            let start = Instant::now();
            let opts = ScanOptions { home: home.clone(), rules, walk, apps_dir: apps_dir() };
            let findings = run(&opts);
            if a.json {
                let doc = json::scan_document(&findings, &opts.rules, free_space(&home), start.elapsed().as_millis() as u64);
                println!("{}", serde_json::to_string_pretty(&doc).unwrap());
            } else {
                let info = ReportInfo {
                    home: &home,
                    roots: &roots,
                    elapsed: start.elapsed(),
                    min_bytes: a.min_mb * 1_000_000,
                    free_now: free_space(&home),
                };
                print!("{}", report::render(&findings, &info));
            }
            ExitCode::SUCCESS
        }
        Cmd::Clean(a) => run_clean(a, &home),
        Cmd::Map(a) => run_map(a, &home),
        Cmd::Inspect(a) => run_inspect(a, &home),
        Cmd::Known(a) => run_known(a, &home),
    }
}

fn walk_options(home: &std::path::Path, root: &[PathBuf]) -> WalkOptions {
    let default_roots = root.is_empty();
    WalkOptions {
        roots: if default_roots { vec![home.to_path_buf()] } else { root.to_vec() },
        skip: vec![home.join("Library"), home.join(".Trash")],
        skip_hidden_top: default_roots,
    }
}

struct Prepared {
    rules: Vec<rules::Rule>,
    findings: Vec<Finding>,
    plan: clean::Plan,
}

/// Load rules, scan, and pick what to clean.
fn prepare_clean(a: &CleanArgs, home: &std::path::Path) -> Result<Prepared, String> {
    if a.targets.is_empty() && !a.safe {
        return Err("Say what to clean: rule ids or paths from `roomy scan`, or --safe for everything safe.".into());
    }
    let rules = load_rules(a.rules.as_ref())?;
    let ids: Vec<&str> = rules.iter().map(|r| r.id.as_str()).collect();
    // Only rule ids given: scan just those rules, it's faster.
    let only_ids = !a.safe && a.targets.iter().all(|t| ids.contains(&t.as_str()));
    let scan_rules: Vec<rules::Rule> =
        rules.iter().filter(|r| !only_ids || a.targets.contains(&r.id)).cloned().collect();
    eprintln!("Scanning...");
    let findings = run(&ScanOptions {
        home: home.to_path_buf(),
        rules: scan_rules,
        walk: walk_options(home, &a.root),
        apps_dir: apps_dir(),
    });
    let cwd = std::env::current_dir().unwrap_or_else(|_| home.to_path_buf());
    let plan = clean::select(&findings, &ids, &a.targets, a.safe, home, &cwd);
    Ok(Prepared { rules, findings, plan })
}

fn clean_options(a: &CleanArgs, home: &std::path::Path) -> CleanOptions {
    CleanOptions {
        home: home.to_path_buf(),
        trash_dir: home.join(".Trash"),
        force_trash: a.trash,
        timeout: Duration::from_secs(a.timeout),
        tmp_root: rules::user_tmp_root(),
        apps_dir: apps_dir(),
    }
}

fn log_path(home: &std::path::Path) -> PathBuf {
    home.join("Library/Logs/Roomy/clean.jsonl")
}

/// Clean one item with a fresh process list, and log it.
fn clean_and_log(f: &Finding, rule: &rules::Rule, opts: &CleanOptions, log: &std::path::Path) -> Outcome {
    let env = Env::capture();
    let before = free_space(&opts.home);
    let out = clean::clean_one(f, rule, &env, opts);
    let entry = LogEntry {
        time: std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0),
        rule: &f.rule,
        path: &f.path,
        bytes_freed_estimate: f.bytes_freed,
        outcome: &out,
        free_before: before,
        free_after: free_space(&opts.home),
    };
    if let Err(e) = clean::append_log(log, &entry) {
        eprintln!("(couldn't write the log: {e})");
    }
    out
}

fn emit(e: &CleanEvent) {
    println!("{}", serde_json::to_string(e).expect("events serialize"));
}

/// `clean --json`: the app already asked, so no questions here.
fn run_clean_json(a: CleanArgs, home: &std::path::Path) -> ExitCode {
    let p = match prepare_clean(&a, home) {
        Ok(p) => p,
        Err(message) => {
            emit(&CleanEvent::Error { message });
            return ExitCode::FAILURE;
        }
    };
    let rule_of = |id: &str| p.rules.iter().find(|r| r.id == id).expect("finding from a known rule");
    let acts_bytes: u64 =
        p.plan.items.iter().filter(|i| i.pick == Pick::Act).map(|i| p.findings[i.index].bytes_freed).sum();
    emit(&CleanEvent::Plan { items: p.plan.items.len() + p.plan.unmatched.len(), bytes: acts_bytes });

    let opts = clean_options(&a, home);
    let log = log_path(home);
    let start_free = free_space(home);
    let (mut cleaned, mut skipped, mut failed, mut trashed) = (0usize, 0usize, 0usize, 0u64);
    let mut index = 0;
    for item in &p.plan.items {
        let f = &p.findings[item.index];
        let rule = rule_of(&f.rule);
        let out = match &item.pick {
            Pick::Skip(reason) => Outcome::Skipped { reason: reason.clone() },
            Pick::Act => clean_and_log(f, rule, &opts, &log),
        };
        match &out {
            Outcome::Cleaned { method, .. } => {
                cleaned += 1;
                if *method == Method::Trash {
                    trashed += f.bytes_freed;
                }
            }
            Outcome::Skipped { .. } => skipped += 1,
            Outcome::Failed { .. } => failed += 1,
        }
        index += 1;
        emit(&CleanEvent::Item { index, path: &f.path, rule: &f.rule, name: &rule.name, bytes: f.bytes_freed, outcome: &out });
    }
    let gone = Outcome::Skipped { reason: "the scan doesn't find it anymore".into() };
    for t in &p.plan.unmatched {
        index += 1;
        skipped += 1;
        emit(&CleanEvent::Item { index, path: std::path::Path::new(t), rule: "", name: "", bytes: 0, outcome: &gone });
    }
    emit(&CleanEvent::Done {
        cleaned,
        skipped,
        failed,
        free_before: start_free,
        free_after: free_space(home),
        trashed_bytes: trashed,
    });
    if failed > 0 { ExitCode::FAILURE } else { ExitCode::SUCCESS }
}

fn run_clean(a: CleanArgs, home: &std::path::Path) -> ExitCode {
    if a.json {
        return run_clean_json(a, home);
    }
    let Prepared { rules: all_rules, findings, plan } = match prepare_clean(&a, home) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    if let Some(t) = plan.unmatched.first() {
        eprintln!(
            "error: `{t}` isn't something the scanner found. The cleaner only removes what a rule matched; run `roomy scan` to see the list"
        );
        return ExitCode::FAILURE;
    }
    for n in &plan.notes {
        println!("Note: {n}");
    }
    let rule_of = |id: &str| all_rules.iter().find(|r| r.id == id).expect("finding from a known rule");

    // Show the plan.
    let acts: Vec<usize> = plan.items.iter().filter(|i| i.pick == Pick::Act).map(|i| i.index).collect();
    let total: u64 = acts.iter().map(|&i| findings[i].bytes_freed).sum();
    let min = a.min_mb * 1_000_000;
    let home_s = home.to_string_lossy().to_string();
    if !acts.is_empty() {
        println!("\nWILL CLEAN  ·  about {}", human_bytes(total));
        let mut small = Vec::new();
        for &i in &acts {
            let f = &findings[i];
            if f.bytes_freed < min {
                small.push(i);
                continue;
            }
            let how = match clean::choose_method(f, Some(rule_of(&f.rule)), a.trash) {
                Method::Delete => String::new(),
                m => format!("   → {}", m.label().replace(&home_s, "~")),
            };
            println!("  {:>8}  {}{how}", human_bytes(f.bytes_freed), tilde(&f.path, home));
            if let Some(r) = &f.reason {
                println!("            note: {r}");
            }
        }
        if !small.is_empty() {
            let bytes: u64 = small.iter().map(|&i| findings[i].bytes_freed).sum();
            println!("  {:>8}  + {}", human_bytes(bytes), smaller_items(&findings, &small));
        }
        println!("Everything is deleted unless it says → (Trash or the tool's own clean command).");
    }
    let skips: Vec<_> = plan.items.iter().filter_map(|i| match &i.pick {
        Pick::Skip(r) => Some((i.index, r)),
        Pick::Act => None,
    }).collect();
    if !skips.is_empty() {
        println!("\nSKIPPING (in use right now)");
        for (i, r) in skips {
            println!("  {:>8}  {}: {r}", human_bytes(findings[i].bytes_freed), tilde(&findings[i].path, home));
        }
    }
    if acts.is_empty() {
        println!("\nNothing to clean.");
        return ExitCode::SUCCESS;
    }

    // Ask.
    if !a.yes {
        if !std::io::stdin().is_terminal() {
            println!("\nThis was a preview. Run again with --yes to clean.");
            return ExitCode::SUCCESS;
        }
        print!("\nClean {} item{} (about {})? [y/N] ", acts.len(), if acts.len() == 1 { "" } else { "s" }, human_bytes(total));
        let _ = std::io::stdout().flush();
        let mut answer = String::new();
        let _ = std::io::stdin().read_line(&mut answer);
        if !matches!(answer.trim().to_lowercase().as_str(), "y" | "yes") {
            println!("Nothing was cleaned.");
            return ExitCode::SUCCESS;
        }
    }

    // Clean, one at a time, checking each again right before.
    let opts = clean_options(&a, home);
    let log = log_path(home);
    let start_free = free_space(home);
    let (mut cleaned, mut trashed, mut failed) = (0usize, 0u64, 0usize);
    let mut quiet_done = Vec::new();
    println!();
    for &i in &acts {
        let f = &findings[i];
        let out = clean_and_log(f, rule_of(&f.rule), &opts, &log);
        let shown = tilde(&f.path, home);
        match &out {
            Outcome::Cleaned { method, note } => {
                cleaned += 1;
                if *method == Method::Trash {
                    trashed += f.bytes_freed;
                }
                let verb = if *method == Method::Trash { "trashed" } else { "cleaned" };
                if f.bytes_freed < min && note.is_none() && *method != Method::Trash {
                    quiet_done.push(i);
                } else {
                    println!("  ✓ {verb:<8} {:>8}  {shown}", human_bytes(f.bytes_freed));
                    if let Some(n) = note {
                        println!("                        {n}");
                    }
                }
            }
            Outcome::Skipped { reason } => println!("  – skipped  {:>8}  {shown}: {reason}", human_bytes(f.bytes_freed)),
            Outcome::Failed { error, .. } => {
                failed += 1;
                println!("  ✗ failed   {:>8}  {shown}: {error}", human_bytes(f.bytes_freed));
            }
        }
    }

    if !quiet_done.is_empty() {
        let bytes: u64 = quiet_done.iter().map(|&i| findings[i].bytes_freed).sum();
        println!("  ✓ cleaned  {:>8}  {}", human_bytes(bytes), smaller_items(&findings, &quiet_done));
    }
    let end_free = free_space(home);
    println!("\nCleaned {cleaned} of {} item{}.", acts.len(), if acts.len() == 1 { "" } else { "s" });
    if let (Some(s), Some(e)) = (start_free, end_free) {
        println!("Free space: {} → {}.", human_bytes(s), human_bytes(e));
    }
    if trashed > 0 {
        println!("{} is in the Trash. Empty the Trash to get that space back.", human_bytes(trashed));
    }
    println!("Log: {}", tilde(&log, home));
    if failed > 0 { ExitCode::FAILURE } else { ExitCode::SUCCESS }
}
