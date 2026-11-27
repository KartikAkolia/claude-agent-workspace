//! Recovery copies of unsaved work (docs/mdview-plan.md, "Phase 4 design"): the folder and its
//! lock, the copy format, the local-path test, the per-window slot that writes and deletes
//! copies, and the startup scan. The format and the mountinfo parsing are pure and unit-tested.

use std::collections::{HashMap, VecDeque};
use std::ffi::OsString;
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, FileExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

use gtk::{gio, glib};

use crate::file::{self, Guard};

/// The header's fixed start; the attempts digit follows it, at byte 18.
const PREFIX: &[u8] = b"mdview-recovery 1 ";
const DIGIT_AT: u64 = 18;
/// The longest header line, enough for any local path percent-encoded (about 12 KiB).
pub const HEADER_MAX: usize = 16 * 1024;
/// Filesystems the local-path test trusts: local ones, where nothing can wait on a daemon or a
/// network. Anything else (FUSE, NFS, CIFS, autofs, overlay, 9p…) isn't local.
const LOCAL_TYPES: [&str; 12] = [
    "ext4", "ext3", "ext2", "btrfs", "xfs", "f2fs", "bcachefs", "zfs", "tmpfs", "vfat", "exfat",
    "ntfs3",
];
const MAX_LINKS: usize = 40;

/// The recovery lock, held for the life of the process once taken.
static LOCK: OnceLock<File> = OnceLock::new();

// The copy format.

/// A decoded copy.
#[derive(Debug)]
pub struct RecoveryCopy {
    pub attempts: u8,
    pub time: i64,
    pub uri: Option<String>,
    pub guard: Option<Guard>,
    pub text: String,
}

/// The copy's bytes: the header line, then the text. `None` when the text or the header is over
/// its limit, which the caller reports as "Too large to autosave".
pub fn encode(
    attempts: u8,
    time: i64,
    uri: Option<&str>,
    guard: Option<&Guard>,
    text: &str,
) -> Option<Vec<u8>> {
    if text.len() > max_text() {
        return None;
    }
    let header = format!(
        "{}{} {time} {} {} {}\n",
        String::from_utf8_lossy(PREFIX),
        attempts.min(9),
        text.len(),
        uri.unwrap_or("-"),
        guard.map_or("-", Guard::to_hex),
    );
    if header.len() > HEADER_MAX {
        return None;
    }
    let mut bytes = header.into_bytes();
    bytes.extend_from_slice(text.as_bytes());
    Some(bytes)
}

fn max_text() -> usize {
    usize::try_from(file::MAX_BYTES).unwrap_or(usize::MAX)
}

/// Decodes a copy. The header must match exactly, `length` must equal the text's byte count,
/// and the text must pass the same checks as an opened file (file::check_text).
pub fn decode(bytes: &[u8]) -> Result<RecoveryCopy, String> {
    let end = bytes
        .iter()
        .take(HEADER_MAX)
        .position(|&b| b == b'\n')
        .ok_or("it has no header line")?;
    let header = &bytes[..end];
    let rest = header
        .strip_prefix(PREFIX)
        .ok_or("it isn't an mdview recovery copy")?;
    let rest = std::str::from_utf8(rest).map_err(|_| "its header isn't UTF-8")?;
    let fields: Vec<&str> = rest.split(' ').collect();
    let [attempts, time, length, uri, guard] = fields[..] else {
        return Err("its header doesn't have its fields".to_owned());
    };
    let attempts = match attempts.as_bytes() {
        [d @ b'0'..=b'9'] => d - b'0',
        _ => return Err("its attempts count is malformed".to_owned()),
    };
    let time = time.parse::<i64>().map_err(|_| "its time is malformed")?;
    let length = length
        .parse::<usize>()
        .map_err(|_| "its length is malformed")?;
    let text = &bytes[end + 1..];
    if length > max_text() {
        return Err("its text is over the size limit".to_owned());
    }
    if text.len() != length {
        return Err(format!("it is {} bytes, not {length}", text.len()));
    }
    let uri = match uri {
        "-" => None,
        u if !u.is_empty() && !u.contains(char::is_whitespace) => Some(u.to_owned()),
        _ => return Err("its URI is malformed".to_owned()),
    };
    let guard = match guard {
        "-" => None,
        hex => Some(Guard::from_hex(hex).ok_or("its guard is malformed")?),
    };
    let text = file::check_text(text)?.to_owned();
    Ok(RecoveryCopy {
        attempts,
        time,
        uri,
        guard,
        text,
    })
}

