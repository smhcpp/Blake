const lexer = @import("lexer.zig");
const BlakeParserError = @import("lexer.zig").BlakeParserError;
const Allocator = std.mem.Allocator;
const print = std.debug.print;
const std = @import("std");

pub const ArrayType = enum { i32, f32, bln, str };
///To do:
///array insert, insertat(ind,item,dimension: for which dimension), remove, removeat, shape,length,
///access: arr[3] with indices starting from 0
///array scalar operations: */+-%, array to array operations. use + as concatenation with strings, bools
///have no operation. and for int and float use vectors(of course when evaluating)!
///
///functions
///
///if else, else if
///
///while
///
///import
///
///options: blk.o.workspace_num
///functions: blk.f.layout(), blk.f.open(), blk.f.keymap, blk.f.pass,...
///file io: blk.io.open... (only if needed)
///terminal: blk.t.run() run some command.
pub const AstNode = union(enum) {
    i32: struct { val: i32, ln: u16, pil: u16 },
    f32: struct { val: f32, ln: u16, pil: u16 },
    str: struct { val: []const u8, ln: u16, pil: u16 },
    bln: struct { val: bool, ln: u16, pil: u16 },
    v: struct { val: void, ln: u16, pil: u16 },
    arr: struct {
        ln: u16,
        pil: u16,
        el: std.ArrayList(*AstNode),
        type: ArrayType,
    },
    vref: struct { name: []const u8, ln: u16, pil: u16 },
    call: struct { name: []const u8, ln: u16, pil: u16, args: std.ArrayList(*AstNode) },
    // fun: struct { params: std.ArrayList([]const u8), body: std.ArrayList(AstNode) },
    // If: struct { cond: *AstNode, body: std.ArrayList(AstNode), el: ?std.ArrayList(AstNode) },
    // While: struct { cond: *AstNode, body: std.ArrayList(AstNode) },
    assign: struct { name: []const u8, ln: u16, pil: u16, value: *AstNode },
    bin: struct { op: lexer.TokenType, ln: u16, pil: u16, lhs: *AstNode, rhs: *AstNode },
};

