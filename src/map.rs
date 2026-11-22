//! The space map: where the disk actually goes, folder by folder, and how
//! much of each folder the rules can free. Big folders no rule explains are
//! where a person (or later, an AI) should look next.

use crate::Finding;
use rayon::prelude::*;
use serde::Serialize;
use std::collections::HashSet;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Kind {
    Folder,
    /// An app or a library bundle: counted, but not opened up.
    Bundle,
    /// Your own files (Documents, Photos, iCloud Drive): shown, never suggested.
    Personal,
    /// The files sitting directly in a folder, added up.
    Files,
    /// The smaller folders of a parent, added up.
    Other,
    /// macOS didn't let us look inside.
    Unreadable,
}

#[derive(Debug, Clone, Serialize)]
pub struct Node {
    pub path: PathBuf,
    pub name: String,
    pub kind: Kind,
    /// Space on disk (shared clone blocks counted fully, hard links once).
    pub bytes: u64,
    /// How much of this the scan can free.
    pub cleanable: u64,
    pub children: Vec<Node>,
}

#[derive(Debug, Clone)]
pub struct MapOptions {
    /// Folders below this depth are counted, not listed.
    pub max_depth: usize,
    /// Folders smaller than this are added up into "Other".
    pub min_bytes: u64,
    /// At most this many folders listed per parent.
    pub max_children: usize,
    pub home: PathBuf,
}

impl MapOptions {
    pub fn new(home: &Path) -> MapOptions {
        MapOptions { max_depth: 8, min_bytes: 50_000_000, max_children: 30, home: home.to_path_buf() }
    }
}

#[derive(Debug, Serialize)]
pub struct MapDocument {
    pub total_bytes: Option<u64>,
    pub used_bytes: Option<u64>,
    pub free_bytes: Option<u64>,
    /// Space the map's folders add up to.
    pub mapped_bytes: u64,
    pub cleanable_bytes: u64,
    pub elapsed_ms: u64,
    pub roots: Vec<Node>,
}

const BUNDLE_SUFFIX: &[&str] =
    &[".app", ".photoslibrary", ".musiclibrary", ".tvlibrary", ".fcpbundle", ".framework", ".xcarchive", ".bundle", ".imovielibrary", ".photoslibrary"];

/// Everything on the Mac that isn't the sealed, read-only system: users,
/// apps, /Library, /private, /opt, /usr/local. macOS shows it merged into `/`.
pub const DATA_VOLUME: &str = "/System/Volumes/Data";

/// Map the Data volume when there is one: the whole disk, each byte once.
pub fn disk_roots(has_data_volume: bool) -> Vec<PathBuf> {
    if has_data_volume { vec![PathBuf::from(DATA_VOLUME)] } else { vec![] }
}

/// The path as you see it: `/System/Volumes/Data/Users` is `/Users`.
fn shown(path: &Path) -> PathBuf {
    match path.strip_prefix(DATA_VOLUME) {
        Ok(rest) => Path::new("/").join(rest),
        Err(_) => path.to_path_buf(),
    }
}

/// Give the map the paths you see, so they match the scan's and open in Finder.
pub fn rebase(node: &mut Node) {
    if node.path == Path::new(DATA_VOLUME) && node.name == DATA_VOLUME {
        node.name = "/".into();
    }
    node.path = shown(&node.path);
    for c in &mut node.children {
        rebase(c);
    }
}

fn kind_of(path: &Path, name: &str, home: &Path) -> Kind {
    let path = &shown(path);
    if BUNDLE_SUFFIX.iter().any(|s| name.ends_with(s)) {
        return if name.ends_with("library") { Kind::Personal } else { Kind::Bundle };
    }
    let personal = ["Documents", "Desktop", "Pictures", "Movies", "Music", "Library/Mobile Documents", "Library/Mail", "Library/Messages"];
    if personal.iter().any(|p| *path == home.join(p)) { Kind::Personal } else { Kind::Folder }
}

struct Walk<'a> {
    opts: &'a MapOptions,
    dev: u64,
    /// (dev, inode) of files with more than one name, counted once.
    links: Mutex<HashSet<(u64, u64)>>,
}

