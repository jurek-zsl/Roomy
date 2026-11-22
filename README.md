# Roomy (engine: mac-cleaner)

Finds space you can free on your Mac, tells you why it's safe, and cleans it.
`scan` never deletes anything. `clean` shows its plan and asks first.

```bash
cargo build --release
./target/release/mac-cleaner scan            # report
./target/release/mac-cleaner scan --json     # for the future UI
./target/release/mac-cleaner rules           # list rules
./target/release/mac-cleaner scan --root ~/Documents/code --min-mb 1
./target/release/mac-cleaner scan --rules my-rules.toml   # add your own rules

./target/release/mac-cleaner clean --safe                  # everything "safe now"
./target/release/mac-cleaner clean node-modules bun-cache  # by rule id
./target/release/mac-cleaner clean ~/code/app              # safe items in one project
./target/release/mac-cleaner clean --safe --trash          # to the Trash instead
```

Use the release binary, not `cargo run`: the `rust-target` rule waits while cargo runs.

## The Mac app: Roomy

A SwiftUI app in `app/`, made of a window and a menu bar item, both on top of this engine.

**Window**
- A big "you can safely free" number.
- A disk bar: used / safe to clean / review / free.
- Real app icons for app caches.
- Temp paths shown as `Temp/...`.
- For items an app is using, a "Quit <app>" button.

**Menu bar**
- Free space and a mini disk bar.
- Rescans every 6 hours.
- Optional low-space alert (at most once a day).
- Optional open at login.

**Screens off-screen:** `xcodebuild test -scheme Snapshots ...` renders every screen (light and dark) into `app/build/snapshots/`. It's also where the app icon is drawn.

```bash
cd app
xcodegen generate
xcodebuild -scheme MacCleaner -configuration Release -derivedDataPath build build
open "build/Build/Products/Release/Roomy.app"
xcodebuild test -scheme MacCleaner -destination 'platform=macOS' -derivedDataPath build
```

- The build also runs `cargo build --release` and puts the engine inside the app
  as `Contents/MacOS/mac-cleaner`. The app runs it and reads its JSON.
- **The window:** Safe now / Review first / Blocked, with checkboxes, details,
  a confirm sheet, progress, a summary, and a scan again after every clean.
- **The menu bar:** free space, how much is safe to clean, and a two-step
  "Clean Safe Items".
- Not sandboxed (the sandbox would hide the caches), so it can't go in the App Store.
- The first scan makes macOS ask for Documents, Desktop and Downloads access.
- `app/project.yml` is the source of the Xcode project. The `.xcodeproj` is generated.

JSON for the app:

- `scan --json` prints `{free_bytes, elapsed_ms, findings: [...]}`. Each finding
  also has `name`, `section` (`safe-now`/`review`/`blocked`) and `method`
  (`delete`/`trash`/`command`).
- `clean --json -- <paths>` prints one event per line: `plan`, `item`..., `done`
  (or `error`). It doesn't ask first, because the app already asked. A path the
  scan no longer finds comes back as a skipped item.

## How it works

1. **Rules** (`rules/default.toml`): every kind of junk is a rule in a data file.
   A rule matches a fixed path (`~/.cache/uv`) or a folder name next to a
   marker file (`target/` next to `Cargo.toml`).
2. **Scan** (`src/scan.rs`): checks the fixed paths, then walks your home
   folder in parallel for build folders. Skips `~/Library`, hidden folders at
   the top of home (installed tools live there), `.git`, app bundles, and
   other volumes. Stops at the first match, so nested `node_modules` count once.
3. **Size** (`src/size.rs`): measures what deleting would **really** free.
   APFS clones (pnpm, uv, `cp -c`) share disk blocks, so a folder can be 3 GB
   on disk but free 400 MB. Read with `getattrlist` (`ATTR_CMNEXT_PRIVATESIZE`,
   `ATTR_CMNEXT_CLONE_REFCNT`). Hard links are counted once and only freed
   when every name is inside the folder.
4. **Verify** (`src/verify.rs`): checks before anything is called safe:
   - `git-ignored`: build folders git doesn't ignore go to Review
   - `not-running:NAME`: blocked while that program runs
   - `lock-free:PATH`: blocked while another process holds the lock (uv)
   - `npx-idle`: blocked while a package from that npx folder runs
5. **Report** (`src/report.rs`): Safe now / Review first / Blocked, biggest first.
6. **Clean** (`src/clean.rs`): only acts on what a rule found.
   - Shows the plan and asks `[y/N]`. Not in a terminal: preview only, unless `--yes`.
   - Plain `rm` rules are deleted directly (no shell). Tool rules run the
     tool's own command with a time limit; if the tool isn't installed, the
     folder is deleted. Review items and `--trash` go to the Trash.
   - Review items must be named (rule id or exact path). Blocked items are skipped.
   - Runs the checks again right before each item, with a fresh process list.
   - Refuses home, main folders (Documents, Library, ...), links, and paths
     through links, even if a rule matched them.
   - Logs every item to `~/Library/Logs/mac-cleaner/clean.jsonl`.

## Rules so far

Groups from the rule catalog:

- **A:** package manager caches.
- **B:** build output in projects.
- **C:** app web caches (Electron/Chromium) and crash reports.
- **D:** updater leftovers and old versions.
- **E:** Xcode, Simulator and Godot leftovers.
- **F:** the per-user temp area (`$USERTMP`: clang module cache, PyInstaller leftovers).

Checks:

- `app-not-running` blocks an `Application Support/<App>/...` cache while that app runs.
- The cleaner may touch the per-user temp area but never its main folders.

## Tests

```bash
cargo test
```

The tests make real APFS clones, hard links, git repos, file locks, read-only
folders and hung commands in temp folders.
