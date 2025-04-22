const std = @import("std");
const print = std.debug.print;
const parserf = @import("parser.zig");
const lexer = @import("lexer.zig");

pub const MethodWrapper = struct {
    ptr: *const fn (*anyopaque, []const Value) anyerror!Value,
    ctx: *anyopaque,
};

/// Value type for evaluation results
pub const Value = union(enum) {
    i32: i32,
    f32: f32,
    str: []const u8,
    bln: bool,
    v: void,
};

/// Errors that can occur during evaluation
const InterpreterError = parserf.ParserError;

/// Interpreter walks the AST and computes values, with an environment for variables
pub const Interpreter = struct {
    allocator: std.mem.Allocator,
    env: std.StringHashMap(Value),
    parser: *parserf.Parser,

    methods: std.StringHashMap(MethodWrapper),
    sn: usize = 0,

    /// Create a new Interpreter using the given allocator
    pub fn init(allocator: std.mem.Allocator, buffer: []const u8) !*Interpreter {
        const inter = try allocator.create(Interpreter);
        inter.* = Interpreter{
            .allocator = allocator,
            .env = std.StringHashMap(Value).init(allocator),
            .parser = try parserf.Parser.init(allocator, buffer),
            .methods = std.StringHashMap(MethodWrapper).init(allocator),
        };
        return inter;
    }

    /// Free any resources held by the Interpreter
    pub fn deinit(self: *Interpreter) void {
        self.env.deinit();
        self.parser.deinit();
        self.methods.deinit();
    }

    pub fn registerMethod(self: *Interpreter, method: MethodWrapper, trigger: []const u8) !void {
        try self.methods.put(trigger, method);
    }

    pub fn evaluate(self: *Interpreter) !void {
        while (self.parser.statements.items.len > self.sn) : (self.sn += 1) {
            const idx = self.sn;
            const result = try self.eval(self.parser.statements.items[self.sn]);
            switch (result) {
                .i32 => |i| std.debug.print("Result[{}] = {} (int)\n", .{ idx, i }),
                .f32 => |f| std.debug.print("Result[{}] = {} (float)\n", .{ idx, f }),
                .str => |s| std.debug.print("Result[{}] = \"{s}\" (string)\n", .{ idx, s }),
                .bln => |b| std.debug.print("Result[{}] = {} (bool)\n", .{ idx, b }),
                .v => |_| std.debug.print("Result[{}] = void\n", .{idx}),
            }
        }
        self.sn = 0;
    }

    /// Evaluate an AST node, updating env on assignments
    fn eval(self: *Interpreter, node: *parserf.AstNode) !Value {
        return switch (node.*) {
            .i32 => |v| Value{ .i32 = v },
            .f32 => |v| Value{ .f32 = v },
            .str => |s| Value{ .str = s },
            .bln => |b| Value{ .bln = b },
            .vref => |name| self.env.get(name) orelse return InterpreterError.UndefinedVariable,
            .assign => |asgn| blk: {
                const rhs_val = try self.eval(asgn.value);
                try self.env.put(asgn.name, rhs_val);
                break :blk rhs_val;
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
                return InterpreterError.UnknownFunction;
            },
            else => return InterpreterError.InvalidOperator,
        };
    }

    /// Handle binary operations
    fn evalBinaryOp(self: *Interpreter, op: lexer.TokenType, left: Value, right: Value) !Value {
        return switch (op) {
            .Plus => self.add(left, right),
            .Minus => self.sub(left, right),
            .Star => self.mul(left, right),
            .Slash => self.div(left, right),
            .Percent => self.mod(left, right),
            .Caret => self.exp(left, right),
            else => InterpreterError.InvalidOperator,
        };
    }

    fn add(self: *Interpreter, a: Value, b: Value) !Value {
        switch (a) {
            .i32 => |a_int| switch (b) {
                .i32 => |b_int| return Value{ .i32 = a_int + b_int },
                .f32 => |b_float| return Value{ .f32 = @as(f32, @floatFromInt(a_int)) + b_float },
                .str => |b_str| {
                    const a_str = try toString(self.allocator, a);
                    defer self.allocator.free(a_str);
                    return try stringConcat(self.allocator, a_str, b_str);
                },
                else => return InterpreterError.TypeMismatch,
            },
            .f32 => |a_float| switch (b) {
                .i32 => |b_int| return Value{ .f32 = a_float + @as(f32, @floatFromInt(b_int)) },
                .f32 => |b_float| return Value{ .f32 = a_float + b_float },
                .str => |b_str| {
                    const a_str = try toString(self.allocator, a);
                    defer self.allocator.free(a_str);
                    return try stringConcat(self.allocator, a_str, b_str);
                },
                else => return InterpreterError.TypeMismatch,
            },
            .str => |a_str| switch (b) {
                .str => |b_str| return try stringConcat(self.allocator, a_str, b_str),
                else => {
                    const b_str = try toString(self.allocator, b);
                    defer self.allocator.free(b_str);
                    return try stringConcat(self.allocator, a_str, b_str);
                },
            },
            else => return InterpreterError.TypeMismatch,
        }
    }

    fn sub(self: *Interpreter, a: Value, b: Value) !Value {
        _ = self;
        switch (a) {
            .i32 => |a_int| switch (b) {
                .i32 => |b_int| return Value{ .i32 = a_int - b_int },
                .f32 => |b_float| return Value{ .f32 = @as(f32, @floatFromInt(a_int)) - b_float },
                else => return InterpreterError.TypeMismatch,
            },
            .f32 => |a_float| switch (b) {
                .i32 => |b_int| return Value{ .f32 = a_float - @as(f32, @floatFromInt(b_int)) },
                .f32 => |b_float| return Value{ .f32 = a_float - b_float },
                else => return InterpreterError.TypeMismatch,
            },
            else => return InterpreterError.TypeMismatch,
        }
    }

    fn mul(self: *Interpreter, a: Value, b: Value) !Value {
        _ = self;
        switch (a) {
            .i32 => |a_int| switch (b) {
                .i32 => |b_int| return Value{ .i32 = a_int * b_int },
                .f32 => |b_float| return Value{ .f32 = @as(f32, @floatFromInt(a_int)) * b_float },
                else => return InterpreterError.TypeMismatch,
            },
            .f32 => |a_float| switch (b) {
                .i32 => |b_int| return Value{ .f32 = a_float * @as(f32, @floatFromInt(b_int)) },
                .f32 => |b_float| return Value{ .f32 = a_float * b_float },
                else => return InterpreterError.TypeMismatch,
            },
            else => return InterpreterError.TypeMismatch,
        }
    }

    fn div(self: *Interpreter, a: Value, b: Value) !Value {
        _ = self;
        switch (b) {
            .i32 => |b_int| if (b_int == 0) return InterpreterError.DivisionByZero,
            .f32 => |b_float| if (b_float == 0.0) return InterpreterError.DivisionByZero,
            else => {},
        }

        switch (a) {
            .i32 => |a_int| switch (b) {
                .i32 => |b_int| return Value{ .i32 = @divTrunc(a_int, b_int) },
                .f32 => |b_float| return Value{ .f32 = @as(f32, @floatFromInt(a_int)) / b_float },
                else => return InterpreterError.TypeMismatch,
            },
            .f32 => |a_float| switch (b) {
                .i32 => |b_int| return Value{ .f32 = a_float / @as(f32, @floatFromInt(b_int)) },
                .f32 => |b_float| return Value{ .f32 = a_float / b_float },
                else => return InterpreterError.TypeMismatch,
            },
            else => return InterpreterError.TypeMismatch,
        }
    }

    fn mod(self: *Interpreter, a: Value, b: Value) !Value {
        _ = self;
        switch (a) {
            .i32 => |a_int| switch (b) {
                .i32 => |b_int| {
                    if (b_int == 0) return InterpreterError.DivisionByZero;
                    return Value{ .i32 = @mod(a_int, b_int) };
                },
                else => return InterpreterError.TypeMismatch,
            },
            else => return InterpreterError.TypeMismatch,
        }
    }

    fn exp(self: *Interpreter, a: Value, b: Value) !Value {
        _ = self;
        switch (a) {
            .i32 => |a_int| switch (b) {
                .i32 => |b_int| {
                    if (b_int < 0) return InterpreterError.TypeMismatch;
                    return Value{ .i32 = std.math.pow(i32, a_int, @intCast(b_int)) };
                },
                .f32 => |b_float| return Value{ .f32 = std.math.pow(f32, @as(f32, @floatFromInt(a_int)), b_float) },
                else => return InterpreterError.TypeMismatch,
            },
            .f32 => |a_float| switch (b) {
                .i32 => |b_int| return Value{ .f32 = std.math.pow(f32, a_float, @floatFromInt(b_int)) },
                .f32 => |b_float| return Value{ .f32 = std.math.pow(f32, a_float, b_float) },
                else => return InterpreterError.TypeMismatch,
            },
            else => return InterpreterError.TypeMismatch,
        }
    }

    fn stringConcat(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !Value {
        const result = try allocator.alloc(u8, a.len + b.len);
        @memcpy(result[0..a.len], a);
        @memcpy(result[a.len..], b);
        return Value{ .str = result };
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
    }

    return buffer.toOwnedSlice();
}
