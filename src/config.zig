const std = @import("std");
const print = std.debug.print;
const xkb = @import("xkbcommon");
const wlr = @import("wlroots");
const Keyboard = @import("keyboard.zig").Keyboard;
const utility = @import("utility.zig");
const datatypes = @import("datatypes.zig");

pub const Config = struct {
    layouts: std.ArrayList(datatypes.Layout),
    configs: std.StringHashMap([]const u8),
    keymaps: std.AutoHashMap(xkb.Keysym, datatypes.Keymap),
    bindsi: std.StringHashMap(datatypes.BindActions),
    bindsn: std.StringHashMap(datatypes.BindActions),
    bindsc: std.StringHashMap(datatypes.BindActions),
    // binds does not have modes. we need to have
    // 3 binds possibly to cover normal mode and command mode
    // and insert mode
};

pub fn keyToString(allocator: std.mem.Allocator, symi: u32) ![]const u8 {
    var string = std.ArrayList(u8).init(allocator);
    defer string.deinit();
    for (datatypes.ListModKeysForWrite) |mod| {
        if (mod.sym == symi) {
            try string.append('<');
            try string.appendSlice(mod.name);
            try string.append('>');
            // std.debug.print("mod: {s}\n", .{mod.sym});
        }
    }
    var buffer: [8]u8 = undefined;
    const sym: xkb.Keysym = @enumFromInt(symi);
    const len = xkb.Keysym.toUTF8(sym, &buffer, buffer.len);
    if (len > 0) {
        try string.append(buffer[0]);
    }
    const res = try string.toOwnedSlice();
    // std.debug.print("keytostring: {s}\n", .{res});
    return res;
}

pub fn keysToString(allocator: std.mem.Allocator, keys: [][]const u32) ![]const u8 {
    var string = std.ArrayList(u8).init(allocator);
    var cur = std.ArrayList(u8).init(allocator);
    for (keys) |arr| {
        switch (arr.len) {
            0 => {},
            1 => {
                // print("arr: {any}\n",.{arr});
                const str = try keyToString(allocator, arr[0]);
                if (str.len != 0) {
                    try string.appendSlice(str);
                }
            },
            else => {
                for (arr) |k| {
                    // we consider that this array number is sorted already!
                    const str = try keyToString(allocator, k);
                    if (str.len != 0) {
                        if (cur.items.len > 0) try cur.appendSlice("-");
                        if (str.len == 1) {
                            try cur.appendSlice(str);
                        } else {
                            try cur.appendSlice(str[1 .. str.len - 1]);
                        }
                    }
                }
                const tt = try cur.toOwnedSlice();
                try string.appendSlice("<");
                try string.appendSlice(tt);
                try string.appendSlice(">");
            },
        }
    }
    const res = try string.toOwnedSlice();
    return res;
}

pub fn keysFromModStr(allocator: std.mem.Allocator, input: []const u8) ![]const u32 {
    var inparts = std.mem.splitScalar(u8, input, '-');
    var keys = std.ArrayList(u32).init(allocator);
    defer keys.deinit();
    while (inparts.next()) |part| {
        switch (part.len) {
            0 => {},
            1 => {
                const sym = keyFromChar(part[0]);
                try keys.append(@intFromEnum(sym));
            },
            else => {
                var cur = std.ArrayList(u32).init(allocator);
                defer cur.deinit();
                for (datatypes.ListModKeys) |mod| {
                    if (std.mem.startsWith(u8, part, mod.name)) {
                        try cur.append(mod.sym);
                        // print("Mod: {}\n",.{mod.sym});
                    }
                }
                const bb = try cur.toOwnedSlice();
                try keys.appendSlice(bb);
            },
        }
    }
    const keysarr = try keys.toOwnedSlice();
    //there must be a lower to higher sorting here
    return keysarr;
}

/// Gets a character and gives the corresponding xkb.Keysym.
pub fn keyFromChar(char: u8) xkb.Keysym {
    const sym = xkb.Keysym.fromUTF32(@intCast(char));
    return sym;
}

