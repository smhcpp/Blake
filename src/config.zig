const std = @import("std");
const xkb = @import("xkbcommon");
const wlr = @import("wlroots");
const utility = @import("utility.zig");

pub const Keymap = struct {
    tap: xkb.Keysym = @enumFromInt(0),
    hold: xkb.Keysym = @enumFromInt(0),
};

pub const ModKeyValue = struct {
    ShtL: u32 = 1 << 0,
    ShtR: u32 = 1 << 1,
    CtrL: u32 = 1 << 2,
    CtrR: u32 = 1 << 3,
    AltL: u32 = 1 << 4,
    AltR: u32 = 1 << 5,
    SupL: u32 = 1 << 6,
    SupR: u32 = 1 << 7,
    Cap: u32 = 1 << 8,
    Num: u32 = 1 << 9,
    Tab: u32 = 1 << 10,
    Esc: u32 = 1 << 11,
    BS: u32 = 1 << 12,
    CR: u32 = 1 << 13,
    // 14-19
    F1: u32 = 1 << 20,
    F2: u32 = 1 << 21,
    F3: u32 = 1 << 22,
    F4: u32 = 1 << 23,
    F5: u32 = 1 << 24,
    F6: u32 = 1 << 25,
    F7: u32 = 1 << 26,
    F8: u32 = 1 << 27,
    F9: u32 = 1 << 28,
    F10: u32 = 1 << 29,
    F11: u32 = 1 << 30,
    F12: u32 = 1 << 31,
};

pub const ListModNames: [32][]const u8 = .{
    "ShtL", "ShtR", "CtrL", "CtrR", "AltL", "AltR", "SupL", "SupR", "Cap", "Num", "Tab", "Esc", "BS",
    "CR",   " ",    " ",    " ",    " ",    " ",    " ",    "F1",   "F2",  "F3",  "F4",  "F5",  "F6",
    "F7",   "F8",   "F9",   "F10",  "F11",  "F12",
};

pub const ConfigError = error{
    MapNotFound,
    WrongLayoutNumbers,
    LayoutLessNumbers,
    KeymapNotEnoughParams,
    LayoutNotEnoughParams,
    MissingHomeDir,
    WrongMode,
};

pub const Mode = enum { n, i, c };

pub fn getMode(char: u8) !Mode {
    if (char == 'n') return Mode.n;
    if (char == 'i') return Mode.i;
    if (char == 'c') return Mode.c;
    return ConfigError.WrongMode;
}

pub const Config = struct {
    layouts: std.ArrayList(Layout),
    configs: std.StringHashMap([]const u8),
    keymaps: std.AutoHashMap(xkb.Keysym, Keymap),
    binds: *utility.KeyBindNode,
};

pub const Layout = struct {
    name: []const u8,
    size: u8,
    boxs: std.ArrayList([4]f32),
};

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
        // std.debug.print("cmd: {s}\n", .{cmd});
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
        .configs = std.StringHashMap([]const u8).init(allocator),
        .keymaps = std.AutoHashMap(xkb.Keysym, Keymap).init(allocator),
        .binds = try utility.KeyBindNode.init(allocator),
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
        const keywords: [5][]const u8 = .{ "loadLayout", "act", "config", "bind", "keymap" };
        const cmd_trimmed = std.mem.trim(u8, cmd, " \t\r");
        for (keywords, 0..) |keyword, i| {
            if (std.mem.startsWith(u8, cmd_trimmed, keyword)) {
                const slice = cmd_trimmed[keyword.len..cmd_trimmed.len];
                const trimmed_slice = std.mem.trim(u8, slice, " \t\r");
                switch (i) {
                    0 => {
                        const layout_slice = trimmed_slice[1 .. trimmed_slice.len - 1];
                        const layout_toks = splitLayoutCmd(allocator, layout_slice);
                        defer layout_toks.deinit();
                        const layout = try parseLayout(allocator, layout_toks.items[1], layout_toks.items[0]);
                        try config.layouts.append(layout);
                    },
                    1 => {
                        const set_parts = splitCmds(allocator, trimmed_slice[1 .. trimmed_slice.len - 1], ',');
                        if (set_parts.items.len == 3) {
                            parseSet(allocator, set_parts.items[2]) catch |e| {
                                std.debug.print("parseKeymap: {}", .{e});
                            };
                        } else {
                            std.debug.print("Config file set function requires 3 parameters: {s}", .{slice});
                        }
                    },
                    2 => {
                        var conf_toks = std.mem.splitScalar(u8, trimmed_slice[1 .. trimmed_slice.len - 1], ',');
                        if (conf_toks.next()) |next| {
                            if (conf_toks.next()) |next2| {
                                // checking length of next and next2 for error also is good
                                config.configs.put(std.mem.trim(u8, next, " \t\r"), std.mem.trim(u8, next2, " \t\r")) catch |e| {
                                    std.debug.print("Could not put the config in the config map: {}\n", .{e});
                                };
                            } else {
                                //some other error
                            }
                        } else {
                            // some error
                        }
                    },
                    3 => {
                        const pass_toks = splitCmds(allocator, trimmed_slice[1 .. trimmed_slice.len - 1], ',');
                        if (pass_toks.items.len == 4) {
                            // const mode = try getMode(std.mem.trim(u8, pass_toks.items[0], " \t\r")[0]);
                            const cmdout = std.mem.trim(u8, pass_toks.items[2], " \t\r");
                            var apps = std.ArrayList([]const u8).init(allocator);
                            const tempo = std.mem.trim(u8, pass_toks.items[3], " \r\t");
                            var pass_apps = std.mem.splitScalar(u8, tempo[1 .. tempo.len - 1], ',');
                            const cmdin = std.mem.trim(u8, pass_toks.items[1], " \t\r");
                            while (pass_apps.next()) |app| {
                                const valid_app = std.mem.trim(u8, app, " \t\r");
                                try apps.append(valid_app[1 .. valid_app.len - 1]);
                            }
                            const cmdinp = parseKey(allocator, cmdin);
                            const cmdoutp = parseKey(allocator, cmdout);
                            if (cmdinp.len != 0 and cmdoutp.len != 0) {
                                const apps_ = apps.toOwnedSlice() catch &[_][]const u8{};
                                _ = try config.binds.insert(cmdinp, cmdoutp, apps_);
                            } else {
                                //some error
                            }
                        } else {
                            //some error
                        }
                    },
                    else => {},
                }
            }
        }
    }
    return config;
}

