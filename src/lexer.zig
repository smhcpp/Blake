const std = @import("std");
// const mvzr = @import("mvzr");
const Allocator = std.mem.Allocator;
const print = std.debug.print;

pub const TokenType = enum {
    // Space, // ' '
    Eol, // '\n'
    ParO, // (
    ParC, // )
    CurO, // {
    CurC, // }
    BraO, // [
    BraC, // ]
    Comma, // ,
    Dot, // .
    Minus, // -
    Plus, // +
    Slash, // /
    Percent, // %
    Tild, //~
    Caret, //^
    Star, // *
    SColon, // ;
    Colon, // :
    BSlash, // Backslash: \
    Sharp, // #
    Uline, // _
    Excl, // !
    E, // =
    // Two-character (or more) tokens:
    SlashStar, // /*
    StarSlash, // */
    NE, // !=
    EE, // ==
    Gr, // >
    GrE, // >=
    Le, // <
    LeE, // <=
    // datatypes
    Quo, // '
    DQuo, // "
    I32, // integers
    F32, //floating number
    F, // false
    T, // true
    // Keywords:
    Id,
    And,
    Or,
    If,
    Else,
    Struct,
    For,
    While,
    Null,
    Print,
    Return,
    This,
    Var,
    Fn,
    Eof,
};

pub const Keyword = struct {
    type: TokenType,
    lexeme: []const u8,
};

pub const keywords: []const Keyword = &[_]Keyword{
    Keyword{ .type = .And, .lexeme = "and" },
    Keyword{ .type = .Or, .lexeme = "or" },
    Keyword{ .type = .If, .lexeme = "if" },
    Keyword{ .type = .Else, .lexeme = "else" },
    Keyword{ .type = .Struct, .lexeme = "struct" },
    Keyword{ .type = .For, .lexeme = "for" },
    Keyword{ .type = .While, .lexeme = "while" },
    Keyword{ .type = .Null, .lexeme = "null" },
    // Keyword{ .type = .Print, .lexeme = "print" },
    Keyword{ .type = .Return, .lexeme = "return" },
    Keyword{ .type = .This, .lexeme = "this" },
    Keyword{ .type = .Var, .lexeme = "var" },
    Keyword{ .type = .Fn, .lexeme = "fn" },
};

pub const Token = struct {
    ///line number of the line where our token lies in
    ln: u16,
    /// position of the token starting placing in the line
    pil: u16,
    lexeme: []const u8,
    type: TokenType,
    ///length of the token
    len: u16,

    pub fn init(allocator: Allocator, linenumber: u16, tokentype: TokenType, posinline: u16, tokenlength: u16, lexeme: []const u8) !*Token {
        const token = try allocator.create(Token);
        token.* = Token{
            .ln = linenumber,
            .type = tokentype,
            .pil = posinline,
            .len = tokenlength,
            .lexeme = switch (tokentype) {
                .Id, .Quo, .DQuo, .I32, .F32 => lexeme,
                else => "",
            },
        };
        return token;
    }

    pub fn str(token: *Token, scanner: *Scanner) []const u8 {
        switch (token.type) {
            .Id, .I32, .F32, .Quo, .DQuo => return token.lexeme,
            .Eol => return "Eol",
            .Eof => return "Eof",
            else => {
                return scanner.lines.items[token.ln][token.pil .. token.len + token.pil];
            },
        }
    }
};

