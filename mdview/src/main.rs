//! mdview: a small Markdown viewer that follows the system GTK theme. docs/mdview-plan.md has
//! the design; docs/mdview.md has usage.

mod file;
mod find;
mod link;
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

    // Quit asks about each window's unsaved work first (window::quit).
    let quit = gio::SimpleAction::new("quit", None);
    let weak = app.downgrade();
    quit.connect_activate(move |_, _| {
        if let Some(app) = weak.upgrade() {
            window::quit(&app);
        }
    });
    app.add_action(&quit);
    // Zoom is app-wide (window::zoom): every window's text, both views.
    for (name, step) in [("zoom-in", 1), ("zoom-out", -1), ("zoom-reset", 0)] {
        let action = gio::SimpleAction::new(name, None);
        action.connect_activate(move |_, _| window::zoom(step));
        app.add_action(&action);
    }
    // Undo, redo, cut, copy, paste and select all are the TextView's own bindings.
    let accels: [(&str, &[&str]); 16] = [
        (
            "app.zoom-in",
            &["<Control>plus", "<Control>equal", "<Control>KP_Add"],
        ),
        ("app.zoom-out", &["<Control>minus", "<Control>KP_Subtract"]),
        ("app.zoom-reset", &["<Control>0", "<Control>KP_0"]),
        ("win.fullscreen", &["F11"]),
        ("app.quit", &["<Control>q"]),
        ("win.new", &["<Control>n"]),
        ("win.open", &["<Control>o"]),
        ("win.save", &["<Control>s"]),
        ("win.save-as", &["<Control><Shift>s"]),
        ("win.close", &["<Control>w"]),
        ("win.edit", &["<Control>e"]),
        ("win.find", &["<Control>f"]),
        ("win.replace", &["<Control>h"]),
        ("win.goto", &["<Control>l"]),
        ("win.find-next", &["F3"]),
        ("win.find-previous", &["<Shift>F3"]),
    ];
    for (action, keys) in accels {
        app.set_accels_for_action(action, keys);
    }
}
