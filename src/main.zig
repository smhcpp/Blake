const std = @import("std");
const posix = std.posix;
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
// const gpa = std.heap.c_allocator;

const Server = @import("server.zig").Server;

pub fn main() anyerror!void {
    // wlr.log.init(.debug, null);

    var server: Server = undefined;
    try server.init();
    defer server.deinit();

    var buf: [11]u8 = undefined;
    server.socket = try server.wlserver.addSocketAuto(&buf);

    if (std.os.argv.len >= 2) {
        const cmd = std.mem.span(std.os.argv[1]);
        var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", cmd }, server.alloc);
        var env_map = try std.process.getEnvMap(server.alloc);
        defer env_map.deinit();
        try env_map.put("WAYLAND_DISPLAY", server.socket);
        child.env_map = &env_map;
        try child.spawn();
    }

    try server.backend.start();

    std.log.info("Running compositor on WAYLAND_DISPLAY={s}", .{server.socket});
    server.wlserver.run();

    // std.debug.print("\n here is the first layout: {s}, {any}\n\n", .{ server.layouts.items[0].name, server.layouts.items[0].boxs });
}
