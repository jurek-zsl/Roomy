//! Measuring how much space a file or folder uses, and how much deleting it
//! would really free.
//!
//! Two traps a plain `du` falls into:
//! - APFS clones: `cp -c`, pnpm, uv and Finder copies share disk blocks.
//!   Each copy looks full size, but deleting one frees only its private
//!   (unshared) blocks. We ask APFS for that with `ATTR_CMNEXT_PRIVATESIZE`.
//! - Hard links: one file with several names. Deleting the names inside the
//!   folder frees nothing while a name outside it still exists.

use rayon::prelude::*;
use serde::Serialize;
use std::collections::HashMap;
use std::ffi::CString;
use std::fs::{self, Metadata};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
pub struct Size {
    /// Space the files take on disk, counting shared blocks fully.
    pub on_disk: u64,
    /// Space deleting them would actually free.
    pub freed: u64,
    pub files: u64,
}

struct Acc {
    dev: u64,
    on_disk: AtomicU64,
    freed: AtomicU64,
    files: AtomicU64,
    /// (dev, inode) -> (names seen inside the folder, total names, bytes)
    links: Mutex<HashMap<(u64, u64), (u64, u64, u64)>>,
}

/// Measure a file or a folder (recursively, in parallel). Never follows
/// symlinks and never crosses into another volume.
pub fn measure(path: &Path) -> Size {
    let Ok(md) = fs::symlink_metadata(path) else {
        return Size::default();
    };
    let acc = Acc {
        dev: md.dev(),
        on_disk: AtomicU64::new(0),
        freed: AtomicU64::new(0),
        files: AtomicU64::new(0),
        links: Mutex::new(HashMap::new()),
    };
    if md.is_dir() {
        measure_dir(path, &acc);
    } else if md.is_file() {
        add_file(path, &md, &acc);
    }
    let mut freed = acc.freed.into_inner();
    for (seen, nlink, bytes) in acc.links.into_inner().unwrap().into_values() {
        // Only freed if every name of the file is inside this folder.
        if seen >= nlink {
            freed += bytes;
        }
    }
    Size { on_disk: acc.on_disk.into_inner(), freed, files: acc.files.into_inner() }
}

fn measure_dir(dir: &Path, acc: &Acc) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    let entries: Vec<_> = rd.flatten().collect();
    entries.par_iter().for_each(|e| {
        let p = e.path();
        let Ok(md) = fs::symlink_metadata(&p) else { return };
        if md.dev() != acc.dev {
            return;
        }
        if md.is_dir() {
            measure_dir(&p, acc);
        } else if md.is_file() {
            add_file(&p, &md, acc);
        }
    });
}

fn add_file(p: &Path, md: &Metadata, acc: &Acc) {
    let alloc = md.blocks() * 512;
    acc.files.fetch_add(1, Ordering::Relaxed);
    if md.nlink() > 1 {
        let mut links = acc.links.lock().unwrap();
        let e = links.entry((md.dev(), md.ino())).or_insert((0, md.nlink(), alloc));
        e.0 += 1;
        if e.0 == 1 {
            acc.on_disk.fetch_add(alloc, Ordering::Relaxed);
        }
        return;
    }
    acc.on_disk.fetch_add(alloc, Ordering::Relaxed);
    let freed = match apfs_clone_info(p) {
        // Shared with a clone: only the private part comes back.
        Some(info) if info.refcount > 1 => info.private.min(alloc),
        _ => alloc,
    };
    acc.freed.fetch_add(freed, Ordering::Relaxed);
}

// --- APFS clone info via getattrlist(2) ------------------------------------

const ATTR_BIT_MAP_COUNT: u16 = 5;
const ATTR_CMN_RETURNED_ATTRS: u32 = 0x8000_0000;
const ATTR_CMNEXT_PRIVATESIZE: u32 = 0x0000_0008;
const ATTR_CMNEXT_CLONE_REFCNT: u32 = 0x0000_1000;
const FSOPT_NOFOLLOW: u32 = 0x0000_0001;
const FSOPT_ATTR_CMN_EXTENDED: u32 = 0x0000_0020;

#[repr(C)]
struct AttrList {
    bitmapcount: u16,
    reserved: u16,
    commonattr: u32,
    volattr: u32,
    dirattr: u32,
    fileattr: u32,
    forkattr: u32,
}

#[repr(C, align(8))]
struct AttrBuf([u8; 64]);

