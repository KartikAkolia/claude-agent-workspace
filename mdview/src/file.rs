//! Reading and writing Markdown files: the strict checks, the capped read, and saves that never
//! overwrite an outside change unasked (docs/mdview-plan.md, "Strictness" and "Saving").
//! Each refusal is a lower-case clause ("it isn't a regular file"), shown under a heading such
//! as "Couldn't open ...".

use std::hash::{DefaultHasher, Hasher};
use std::path::{Path, PathBuf};

use gtk::gio;
use gtk::glib;
use gtk::prelude::*;

/// Anything bigger is refused before it is read.
pub const MAX_BYTES: i64 = 8 * 1024 * 1024;

/// `.md` or `.markdown`, in any case: shared-mime-info's `*.md` glob offers `README.MD` too.
pub fn is_markdown_name(name: &Path) -> bool {
    name.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| e.eq_ignore_ascii_case("md") || e.eq_ignore_ascii_case("markdown"))
}

/// The name Save As writes to: `.md` is added when there is no extension, and any extension
/// other than `.md` or `.markdown` is refused.
pub fn save_name(name: &Path) -> Result<PathBuf, String> {
    if is_markdown_name(name) {
        return Ok(name.to_owned());
    }
    match name.extension() {
        None => Ok(name.with_extension("md")),
        Some(_) => Err("only .md and .markdown files can be saved from mdview".to_owned()),
    }
}

/// The text, if the bytes are UTF-8 with no NUL. NUL is valid UTF-8, but `TextBuffer` rejects
/// it and keeps nothing, so a later save would wipe the file.
pub fn check_text(bytes: &[u8]) -> Result<&str, String> {
    if let Some(at) = bytes.iter().position(|&b| b == 0) {
        return Err(format!(
            "it holds a NUL byte (at byte {at}), so it isn't text"
        ));
    }
    std::str::from_utf8(bytes)
        .map_err(|e| format!("it isn't valid UTF-8 (from byte {})", e.valid_up_to()))
}

/// What the file was when mdview last read or wrote it. The etag is only the modification time,
/// so the hash of the bytes is kept too: an outside edit that restored the old time still shows.
#[derive(Clone, Debug)]
pub struct Guard {
    etag: Option<glib::GString>,
    hash: u64,
}

impl Guard {
    /// Whether `bytes` are what the file held when this guard was taken.
    pub fn matches(&self, bytes: &[u8]) -> bool {
        self.hash == hash(bytes)
    }
}

fn hash(bytes: &[u8]) -> u64 {
    let mut hasher = DefaultHasher::new();
    hasher.write(bytes);
    hasher.finish()
}

pub struct Loaded {
    pub text: String,
    pub guard: Guard,
}

/// Reads a Markdown file, refusing anything that isn't a regular file of at most `MAX_BYTES`
/// with a Markdown name. A FIFO hangs the read and `/dev/zero` exhausts memory, so the type and
/// size are checked first, following symlinks.
pub async fn load(file: &gio::File) -> Result<Loaded, String> {
    let name = file.basename().ok_or("it has no file name")?;
    if !is_markdown_name(&name) {
        return Err("only .md and .markdown files open in mdview".to_owned());
    }
    let info = file
        .query_info_future(
            "standard::type,standard::size,etag::value",
            gio::FileQueryInfoFlags::NONE,
            glib::Priority::DEFAULT,
        )
        .await
        .map_err(|e| e.message().to_owned())?;
    // Unknown passes: some gvfs backends report no type, and the capped read below still guards
    // the size. Directories, FIFOs, devices and the like are refused.
    if !matches!(
        info.file_type(),
        gio::FileType::Regular | gio::FileType::Unknown
    ) {
        return Err("it isn't a regular file".to_owned());
    }
    if info.size() > MAX_BYTES {
        return Err(too_big());
    }
    let bytes = read_capped(file).await?;
    let text = check_text(&bytes)?.to_owned();
    let guard = Guard {
        etag: info.etag(),
        hash: hash(&bytes),
    };
    Ok(Loaded { text, guard })
}

fn too_big() -> String {
    format!("it is larger than {} MiB", MAX_BYTES >> 20)
}

/// Reads in chunks and stops just past the cap: some gvfs backends report no size at all, and a
/// file may have grown since it was checked.
pub async fn read_capped(file: &gio::File) -> Result<Vec<u8>, String> {
    let limit = usize::try_from(MAX_BYTES).unwrap_or(usize::MAX);
    let stream = file
        .read_future(glib::Priority::DEFAULT)
        .await
        .map_err(|e| e.message().to_owned())?;
    let mut bytes = Vec::new();
    loop {
        let chunk = stream
            .read_bytes_future(64 * 1024, glib::Priority::DEFAULT)
            .await
            .map_err(|e| e.message().to_owned())?;
        if chunk.is_empty() {
            return Ok(bytes);
        }
        bytes.extend_from_slice(&chunk);
        if bytes.len() > limit {
            return Err(too_big());
        }
    }
}