pub const Parser = struct {
    scanner: *lexer.Scanner,
    statements: std.ArrayList(*AstNode),
    tn: u32,

    pub fn init(allocator: std.mem.Allocator, buffer: []const u8) !*Parser {
        const parser = try allocator.create(Parser);
        parser.* = Parser{
            .tn = 0,
            .scanner = try lexer.Scanner.init(allocator, buffer),
            .statements = std.ArrayList(*AstNode).init(allocator),
            // .symbols = std.StringHashMap(usize).init(allocator),
        };
        return parser;
    }

    pub fn deinit(parser: *Parser) void {
        parser.scanner.deinit();
        parser.statements.deinit();
        // parser.symbols.deinit();
    }

    pub fn printTree(parser: *Parser) void {
        for (parser.statements.items) |item| {
            print("stmt: {any}\n", .{item.*});
        }
    }

    fn advance(parser: *Parser) void {
        if (parser.tn + 1 < parser.scanner.tokens.items.len) {
            parser.tn += 1;
        }
    }

    fn expect(parser: *Parser, expected: lexer.TokenType) !void {
        const token = parser.scanner.tokens.items[parser.tn];
        if (token.type != expected) {
            try parser.scanner.panicAt(
                try std.fmt.allocPrint(parser.scanner.allocator, "Expected {s}, found {s}", .{ @tagName(expected), @tagName(token.type) }),
                token.ln,
                token.pil,
            );
        }
        parser.advance();
    }

    fn match(parser: *Parser, expected: lexer.TokenType) bool {
        const token = parser.scanner.tokens.items[parser.tn];
        if (token.type == expected) {
            parser.advance();
            return true;
        }
        return false;
    }

    pub fn parse(parser: *Parser) !void {
        const scanner = parser.scanner;
        try scanner.tokenise();
        // scanner.printTokens();
        while (parser.tn < scanner.tokens.items.len and scanner.tokens.items[parser.tn].type != .Eof) {
            const stmt = try parser.parseStatement();
            try parser.statements.append(stmt);
        }
    }

    fn parseStatement(parser: *Parser) anyerror!*AstNode {
        switch (parser.scanner.tokens.items[parser.tn].type) {
            .I32 => return try parser.parseI32(),
            .F32 => return try parser.parseF32(),
            .DQuo, .Quo => return try parser.parseStr(),
            .T, .F => return try parser.parseBln(),
            // .Fn => try parser.parseFn(),
            // .If => try parser.parseIf(),
            // .While => try parser.parseWhile(),
            // else => try parser.parseExpr(),
            else => return try parser.parseId(),
        }
    }

    fn parseId(parser: *Parser) !*AstNode {
        const token = parser.scanner.tokens.items[parser.tn];
        try parser.expect(.Id);
        if (parser.match(.E)) {
            const node = try parser.scanner.allocator.create(AstNode);
            const value = try parser.parseExpr();
            try parser.expect(.Eol);
            node.* = AstNode{ .assign = .{
                .value = value,
                .ln = token.ln,
                .pil = token.pil,
                .name = token.lexeme,
            } };
            return node;
        }

        if (parser.match(.ParO)) {
            var args = std.ArrayList(*AstNode).init(parser.scanner.allocator);
            while (parser.scanner.tokens.items[parser.tn].type != .ParC) {
                const arg = try parser.parseExpr();
                try args.append(arg);
                if (!parser.match(.Comma)) break;
            }

            try parser.expect(.ParC);
            try parser.expect(.Eol); // Expect end of line after call

            const node = try parser.scanner.allocator.create(AstNode);
            node.* = .{ .call = .{ .name = token.lexeme, .args = args, .ln = token.ln, .pil = token.pil } };
            return node;
        }

        const ref_node = try parser.scanner.allocator.create(AstNode);
        ref_node.* = .{ .vref = .{ .name = token.lexeme, .ln = token.ln, .pil = token.pil } };
        return ref_node;
    }

    fn parseI32(parser: *Parser) !*AstNode {
        const node = try parser.scanner.allocator.create(AstNode);
        const token = parser.scanner.tokens.items[parser.tn];
        const value = try std.fmt.parseInt(i32, token.lexeme, 10);
        parser.advance();
        node.* = AstNode{ .i32 = .{ .val = value, .ln = token.ln, .pil = token.pil } };
        return node;
    }

    fn parseF32(parser: *Parser) !*AstNode {
        const node = try parser.scanner.allocator.create(AstNode);
        const token = parser.scanner.tokens.items[parser.tn];
        const value = try std.fmt.parseFloat(f32, token.lexeme);
        parser.advance();
        node.* = AstNode{ .f32 = .{ .val = value, .ln = token.ln, .pil = token.pil } };
        return node;
    }

    fn parseBln(parser: *Parser) !*AstNode {
        const node = try parser.scanner.allocator.create(AstNode);
        const token = parser.scanner.tokens.items[parser.tn];
        parser.advance();
        node.* = AstNode{ .bln = .{ .ln = token.ln, .pil = token.pil, .val = if (token.type == .T) true else false } };
        return node;
    }

    fn parseStr(parser: *Parser) !*AstNode {
        const node = try parser.scanner.allocator.create(AstNode);
        const token = parser.scanner.tokens.items[parser.tn];
        parser.advance();
        node.* = AstNode{ .str = .{ .ln = token.ln, .pil = token.pil, .val = token.lexeme[1 .. token.lexeme.len - 1] } };
        return node;
    }

    fn parseExpr(parser: *Parser) !*AstNode {
        return try parser.parseAddSub();
    }

    fn parseAddSub(parser: *Parser) !*AstNode {
        var left = try parser.parseMulDiv();
        while (true) {
            const op = parser.scanner.tokens.items[parser.tn];
            if (op.type == .Plus or op.type == .Minus) {
                parser.advance();
                const right = try parser.parseMulDiv();
                const node = try parser.scanner.allocator.create(AstNode);
                node.* = .{ .bin = .{ .ln = op.ln, .pil = op.pil, .op = op.type, .lhs = left, .rhs = right } };
                left = node;
            } else {
                break;
            }
        }
        return left;
    }

    fn parseMulDiv(parser: *Parser) !*AstNode {
        var left = try parser.parseExponent();
        while (true) {
            const op = parser.scanner.tokens.items[parser.tn];
            if (op.type == .Star or op.type == .Slash or op.type == .Percent) {
                parser.advance();
                const right = try parser.parseExponent();
                const node = try parser.scanner.allocator.create(AstNode);
                node.* = .{ .bin = .{ .ln = op.ln, .pil = op.pil, .op = op.type, .lhs = left, .rhs = right } };
                left = node;
            } else {
                break;
            }
        }
        return left;
    }

    fn parseExponent(parser: *Parser) !*AstNode {
        var left = try parser.parseTerminal();
        const tok = parser.scanner.tokens.items[parser.tn];
        if (parser.match(.Caret)) {
            const right = try parser.parseExponent();
            const node = try parser.scanner.allocator.create(AstNode);
            node.* = .{ .bin = .{ .ln = tok.ln, .pil = tok.pil, .op = .Caret, .lhs = left, .rhs = right } };
            left = node;
        }
        return left;
    }

    fn parseArray(parser: *Parser) !*AstNode {
        const tok = parser.scanner.tokens.items[parser.tn];
        try parser.expect(.BraO);
        var elements = std.ArrayList(*AstNode).init(parser.scanner.allocator);

        if (parser.scanner.tokens.items[parser.tn].type == .BraC) {
            // Empty array
            try parser.expect(.BraC);
            const node = try parser.scanner.allocator.create(AstNode);
            node.* = .{
                .arr = .{
                    .ln = tok.ln,
                    .pil = tok.pil,
                    .el = elements,
                    .type = .i32, // Default type for empty arrays
                },
            };
            return node;
        }
        // Parse first element to determine type
        _ = parser.match(.Eol);
        const first_element = try parser.parseExpr();
        try elements.append(first_element);
        const array_type = try getElementType(first_element.*);
        _ = parser.match(.Eol);

        // Parse remaining elements
        while (parser.match(.Comma)) {
            _ = parser.match(.Eol);
            if (parser.scanner.tokens.items[parser.tn].type == .BraC) break;

            const elem = try parser.parseExpr();
            const elem_type = try getElementType(elem.*);

            if (elem_type != array_type) {
                const m = parser.scanner.tokens.items[parser.tn];
                try parser.scanner.panicAt("All array elements must be of the same type", m.ln, m.pil);
                return BlakeParserError.Msg;
            }

            _ = parser.match(.Eol);
            try elements.append(elem);
        }

        try parser.expect(.BraC);

        const node = try parser.scanner.allocator.create(AstNode);
        node.* = .{ .arr = .{
            .el = elements,
            .ln = tok.ln,
            .pil = tok.pil,
            .type = array_type,
        } };
        return node;
    }

    fn parseTerminal(parser: *Parser) anyerror!*AstNode {
        const tok = parser.scanner.tokens.items[parser.tn];
        switch (tok.type) {
            .I32 => return try parser.parseI32(),
            .F32 => return try parser.parseF32(),
            .Quo, .DQuo => return try parser.parseStr(),
            .F, .T => return try parser.parseBln(),
            .Id => return try parser.parseId(),
            .BraO => return try parser.parseArray(),
            .ParO => {
                parser.advance();
                const expr = try parser.parseExpr();
                try parser.expect(.ParC);
                return expr;
            },
            // .Eol => {},
            else => {
                try parser.scanner.panicAt("Unrecognized value type", tok.ln, tok.pil);
                return BlakeParserError.Msg;
            },
        }
    }
};

pub fn getElementType(node: AstNode) !ArrayType {
    return switch (node) {
        .i32 => .i32,
        .f32 => .f32,
        .str => .str,
        .bln => .bln,
        .arr => |ar| ar.type,
        else => {
            return BlakeParserError.Msg;
        },
    };
}