unsafe extern "C" {
    #[link_name = "getattrlist"]
    fn sys_getattrlist(
        path: *const libc::c_char,
        attr_list: *mut AttrList,
        attr_buf: *mut libc::c_void,
        attr_buf_size: libc::size_t,
        options: u32,
    ) -> libc::c_int;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CloneInfo {
    /// Bytes not shared with any clone.
    pub private: u64,
    /// How many files share these blocks (1 = not cloned).
    pub refcount: u32,
}

/// Ask APFS how much of a file is shared with clones. `None` when the
/// volume doesn't support it (not APFS) or the call fails.
pub fn apfs_clone_info(path: &Path) -> Option<CloneInfo> {
    let c = CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut list = AttrList {
        bitmapcount: ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: ATTR_CMN_RETURNED_ATTRS,
        volattr: 0,
        dirattr: 0,
        fileattr: 0,
        forkattr: ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONE_REFCNT,
    };
    let mut buf = AttrBuf([0; 64]);
    // SAFETY: valid C string, a correctly laid out attrlist, and a buffer
    // whose real size we pass.
    let rc = unsafe {
        sys_getattrlist(
            c.as_ptr(),
            &mut list,
            buf.0.as_mut_ptr().cast(),
            buf.0.len(),
            FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED,
        )
    };
    if rc != 0 {
        return None;
    }
    let b = &buf.0;
    let u32_at = |o: usize| u32::from_ne_bytes(b[o..o + 4].try_into().unwrap());
    // Layout: u32 length, attribute_set_t (5 x u32) of returned attrs,
    // then the requested extended attrs in bit order.
    let returned_fork = u32_at(4 + 16);
    let mut off = 24;
    let private = if returned_fork & ATTR_CMNEXT_PRIVATESIZE != 0 {
        let v = i64::from_ne_bytes(b[off..off + 8].try_into().unwrap());
        off += 8;
        v.max(0) as u64
    } else {
        return None;
    };
    let refcount = if returned_fork & ATTR_CMNEXT_CLONE_REFCNT != 0 { u32_at(off) } else { 1 };
    Some(CloneInfo { private, refcount })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    unsafe extern "C" {
        fn clonefile(src: *const libc::c_char, dst: *const libc::c_char, flags: u32) -> libc::c_int;
    }

    fn write_file(p: &Path, bytes: usize) {
        let mut f = fs::File::create(p).unwrap();
        // Non-zero, non-repeating-ish data so nothing gets compressed away.
        let chunk: Vec<u8> = (0..65536u32).map(|i| (i.wrapping_mul(2654435761) >> 13) as u8).collect();
        let mut left = bytes;
        while left > 0 {
            let n = left.min(chunk.len());
            f.write_all(&chunk[..n]).unwrap();
            left -= n;
        }
        f.sync_all().unwrap();
    }

    fn clone(src: &Path, dst: &Path) {
        let s = CString::new(src.as_os_str().as_bytes()).unwrap();
        let d = CString::new(dst.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { clonefile(s.as_ptr(), d.as_ptr(), 0) }, 0, "clonefile failed");
    }

    #[test]
    fn plain_folder_frees_its_size() {
        let dir = tempfile::tempdir().unwrap();
        write_file(&dir.path().join("a"), 2_000_000);
        write_file(&dir.path().join("b"), 1_000_000);
        let s = measure(dir.path());
        assert_eq!(s.files, 2);
        assert!(s.on_disk >= 3_000_000, "{s:?}");
        assert_eq!(s.freed, s.on_disk);
    }

    #[test]
    fn cloned_file_frees_almost_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("orig");
        let inner = dir.path().join("inner");
        fs::create_dir(&inner).unwrap();
        write_file(&src, 4_000_000);
        clone(&src, &inner.join("copy"));

        let info = apfs_clone_info(&inner.join("copy")).expect("APFS clone info");
        assert!(info.refcount >= 2, "{info:?}");

        let s = measure(&inner);
        assert!(s.on_disk >= 4_000_000, "looks full size: {s:?}");
        assert!(s.freed < 400_000, "but deleting frees little: {s:?}");
    }

    #[test]
    fn hard_link_outside_folder_frees_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let inner = dir.path().join("inner");
        fs::create_dir(&inner).unwrap();
        write_file(&inner.join("f"), 1_000_000);
        fs::hard_link(inner.join("f"), dir.path().join("outside")).unwrap();
        let s = measure(&inner);
        assert!(s.on_disk >= 1_000_000);
        assert_eq!(s.freed, 0);
    }

    #[test]
    fn hard_links_all_inside_count_once() {
        let dir = tempfile::tempdir().unwrap();
        write_file(&dir.path().join("f"), 1_000_000);
        fs::hard_link(dir.path().join("f"), dir.path().join("g")).unwrap();
        let s = measure(dir.path());
        assert_eq!(s.files, 2);
        assert_eq!(s.freed, s.on_disk);
        assert!(s.on_disk < 1_500_000, "counted once: {s:?}");
    }
}
