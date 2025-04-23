const std = @import("std");
const Server = @import("server.zig").Server;
const print = std.debug.print;
const xkb = @import("xkbcommon");
const wlr = @import("wlroots");
const Keyboard = @import("keyboard.zig").Keyboard;
const utility = @import("utility.zig");
const datatypes = @import("datatypes.zig");
const interpreterf = @import("interpreter.zig");
const Api = @import("api.zig");

pub const Config = struct {
    server: *Server,
    workspace_num: u8 = 1,
    workspace_cur: u8 = 0,

    layouts: std.ArrayList(datatypes.Layout),
    keymaps: std.AutoHashMap(xkb.Keysym, datatypes.Keymap),
    bindsi: std.StringHashMap(datatypes.BindActions),
    bindsn: std.StringHashMap(datatypes.BindActions),
    bindsc: std.StringHashMap(datatypes.BindActions),
    // binds does not have modes. we need to have
    // 3 binds possibly to cover normal mode and command mode
    // and insert mode

    pub fn init(server: *Server) !*Config {
        const config = try server.alloc.create(Config);
        config.* = Config{
            .server = server,
            .layouts = std.ArrayList(datatypes.Layout).init(server.alloc),
            .keymaps = std.AutoHashMap(xkb.Keysym, datatypes.Keymap).init(server.alloc),
            .bindsi = std.StringHashMap(datatypes.BindActions).init(server.alloc),
            .bindsc = std.StringHashMap(datatypes.BindActions).init(server.alloc),
            .bindsn = std.StringHashMap(datatypes.BindActions).init(server.alloc),
        };
        try config.loadConfig();
        return config;
    }

    fn loadConfig(config: *Config) !void {
        const home_dir = std.posix.getenv("HOME") orelse return datatypes.BlakeError.MissingHomeDir;
        const file_path = try std.fs.path.join(config.server.alloc, &.{ home_dir, ".config", "blake", "test.blk" });
        defer config.server.alloc.free(file_path);
        var file = try std.fs.openFileAbsolute(file_path, .{});
        defer file.close();
        const buffer = try file.readToEndAlloc(config.server.alloc, 4096);
        defer config.server.alloc.free(buffer);

        const interpreter = try interpreterf.Interpreter.init(config.server.alloc, buffer);
        defer interpreter.deinit();

        try interpreter.parser.parse();

        try interpreter.registerMethod(.{ .ptr = &Api.openApp, .ctx = config }, "open");
        try interpreter.registerMethod(.{ .ptr = &Api.cycleWindowBackward, .ctx = config }, "cycf");
        try interpreter.registerMethod(.{ .ptr = &Api.cycleWindowForward, .ctx = config }, "cycb");
        try interpreter.registerMethod(.{ .ptr = &Api.printValue, .ctx = config }, "print");
        try interpreter.registerMethod(.{ .ptr = &Api.loadLayout, .ctx = config }, "layout");
        
        try interpreter.evaluate();
    }
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