/// A copy's file name stem must be a lowercase uuid, so the scan ignores anything else.
fn is_copy_stem(stem: &str) -> bool {
    glib::uuid_string_is_valid(stem) && !stem.bytes().any(|b| b.is_ascii_uppercase())
}

// The local-path test.

#[derive(Debug, PartialEq, Eq)]
pub struct Mount {
    point: Vec<u8>,
    fstype: String,
}

/// Parses `/proc/self/mountinfo`: field 5 is the mount point (octal-escaped), and the type is
/// the first field after the ` - ` separator, since the optional fields before it vary.
/// It is bytes, not text: the kernel escapes only space, tab, newline and backslash, so a mount
/// point can hold any other byte.
pub fn parse_mountinfo(text: &[u8]) -> Vec<Mount> {
    text.split(|&b| b == b'\n')
        .filter_map(|line| {
            let fields: Vec<&[u8]> = line.split(|&b| b == b' ').collect();
            let separator = fields.iter().position(|&f| f == b"-")?;
            let point = unescape(fields.get(4)?);
            let fstype = String::from_utf8_lossy(fields.get(separator + 1)?).into_owned();
            Some(Mount { point, fstype })
        })
        .collect()
}

/// Decodes mountinfo's `\040`-style octal escapes. One that doesn't fit a byte stays literal.
fn unescape(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let octal = bytes
            .get(i + 1..i + 4)
            .filter(|d| d.iter().all(|b| (b'0'..=b'7').contains(b)))
            .and_then(|d| {
                let value = d.iter().fold(0u16, |n, b| n * 8 + u16::from(b - b'0'));
                u8::try_from(value).ok()
            });
        match (bytes[i], octal) {
            (b'\\', Some(byte)) => {
                out.push(byte);
                i += 4;
            }
            (b, _) => {
                out.push(b);
                i += 1;
            }
        }
    }
    out
}

/// Whether `point` is `path` or one of its component prefixes (`/mnt/a` is a prefix of
/// `/mnt/a/x`, not of `/mnt/ab`).
fn is_component_prefix(point: &[u8], path: &[u8]) -> bool {
    point == b"/"
        || path == point
        || (path.starts_with(point) && path.get(point.len()) == Some(&b'/'))
}

/// Whether the mount `path` sits on is local: the longest component-prefix mount point wins,
/// and a point listed more than once is local only if every entry for it is, since the later
/// line isn't always the visible mount (a mount placed beneath another).
pub fn mount_is_local(mounts: &[Mount], path: &[u8]) -> bool {
    let Some(longest) = mounts
        .iter()
        .filter(|m| is_component_prefix(&m.point, path))
        .map(|m| m.point.len())
        .max()
    else {
        return false;
    };
    mounts
        .iter()
        .filter(|m| m.point.len() == longest && is_component_prefix(&m.point, path))
        .all(|m| LOCAL_TYPES.contains(&m.fstype.as_str()))
}

/// Whether a path can be touched without risk of an uninterruptible wait on a FUSE daemon or a
/// network mount. It walks the path from `/`, checking each prefix's mount before touching it,
/// and follows symlinks (up to 40) through `readlink` of the local directory they sit in.
/// `ENOENT` counts as local, since the missing component's parent was; any other error doesn't.
pub fn is_local_path(path: &Path) -> bool {
    let Ok(text) = fs::read("/proc/self/mountinfo") else {
        return false;
    };
    walk(path, &parse_mountinfo(&text))
}

fn walk(path: &Path, mounts: &[Mount]) -> bool {
    if !path.is_absolute() || !mount_is_local(mounts, b"/") {
        return false;
    }
    let mut resolved = PathBuf::from("/");
    let mut pending: VecDeque<OsString> = components(path);
    let mut links = 0;
    while let Some(part) = pending.pop_front() {
        if part == ".." {
            resolved.pop();
            continue;
        }
        let candidate = resolved.join(&part);
        if !mount_is_local(mounts, candidate.as_os_str().as_bytes()) {
            return false;
        }
        match fs::symlink_metadata(&candidate) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => return true,
            Err(_) => return false,
            Ok(meta) if meta.file_type().is_symlink() => {
                links += 1;
                let Ok(target) = fs::read_link(&candidate) else {
                    return false;
                };
                if links > MAX_LINKS {
                    return false;
                }
                if target.is_absolute() {
                    resolved = PathBuf::from("/");
                }
                for part in components(&target).into_iter().rev() {
                    pending.push_front(part);
                }
            }
            Ok(_) => resolved = candidate,
        }
    }
    true
}

