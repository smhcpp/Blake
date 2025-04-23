const std = @import("std");
const print = std.debug.print;
const pf = @import("parser.zig");
const lexer = @import("lexer.zig");
const BlakeParserError = @import("lexer.zig").BlakeParserError;

pub const MethodWrapper = struct {
    ptr: *const fn (*anyopaque, []const Value) anyerror!Value,
    ctx: *anyopaque,
};

pub const ValueType = enum { i32, f32, str, bln, v, arr };

/// Value type for evaluation results
pub const Value = union(ValueType) {
    i32: i32,
    f32: f32,
    str: []const u8,
    bln: bool,
    v: void,
    arr: struct {
        items: []Value,
        allocator: std.mem.Allocator,
        pub fn deinit(self: *@This()) void {
            for (self.items) |item| {
                if (item == .arr) item.arr.deinit();
            }
            self.allocator.free(self.items);
        }
    },
};

/// Interpreter walks the AST and computes values, with an environment for variables
pub const Interpreter = struct {
    allocator: std.mem.Allocator,
    env: std.StringHashMap(Value),
    parser: *pf.Parser,

    methods: std.StringHashMap(MethodWrapper),
    sn: usize = 0,

    /// Create a new Interpreter using the given allocator
    pub fn init(allocator: std.mem.Allocator, buffer: []const u8) !*Interpreter {
        const inter = try allocator.create(Interpreter);
        inter.* = Interpreter{
            .allocator = allocator,
            .env = std.StringHashMap(Value).init(allocator),
            .parser = try pf.Parser.init(allocator, buffer),
            .methods = std.StringHashMap(MethodWrapper).init(allocator),
        };
        return inter;
    }

    /// Free any resources held by the Interpreter
    pub fn deinit(self: *Interpreter) void {
        // Clean up arrays in environment
        // var env_it = self.env.iterator();
        // while (env_it.next()) |entry| {
        // if (entry.value_ptr.* == .arr) {
        // entry.value_ptr.arr.deinit();
        // }
        // }

        // Clean up parsed AST arrays
        for (self.parser.statements.items) |stmt| {
            recursiveDeinit(stmt, self.allocator);
        }
        self.env.deinit();
        self.parser.deinit();
        self.methods.deinit();
    }

    fn recursiveDeinit(node: *pf.AstNode, allocator: std.mem.Allocator) void {
        switch (node.*) {
            .arr => |arr| {
                for (arr.el.items) |elem| {
                    recursiveDeinit(elem, allocator);
                }
                arr.el.deinit();
            },
            .call => |call| {
                for (call.args.items) |arg| {
                    recursiveDeinit(arg, allocator);
                }
                call.args.deinit();
            },
            .bin => |bin| {
                recursiveDeinit(bin.lhs, allocator);
                recursiveDeinit(bin.rhs, allocator);
            },
            else => {},
        }
        allocator.destroy(node);
    }

    pub fn registerMethod(self: *Interpreter, method: MethodWrapper, trigger: []const u8) !void {
        try self.methods.put(trigger, method);
    }

    pub fn evaluate(self: *Interpreter) !void {
        while (self.parser.statements.items.len > self.sn) : (self.sn += 1) {
            _ = try self.eval(self.parser.statements.items[self.sn]);
        }
        self.sn = 0;
    }

    /// Evaluate an AST node, updating env on assignments
    fn eval(self: *Interpreter, node: *pf.AstNode) !Value {
        return switch (node.*) {
            .i32 => |n| Value{ .i32 = n.val },
            .f32 => |n| Value{ .f32 = n.val },
            .str => |n| Value{ .str = n.val },
            .bln => |n| Value{ .bln = n.val },
            .vref => |n| self.env.get(n.name) orelse {
                try self.parser.scanner.panicAt("Undefined Variable", n.ln, n.pil);
                return BlakeParserError.Msg;
            },
            .assign => |asgn| blk: {
                const rhs_val = try self.eval(asgn.value);
                try self.env.put(asgn.name, rhs_val);
                break :blk rhs_val;
            },
            .arr => |arr| blk: {
                const items = try self.allocator.alloc(Value, arr.el.items.len);
                for (arr.el.items, 0..) |elem, i| {
                    items[i] = try self.eval(elem);
                }
                break :blk Value{ .arr = .{
                    .items = items,
                    .allocator = self.allocator,
                } };
            },
            .bin => |b| blk: {
                const left = try self.eval(b.lhs);
                const right = try self.eval(b.rhs);
                break :blk try self.evalBinaryOp(b.op, left, right);
            },
            .call => |call_node| blk: {
                // if (std.mem.eql(u8, call_node.name, "print")) {
                // for (call_node.args.items) |arg| {
                // const v = try self.eval(arg);
                // try printValue(v);
                // }
                // std.debug.print("\n", .{});
                // break :blk Value.v;
                // }

                if (self.methods.get(call_node.name)) |method| {
                    var args = std.ArrayList(Value).init(self.allocator);
                    defer args.deinit();
                    for (call_node.args.items) |arg| {
                        try args.append(try self.eval(arg));
                    }

                    const result = try method.ptr(method.ctx, args.items);
                    break :blk result;
                }
                try self.parser.scanner.panicAt("Unknown function", call_node.ln, call_node.pil);
                return BlakeParserError.Msg;
            },
            else => return BlakeParserError.InvalidOperator,
        };
    }

    fn toStringValue(allocator: std.mem.Allocator, val: Value) anyerror![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        switch (val) {
            .i32 => |v| try buffer.writer().print("{}", .{v}),
            .f32 => |v| try buffer.writer().print("{d:.7}", .{v}),
            .bln => |v| try buffer.writer().print("{}", .{v}),
            .arr => |arr| {
                try buffer.append('[');
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try buffer.appendSlice(", ");
                    const s = try toStringValue(allocator, item);
                    defer allocator.free(s);
                    try buffer.appendSlice(s);
                }
                try buffer.append(']');
            },
            .str => |s| {
                try buffer.appendSlice(s);
            },
            .v => {
                try buffer.appendSlice("Void");
            },
        }
        return buffer.toOwnedSlice();
    }

    fn handleArrayOperation(self: *Interpreter, op: lexer.TokenType, a: Value, b: Value) !Value {
        const allocator = self.allocator;
        // Array-Array operations
        if (a == .arr and b == .arr) {
            if (a.arr.items.len != b.arr.items.len) {
                return BlakeParserError.ArrayLengthMismatch;
            }
            const results = try allocator.alloc(Value, a.arr.items.len);
            for (a.arr.items, b.arr.items, 0..) |a_item, b_item, i| {
                results[i] = try self.evalBinaryOp(op, a_item, b_item);
            }
            return Value{ .arr = .{ .items = results, .allocator = self.allocator } };
        }

        // Array-Scalar operations
        if (a == .arr) {
            const results = try allocator.alloc(Value, a.arr.items.len);
            for (a.arr.items, 0..) |item, i| {
                results[i] = try self.evalBinaryOp(op, item, b);
            }
            return Value{ .arr = .{ .items = results, .allocator = self.allocator } };
        }

        if (b == .arr) {
            const results = try allocator.alloc(Value, b.arr.items.len);
            for (b.arr.items, 0..) |item, i| {
                results[i] = try self.evalBinaryOp(op, a, item);
            }
            return Value{ .arr = .{ .items = results, .allocator = self.allocator } };
        }

        return BlakeParserError.TypeMismatch;
    }

    /// Handle binary operations
    fn evalBinaryOp(self: *Interpreter, op: lexer.TokenType, left: Value, right: Value) anyerror!Value {
        if (left == .arr or right == .arr) return self.handleArrayOperation(op, left, right);
        return switch (op) {
            .Plus => self.add(left, right),
            .Minus => self.sub(left, right),
            .Star => self.mul(left, right),
            .Slash => self.div(left, right),
            .Percent => self.mod(left, right),
            .Caret => self.exp(left, right),
            else => BlakeParserError.InvalidOperator,
        };
    }

    fn add(self: *Interpreter, a: Value, b: Value) !Value {
        if (a == .str or b == .str) {
            const a_str = try toStringValue(self.allocator, a);
            defer self.allocator.free(a_str);
            const b_str = try toStringValue(self.allocator, b);
            defer self.allocator.free(b_str);
            return try stringConcat(self.allocator, a_str, b_str);
        }

        switch (a) {
            .i32 => |a_int| switch (b) {
                .i32 => |b_int| return Value{ .i32 = a_int + b_int },
                .f32 => |b_float| return Value{ .f32 = @as(f32, @floatFromInt(a_int)) + b_float },
                .str => |b_str| {
                    const a_str = try toString(self.allocator, a);
                    defer self.allocator.free(a_str);
                    return try stringConcat(self.allocator, a_str, b_str);
                },
                else => return BlakeParserError.TypeMismatch,
            },
            .f32 => |a_float| switch (b) {
                .i32 => |b_int| return Value{ .f32 = a_float + @as(f32, @floatFromInt(b_int)) },
                .f32 => |b_float| return Value{ .f32 = a_float + b_float },
                .str => |b_str| {
                    const a_str = try toString(self.allocator, a);
                    defer self.allocator.free(a_str);
                    return try stringConcat(self.allocator, a_str, b_str);
                },
                else => return BlakeParserError.TypeMismatch,
            },
            else => return BlakeParserError.TypeMismatch,
        }
    }

    fn sub(self: *Interpreter, a: Value, b: Value) !Value {
        _ = self;
        switch (a) {
            .i32 => |a_int| switch (b) {
                .i32 => |b_int| return Value{ .i32 = a_int - b_int },
                .f32 => |b_float| return Value{ .f32 = @as(f32, @floatFromInt(a_int)) - b_float },
                else => return BlakeParserError.TypeMismatch,
            },
            .f32 => |a_float| switch (b) {
                .i32 => |b_int| return Value{ .f32 = a_float - @as(f32, @floatFromInt(b_int)) },
                .f32 => |b_float| return Value{ .f32 = a_float - b_float },
                else => return BlakeParserError.TypeMismatch,
            },
            else => return BlakeParserError.TypeMismatch,
        }
    }

    fn mul(self: *Interpreter, a: Value, b: Value) !Value {
        _ = self;
        switch (a) {
            .i32 => |a_int| switch (b) {
                .i32 => |b_int| return Value{ .i32 = a_int * b_int },
                .f32 => |b_float| return Value{ .f32 = @as(f32, @floatFromInt(a_int)) * b_float },
                else => return BlakeParserError.TypeMismatch,
            },
            .f32 => |a_float| switch (b) {
                .i32 => |b_int| return Value{ .f32 = a_float * @as(f32, @floatFromInt(b_int)) },
                .f32 => |b_float| return Value{ .f32 = a_float * b_float },
                else => return BlakeParserError.TypeMismatch,
            },
            else => return BlakeParserError.TypeMismatch,
        }
    }

    fn div(self: *Interpreter, a: Value, b: Value) !Value {
        _ = self;
        switch (b) {
            .i32 => |b_int| if (b_int == 0) return BlakeParserError.DivisionByZero,
            .f32 => |b_float| if (b_float == 0.0) return BlakeParserError.DivisionByZero,
            else => {},
        }

        switch (a) {
            .i32 => |a_int| switch (b) {
                .i32 => |b_int| return Value{ .i32 = @divTrunc(a_int, b_int) },
                .f32 => |b_float| return Value{ .f32 = @as(f32, @floatFromInt(a_int)) / b_float },
                else => return BlakeParserError.TypeMismatch,
            },
            .f32 => |a_float| switch (b) {
                .i32 => |b_int| return Value{ .f32 = a_float / @as(f32, @floatFromInt(b_int)) },
                .f32 => |b_float| return Value{ .f32 = a_float / b_float },
                else => return BlakeParserError.TypeMismatch,
            },
            else => return BlakeParserError.TypeMismatch,
        }
    }

    fn mod(self: *Interpreter, a: Value, b: Value) !Value {
        _ = self;
        switch (a) {
            .i32 => |a_int| switch (b) {
                .i32 => |b_int| {
                    if (b_int == 0) return BlakeParserError.DivisionByZero;
                    return Value{ .i32 = @mod(a_int, b_int) };
                },
                else => return BlakeParserError.TypeMismatch,
            },
            else => return BlakeParserError.TypeMismatch,
        }
    }

    fn exp(self: *Interpreter, a: Value, b: Value) !Value {
        _ = self;
        switch (a) {
            .i32 => |a_int| switch (b) {
                .i32 => |b_int| {
                    if (b_int < 0) return BlakeParserError.TypeMismatch;
                    return Value{ .i32 = std.math.pow(i32, a_int, @intCast(b_int)) };
                },
                .f32 => |b_float| return Value{ .f32 = std.math.pow(f32, @as(f32, @floatFromInt(a_int)), b_float) },
                else => return BlakeParserError.TypeMismatch,
            },
            .f32 => |a_float| switch (b) {
                .i32 => |b_int| return Value{ .f32 = std.math.pow(f32, a_float, @floatFromInt(b_int)) },
                .f32 => |b_float| return Value{ .f32 = std.math.pow(f32, a_float, b_float) },
                else => return BlakeParserError.TypeMismatch,
            },
            else => return BlakeParserError.TypeMismatch,
        }
    }

    fn stringConcat(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !Value {
        const result = try allocator.alloc(u8, a.len + b.len);
        @memcpy(result[0..a.len], a);
        @memcpy(result[a.len..], b);
        return Value{ .str = result };
    }

    fn arrayIndex(self: *Interpreter, array: Value, index: Value) !Value {
        _ = self;
        if (array != .array) return BlakeParserError.TypeMismatch;
        if (index != .i32) return BlakeParserError.TypeMismatch;

        const idx = @as(usize, @intCast(index.i32));
        if (idx >= array.array.items.len) {
            return BlakeParserError.IndexOutOfBounds;
        }

        return array.array.items[idx];
    }

    fn arrayConcat(self: *Interpreter, a: Value, b: Value) !Value {
        const allocator = self.allocator;
        const new_items = try allocator.alloc(Value, a.arr.items.len + b.arr.items.len);
        @memcpy(new_items[0..a.arr.items.len], a.arr.items);
        @memcpy(new_items[a.items.len..], b.arr.items);
        return Value{ .array = .{
            .items = new_items,
            .allocator = allocator,
        } };
    }
};

fn toString(allocator: std.mem.Allocator, v: Value) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    switch (v) {
        .i32 => |i| try buffer.writer().print("{}", .{i}),
        .f32 => |f| try buffer.writer().print("{d:.2}", .{f}),
        .str => |s| return s,
        .bln => |b| try buffer.writer().print("{}", .{b}),
        .v => try buffer.writer().print("void", .{}),
        .arr => |arr| try buffer.writer().print("{any}", .{arr}),
    }

    return buffer.toOwnedSlice();
}

pub fn getType(v: Value) ValueType {
    switch (v) {
        .i32 => return .i32,
        .f32 => return .f32,
        .str => return .str,
        .bln => return .bln,
        .v => return .v,
        .arr => return .arr,
    }
}
