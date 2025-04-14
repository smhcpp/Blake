const std = @import("std");
const Keyboard = @import("keyboard.zig").Keyboard;

pub fn openApp(keyboard: *Keyboard, appname: []const u8) bool {
    var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", appname }, keyboard.server.alloc);
    var env_map = std.process.getEnvMap(keyboard.server.alloc) catch |err| {
        std.log.err("Failed to spawn: {}", .{err});
        return false;
    };
    defer env_map.deinit();
    env_map.put("WAYLAND_DISPLAY", keyboard.server.socket) catch |err| {
        std.log.err("Failed to put the socket for the enviornment {}", .{err});
    };
    child.env_map = &env_map;

    // Set the environment variables
    _ = child.spawn() catch |err| {
        std.log.err("Failed to spawn: {}", .{err});
        return false;
    };
    return true;
}

pub fn CycleWindowForward(keyboard: *Keyboard) void {
    const pre = keyboard.server.workspace_cur;
    keyboard.server.workspace_cur += 1;
    if (keyboard.server.workspace_cur >= keyboard.server.workspace_num) keyboard.server.workspace_cur -= keyboard.server.workspace_num;
    keyboard.server.switchWS(pre);
}

pub fn CycleWindowBackward(keyboard: *Keyboard) void {
    const pre = keyboard.server.workspace_cur;
    if (keyboard.server.workspace_cur > 0) {
        keyboard.server.workspace_cur -= 1;
    } else {
        keyboard.server.workspace_cur = keyboard.server.workspace_num - 1;
    }
    keyboard.server.switchWS(pre);
}
