const std = @import("std");
const Allocator = std.mem.Allocator;
const logkbn = std.log.scoped(.KeyBindNode);

pub fn sumSize(comptime T: type, n: T) T {
    var sum: T = 0;
    var i: T = 1;
    while (i <= n) : (i = i + 1) {
        sum = sum + i;
    }
    return sum;
}

pub fn OrderedAutoHashMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        map: std.AutoHashMap(K, Node),
        head: ?K,
        tail: ?K,

        pub const Node = struct {
            value: V,
            prev: ?K,
            next: ?K,
        };

        pub fn init(allocator: Allocator) Self {
            return .{
                .map = std.AutoHashMap(K, Node).init(allocator),
                .head = null,
                .tail = null,
            };
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit();
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            if (self.map.contains(key)) {
                self.removeFromList(key);
            }

            const node = Node{
                .value = value,
                .prev = self.tail,
                .next = null,
            };

            try self.map.put(key, node);

            if (self.tail) |tail_key| {
                if (self.map.getPtr(tail_key)) |tail_node| {
                    tail_node.next = key;
                }
            } else {
                self.head = key;
            }

            self.tail = key;
        }

        pub fn get(self: *const Self, key: K) ?V {
            const node = self.map.get(key) orelse return null;
            return node.value;
        }

        pub fn getPtr(self: *Self, key: K) ?*V {
            const node_ptr = self.map.getPtr(key) orelse return null;
            return &node_ptr.value;
        }

        fn removeFromList(self: *Self, key: K) void {
            const node = self.map.get(key) orelse return;

            // Update previous node's next pointer
            if (node.prev) |prev_key| {
                if (self.map.getPtr(prev_key)) |prev_node| {
                    prev_node.next = node.next;
                }
            } else {
                // This node was the head, update head
                self.head = node.next;
            }

            // Update next node's previous pointer
            if (node.next) |next_key| {
                if (self.map.getPtr(next_key)) |next_node| {
                    next_node.prev = node.prev;
                }
            } else {
                // This node was the tail, update tail
                self.tail = node.prev;
            }
        }

        pub fn remove(self: *Self, key: K) ?V {
            const node = self.map.get(key) orelse return null;
            self.removeFromList(key);
            const value = node.value;
            _ = self.map.remove(key);
            return value;
        }

        pub fn contains(self: *Self, key: K) bool {
            return self.map.contains(key);
        }

        pub fn iterator(self: *Self) Iterator {
            return .{
                .current = self.head,
                .map = &self.map,
            };
        }

        pub const Iterator = struct {
            current: ?K,
            map: *const std.AutoHashMap(K, Node),

            pub fn next(self: *Iterator) ?K {
                const current_key = self.current orelse return null;
                const node = self.map.get(current_key) orelse {
                    self.current = null;
                    return null;
                };
                self.current = node.next;
                return current_key;
            }
        };
    };
}

pub const KeyBindNode = struct {
    branches: std.AutoHashMap(u64, *KeyBindNode),
    cmdout: []const u64,
    appnames: std.ArrayList([]const u8),
    allocator: Allocator,

    /// Initialize a new node
    pub fn init(allocator: Allocator) !*KeyBindNode {
        const node = try allocator.create(KeyBindNode); 
        node.* = .{
            .branches = std.AutoHashMap(u64, *KeyBindNode).init(allocator),
            .cmdout = &.{},
            .appnames = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
        return node;
    }

    /// Recursively free memory
    pub fn deinit(self: *KeyBindNode) void {
        var iter = self.branches.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.branches.deinit();
        
        if (self.cmdout.len > 0) {
            self.allocator.free(self.cmdout);
        }
        
        for (self.appnames.items) |name| {
            self.allocator.free(name);
        }
        self.appnames.deinit();
        self.allocator.destroy(self);
    }

    /// Insert a command sequence with associated data
    pub fn insert(
        self: *KeyBindNode,
        sequence: []const u64,
        cmdout: []const u64,
        appnames: []const []const u8
    ) !void {
        var current = self;
        for (sequence) |cmd| {
            const next = current.branches.get(cmd) orelse blk: {
                const node = try KeyBindNode.init(current.allocator); 
                current.branches.put(cmd, node) catch |err| {
                    logkbn.err("Failed to insert command 0x{x}: {s}", .{cmd, @errorName(err)});
                    node.deinit();
                };
                break :blk node;
            };
            current = next;
        }
        _= current.updateBoth(cmdout, appnames);
    }

    /// Update appnames with new values
    pub fn updateAppNames(self: *KeyBindNode, new_appnames: []const []const u8) bool {
        // Clear existing
        for (self.appnames.items) |name| {
            self.allocator.free(name);
        }
        self.appnames.clearAndFree();

        // Add new
        for (new_appnames) |name| {
            const name_copy = self.allocator.dupe(u8, name) catch |err| {
                logkbn.err("Failed to duplicate appname '{s}': {s}", .{name, @errorName(err)});
                return false;
            };
            self.appnames.append(name_copy) catch |err| {
                self.allocator.free(name_copy);
                logkbn.err("Failed to store appname '{s}': {s}", .{name, @errorName(err)});
                return false;
            };
        }
        return true;
    }

    /// Update cmdout with new values
    pub fn updateCmdOut(self: *KeyBindNode, new_cmdout: []const u64) bool {
        if (self.cmdout.len > 0) {
            self.allocator.free(self.cmdout);
        }
        self.cmdout = self.allocator.dupe(u64, new_cmdout) catch |err| {
            logkbn.err("Failed to duplicate cmdout: {s}", .{@errorName(err)});
            self.cmdout = &.{};
            return false;
        };
        return true;
    }

    /// Update both fields at once
    pub fn updateBoth(self: *KeyBindNode, new_cmdout: []const u64, new_appnames: []const []const u8) bool {
        return self.updateCmdOut(new_cmdout) and self.updateAppNames(new_appnames);
    }

    /// Search for complete command sequence
    pub fn search(self: *KeyBindNode, sequence: []const u64) ?*KeyBindNode {
        var current = self;
        for (sequence) |cmd| {
            current = current.branches.get(cmd) orelse return null;
        }
        return current;
    }

    /// Find longest matching partial sequence
    pub fn searchPartial(self: *KeyBindNode, input: []const u64) ?*KeyBindNode {
        var current: ?*KeyBindNode = self;
        var i: usize = 0;
        
        while (i < input.len) : (i += 1) {
            current = current.?.branches.get(input[i]) orelse break;
        }
        return current;
    }
};