/// Map one folder (a root).
pub fn map_root(root: &Path, opts: &MapOptions) -> Option<Node> {
    let md = fs::metadata(root).ok()?;
    if !md.is_dir() {
        return None;
    }
    let w = Walk { opts, dev: md.dev(), links: Mutex::new(HashSet::new()) };
    let name = root.to_string_lossy().into_owned();
    Some(w.node(root, name, 0))
}

impl Walk<'_> {
    fn file_bytes(&self, md: &fs::Metadata) -> u64 {
        if md.nlink() > 1 && !self.links.lock().unwrap().insert((md.dev(), md.ino())) {
            return 0;
        }
        md.blocks() * 512
    }

    fn node(&self, path: &Path, name: String, depth: usize) -> Node {
        let kind = kind_of(path, &name, &self.opts.home);
        let Ok(rd) = fs::read_dir(path) else {
            return Node { path: path.to_path_buf(), name, kind: Kind::Unreadable, bytes: 0, cleanable: 0, children: vec![] };
        };
        let mut files = 0u64;
        let mut dirs = Vec::new();
        for e in rd.flatten() {
            let Ok(md) = e.metadata() else { continue };
            if md.is_dir() {
                if md.dev() == self.dev {
                    dirs.push(e.file_name().to_string_lossy().into_owned());
                }
            } else {
                files += self.file_bytes(&md);
            }
        }
        let open = kind != Kind::Bundle && !(kind == Kind::Personal && name.ends_with("library"));
        let list = open && depth < self.opts.max_depth;
        let mut children: Vec<Node> = dirs
            .par_iter()
            .map(|d| {
                let p = path.join(d);
                if list { self.node(&p, d.clone(), depth + 1) } else { self.total(&p, d.clone()) }
            })
            .collect();
        let bytes = files + children.iter().map(|c| c.bytes).sum::<u64>();
        if !list {
            children.clear();
        } else {
            let (locked, mut readable): (Vec<Node>, Vec<Node>) = children.into_iter().partition(|c| c.kind == Kind::Unreadable);
            readable.sort_by(|a, b| b.bytes.cmp(&a.bytes).then(a.name.cmp(&b.name)));
            children = readable;
            let keep = children.iter().take_while(|c| c.bytes >= self.opts.min_bytes).count().min(self.opts.max_children);
            let rest: u64 = children.drain(keep..).map(|c| c.bytes).sum();
            if files >= self.opts.min_bytes {
                children.push(self.leaf(path, "Files here", Kind::Files, files));
            }
            let small_files = if files >= self.opts.min_bytes { 0 } else { files };
            if rest + small_files > 0 {
                children.push(self.leaf(path, "Smaller items", Kind::Other, rest + small_files));
            }
            children.sort_by(|a, b| b.bytes.cmp(&a.bytes));
            children.extend(locked);
        }
        Node { path: path.to_path_buf(), name, kind, bytes, cleanable: 0, children }
    }

    fn leaf(&self, parent: &Path, name: &str, kind: Kind, bytes: u64) -> Node {
        Node { path: parent.to_path_buf(), name: name.into(), kind, bytes, cleanable: 0, children: vec![] }
    }

    /// Just the size of a folder, no tree.
    fn total(&self, path: &Path, name: String) -> Node {
        let mut stack = vec![path.to_path_buf()];
        let mut bytes = 0;
        let mut readable = true;
        while let Some(dir) = stack.pop() {
            let Ok(rd) = fs::read_dir(&dir) else {
                readable &= dir != path;
                continue;
            };
            let subdirs: Vec<PathBuf> = rd
                .flatten()
                .filter_map(|e| {
                    let md = e.metadata().ok()?;
                    if md.is_dir() {
                        (md.dev() == self.dev).then(|| e.path())
                    } else {
                        bytes += self.file_bytes(&md);
                        None
                    }
                })
                .collect();
            if subdirs.len() > 8 {
                bytes += subdirs.par_iter().map(|d| self.total(d, String::new()).bytes).sum::<u64>();
            } else {
                stack.extend(subdirs);
            }
        }
        let kind = if readable { kind_of(path, &name, &self.opts.home) } else { Kind::Unreadable };
        Node { path: path.to_path_buf(), name, kind, bytes, cleanable: 0, children: vec![] }
    }
}