pub enum SaveError {
    /// The file changed on disk since it was loaded or last saved.
    Conflict,
    /// The write failed. `in_place` is true where gio rewrites the file in place rather than
    /// renaming a finished copy over it, so a failure part-way can leave it incomplete.
    Failed { message: String, in_place: bool },
}

/// Saves `text` to `file`, returning the guard for what is now on disk.
///
/// With a guard, an outside change since it was taken is refused as `Conflict`: the file is
/// re-read and its hash compared, which catches an edit that kept the modification time, and the
/// write passes the etag, which closes the gap between that check and the write. A file deleted
/// meanwhile is simply written again. Without a guard (a new file, or an overwrite the user has
/// confirmed) it writes regardless.
pub async fn save(file: &gio::File, text: &str, guard: Option<&Guard>) -> Result<Guard, SaveError> {
    let mut etag = None;
    if let Some(guard) = guard {
        let exists = match file
            .query_info_future(
                "standard::type",
                gio::FileQueryInfoFlags::NONE,
                glib::Priority::DEFAULT,
            )
            .await
        {
            Ok(_) => true,
            Err(e) if e.matches(gio::IOErrorEnum::NotFound) => false,
            Err(e) => return Err(failed(file, e.message()).await),
        };
        if exists {
            // Unreadable now, or too big: either way it isn't what was loaded.
            match read_capped(file).await {
                Ok(bytes) if guard.matches(&bytes) => etag = guard.etag.clone(),
                _ => return Err(SaveError::Conflict),
            }
        }
    }
    let bytes = text.as_bytes().to_vec();
    let result = file
        .replace_contents_future(bytes, etag.as_deref(), false, gio::FileCreateFlags::NONE)
        .await;
    match result {
        Ok((bytes, etag)) => Ok(Guard {
            etag,
            hash: hash(&bytes),
        }),
        Err((_, e)) if e.matches(gio::IOErrorEnum::WrongEtag) => Err(SaveError::Conflict),
        Err((_, e)) => Err(failed(file, e.message()).await),
    }
}

async fn failed(file: &gio::File, message: &str) -> SaveError {
    SaveError::Failed {
        message: message.to_owned(),
        in_place: rewritten_in_place(file).await,
    }
}

/// Whether gio writes this file in place: for a symlink, a hard link, or a file whose folder
/// can't be written (gio/glocalfileoutputstream.c). Unknown counts as yes, the cautious answer.
async fn rewritten_in_place(file: &gio::File) -> bool {
    let Ok(info) = file
        .query_info_future(
            "standard::is-symlink,unix::nlink",
            gio::FileQueryInfoFlags::NOFOLLOW_SYMLINKS,
            glib::Priority::DEFAULT,
        )
        .await
    else {
        return true;
    };
    if info.is_symlink() || info.attribute_uint32("unix::nlink") > 1 {
        return true;
    }
    let Some(folder) = file.parent() else {
        return true;
    };
    folder
        .query_info_future(
            "access::can-write",
            gio::FileQueryInfoFlags::NONE,
            glib::Priority::DEFAULT,
        )
        .await
        .map_or(true, |i| !i.boolean("access::can-write"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markdown_names() {
        for ok in ["a.md", "README.MD", "x.Markdown", "dir.d/notes.md"] {
            assert!(is_markdown_name(Path::new(ok)), "{ok}");
        }
        for refused in ["a.txt", "md", ".md", "a.md.bak", "a.mdx", "noext"] {
            assert!(!is_markdown_name(Path::new(refused)), "{refused}");
        }
    }

    #[test]
    fn save_names() {
        let ok = |n: &str| save_name(Path::new(n)).map(|p| p.display().to_string());
        assert_eq!(ok("notes"), Ok("notes.md".to_owned()));
        assert_eq!(ok("README.MD"), Ok("README.MD".to_owned()));
        assert_eq!(ok("a.markdown"), Ok("a.markdown".to_owned()));
        assert!(ok("notes.txt").is_err());
        assert!(ok("a.md.bak").is_err());
    }

    #[test]
    fn guard_matches_only_the_same_bytes() {
        let guard = Guard {
            etag: None,
            hash: hash(b"# a\n"),
        };
        assert!(guard.matches(b"# a\n"));
        assert!(!guard.matches(b"# a\r\n"));
        assert!(!guard.matches(b""));
    }

    #[test]
    fn text_checks() {
        assert_eq!(check_text("é # ok\r\n".as_bytes()), Ok("é # ok\r\n"));
        assert!(
            check_text(b"a\0b")
                .unwrap_err()
                .contains("NUL byte (at byte 1)")
        );
        assert!(check_text(b"ok\xff").unwrap_err().contains("from byte 2"));
    }
}
