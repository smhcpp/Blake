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

        try interpreter.evaluate();
    }
};
