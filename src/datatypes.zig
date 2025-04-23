const std = @import("std");
const xkb = @import("xkbcommon");
const wlr = @import("wlroots");
const Keyboard = @import("keyboard.zig").Keyboard;
const utility = @import("utility.zig");
const Allocator = std.mem.Allocator;

pub const Keymap = struct {
    tap: xkb.Keysym = @enumFromInt(0),
    hold: xkb.Keysym = @enumFromInt(0),
};

pub const ModKey = struct {
    name: []const u8,
    sym: u32,
};

// pub const ListConfigKeywords: [6][]const u8 = .{ "loadLayout", "bind", "config", "pass", "keymap", "open" };
// pub const ListConfigBindKeywords: []const u8 = &[_]u8{ 3, 5 };

/// Space and Tab should be written as ' ' and '\t' respectively, so this list
/// does not containt those keysyms which is good for writting.
pub const ListModKeysForWrite = [_]ModKey{
    ModKey{ .name = "CR", .sym = xkb.Keysym.Return },
    ModKey{ .name = "Esc", .sym = xkb.Keysym.Escape },
    ModKey{ .name = "BS", .sym = xkb.Keysym.BackSpace },
    ModKey{ .name = "ShL", .sym = xkb.Keysym.Shift_L },
    ModKey{ .name = "ShR", .sym = xkb.Keysym.Shift_R },
    ModKey{ .name = "CtL", .sym = xkb.Keysym.Control_L },
    ModKey{ .name = "CtR", .sym = xkb.Keysym.Control_R },
    ModKey{ .name = "AlL", .sym = xkb.Keysym.Alt_L },
    ModKey{ .name = "AlR", .sym = xkb.Keysym.Alt_R },
    ModKey{ .name = "SuL", .sym = xkb.Keysym.Super_L },
    ModKey{ .name = "SuR", .sym = xkb.Keysym.Super_R },
    ModKey{ .name = "Cap", .sym = xkb.Keysym.Caps_Lock },
    ModKey{ .name = "Num", .sym = xkb.Keysym.Num_Lock },
    // here there should be some other keys which will be added later
    ModKey{ .name = "F1", .sym = xkb.Keysym.F1 },
    ModKey{ .name = "F2", .sym = xkb.Keysym.F2 },
    ModKey{ .name = "F3", .sym = xkb.Keysym.F3 },
    ModKey{ .name = "F4", .sym = xkb.Keysym.F4 },
    ModKey{ .name = "F5", .sym = xkb.Keysym.F5 },
    ModKey{ .name = "F6", .sym = xkb.Keysym.F6 },
    ModKey{ .name = "F7", .sym = xkb.Keysym.F7 },
    ModKey{ .name = "F8", .sym = xkb.Keysym.F8 },
    ModKey{ .name = "F9", .sym = xkb.Keysym.F9 },
    ModKey{ .name = "F10", .sym = xkb.Keysym.F10 },
    ModKey{ .name = "F11", .sym = xkb.Keysym.F11 },
    ModKey{ .name = "F12", .sym = xkb.Keysym.F12 },
};