pub const Scanner = struct {
    /// which line we are looking at
    ln: u16,
    /// where is the cursor position in line
    pil: u16,
    /// list of all lines
    lines: std.ArrayList([]const u8) = undefined,
    ///list of all tokens
    tokens: std.ArrayList(*Token),
    allocator: Allocator,

    fn panic(scanner: *Scanner, msg: []const u8) void {
        // for now we exit but in blake it should only return error
        scanner.panicAt(msg, scanner.ln, scanner.pil);
    }

    pub fn panicAt(scanner: *Scanner, msg: []const u8, linenumber: u16, pil: u16) void {
        const line = scanner.lines.items[linenumber];
        const tabcount = std.mem.count(u8, line, "\t");
        print("Error: {s},\n{:6} | {s}\n", .{ msg, linenumber, line });
        var i: u16 = 0;
        while (i < tabcount) : (i += 1) {
            print("\t", .{});
        }
        // 3 for ` | `, 6 for :6
        print("         ", .{});
        i = 0;
        while (i < pil - tabcount) : (i += 1) {
            print(" ", .{});
        }
        print("^\n", .{});
        std.process.exit(0);
    }

    pub fn init(allocator: Allocator, buffer: []const u8) !*Scanner {
        const scanner = try allocator.create(Scanner);
        scanner.* = Scanner{
            .ln = 0,
            .pil = 0,
            .lines = std.ArrayList([]const u8).init(allocator),
            .tokens = std.ArrayList(*Token).init(allocator),
            .allocator = allocator,
        };

        var lines = std.mem.splitScalar(u8, buffer, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) try scanner.lines.append(line);
        }
        return scanner;
    }

    pub fn printTokens(scanner: *Scanner) void {
        for (scanner.tokens.items) |tok| {
            print("token: {s:<20}    type: {}\n", .{ tok.str(scanner), tok.type });
        }
    }

    pub fn tokenise(scanner: *Scanner) !void {
        if (scanner.lines.items.len == 0) return;
        scanner.ln = 0;

        while (scanner.lines.items.len > scanner.ln) : (scanner.ln += 1) {
            scanner.pil = 0;
            while (scanner.pil < scanner.lines.items[scanner.ln].len) : (scanner.pil += 1) {
                const c = scanner.lines.items[scanner.ln][scanner.pil];
                switch (c) {
                    '0'...'9' => {
                        try scanner.addTokenNumber();
                    },
                    'a'...'z', 'A'...'Z', '_' => {
                        try scanner.addTokenId();
                    },
                    '>' => {
                        try scanner.addTokenComparison(TokenType.Gr, TokenType.GrE);
                    },
                    '<' => {
                        try scanner.addTokenComparison(TokenType.Le, TokenType.LeE);
                    },
                    '=' => {
                        try scanner.addTokenComparison(TokenType.E, TokenType.EE);
                    },
                    '!' => {
                        try scanner.addTokenComparison(TokenType.Excl, TokenType.NE);
                    },
                    '{' => {
                        try scanner.addTokenByType(TokenType.CurO, 1);
                    },
                    '}' => {
                        try scanner.addTokenByType(TokenType.CurC, 1);
                    },
                    '(' => {
                        try scanner.addTokenByType(TokenType.ParO, 1);
                    },
                    ')' => {
                        try scanner.addTokenByType(TokenType.ParC, 1);
                    },
                    '[' => {
                        try scanner.addTokenByType(TokenType.BraO, 1);
                    },
                    ']' => {
                        try scanner.addTokenByType(TokenType.BraC, 1);
                    },
                    '\'' => {
                        try scanner.addTokenString(TokenType.Quo);
                    },
                    '"' => {
                        try scanner.addTokenString(TokenType.DQuo);
                    },
                    '*' => {
                        try scanner.addTokenByType(TokenType.Star, 1);
                    },
                    '^' => {
                        try scanner.addTokenByType(TokenType.Caret, 1);
                    },
                    '~' => {
                        try scanner.addTokenByType(TokenType.Tild, 1);
                    },
                    '%' => {
                        try scanner.addTokenByType(TokenType.Percent, 1);
                    },
                    '/' => {
                        try scanner.addTokenSlash(TokenType.Slash);
                    },
                    '+' => {
                        try scanner.addTokenByType(TokenType.Plus, 1);
                    },
                    '#' => {
                        break;
                    },
                    '-' => {
                        try scanner.addTokenByType(TokenType.Minus, 1);
                    },
                    '\\' => {
                        scanner.panic("\\ can only be used inside string literals");
                    },
                    ',' => {
                        try scanner.addTokenByType(TokenType.Comma, 1);
                    },
                    '.' => {
                        try scanner.addTokenDot();
                    },
                    ';' => {
                        try scanner.addTokenByType(TokenType.SColon, 1);
                    },
                    ':' => {
                        try scanner.addTokenByType(TokenType.Colon, 1);
                    },
                    ' ', '\t', '\r' => {
                        // const last = scanner.tokens.items.len;
                        // if (last == 0 or scanner.tokens.items[last - 1].type != TokenType.Space)
                        // try scanner.addTokenByType(TokenType.Space, 1);
                    },
                    else => {
                        scanner.panic("Use of uncategorized character");
                    },
                }
            }

            const last = scanner.tokens.items.len;
            if (last == 0 or scanner.tokens.items[last - 1].type != TokenType.Eol)
                try scanner.addTokenByType(TokenType.Eol, 1);
        }
        try scanner.addTokenByType(TokenType.Eof, 1);
    }

    fn addTokenNumber(scanner: *Scanner) !void {
        const ipos = scanner.pil;
        var isfloat: bool = false;
        scanner.pil += 1;
        while (scanner.pil < scanner.lines.items[scanner.ln].len) : (scanner.pil += 1) {
            const c = scanner.lines.items[scanner.ln][scanner.pil];
            switch (c) {
                '0'...'9' => {},
                '.' => {
                    if (isfloat) {
                        scanner.panicAt("Multiple `.` for a flating number", scanner.ln, ipos);
                    }
                    isfloat = true;
                },
                else => {
                    break;
                },
            }
        }
        //should we check for the size of the number?
        const lexeme = scanner.lines.items[scanner.ln][ipos..scanner.pil];
        if (isfloat) {
            try scanner.addTokenAt(TokenType.F32, scanner.ln, ipos, scanner.pil - ipos, lexeme);
        } else {
            try scanner.addTokenAt(TokenType.I32, scanner.ln, ipos, scanner.pil - ipos, lexeme);
        }
        scanner.pil -= 1;
    }

    fn addTokenId(scanner: *Scanner) !void {
        const ipos = scanner.pil;
        scanner.pil += 1;
        while (scanner.pil < scanner.lines.items[scanner.ln].len) : (scanner.pil += 1) {
            const c = scanner.lines.items[scanner.ln][scanner.pil];
            switch (c) {
                '_', 'a'...'z', 'A'...'Z', '0'...'9' => {},
                else => {
                    break;
                },
            }
        }
        const lexeme = scanner.lines.items[scanner.ln][ipos..scanner.pil];
        var found: bool = false;
        for (keywords) |k| {
            if (std.mem.eql(u8, k.lexeme, lexeme)) {
                found = true;
                try scanner.addTokenAt(k.type, scanner.ln, ipos, scanner.pil - ipos, "");
                break;
            }
        }
        if (!found) {
            if (lexeme.len < 20) {
                try scanner.addTokenAt(TokenType.Id, scanner.ln, ipos, scanner.pil - ipos, lexeme);
            } else {
                scanner.panicAt("Identifier has a problem (make sure to put at most 20 alphanumerical characters)", scanner.ln, ipos);
            }
        }
        scanner.pil -= 1;
    }

    fn addTokenDot(scanner: *Scanner) !void {
        const ipos = scanner.pil;
        scanner.pil += 1;
        while (scanner.pil < scanner.lines.items[scanner.ln].len) : (scanner.pil += 1) {
            const cp = scanner.lines.items[scanner.ln][scanner.pil];
            switch (cp) {
                '0'...'9' => {},
                else => {
                    break;
                },
            }
        }
        const len = scanner.pil - ipos;
        if (len > 1) {
            const lexeme = scanner.lines.items[scanner.ln][ipos..scanner.pil];
            try scanner.addTokenAt(TokenType.F32, scanner.ln, ipos, len, lexeme);
        } else {
            try scanner.addTokenByType(TokenType.Dot, 1);
        }
        scanner.pil -= 1;
    }

    /// It adds the comparison token
    fn addTokenComparison(scanner: *Scanner, basetype: TokenType, combinationtype: TokenType) !void {
        if (scanner.lines.items[scanner.ln].len - 1 > scanner.pil) {
            if (scanner.lines.items[scanner.ln][scanner.pil + 1] == '=') {
                try scanner.addTokenByType(combinationtype, 2);
                scanner.pil += 1;
            } else {
                try scanner.addTokenByType(basetype, 1);
            }
        } else {
            scanner.panic("The operator at the end of the line has no follow up.");
        }
    }

    /// adds the string token.
    fn addTokenString(scanner: *Scanner, ttype: TokenType) !void {
        const c = scanner.lines.items[scanner.ln][scanner.pil];
        var str = std.ArrayList(u8).init(scanner.allocator);
        defer str.deinit();
        try str.append(c);
        var len: u16 = 1;
        const i = scanner.ln;
        const j = scanner.pil;
        scanner.pil += 1;
        var instring: bool = true;
        var bsflag: bool = false;
        while (instring) : (scanner.pil += 1) {
            if (scanner.pil >= scanner.lines.items[scanner.ln].len) {
                scanner.ln += 1;
                scanner.pil = 0;
            }
            if (scanner.isEnd()) break;
            len += 1;
            const cp = scanner.lines.items[scanner.ln][scanner.pil];
            try str.append(cp);
            if (cp == c and !bsflag) {
                instring = false;
                const lexeme = try str.toOwnedSlice();
                try scanner.addTokenAt(ttype, i, j, len, lexeme);
            }

            if (cp == '\\') {
                bsflag = !bsflag;
            } else {
                bsflag = false;
            }
        }
        if (scanner.pil != 0) scanner.pil -= 1;
        if (instring) {
            scanner.panicAt("The string has no end.", i, j);
        }
    }

    fn addTokenSlash(scanner: *Scanner, ttype: TokenType) !void {
        const i = scanner.ln;
        const j = scanner.pil;
        // print("{s}", .{scanner.lines.items[scanner.ln][scanner.pil .. scanner.pil + 1]});
        var incomment: bool = false;
        var bsflag: bool = false;
        if (scanner.pil + 1 < scanner.lines.items[scanner.ln].len) {
            const cp = scanner.lines.items[scanner.ln][scanner.pil + 1];
            if (cp == '*') {
                incomment = true;
                scanner.pil += 2;
            } else {
                try scanner.addTokenByType(ttype, 1);
            }
        } else {
            scanner.panic("`/` at the end of the line has now follow up.");
        }
        while (incomment) : (scanner.pil += 1) {
            if (scanner.pil + 1 >= scanner.lines.items[scanner.ln].len) {
                scanner.ln += 1;
                scanner.pil = 0;
            }
            if (scanner.isEnd()) break;
            if (scanner.lines.items[scanner.ln].len == 1) continue;
            const c1 = scanner.lines.items[scanner.ln][scanner.pil];
            const c2 = scanner.lines.items[scanner.ln][scanner.pil + 1];
            if (c1 == '*' and c2 == '/' and !bsflag) {
                incomment = false;
                scanner.pil += 1;
            }
            if (c1 == '\\') {
                bsflag = !bsflag;
            } else {
                bsflag = false;
            }
        }
        if (scanner.pil != 0) scanner.pil -= 1;
        if (incomment) {
            scanner.panicAt("The comment starting by `/*` has no end.", i, j);
        }
    }

    fn isEnd(scanner: *Scanner) bool {
        return scanner.ln >= scanner.lines.items.len or
            (scanner.ln == scanner.lines.items.len - 1 and
                scanner.pil >= scanner.lines.items[scanner.lines.items.len - 1].len);
    }

    fn addTokenByType(scanner: *Scanner, ttype: TokenType, len: u16) !void {
        const tok = try Token.init(scanner.allocator, scanner.ln, ttype, scanner.pil, len, "");
        try scanner.tokens.append(tok);
    }

    fn addTokenAt(scanner: *Scanner, ttype: TokenType, linenumber: u16, pil: u16, len: u16, lexeme: []const u8) !void {
        const tok = try Token.init(scanner.allocator, linenumber, ttype, pil, len, lexeme);
        try scanner.tokens.append(tok);
    }

    pub fn deinit(scanner: *Scanner) void {
        for (scanner.tokens.items) |item| {
            scanner.allocator.destroy(item);
        }
        scanner.tokens.deinit();
        scanner.lines.deinit();
    }
};
