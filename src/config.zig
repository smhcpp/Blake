const std = @import("std");
pub const ConfigError = error{
    MapNotFound,
    WrongLayoutNumbers,
    LayoutLessNumbers,
    KeymapNotEnoughParams,
    LayoutNotEnoughParams,
    MissingHomeDir,
};

pub const Config = struct {
    layouts: std.ArrayList(Layout),
};

pub const Layout = struct {
    name: []const u8,
    size: u8,
    boxs: std.ArrayList([4]f32),
};

pub fn sumSize(comptime T: type, n: T) T {
    var sum: T = 0;
    var i: T = 1;
    while (i <= n) : (i = i + 1) {
        sum = sum + i;
    }
    return sum;
}

fn splitCmds(allocator: std.mem.Allocator, s: []const u8, char: u8) std.ArrayList([]const u8) {
    var cmds = std.ArrayList([]const u8).init(allocator);
    var level: usize = 0;
    var cur: std.ArrayList(u8) = std.ArrayList(u8).init(allocator);

    for (s) |c| {
        if (c == '{') {
            level += 1;
        } else if (c == '}') {
            if (level > 0) level -= 1;
        } else if (c == char and level == 0) {
            const cmd = cur.toOwnedSlice() catch "";
            if (cmd.len > 0) {
                // std.debug.print("cmd: {s}\n", .{cmd});
                cmds.append(cmd) catch |e| {
                    std.debug.print("error: {}", .{e});
                };
            }
            continue;
        }
        cur.append(c) catch |e| {
            std.debug.print("error: {}", .{e});
        };
    }
    // catch the last statement for the case char!=';'
    const cmd = cur.toOwnedSlice() catch "";
    if (cmd.len > 0) {
        std.debug.print("cmd: {s}\n", .{cmd});
        cmds.append(cmd) catch |e| {
            std.debug.print("error: {}", .{e});
        };
    }
    return cmds;
}

fn splitLayoutCmd(allocator: std.mem.Allocator, s: []const u8) std.ArrayList([]const u8) {
    var cmds = std.ArrayList([]const u8).init(allocator);

    for (s, 0..) |c, i| {
        if (c == ',') {
            const cmd1 = s[0..i];
            const cmd2 = s[i + 1 .. s.len];
            cmds.append(std.mem.trim(u8, cmd1, " \t\r")) catch |e| {
                std.debug.print("error: {}", .{e});
            };
            cmds.append(std.mem.trim(u8, cmd2, " \t\r")) catch |e| {
                std.debug.print("error: {}", .{e});
            };
            break;
        }
    }
    return cmds;
}

pub fn loadConfig(allocator: std.mem.Allocator) !Config {
    const home_dir = std.posix.getenv("HOME") orelse return ConfigError.MissingHomeDir;
    const file_path = try std.fs.path.join(allocator, &.{ home_dir, ".config", "blake", "config.conf" });
    defer allocator.free(file_path);
    var file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();
    const buffer = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(buffer);
    const config = try parseConfig(allocator, buffer);
    return config;
}

fn parseConfig(allocator: std.mem.Allocator, input: []const u8) !Config {
    var lines = std.mem.splitScalar(u8, input, '\n');
    var config = Config{
        .layouts = std.ArrayList(Layout).init(allocator),
    };
    var joined_commands = std.ArrayList(u8).init(allocator);
    defer joined_commands.deinit();
    while (lines.next()) |line| {
        const cleaned_line = blk: {
            if (std.mem.indexOf(u8, line, "#")) |hash_pos|
                break :blk std.mem.trimRight(u8, line[0..hash_pos], " \t\r");
            break :blk std.mem.trimRight(u8, line, " \t\r");
        };
        if (cleaned_line.len == 0) continue;
        try joined_commands.appendSlice(cleaned_line);
    }
    const final_string = try joined_commands.toOwnedSlice();
    defer allocator.free(final_string);

    const cmds = splitCmds(allocator, final_string, ';');
    var tokens = std.ArrayList([]const u8).init(allocator);
    defer {
        for (tokens.items) |t| allocator.free(t);
        tokens.deinit();
    }

    for (cmds.items) |cmd| {
        if (cmd.len == 0) continue;
        const keywords: [3][]const u8 = .{ "loadLayout", "set", "setKey" };
        for (keywords, 0..) |keyword, i| {
            if (std.mem.startsWith(u8, cmd, keyword)) {
                const slice = cmd[keyword.len..cmd.len];
                const trimmed_slice = std.mem.trim(u8, slice, " \t\r");
                switch (i) {
                    0 => {
                        const layout_slice = trimmed_slice[1 .. trimmed_slice.len - 1];
                        const layout_toks = splitLayoutCmd(allocator, layout_slice);
                        defer layout_toks.deinit();
                        std.debug.print("name: {s}\n", .{layout_toks.items[0]});
                        const layout = try parseLayout(allocator, layout_toks.items[1], layout_toks.items[0]);
                        try config.layouts.append(layout);
                        std.debug.print("array: {any}\n", .{layout.boxs.items});
                    },
                    1 => {
                        const set_parts = splitCmds(allocator, trimmed_slice[1 .. trimmed_slice.len - 1], ',');
                        std.debug.print("set: {any}\n", .{set_parts.items});
                    },
                    else => {},
                }
            }
        }
    }
    return config;
}

fn parseKeymap(allocator: std.mem.Allocator, input: []const u8) !void {
    //should return a hashmap with all the keysbindings as keys of the
    //hash map
    _ = allocator;
    _ = input;
}

fn parseLayout(allocator: std.mem.Allocator, input: []const u8, layout_name: []const u8) !Layout {
    var k: usize = 0;
    var dep: u8 = 0;
    var layout_size: u8 = 0;
    var cur: std.ArrayList(u8) = std.ArrayList(u8).init(allocator);
    var cur_arr: std.ArrayList([4]f32) = std.ArrayList([4]f32).init(allocator);
    while (k < input.len) : (k += 1) {
        switch (input[k]) {
            '[' => {
                dep += 1;
                if (dep == 2) {
                    layout_size += 1;
                }
            },
            ']' => {
                if (dep == 3) {
                    const p = cur.toOwnedSlice() catch "";
                    if (p.len > 0) {
                        var ts = std.mem.tokenizeAny(u8, p, ",");
                        var arr: [4]f32 = .{ 0, 0, 0, 0 };
                        var j: usize = 0;
                        while (ts.next()) |t| {
                            if (t.len == 0) continue;
                            arr[j] = std.fmt.parseFloat(f32, t) catch return ConfigError.WrongLayoutNumbers;
                            j += 1;
                        }
                        if (arr.len != 4) return ConfigError.LayoutLessNumbers;
                        try cur_arr.append(arr);
                    }
                }
                dep -= 1;
            },
            ' ', '\t' => continue,
            else => {
                if (dep == 3) {
                    try cur.append(input[k]);
                }
            },
        }
    }
    const layout = Layout{
        .name = layout_name,
        .boxs = cur_arr,
        .size = layout_size,
    };
    return layout;
}