/// Gets a string and parses it to a list of integers that can give keysyms by enumFromInt.
pub fn keysFromString(allocator: std.mem.Allocator, input: []const u8) ![][]const u32 {
    var syms = std.ArrayList([]const u32).init(allocator);
    defer syms.deinit();
    var cur = std.ArrayList(u8).init(allocator);
    defer cur.deinit();
    var in: bool = false;
    var bsflag: bool = false;
    for (input) |c| {
        // defer {
        // if (c != '\\' and bsflag) bsflag = false;
        // }
        const k = @intFromEnum(keyFromChar(c));
        var arr = try allocator.alloc(u32, 1);
        arr[0] = k;
        // const arr = .{@intFromEnum(keyFromChar(c))};
        switch (c) {
            '<' => {
                if (bsflag) {
                    try syms.append(arr);
                    bsflag = false;
                } else {
                    if (!in) {
                        in = true;
                    } else {
                        // some error
                    }
                }
            },
            '>' => {
                if (bsflag) {
                    bsflag = false;
                    try syms.append(arr);
                } else {
                    if (in) {
                        in = false;
                        const temp = try cur.toOwnedSlice();
                        const tt = try keysFromModStr(allocator, temp);
                        try syms.append(tt);
                    } else {
                        //some error!
                    }
                }
            },
            '\\' => {
                if (bsflag) {
                    bsflag = false;
                    try syms.append(arr);
                } else {
                    bsflag = true;
                }
            },
            else => {
                bsflag = false;
                if (in) {
                    try cur.append(c);
                } else {
                    try syms.append(arr);
                }
            },
        }
    }
    const symsarr = try syms.toOwnedSlice();
    return symsarr;
}

