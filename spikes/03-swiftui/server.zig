//! Spike: stand-in daemon. Newline-delimited JSON-RPC over a Unix socket.
//! Answers entries.list with keyset paging over synthetic rows.
//! Usage: server <socket-path>
const std = @import("std");
const Io = std.Io;

const total = 10_000;

fn serve(io: Io, stream: Io.net.Stream) Io.Cancelable!void {
    defer stream.close(io);
    var in_buf: [4096]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var writer = stream.writer(io, &out_buf);
    const in = &reader.interface;
    const out = &writer.interface;

    while (true) {
        const line = in.takeDelimiterExclusive('\n') catch return;
        in.toss(1);
        // Request shape: {"id":N,"method":"entries.list","params":{"after":N,"limit":N}}
        const id = field(line, "\"id\":") orelse 0;
        const after = field(line, "\"after\":") orelse 0;
        const limit = field(line, "\"limit\":") orelse 200;
        const end = @min(after + limit, total);
        out.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"next\":{d},\"items\":[", .{ id, end }) catch return;
        var i = after;
        while (i < end) : (i += 1) {
            if (i != after) out.writeByte(',') catch return;
            out.print("{{\"id\":{d},\"title\":\"Entry number {d} from a synthetic feed\",\"feed\":\"Feed {d}\"}}", .{ i, i, i % 97 }) catch return;
        }
        out.writeAll("]}}\n") catch return;
        out.flush() catch return;
    }
}

fn field(line: []const u8, key: []const u8) ?usize {
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    var i = at + key.len;
    var v: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) v = v * 10 + (line[i] - '0');
    return v;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    Io.Dir.cwd().deleteFile(io, args[1]) catch {};
    const address = try Io.net.UnixAddress.init(args[1]);
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    var group: Io.Group = .init;
    while (true) {
        const stream = try server.accept(io);
        try group.concurrent(io, serve, .{ io, stream });
    }
}
