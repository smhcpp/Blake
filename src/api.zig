const std = @import("std");
const dt = @import("datatypes.zig");
const print = std.debug.print;
const Config = @import("config.zig").Config;
const Value = @import("interpreter.zig").Value;
const ValueType = @import("interpreter.zig").ValueType;
const inter = @import("interpreter.zig");
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
        .arr => |a| {
            std.debug.print("{any}", .{a.items});
        },
    }
    return Value{
        .v = {},
    };
}

pub fn loadLayout(o: *anyopaque, args: []const Value) anyerror!Value {
    const config: *Config = @ptrCast(@alignCast(o));

    const name = args[0];
    const arr1 = args[1];
    var boxs = std.ArrayList([4]f32).init(config.server.alloc);
    for (arr1.arr.items) |arr2| {
        for (arr2.arr.items) |arr3| {
            var a: [4]f32 = .{0} ** 4;
            for (arr3.arr.items, 0..) |v, i| {
                a[i] = v.f32;
            }
            try boxs.append(a);
        }
    }
    const layout = dt.Layout{
        .name = name.str,
        .size = @intCast(arr1.arr.items.len),
        .boxs = boxs,
    };
    try config.layouts.append(layout);
    return Value{ .v = {} };
}
