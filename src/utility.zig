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
