//! mdview: a small Markdown viewer that follows the system GTK theme. docs/mdview-plan.md has
//! the design; docs/mdview.md has usage.

mod file;
mod render;
mod window;

use gtk::prelude::*;
use gtk::{gdk, gio, glib};

/// Debug builds get their own id, so `cargo run` doesn't hand its files over D-Bus to an
/// installed copy that is running.
const APP_ID: &str = if cfg!(debug_assertions) {
    "io.github.kartikakolia.mdview.Devel"
} else {
    "io.github.kartikakolia.mdview"
};

fn main() -> glib::ExitCode {
    let app = gtk::Application::builder()
        .application_id(APP_ID)
        .flags(gio::ApplicationFlags::HANDLES_OPEN)
        .build();
    app.connect_startup(startup);
    app.connect_activate(window::activate);
    app.connect_open(|app, files, _hint| {
        for file in files {
            window::open(app, file.clone());
        }
    });
    app.run()
}

fn startup(app: &gtk::Application) {
    // One above USER priority: KDE's ~/.config/gtk-4.0/gtk.css imports the whole Nordic sheet
    // at USER priority, and GTK compares priority before specificity.
    let provider = gtk::CssProvider::new();
    provider.load_from_string(include_str!("../style.css"));
    if let Some(display) = gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &provider,
            gtk::STYLE_PROVIDER_PRIORITY_USER + 1,
        );
    }

    let quit = gio::SimpleAction::new("quit", None);
    let weak = app.downgrade();
    quit.connect_activate(move |_, _| {
        if let Some(app) = weak.upgrade() {
            app.quit();
        }
    });
    app.add_action(&quit);
    app.set_accels_for_action("app.quit", &["<Control>q"]);
    app.set_accels_for_action("win.open", &["<Control>o"]);
    app.set_accels_for_action("win.close", &["<Control>w"]);
}