///Contains all modkeys for reading from config files.
pub const ListModKeys = [_]ModKey{
    ModKey{ .name = "CR", .sym = xkb.Keysym.Return },
    ModKey{ .name = "Esc", .sym = xkb.Keysym.Escape },
    ModKey{ .name = "Tab", .sym = xkb.Keysym.Tab },
    ModKey{ .name = "Spc", .sym = xkb.Keysym.space },
    ModKey{ .name = "BS", .sym = xkb.Keysym.BackSpace },
    ModKey{ .name = "ShL", .sym = xkb.Keysym.Shift_L },
    ModKey{ .name = "ShR", .sym = xkb.Keysym.Shift_R },
    ModKey{ .name = "CtL", .sym = xkb.Keysym.Control_L },
    ModKey{ .name = "CtR", .sym = xkb.Keysym.Control_R },
    ModKey{ .name = "AlL", .sym = xkb.Keysym.Alt_L },
    ModKey{ .name = "AlR", .sym = xkb.Keysym.Alt_R },
    ModKey{ .name = "SuL", .sym = xkb.Keysym.Super_L },
    ModKey{ .name = "SuR", .sym = xkb.Keysym.Super_R },
    ModKey{ .name = "Cap", .sym = xkb.Keysym.Caps_Lock },
    ModKey{ .name = "Num", .sym = xkb.Keysym.Num_Lock },
    // here there should be some other keys which will be added later
    ModKey{ .name = "F1", .sym = xkb.Keysym.F1 },
    ModKey{ .name = "F2", .sym = xkb.Keysym.F2 },
    ModKey{ .name = "F3", .sym = xkb.Keysym.F3 },
    ModKey{ .name = "F4", .sym = xkb.Keysym.F4 },
    ModKey{ .name = "F5", .sym = xkb.Keysym.F5 },
    ModKey{ .name = "F6", .sym = xkb.Keysym.F6 },
    ModKey{ .name = "F7", .sym = xkb.Keysym.F7 },
    ModKey{ .name = "F8", .sym = xkb.Keysym.F8 },
    ModKey{ .name = "F9", .sym = xkb.Keysym.F9 },
    ModKey{ .name = "F10", .sym = xkb.Keysym.F10 },
    ModKey{ .name = "F11", .sym = xkb.Keysym.F11 },
    ModKey{ .name = "F12", .sym = xkb.Keysym.F12 },
};

pub const BlakeError = error{
    MapNotFound,
    NullConfig,
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
    return BlakeError.WrongMode;
}

pub const Layout = struct {
    name: []const u8,
    size: u8,
    boxs: []const [4]f32,
};

pub const BindActions = struct {
    const Self = @This();

    appnames: std.ArrayList([]const u8),
    handlers: std.ArrayList(ActionHandler),
    allocator: Allocator,

    /// Initialize a new BindActions instance
    pub fn init(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .appnames = std.ArrayList([]const u8).init(allocator),
            .handlers = std.ArrayList(ActionHandler).init(allocator),
            .allocator = allocator,
        };
        return self;
    }

    /// Free all resources associated with the BindActions
    pub fn deinit(self: *Self) void {
        // Free all appname strings
        for (self.appnames.items) |name| {
            self.allocator.free(name);
        }
        self.appnames.deinit();

        // Handlers don't own their params, just clear the list
        self.handlers.deinit();

        // Free the struct itself
        self.allocator.destroy(self);
    }

    /// Add a new handler to the bind actions
    pub fn addHandler(self: *Self, handler: ActionHandler) !void {
        try self.handlers.append(handler);
    }

    /// Remove a handler by index
    pub fn removeHandler(self: *Self, index: usize) void {
        _ = self.handlers.swapRemove(index);
    }

    /// Add an application name to the bind's scope
    pub fn addAppname(self: *Self, name: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        try self.appnames.append(name_copy);
    }

    /// Remove an appname by index
    pub fn removeAppname(self: *Self, index: usize) void {
        const name = self.appnames.swapRemove(index);
        self.allocator.free(name);
    }

    /// Check if an appname exists in the bind's scope
    pub fn hasAppname(self: *Self, name: []const u8) bool {
        for (self.appnames.items) |app| {
            if (std.mem.eql(u8, app, name)) return true;
        }
        return false;
    }

    /// Add multiple handlers at once
    pub fn addHandlers(self: *Self, handlers: []const ActionHandler) !void {
        try self.handlers.appendSlice(handlers);
    }

    /// Add multiple appnames at once
    pub fn addAppnames(self: *Self, names: []const []const u8) !void {
        for (names) |name| {
            try self.addAppname(name);
        }
    }

    /// Execute all registered handlers
    pub fn triggerAll(self: *Self, context: ?*anyopaque) void {
        for (self.handlers.items) |handler| {
            handler.func(context);
        }
    }

    /// Clear all handlers while keeping capacity
    pub fn clearHandlers(self: *Self) void {
        self.handlers.clearRetainingCapacity();
    }

    /// Clear all appnames while keeping capacity
    pub fn clearAppnames(self: *Self) void {
        for (self.appnames.items) |name| {
            self.allocator.free(name);
        }
        self.appnames.clearRetainingCapacity();
    }
};

pub const ActionHandler = struct {
    func: *const fn (ctx: ?*anyopaque) void,
    params: ?*anyopaque,
};