/// A path's parts, with `.` dropped and `..` kept for the walk to apply after resolution.
fn components(path: &Path) -> VecDeque<OsString> {
    path.components()
        .filter_map(|c| match c {
            Component::Normal(p) => Some(p.to_owned()),
            Component::ParentDir => Some(OsString::from("..")),
            Component::RootDir | Component::CurDir | Component::Prefix(_) => None,
        })
        .collect()
}

// The folder and the startup scan.

/// `$XDG_STATE_HOME/mdview/recovery` (or `~/.local/state/…`), `recovery-devel` for a debug
/// build, whose app id differs from an installed copy's.
pub fn folder() -> PathBuf {
    let state = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| glib::home_dir().join(".local/state"));
    let name = if cfg!(debug_assertions) {
        "recovery-devel"
    } else {
        "recovery"
    };
    state.join("mdview").join(name)
}

/// A copy to reopen, its attempts already raised on disk.
pub struct Recovered {
    pub uuid: String,
    pub copy: RecoveryCopy,
}

/// What startup found.
pub struct Startup {
    /// `None` when autosave is on, or why it is off.
    pub off: Option<String>,
    pub recovered: Vec<Recovered>,
    /// Copies moved to `failed/` on this start.
    pub failed: usize,
}

impl Startup {
    fn off(reason: impl Into<String>) -> Self {
        Self {
            off: Some(reason.into()),
            recovered: Vec::new(),
            failed: 0,
        }
    }
}

/// Checks the folder, takes the lock, and scans for copies, in the design's order: sweep,
/// decode, filter (moving failures to `failed/`), open every survivor for writing, then bump.
pub fn start() -> Startup {
    let dir = folder();
    // Before anything is created, so a `~/.local/state` symlink into a dead mount can't hang it.
    if !is_local_path(&dir) {
        return Startup::off("the recovery folder isn't on a local filesystem");
    }
    if let Err(e) = DirBuilder::new().recursive(true).mode(0o700).create(&dir) {
        return Startup::off(format!("the recovery folder can't be created: {e}"));
    }
    if let Err(reason) = check_folder(&dir) {
        return Startup::off(reason);
    }
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(dir.join("lock"));
    match lock.map(|f| (f.try_lock(), f)) {
        Ok((Ok(()), f)) => {
            let _ = LOCK.set(f);
        }
        Ok((Err(fs::TryLockError::WouldBlock), _)) => {
            return Startup::off("another mdview is using the recovery folder");
        }
        Ok((Err(fs::TryLockError::Error(e)), _)) => {
            return Startup::off(format!("the recovery lock can't be taken: {e}"));
        }
        Err(e) => return Startup::off(format!("the recovery lock can't be opened: {e}")),
    }
    scan(&dir)
}

/// The folder must be the user's own real folder, `0700`; a wider mode is tightened.
fn check_folder(dir: &Path) -> Result<(), String> {
    let meta = fs::symlink_metadata(dir).map_err(|e| format!("the recovery folder: {e}"))?;
    if meta.file_type().is_symlink() || !meta.is_dir() {
        return Err("the recovery folder is a symlink or not a folder".to_owned());
    }
    let me = gio::Credentials::new().unix_user().ok();
    if me != Some(meta.uid()) {
        return Err("the recovery folder isn't owned by you".to_owned());
    }
    if meta.mode() & 0o077 != 0 {
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
            .map_err(|e| format!("the recovery folder's mode can't be tightened: {e}"))?;
    }
    Ok(())
}

