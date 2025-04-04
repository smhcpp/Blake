const std = @import("std");

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

        pub fn init(allocator: std.mem.Allocator) Self {
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
            // Remove the key from its current position if it exists
            if (self.map.contains(key)) {
                self.removeFromList(key);
            }

            const node = Node{
                .value = value,
                .prev = self.tail,
                .next = null,
            };

            try self.map.put(key, node);

            // Update the previous tail's next pointer
            if (self.tail) |tail_key| {
                if (self.map.getPtr(tail_key)) |tail_node| {
                    tail_node.next = key;
                }
            } else {
                // The list was empty, update head
                self.head = key;
            }

            // Update tail to the new key
            self.tail = key;
        }

        // pub fn count(self: *const Self) usize {
        // return self.map.count();
        // }

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
