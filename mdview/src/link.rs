//! What a click on a link does. Pure apart from glib's URI helpers, so it is unit-tested.

use std::path::{Path, PathBuf};

use gtk::glib;

use crate::file;

#[derive(Debug, PartialEq, Eq)]
pub enum Target {
    /// `http`, `https` or `mailto`: handed to the desktop, through the portal.
    External(String),
    /// A Markdown file, opened in the same window.
    Markdown(PathBuf),
    /// Anything else: an in-page anchor, another scheme, a file that isn't Markdown, or a
    /// relative link in a document that has no folder yet.
    Nothing,
}

/// Resolves a link's target against the folder of the document it is in. A relative path has
/// its `#fragment` and `?query` dropped and its percent-escapes decoded.
pub fn resolve(href: &str, folder: Option<&Path>) -> Target {
    let href = href.trim();
    if let Some(scheme) = glib::Uri::peek_scheme(href) {
        return match scheme.as_str() {
            "http" | "https" | "mailto" => Target::External(href.to_owned()),
            "file" => {
                let uri = href.split('#').next().unwrap_or(href);
                match glib::filename_from_uri(uri) {
                    Ok((path, _)) if file::is_markdown_name(&path) => Target::Markdown(path),
                    _ => Target::Nothing,
                }
            }
            _ => Target::Nothing,
        };
    }
    let path = href.split(['#', '?']).next().unwrap_or_default();
    let Some(decoded) = glib::Uri::unescape_string(path, None) else {
        return Target::Nothing;
    };
    let path = Path::new(decoded.as_str());
    if path.as_os_str().is_empty() || !file::is_markdown_name(path) {
        return Target::Nothing;
    }
    if path.is_absolute() {
        return Target::Markdown(path.to_owned());
    }
    folder.map_or(Target::Nothing, |folder| {
        Target::Markdown(folder.join(path))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn web_and_mail_go_to_the_desktop() {
        for href in ["https://x.org/a#b", "HTTP://x.org", "mailto:a@b.org"] {
            assert_eq!(
                resolve(href, None),
                Target::External(href.to_owned()),
                "{href}"
            );
        }
    }

    #[test]
    fn markdown_files_open_here() {
        let folder = Path::new("/notes");
        let md = |p: &str| Target::Markdown(PathBuf::from(p));
        assert_eq!(resolve("plan.md", Some(folder)), md("/notes/plan.md"));
        assert_eq!(
            resolve("../docs/My%20Plan.md#top", Some(folder)),
            md("/notes/../docs/My Plan.md")
        );
        assert_eq!(
            resolve("README.MD?x=1", Some(folder)),
            md("/notes/README.MD")
        );
        assert_eq!(resolve("/abs/x.md", None), md("/abs/x.md"));
        assert_eq!(resolve("file:///tmp/a%20b.md#s", None), md("/tmp/a b.md"));
    }

    #[test]
    fn everything_else_does_nothing() {
        let folder = Some(Path::new("/notes"));
        for href in [
            "#heading",
            "script.sh",
            "file:///proc/self/environ",
            "ftp://x.org/a.md",
            "javascript:alert(1)",
            "x.md%",
        ] {
            assert_eq!(resolve(href, folder), Target::Nothing, "{href}");
        }
        // A new document has no folder, so its relative links go nowhere.
        assert_eq!(resolve("plan.md", None), Target::Nothing);
    }
}
