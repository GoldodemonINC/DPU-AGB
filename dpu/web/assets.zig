//! Web assets, compiled into the executable.
//!
//! This file exists only to set the package root for the `web/` directory, so
//! the three dashboard files can be embedded with paths relative to it. The
//! dashboard then ships inside the binary: nothing to install alongside it, no
//! runtime file I/O, and no chance of the assets drifting from the engine that
//! serves them.
pub const index_html = @embedFile("index.html");
pub const app_js = @embedFile("app.js");
pub const style_css = @embedFile("style.css");
