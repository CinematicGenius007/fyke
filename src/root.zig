//! Pure core of the reader. Nothing in this module performs I/O.

pub const blocks = @import("blocks.zig");
pub const dates = @import("dates.zig");
pub const encoding = @import("encoding.zig");
pub const extract = @import("extract.zig");
pub const feed = @import("feed.zig");
pub const html = @import("html.zig");
pub const layout = @import("layout.zig");
pub const opml = @import("opml.zig");
pub const robots = @import("robots.zig");
pub const terminal = @import("terminal.zig");
pub const url = @import("url.zig");
pub const xml = @import("xml.zig");

test {
    _ = blocks;
    _ = dates;
    _ = encoding;
    _ = extract;
    _ = feed;
    _ = html;
    _ = layout;
    _ = opml;
    _ = robots;
    _ = terminal;
    _ = url;
    _ = xml;
    _ = @import("fuzz.zig");
}
