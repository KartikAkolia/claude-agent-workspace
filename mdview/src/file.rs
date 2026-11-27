//! Opening Markdown files: the strict checks, then the read (docs/mdview-plan.md, "Strictness").
//! Each refusal is a lower-case clause ("it isn't a regular file"), shown under the heading
//! "Couldn't open ...".

use std::path::Path;

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

/// Reads a Markdown file, refusing anything that isn't a regular file of at most `MAX_BYTES`
/// with a Markdown name. A FIFO hangs the read and `/dev/zero` exhausts memory, so the type and
/// size are checked first, following symlinks.
pub async fn load(file: &gio::File) -> Result<String, String> {
    let name = file.basename().ok_or("it has no file name")?;
    if !is_markdown_name(&name) {
        return Err("only .md and .markdown files open in mdview".to_owned());
    }
    let info = file
        .query_info_future(
            "standard::type,standard::size",
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
    let too_big = || format!("it is larger than {} MiB", MAX_BYTES >> 20);
    if info.size() > MAX_BYTES {
        return Err(too_big());
    }
    // Read in chunks and stop just past the cap: some gvfs backends report no size at all, and
    // the file may have grown since the check.
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
            break;
        }
        bytes.extend_from_slice(&chunk);
        if bytes.len() > limit {
            return Err(too_big());
        }
    }
    check_text(&bytes).map(str::to_owned)
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