/// Add up what the scan can free in each folder of the map.
pub fn annotate(node: &mut Node, findings: &[&Finding]) {
    let mine: Vec<&Finding> = findings.iter().copied().filter(|f| f.path.starts_with(&node.path)).collect();
    if matches!(node.kind, Kind::Files | Kind::Other) {
        // These stand for leftovers of the parent; findings belong to named folders.
        return;
    }
    node.cleanable = mine.iter().map(|f| f.bytes_freed).sum::<u64>().min(node.bytes.max(1));
    for c in &mut node.children {
        annotate(c, &mine);
    }
}

/// Map all roots and mark what the findings can free.
pub fn build(roots: &[PathBuf], findings: &[Finding], opts: &MapOptions) -> Vec<Node> {
    let refs: Vec<&Finding> = findings.iter().filter(|f| f.section() != crate::Section::Blocked).collect();
    let mut nodes: Vec<Node> = roots.par_iter().filter_map(|r| map_root(r, opts)).collect();
    for n in &mut nodes {
        rebase(n);
        annotate(n, &refs);
    }
    nodes
}

/// A short text view for the terminal.
pub fn render(doc: &MapDocument, home: &Path, depth: usize) -> String {
    use crate::report::{human_bytes, tilde};
    let mut out = String::new();
    if let Some(used) = doc.used_bytes {
        let other = used.saturating_sub(doc.mapped_bytes);
        out.push_str(&format!(
            "Used {} · mapped {} · macOS, system data and snapshots ~{}\n",
            human_bytes(used),
            human_bytes(doc.mapped_bytes),
            human_bytes(other)
        ));
    }
    out.push_str(&format!("Roomy can free {} of it.\n\n", human_bytes(doc.cleanable_bytes)));
    fn walk(n: &Node, level: usize, depth: usize, home: &Path, out: &mut String) {
        let label = if level == 0 { tilde(&n.path, home) } else { n.name.clone() };
        let free = if n.cleanable > 0 { format!("   can free {}", human_bytes(n.cleanable)) } else { String::new() };
        let note = match n.kind {
            Kind::Personal => "   your files",
            Kind::Unreadable => "   no access",
            _ => "",
        };
        out.push_str(&format!("{:>9}  {}{label}{free}{note}\n", human_bytes(n.bytes), "  ".repeat(level)));
        if level < depth {
            for c in n.children.iter().filter(|c| c.bytes >= 500_000_000) {
                walk(c, level + 1, depth, home, out);
            }
        }
    }
    for r in &doc.roots {
        walk(r, 0, depth, home, &mut out);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rules::Risk;
    use crate::verify::Status;

    #[test]
    fn data_volume_shows_as_root() {
        let leaf = Node { path: "/System/Volumes/Data/Users/me/x".into(), name: "x".into(), kind: Kind::Folder, bytes: 1, cleanable: 0, children: vec![] };
        let mut n = Node { path: DATA_VOLUME.into(), name: DATA_VOLUME.into(), kind: Kind::Folder, bytes: 1, cleanable: 0, children: vec![leaf] };
        rebase(&mut n);
        assert_eq!(n.path, PathBuf::from("/"));
        assert_eq!(n.name, "/");
        assert_eq!(n.children[0].path, PathBuf::from("/Users/me/x"));
    }

    #[test]
    fn personal_folders_found_through_the_data_volume() {
        let home = Path::new("/Users/me");
        assert_eq!(kind_of(Path::new("/System/Volumes/Data/Users/me/Documents"), "Documents", home), Kind::Personal);
        assert_eq!(kind_of(Path::new("/Users/me/Documents"), "Documents", home), Kind::Personal);
    }

    #[test]
    fn whole_disk_roots() {
        assert_eq!(disk_roots(true), vec![PathBuf::from(DATA_VOLUME)]);
    }

    fn file(p: &Path, n: usize) {
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, vec![7u8; n]).unwrap();
    }

    fn opts(home: &Path) -> MapOptions {
        MapOptions { max_depth: 3, min_bytes: 50_000, max_children: 2, home: home.to_path_buf() }
    }

    fn find<'a>(n: &'a Node, name: &str) -> &'a Node {
        n.children.iter().find(|c| c.name == name).unwrap_or_else(|| panic!("no {name} in {:?}", n.children.iter().map(|c| &c.name).collect::<Vec<_>>()))
    }

    fn finding(path: &Path, bytes: u64) -> Finding {
        Finding {
            rule: "r".into(),
            category: "c".into(),
            risk: Risk::Safe,
            status: Status::Ready,
            reason: None,
            path: path.to_path_buf(),
            bytes_on_disk: bytes,
            bytes_freed: bytes,
            files: 1,
            clean: None,
            explain: String::new(),
            detail: None,
            label: None,
        }
    }

    #[test]
    fn maps_sizes_groups_small_and_marks_cleanable() {
        let d = tempfile::tempdir().unwrap();
        let h = d.path();
        file(&h.join("code/big/target/a"), 400_000);
        file(&h.join("code/big/src/main.rs"), 100_000);
        file(&h.join("code/mid/x"), 200_000);
        file(&h.join("code/tiny1/x"), 1_000);
        file(&h.join("code/tiny2/x"), 1_000);
        file(&h.join("code/loose.bin"), 120_000);
        file(&h.join("Tool.app/Contents/bin"), 300_000);
        file(&h.join("Documents/notes.txt"), 60_000);
        fs::hard_link(h.join("code/mid/x"), h.join("code/mid/x-link")).unwrap();

        let findings = vec![finding(&h.join("code/big/target"), 400_000)];
        let root = &build(&[h.to_path_buf()], &findings, &opts(h))[0];
        let code = find(root, "code");
        let big = find(code, "big");
        assert!(big.bytes >= 500_000 && big.bytes < 600_000, "{}", big.bytes);
        assert_eq!(big.cleanable, 400_000);
        assert_eq!(code.cleanable, 400_000);
        assert_eq!(root.cleanable, 400_000);
        let mid = find(code, "mid");
        assert!(mid.bytes < 300_000, "hard link counted once: {}", mid.bytes);
        assert_eq!(code.children.iter().filter(|c| c.kind == Kind::Folder).count(), 2, "max_children");
        let files = find(code, "Files here");
        assert_eq!(files.kind, Kind::Files);
        assert!(find(code, "Smaller items").bytes > 0);
        let sum: u64 = code.children.iter().map(|c| c.bytes).sum();
        assert_eq!(sum, code.bytes, "children add up to the parent");

        let app = find(root, "Tool.app");
        assert_eq!(app.kind, Kind::Bundle);
        assert!(app.children.is_empty() && app.bytes >= 300_000);
        assert_eq!(kind_of(&h.join("Documents"), "Documents", h), Kind::Personal);
        assert_eq!(kind_of(&h.join("x/Photos.photoslibrary"), "Photos.photoslibrary", h), Kind::Personal);
    }

    #[test]
    fn deep_folders_are_counted_not_listed() {
        let d = tempfile::tempdir().unwrap();
        let h = d.path();
        file(&h.join("a/b/c/d/e/f/g"), 300_000);
        let root = map_root(h, &opts(h)).unwrap();
        let c = find(find(find(&root, "a"), "b"), "c");
        assert!(c.children.is_empty(), "depth 3 is the last listed level");
        assert!(c.bytes >= 300_000);
    }

    #[test]
    fn unreadable_folders_are_marked() {
        use std::os::unix::fs::PermissionsExt;
        let d = tempfile::tempdir().unwrap();
        let h = d.path();
        file(&h.join("locked/secret"), 100_000);
        fs::set_permissions(h.join("locked"), fs::Permissions::from_mode(0o000)).unwrap();
        let root = map_root(h, &opts(h)).unwrap();
        fs::set_permissions(h.join("locked"), fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(find(&root, "locked").kind, Kind::Unreadable);
    }
}