pub fn parseKey(allocator: std.mem.Allocator, input: []const u8) []const u64 {
    var inDeep: bool = false;
    var cur: std.ArrayList(u8) = std.ArrayList(u8).init(allocator);
    defer cur.deinit();
    var keys: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(allocator);
    defer keys.deinit();
    // std.debug.print("char keycode: {}, {}\n", .{ 'A', 'Z' });
    for (input) |c| {
        switch (c) {
            '<' => {
                if (inDeep) {
                    // print there is an error here we cannot have
                    // multiple level of < >
                }
                inDeep = true;
                const temp = cur.toOwnedSlice() catch "";
                if (temp.len > 0) {
                    const tempo = allocator.dupe(u8, temp) catch "";
                    keys.append(tempo) catch {
                        // some error here
                    };
                }
            },
            '>' => {
                inDeep = false;
                const temp = cur.toOwnedSlice() catch "";
                if (temp.len > 0) {
                    const tempo = allocator.dupe(u8, temp) catch "";
                    keys.append(tempo) catch {
                        // some error here
                    };
                    // std.debug.print("tempo: {s}\n",.{tempo});
                }
            },
            ' ', '\t', '\r', '"' => {
                //do nothing, skip them
            },
            else => {
                //
                cur.append(c) catch {
                    // some error
                };
            },
        }
    }

    var cmds: std.ArrayList(u64) = std.ArrayList(u64).init(allocator);
    for (keys.items) |k| {
        switch (k.len) {
            0 => {
                //continue
            },
            1 => {
                const cmd = 0;
                cmds.append(cmd) catch {
                    //some error
                };
            },
            else => {
                var ts = std.mem.tokenizeAny(u8, k, "-");
                var modifiers: u32 = 0;
                var sym: u32 = 0;
                while (ts.next()) |t| {
                    switch (t.len) {
                        0 => {},
                        1 => {
                            const tptr: [*:0]const u8 = @ptrCast(t.ptr);
                            const symo = xkb.Keysym.fromName(tptr, @enumFromInt(0));
                            const co = @intFromEnum(symo);
                            // std.debug.print("type of cmd: {}", .{@TypeOf(co)});
                            sym = co;
                        },
                        else => {
                            var ind: u8 = 255;
                            for (ListModNames, 0..) |lmn, idx| {
                                if (std.mem.startsWith(u8, t, lmn)) {
                                    ind = @intCast(idx);
                                    break;
                                }
                            }
                            if (ind != 255) {
                                modifiers |= @as(u32, 1) << @intCast(ind);
                            } else {
                                // some error
                            }
                        },
                    }
                }
                const modifiers64: u64 = @intCast(modifiers);
                const sym64: u64 = @intCast(sym);
                const cmd: u64 = modifiers64 << 32 | sym64;
                cmds.append(cmd) catch {
                    // some error
                };
            },
        }
    }
    const cmdsr = cmds.toOwnedSlice() catch &[_]u64{};
    cmds.deinit();
    return cmdsr;
}

fn parseSet(allocator: std.mem.Allocator, input: []const u8) !void {
    //should return a hashmap with all the keysbindings as keys of the
    //hash map
    const trimmed_in = std.mem.trim(u8, input, " \t\r");
    // std.debug.print("keymap: {s}", .{trimmed_in});
    _ = trimmed_in;
    _ = allocator;
    // _ = input;
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

pub const ModKeyName = struct {
    AltR: []u8 = "AltR",
    AltL: []u8 = "AltL",
    CtrL: []u8 = "CtrL",
    CtrR: []u8 = "CtrR",
    ShtL: []u8 = "ShtL",
    ShtR: []u8 = "ShtR",
    SupR: []u8 = "SupR",
    SupL: []u8 = "SupL",
    Cap: []u8 = "Cap",
    Num: []u8 = "Num",
    Tab: []u8 = "Tab",
    Esc: []u8 = "Esc",
    BS: []u8 = "BS",

    F1: []u8 = "F1",
    F2: []u8 = "F2",
    F3: []u8 = "F3",
    F4: []u8 = "F4",
    F5: []u8 = "F5",
    F6: []u8 = "F6",
    F7: []u8 = "F7",
    F8: []u8 = "F8",
    F9: []u8 = "F9",
    F10: []u8 = "F10",
    F11: []u8 = "F11",
    F12: []u8 = "F12",
};

// pub const KeyCommand = struct {
// modifiers: u32 = 0,
// keysym: xkb.Keysym,
// };