///splits strings with some character as delimiter and skips the delimiters in
///blocks that start with chars in skip (like skip="[{") taking comments into account. It skips any
///newline character: \r or \n
fn split(allocator: std.mem.Allocator, skip: []const u8, s: []const u8, char: u8) std.ArrayList([]const u8) {
    var cmds = std.ArrayList([]const u8).init(allocator);
    var bralevel: u8 = 0;
    var paralevel: u8 = 0;
    var curlylevel: u8 = 0;
    var gtlevel: u8 = 0;
    var instring: bool = false;
    var bsflag: bool = false;
    var cur: std.ArrayList(u8) = std.ArrayList(u8).init(allocator);
    var incomment: bool = false;

    for (s) |c| {
        if (incomment) {
            if (c == '\n' or c == '\r') {
                incomment = false;
                continue;
            }
            continue;
        }

        if (c == '#' and !instring) {
            //only if we are in string, sharp does not comment!
            incomment = true;
            continue;
        }

        if (c == '\\') {
            bsflag = !bsflag;
        }
        defer {
            if (c != '\\') bsflag = false;
        }
        // you have to remove extra backslash from each command?
        // no we only split here the parser does that!

        for (skip) |sk| {
            switch (sk) {
                '(' => {
                    if (!bsflag) {
                        if (c == sk) {
                            paralevel +|= 1;
                        } else if (c == ')') {
                            paralevel -|= 1;
                        }
                    }
                },
                '"' => {
                    if (!bsflag) {
                        if (c == sk) {
                            instring = !instring;
                        }
                    }
                },
                '{' => {
                    if (!bsflag) {
                        if (c == sk) {
                            curlylevel +|= 1;
                        } else if (c == '}') {
                            curlylevel -|= 1;
                        }
                    }
                },
                '[' => {
                    if (!bsflag) {
                        if (c == sk) {
                            bralevel +|= 1;
                        } else if (c == ']') {
                            bralevel -|= 1;
                        }
                    }
                },
                '<' => {
                    if (!bsflag) {
                        if (c == sk) {
                            gtlevel +|= 1;
                        } else if (c == '>') {
                            gtlevel -|= 1;
                        }
                    }
                },
                else => {},
            }
        }
        if (bralevel == 0 and paralevel == 0 and gtlevel == 0 and curlylevel == 0 and !instring) {
            if (c == char) {
                const cmd = cur.toOwnedSlice() catch "";
                if (cmd.len > 0) {
                    // std.debug.print("cmd: {s}\n", .{cmd});
                    cmds.append(cmd) catch |e| {
                        std.debug.print("error: {}", .{e});
                    };
                }
                continue;
            } else if (char != ' ' and c == ' ') {} else if (char != '\t' and c == '\t') {
                //
            } else if (char != '\r' and c == '\r') {} else if (char != '\n' and c == '\n') {
                // remove the need to use trim out of brackets or/and ...
            } else {
                cur.append(c) catch |e| {
                    std.debug.print("error: {}", .{e});
                };
            }
        } else {
            cur.append(c) catch |e| {
                std.debug.print("error: {}", .{e});
            };
        }
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

pub fn loadConfig(allocator: std.mem.Allocator) !*Config {
    const home_dir = std.posix.getenv("HOME") orelse return datatypes.BlakeError.MissingHomeDir;
    const file_path = try std.fs.path.join(allocator, &.{ home_dir, ".config", "blake", "config.conf" });
    defer allocator.free(file_path);
    var file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();
    const buffer = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(buffer);
    const config = try parseConfig(allocator, buffer);
    return config;
}

fn parseCommandPass(allocator: std.mem.Allocator, input: []const u8, appnames: []const u8) !void {
    if (input.len < 3) return;
    const string = input[1 .. input.len - 1];
    const syms = try keysFromString(allocator, string);
    // const str = try keysToString(allocator, syms);
    for (syms) |arr| {
        std.debug.print("{any}\n", .{arr});
    }
    //here we have to pass all these keys to application!
    _ = appnames;
    // std.debug.print("input length: {}\n", .{input.len});
}

fn parseCommandOpen(allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
    const inputtrimmed = std.mem.trim(u8, input, " \t\r");
    const appnames = split(allocator, "\"", inputtrimmed[1 .. inputtrimmed.len - 1], ',');

    var ret: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(allocator);
    defer ret.deinit();
    for (appnames.items) |name| {
        if (name.len > 2) {
            ret.append(name[1 .. name.len - 1]) catch |e| {
                std.log.err("Could not append app name to appnames arraylist: {}", .{e});
            };
        }
    }
    const striped = try ret.toOwnedSlice();
    return striped;
}

fn parseConfig(allocator: std.mem.Allocator, input: []const u8) !*Config {
    var text = split(allocator, "{\"", input, ';');
    defer text.deinit();
    const config = allocator.create(Config);
    if (config) |configptr| {
        configptr.* = Config{
            .layouts = std.ArrayList(datatypes.Layout).init(allocator),
            .configs = std.StringHashMap([]const u8).init(allocator),
            .keymaps = std.AutoHashMap(xkb.Keysym, datatypes.Keymap).init(allocator),
            .bindsi = std.StringHashMap(datatypes.BindActions).init(allocator),
            .bindsn = std.StringHashMap(datatypes.BindActions).init(allocator),
            .bindsc = std.StringHashMap(datatypes.BindActions).init(allocator),
        };
        const cmds = try text.toOwnedSlice();
        var tokens = std.ArrayList([]const u8).init(allocator);
        defer {
            for (tokens.items) |t| allocator.free(t);
            tokens.deinit();
        }

        for (cmds) |cmd| {
            if (cmd.len == 0) continue;
            const cmd_trimmed = std.mem.trim(u8, cmd, " \t\r");
            for (datatypes.ListConfigKeywords, 0..) |keyword, i| {
                if (std.mem.startsWith(u8, cmd_trimmed, keyword)) {
                    const slice = cmd_trimmed[keyword.len..cmd_trimmed.len];
                    const trimmed_slice = std.mem.trim(u8, slice, " \t\r");
                    switch (i) {
                        0 => {
                            // loadLayout:
                            const layout_slice = trimmed_slice[1 .. trimmed_slice.len - 1];
                            const layout_toks = splitLayoutCmd(allocator, layout_slice);
                            defer layout_toks.deinit();
                            const layout = try parseCommandLayout(allocator, layout_toks.items[1], layout_toks.items[0]);
                            try configptr.layouts.append(layout);
                        },
                        1 => {
                            // bind:
                            const bindparts = split(allocator, "{\"[", trimmed_slice[1 .. trimmed_slice.len - 1], ',');

                            if (bindparts.items.len == 4) {
                                const actionparts = split(allocator, "(\"", bindparts.items[2][1 .. bindparts.items[2].len - 1], ';');
                                for (actionparts.items) |action| {
                                    for (datatypes.ListConfigBindKeywords) |kw| {
                                        const actiontrimmed = std.mem.trim(u8, action, " \r\t");
                                        if (std.mem.startsWith(u8, actiontrimmed, datatypes.ListConfigKeywords[kw])) {
                                            if (actiontrimmed.len > datatypes.ListConfigKeywords[kw].len + 2) {
                                                const actionstriped = actiontrimmed[datatypes.ListConfigKeywords[kw].len + 1 .. actiontrimmed.len - 1];
                                                // std.debug.print("striped: {s}\n", .{actionstriped});
                                                // const actionsplit=split(allocator, "\"", actiontrimmed[], ',');
                                                switch (kw) {
                                                    3 => {
                                                        //pass in bind
                                                        // std.debug.print("")
                                                        const passparts = try parseCommandPass(allocator, actionstriped,bindparts.items[3]);
                                                        _ = passparts;
                                                        // for (passparts) |part| {
                                                        // std.debug.print("pass part: {s}\n", .{part});
                                                        // }
                                                    },
                                                    5 => {
                                                        //open in bind
                                                        const openparts = try parseCommandOpen(allocator, actionstriped);
                                                        for (openparts) |part| {
                                                            std.debug.print("open part: {s}\n", .{part});
                                                        }
                                                    },
                                                    else => {},
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        2 => {
                            // config:
                            var conf_toks = std.mem.splitScalar(u8, trimmed_slice[1 .. trimmed_slice.len - 1], ',');
                            if (conf_toks.next()) |next| {
                                if (conf_toks.next()) |next2| {
                                    // checking length of next and next2 for error also is good
                                    configptr.configs.put(std.mem.trim(u8, next, " \t\r"), std.mem.trim(u8, next2, " \t\r")) catch |e| {
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
                            //pass:
                            const pass_toks = split(allocator, "{\"", trimmed_slice[1 .. trimmed_slice.len - 1], ',');
                            if (pass_toks.items.len == 4) {
                                // const cmdout = std.mem.trim(u8, pass_toks.items[2], " \t\r");
                                var apps = std.ArrayList([]const u8).init(allocator);
                                const tempo = std.mem.trim(u8, pass_toks.items[3], " \r\t");
                                var pass_apps = std.mem.splitScalar(u8, tempo[1 .. tempo.len - 1], ',');
                                // const cmdin = std.mem.trim(u8, pass_toks.items[1], " \t\r");
                                while (pass_apps.next()) |app| {
                                    const valid_app = std.mem.trim(u8, app, " \t\r");
                                    try apps.append(valid_app[1 .. valid_app.len - 1]);
                                }
                                // const cmdinp = parseCommandKeymap(allocator, cmdin);
                                // const cmdoutp = parseCommandKeymap(allocator, cmdout);
                                // if (cmdinp.len != 0 and cmdoutp.len != 0) {
                                // const apps_ = apps.toOwnedSlice() catch &[_][]const u8{};
                                // _ = apps_;
                                // _ = try config.binds.insert(cmdinp, cmdoutp, apps_);
                                // } else {
                                // some error
                                // }
                            } else {
                                //some error
                            }
                        },
                        4 => {
                            //keymap
                            const toks = split(allocator, "\"", trimmed_slice[1 .. trimmed_slice.len - 1], ',');
                            _ = toks;
                            // std.debug.print("keymaps: {any}\n", .{toks.items});
                        },
                        else => {},
                    }
                }
            }
        }
        // const configptr=try allocator.create(Config)
        return configptr;
    } else |e| {
        return e;
    }
}

fn parseCommandLayout(allocator: std.mem.Allocator, input: []const u8, layout_name: []const u8) !datatypes.Layout {
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
                            arr[j] = std.fmt.parseFloat(f32, t) catch return datatypes.BlakeError.WrongLayoutNumbers;
                            j += 1;
                        }
                        if (arr.len != 4) return datatypes.BlakeError.LayoutLessNumbers;
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
    const layout = datatypes.Layout{
        .name = layout_name,
        .boxs = cur_arr,
        .size = layout_size,
    };
    return layout;
}
