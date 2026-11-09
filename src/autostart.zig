//! `fyke service`: runs the daemon from login with no client open. The work is the
//! platform's own service manager, so this picks one at compile time and gives
//! `main.zig` and `data_move.zig` one interface to call.

const builtin = @import("builtin");
const client_module = @import("client.zig");

const backend = switch (builtin.os.tag) {
    .macos => @import("launchd.zig"),
    .linux => @import("systemd.zig"),
    else => struct {
        pub fn install(_: client_module.Connector, _: []const u8) !void {
            return error.Unsupported;
        }
        pub fn uninstall(_: client_module.Connector, _: []const u8) !void {
            return error.Unsupported;
        }
        pub fn isInstalled(_: client_module.Connector, _: []const u8) !bool {
            return error.Unsupported;
        }
    },
};

pub const install = backend.install;
pub const uninstall = backend.uninstall;
pub const isInstalled = backend.isInstalled;

test {
    _ = backend;
}