fn scan(dir: &Path) -> Startup {
    let Ok(entries) = fs::read_dir(dir) else {
        return Startup::off("the recovery folder can't be read");
    };
    let mut decoded: Vec<(String, RecoveryCopy)> = Vec::new();
    let mut fail: Vec<String> = Vec::new();
    // A passing I/O error says nothing about the copy: every copy then waits for a later start.
    let mut unreadable: (usize, Option<io::Error>) = (0, None);
    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(e) => {
                unreadable.0 += 1;
                unreadable.1.get_or_insert(e);
                continue;
            }
        };
        let name = entry.file_name();
        let path = entry.path();
        if name.as_bytes().ends_with(b".tmp") {
            let _ = fs::remove_file(&path);
            continue;
        }
        let Some(stem) = name.to_str().and_then(|n| n.strip_suffix(".md")) else {
            continue;
        };
        if !is_copy_stem(stem) {
            continue;
        }
        match read_copy(&path) {
            Ok(Ok(copy)) => decoded.push((stem.to_owned(), copy)),
            Ok(Err(_)) => fail.push(stem.to_owned()),
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => {
                unreadable.0 += 1;
                unreadable.1.get_or_insert(e);
            }
        }
    }
    if let (unread, Some(e)) = unreadable {
        let count = decoded.len() + fail.len() + unread;
        return left(format!("a copy can't be read: {e}"), count, 0);
    }
    // Filter: copies at the attempts limit, and older copies of the same file. The newest is
    // chosen among every decoded copy, so an older one never reopens in place of a newer one
    // that failed.
    let newest = newest_by_uri(&decoded);
    let mut keep: Vec<(String, RecoveryCopy)> = Vec::new();
    for (uuid, copy) in decoded {
        let newest_of_its_file = copy
            .uri
            .as_ref()
            .is_none_or(|uri| newest.get(uri) == Some(&uuid));
        if copy.attempts < 2 && newest_of_its_file {
            keep.push((uuid, copy));
        } else {
            fail.push(uuid);
        }
    }
    // Moves first; any failure leaves every copy not yet moved for a later start.
    let failed_dir = dir.join("failed");
    let mut moved = 0;
    let unmoved = |moved: usize| keep.len() + fail.len() - moved;
    for uuid in &fail {
        let name = format!("{uuid}.md");
        let result = DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&failed_dir)
            .and_then(|()| fs::rename(dir.join(&name), failed_dir.join(&name)));
        if let Err(e) = result {
            return left(
                format!("a copy can't be moved aside: {e}"),
                unmoved(moved),
                moved,
            );
        }
        moved += 1;
    }
    // Then every survivor opened for writing, and only then any bump.
    let mut handles = Vec::with_capacity(keep.len());
    for (uuid, _) in &keep {
        match OpenOptions::new()
            .write(true)
            .open(dir.join(format!("{uuid}.md")))
        {
            Ok(f) => handles.push(f),
            Err(e) => {
                return left(
                    format!("a copy can't be opened for writing: {e}"),
                    keep.len(),
                    moved,
                );
            }
        }
    }
    let count = keep.len();
    let mut recovered = Vec::with_capacity(count);
    for ((uuid, mut copy), handle) in keep.into_iter().zip(handles) {
        copy.attempts += 1;
        // No copy opens on this start, so all of them are left.
        if let Err(e) = handle.write_all_at(&[b'0' + copy.attempts], DIGIT_AT) {
            return left(format!("a copy can't be updated: {e}"), count, moved);
        }
        recovered.push(Recovered { uuid, copy });
    }
    Startup {
        off: None,
        recovered,
        failed: moved,
    }
}

/// For each URI, the uuid of its newest copy: by `time`, then the byte-wise greater uuid.
fn newest_by_uri(copies: &[(String, RecoveryCopy)]) -> HashMap<String, String> {
    let mut newest: HashMap<String, (i64, &str)> = HashMap::new();
    for (uuid, copy) in copies {
        if let Some(uri) = &copy.uri {
            let rank = (copy.time, uuid.as_str());
            let best = newest.entry(uri.clone()).or_insert(rank);
            if rank > *best {
                *best = rank;
            }
        }
    }
    newest
        .into_iter()
        .map(|(uri, (_, uuid))| (uri, uuid.to_owned()))
        .collect()
}

/// Autosave off with copies left for a later start.
fn left(reason: String, count: usize, failed: usize) -> Startup {
    let plural = if count == 1 { "copy" } else { "copies" };
    Startup {
        off: Some(format!(
            "{reason}; {count} recovered {plural} left for a later start"
        )),
        recovered: Vec::new(),
        failed,
    }
}

