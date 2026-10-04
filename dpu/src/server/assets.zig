//! The dashboard's embedded files: one table, read by both the router and the
//! handler.
//!
//! This is the whole truth about what the dashboard serves. It was once a list
//! of paths in the router and a second copy in the handler, which is how a path
//! ends up routable but unservable, or served but unroutable. Two places that
//! have to agree is the same failure the status-code fix removed, so there is
//! one place and it is here.
//!
//! The table is public because the wire suite derives its coverage from it
//! rather than keeping a written-out copy. A list of asset paths in a test is a
//! second thing that has to agree with this table, and it stops agreeing the
//! day somebody adds an entry.

const std = @import("std");

// Static assets are embedded at compile time. The dashboard then ships inside
// the binary: no asset directory to lose and no runtime file I/O. It does not
// mean every request succeeds -- anything outside this set is a 404.
const assets = @import("web_assets");
const index_html = assets.index_html;
const app_js = assets.app_js;
const style_css = assets.style_css;

pub const Asset = struct { path: []const u8, mime: []const u8, body: []const u8 };

pub const ASSETS = [_]Asset{
    .{ .path = "/", .mime = "text/html; charset=utf-8", .body = index_html },
    .{ .path = "/index.html", .mime = "text/html; charset=utf-8", .body = index_html },
    .{ .path = "/app.js", .mime = "application/javascript; charset=utf-8", .body = app_js },
    .{ .path = "/style.css", .mime = "text/css; charset=utf-8", .body = style_css },
};

pub fn findAsset(path: []const u8) ?Asset {
    for (ASSETS) |a| {
        if (std.mem.eql(u8, path, a.path)) return a;
    }
    return null;
}

/// The dashboard's own paths. Anything not in this list is a miss.
pub fn isAssetPath(path: []const u8) bool {
    return findAsset(path) != null;
}
