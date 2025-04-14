const std = @import("std");
const datatypes=@import("datatypes.zig");
const print = std.debug.print;
const config=@import("config.zig");
const utility=@import("utility.zig");
const Allocator = std.mem.Allocator;

pub fn loadConfig(allocator: Allocator, filename: []const u8) !*config.Config {
    const home_dir = std.posix.getenv("HOME") orelse return datatypes.BlakeError.MissingHomeDir;
    const file_path = try std.fs.path.join(allocator, &.{ home_dir, ".config", "blake", filename });
    defer allocator.free(file_path);
    var file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();
    const buffer = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(buffer);
    const conf = try parseConfig(allocator, buffer);
    return conf;
}

pub fn parseConfig(allocator: Allocator, input: []const u8) !*config.Config{
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
        return configptr;
    }else return datatypes.BlakeError.NullConfig;
}