/// Reads a copy: a regular file, not a symlink, within the limits. The outer error is an I/O
/// failure, which says nothing about the copy; the inner one means the copy itself is bad.
fn read_copy(path: &Path) -> io::Result<Result<RecoveryCopy, String>> {
    let meta = fs::symlink_metadata(path)?;
    let limit = file::MAX_BYTES.unsigned_abs() + HEADER_MAX as u64;
    if !meta.file_type().is_file() || meta.len() > limit {
        return Ok(Err("not a regular file within the limits".to_owned()));
    }
    let mut bytes = Vec::new();
    File::open(path)?.take(limit + 1).read_to_end(&mut bytes)?;
    Ok(decode(&bytes))
}

/// `fsync`s the folder, so renames and removals in it survive a power cut.
pub fn sync_folder(dir: &Path) -> io::Result<()> {
    File::open(dir)?.sync_all()
}

// The per-window slot.

/// Shared between a window and its writes on the thread pool. A delete raises the generation,
/// so a write that started before it can't land; a final delete also sets `closed`, so none
/// can start or land after it.
#[derive(Debug)]
pub struct Slot {
    generation: u64,
    seq: u64,
    closed: bool,
    attempts: u8,
}

pub type SlotRef = Arc<Mutex<Slot>>;

pub fn new_slot(attempts: u8) -> SlotRef {
    Arc::new(Mutex::new(Slot {
        generation: 0,
        seq: 0,
        closed: false,
        attempts,
    }))
}

/// A panicked writer must not take the app down with it.
fn guard(slot: &SlotRef) -> MutexGuard<'_, Slot> {
    slot.lock().unwrap_or_else(PoisonError::into_inner)
}

/// One write, prepared on the main thread and run on the pool.
pub struct Job {
    dir: PathBuf,
    uuid: String,
    pub n: u64,
    generation: u64,
    slot: SlotRef,
    bytes: Vec<u8>,
}

/// Prepares a write, or `None` when the slot is closed. The bytes are encoded by the caller.
pub fn begin(slot: &SlotRef, dir: &Path, uuid: &str, bytes: Vec<u8>) -> Option<Job> {
    let mut s = guard(slot);
    if s.closed {
        return None;
    }
    s.seq += 1;
    Some(Job {
        dir: dir.to_owned(),
        uuid: uuid.to_owned(),
        n: s.seq,
        generation: s.generation,
        slot: slot.clone(),
        bytes,
    })
}

/// Runs a write on the pool: its own `.tmp`, `0600`, synced; then, under the slot mutex, the
/// current attempts digit stamped in and the rename, unless a delete or close came meanwhile;
/// then the folder synced with the mutex released.
pub fn run(job: Job) -> Result<(), String> {
    let tmp = job.dir.join(format!("{}.{}.tmp", job.uuid, job.n));
    let target = job.dir.join(format!("{}.md", job.uuid));
    let written = (|| -> io::Result<()> {
        let mut f = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)?;
        f.write_all(&job.bytes)?;
        f.sync_all()
    })();
    if let Err(e) = written {
        let _ = fs::remove_file(&tmp);
        return Err(e.to_string());
    }
    let landed = {
        let s = guard(&job.slot);
        if s.generation == job.generation && !s.closed {
            let stamped = OpenOptions::new()
                .write(true)
                .open(&tmp)
                .and_then(|f| f.write_all_at(&[b'0' + s.attempts.min(9)], DIGIT_AT))
                .and_then(|()| fs::rename(&tmp, &target));
            Some(stamped)
        } else {
            None
        }
    };
    match landed {
        Some(Ok(())) => sync_folder(&job.dir).map_err(|e| e.to_string()),
        Some(Err(e)) => {
            let _ = fs::remove_file(&tmp);
            Err(e.to_string())
        }
        None => remove_if_present(&tmp).map_err(|e| e.to_string()),
    }
}

/// Deletes a window's copy, on the main thread. A final delete also closes the slot. The folder
/// `fsync` follows on the pool. An error other than "not there" is returned, so it can show.
pub fn delete(slot: &SlotRef, dir: &Path, uuid: &str, final_: bool) -> Result<(), String> {
    let result = {
        let mut s = guard(slot);
        s.generation += 1;
        if final_ {
            s.closed = true;
        }
        remove_if_present(&dir.join(format!("{uuid}.md")))
    };
    let dir = dir.to_owned();
    drop(gio::spawn_blocking(move || {
        let _ = sync_folder(&dir);
    }));
    result.map_err(|e| e.to_string())
}

