const Config = @import("config.zig").Config;
const Value = @import("interpreter.zig").Value;
const std = @import("std");
const Keyboard = @import("keyboard.zig").Keyboard;

pub fn openApp(o: *anyopaque, args: []const Value) anyerror!Value {
    const config: *Config = @ptrCast(@alignCast(o));
    const appname = args[0].str;
    var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", appname }, config.server.alloc);
    var env_map = std.process.getEnvMap(config.server.alloc) catch |err| {
        std.log.err("Failed to spawn: {}", .{err});
        return Value{ .bln = false };
    };
    defer env_map.deinit();
    env_map.put("WAYLAND_DISPLAY", config.server.socket) catch |err| {
        std.log.err("Failed to put the socket for the enviornment {}", .{err});
    };
    child.env_map = &env_map;

    // Set the environment variables
    _ = child.spawn() catch |err| {
        std.log.err("Failed to spawn: {}", .{err});
        return Value{ .bln = false };
    };
    return Value{ .bln = true };
}

pub fn cycleWindowForward(o: *anyopaque, args: []const Value) anyerror!Value {
    const config: *Config = @ptrCast(@alignCast(o));
    _ = args;
    const pre = config.workspace_cur;
    config.workspace_cur += 1;
    if (config.workspace_cur >= config.workspace_num) config.workspace_cur -= config.workspace_num;
    config.server.switchWS(pre);
    return Value{
        .v = {},
    };
}

pub fn cycleWindowBackward(o: *anyopaque, args: []const Value) anyerror!Value {
    const config: *Config = @ptrCast(@alignCast(o));
    _ = args;
    const pre = config.workspace_cur;
    if (config.workspace_cur > 0) {
        config.workspace_cur -= 1;
    } else {
        config.workspace_cur = config.workspace_num - 1;
    }
    config.server.switchWS(pre);
    return Value{
        .v = {},
    };
}

pub fn printValue(o: *anyopaque, args: []const Value) anyerror!Value {
    _ = o;
    switch (args[0]) {
        .i32 => |i| std.debug.print("{} ", .{i}),
        .f32 => |f| std.debug.print("{d:.2} ", .{f}),
        .str => |s| std.debug.print("{s} ", .{s}),
        .bln => |b| std.debug.print("{} ", .{b}),
        .v => std.debug.print("(void) ", .{}),
    }
    return Value{
        .v = {},
    };
}