/// Moves a copy to `failed/`, for a recovered text a text buffer couldn't hold exactly; no
/// window exists for it yet. If the move fails the copy stays, for a later start.
pub fn set_aside(dir: &Path, uuid: &str) -> io::Result<()> {
    let failed = dir.join("failed");
    let name = format!("{uuid}.md");
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&failed)?;
    fs::rename(dir.join(&name), failed.join(&name))
}

/// After a recovered window has stayed up: attempts back to 0, in the slot and, if the copy
/// exists, in place. Never creates the file. One critical section, so no write can stamp the
/// old digit in between.
pub fn reset_attempts(slot: &SlotRef, dir: &Path, uuid: &str) {
    let mut s = guard(slot);
    if s.closed {
        return;
    }
    s.attempts = 0;
    let _ = OpenOptions::new()
        .write(true)
        .open(dir.join(format!("{uuid}.md")))
        .and_then(|f| f.write_all_at(b"0", DIGIT_AT));
}

fn remove_if_present(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
}

pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bytes(s: &str) -> &[u8] {
        s.as_bytes()
    }

    #[test]
    fn copies_round_trip() {
        let uri = "file:///home/k/My%20Notes/caf%C3%A9.md";
        let guard = Guard::of(b"# on disk\n");
        let text = "\u{feff}# T\u{e9}st\r\n\r\nno final newline";
        let bytes = encode(1, 1_795_800_000, Some(uri), Some(&guard), text).unwrap();
        assert_eq!(&bytes[..18], PREFIX);
        assert_eq!(bytes[18], b'1');
        let copy = decode(&bytes).unwrap();
        assert_eq!(copy.attempts, 1);
        assert_eq!(copy.time, 1_795_800_000);
        assert_eq!(copy.uri.as_deref(), Some(uri));
        assert!(copy.guard.unwrap().matches(b"# on disk\n"));
        assert_eq!(copy.text, text);
        let new_doc = decode(&encode(0, 5, None, None, "").unwrap()).unwrap();
        assert!(new_doc.uri.is_none() && new_doc.guard.is_none() && new_doc.text.is_empty());
    }

    #[test]
    fn damaged_copies_are_refused() {
        let good = encode(0, 5, None, None, "text").unwrap();
        let mut short = good.clone();
        short.pop();
        let mut long = good.clone();
        long.push(b'x');
        let bad: [&[u8]; 9] = [
            b"",
            b"no header",
            &short,
            &long,
            b"mdview-recovery 2 0 5 4 - -\ntext",
            b"mdview-recovery 1 x 5 4 - -\ntext",
            b"mdview-recovery 1 0 5 4 - nothex\ntext",
            b"mdview-recovery 1 0 5 8 - -\nnul\0byte",
            b"mdview-recovery 1 0 5 1 - -\n\xff",
        ];
        for b in bad {
            assert!(decode(b).is_err(), "{:?}", String::from_utf8_lossy(b));
        }
        assert!(decode(&good).is_ok());
    }

    #[test]
    fn oversized_copies_are_not_encoded() {
        let long_uri = format!("file:///{}", "a".repeat(HEADER_MAX));
        assert!(encode(0, 0, Some(&long_uri), None, "x").is_none());
        let big = "x".repeat(max_text() + 1);
        assert!(encode(0, 0, None, None, &big).is_none());
    }

    #[test]
    fn the_newest_copy_of_a_file_wins_whatever_its_attempts() {
        let copy = |time, uri: Option<&str>, attempts| RecoveryCopy {
            attempts,
            time,
            uri: uri.map(str::to_owned),
            guard: None,
            text: String::new(),
        };
        let copies = vec![
            ("a".to_owned(), copy(10, Some("file:///x.md"), 0)),
            ("b".to_owned(), copy(20, Some("file:///x.md"), 2)),
            ("c".to_owned(), copy(20, Some("file:///y.md"), 0)),
            ("d".to_owned(), copy(20, Some("file:///y.md"), 0)),
            ("e".to_owned(), copy(5, None, 0)),
        ];
        let newest = newest_by_uri(&copies);
        assert_eq!(newest["file:///x.md"], "b");
        assert_eq!(newest["file:///y.md"], "d");
        assert_eq!(newest.len(), 2);
    }

    #[test]
    fn copy_names_are_lowercase_uuids() {
        assert!(is_copy_stem("0f8fad5b-d9cb-469f-a165-70867728950e"));
        assert!(!is_copy_stem("0F8FAD5B-D9CB-469F-A165-70867728950E"));
        assert!(!is_copy_stem("lock"));
        assert!(!is_copy_stem("0f8fad5b-d9cb-469f-a165-70867728950e.1"));
    }

    const MOUNTINFO: &str = "\
22 1 259:2 / / rw,relatime shared:1 - ext4 /dev/nvme0n1p2 rw
30 22 0:26 / /tmp rw,nosuid shared:5 - tmpfs tmpfs rw
40 22 0:40 / /nas\\040box rw - fuse.kio-fuse kio-fuse rw
41 22 0:41 / /mnt/a rw - ext4 /dev/sdb1 rw
50 22 0:50 / /home/k/stack rw master:7 - ext4 /dev/sdc1 rw
51 22 0:51 / /home/k/stack rw - fuse.sshfs host: rw
60 22 0:60 / /auto rw - autofs systemd-1 rw
61 60 0:61 / /auto rw - ext4 /dev/sdd1 rw
";

    #[test]
    fn mountinfo_is_parsed_with_escapes_and_optional_fields() {
        let mounts = parse_mountinfo(MOUNTINFO.as_bytes());
        assert_eq!(mounts.len(), 8);
        assert_eq!(mounts[2].point, bytes("/nas box"));
        assert_eq!(mounts[2].fstype, "fuse.kio-fuse");
        assert_eq!(mounts[4].fstype, "ext4");
    }

    #[test]
    fn escapes_decode_only_when_whole_and_in_range() {
        assert_eq!(unescape(br"a\040b"), b"a b");
        assert_eq!(unescape(br"a\04"), br"a\04");
        assert_eq!(unescape(br"\777"), br"\777");
        assert_eq!(unescape(br"\134"), br"\");
        // Raw bytes that aren't UTF-8 pass through.
        let mounts = parse_mountinfo(b"1 0 0:1 / /mnt/\xff rw - fuse.x x rw\n");
        assert_eq!(mounts[0].point, b"/mnt/\xff");
    }

    #[test]
    fn mounts_are_judged_by_longest_component_prefix() {
        let mounts = parse_mountinfo(MOUNTINFO.as_bytes());
        let local = |p: &str| mount_is_local(&mounts, bytes(p));
        assert!(local("/"));
        assert!(local("/home/k/notes.md"));
        assert!(local("/tmp/x"));
        assert!(!local("/nas box"));
        assert!(!local("/nas box/a.md"));
        assert!(local("/mnt/a/x.md"));
        // /mnt/ab isn't under /mnt/a: it falls back to / (ext4).
        assert!(local("/mnt/ab/x.md"));
        // One point listed twice, once local and once not: not local, whichever line is last.
        assert!(!local("/home/k/stack/x.md"));
        assert!(!local("/auto/x.md"));
    }

    #[test]
    fn the_walk_stops_before_a_non_local_mount() {
        let mounts = parse_mountinfo(MOUNTINFO.as_bytes());
        // Lexical checks only: the walk refuses before touching these.
        assert!(!walk(Path::new("/nas box/a.md"), &mounts));
        assert!(!walk(Path::new("relative.md"), &mounts));
        // A missing path on a local mount counts as local.
        assert!(walk(
            Path::new("/tmp/mdview-test-missing-zz9/x.md"),
            &mounts
        ));
    }

    #[test]
    fn the_walk_follows_symlinks_and_dotdot_into_the_mount_they_reach() {
        let root = std::env::temp_dir().join(format!("mdview-walk-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("a/b")).unwrap();
        std::os::unix::fs::symlink("../a/b", root.join("a/up")).unwrap();
        std::os::unix::fs::symlink("/nas box/x", root.join("away")).unwrap();
        std::os::unix::fs::symlink("loop", root.join("loop")).unwrap();
        let mounts = parse_mountinfo(MOUNTINFO.as_bytes());
        assert!(walk(&root.join("a/up/../b/f.md"), &mounts));
        assert!(!walk(&root.join("away/f.md"), &mounts));
        assert!(!walk(&root.join("loop/f.md"), &mounts));
        fs::remove_dir_all(&root).unwrap();
    }
}
