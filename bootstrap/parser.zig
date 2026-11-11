const std: type = @import("std");
const ast: type = @import("ast.zig");
const diagnostic: type = @import("diagnostic.zig");
const Token: type = @import("lexer.zig").Token;

const Error: type = diagnostic.Error;

pub fn parse(allocator: std.mem.Allocator, tokens: []const Token, report: *diagnostic.Diagnostic) Error!ast.Block {
    var parser: Parser = .{ .allocator = allocator, .tokens = tokens, .report = report };
    const body: ast.Block = try parser.block();
    if (parser.token().kind != .eof) return parser.fail("unexpected block terminator");
    return body;
}

const Parser: type = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    index: usize = 0,
    report: *diagnostic.Diagnostic,

    fn token(self: *const Parser) Token {
        return self.tokens[self.index];
    }

    fn peek(self: *const Parser) Token {
        return self.tokens[@min(self.index + 1, self.tokens.len - 1)];
    }

    fn advance(self: *Parser) void {
        if (self.token().kind != .eof) self.index += 1;
    }

    fn fail(self: *Parser, message: []const u8) Error {
        return diagnostic.fail(self.report, self.token().offset, message);
    }

    fn create(self: *Parser, comptime T: type, value: T) Error!*const T {
        const pointer: *T = try self.allocator.create(T);
        pointer.* = value;
        return pointer;
    }

    fn is(self: *const Parser, text: []const u8) bool {
        const current: Token = self.token();
        return (current.kind == .name or current.kind == .symbol) and std.mem.eql(u8, current.text, text);
    }

    fn expect(self: *Parser, text: []const u8) Error!void {
        if (!self.is(text)) return self.fail(try std.fmt.allocPrint(self.allocator, "expected '{s}'", .{text}));
        self.advance();
    }

    fn take(self: *Parser, text: []const u8) bool {
        if (!self.is(text)) return false;
        self.advance();
        return true;
    }

    fn identifier(self: *Parser) Error![]const u8 {
        if (self.token().kind != .name) return self.fail("expected identifier");
        for ([_][]const u8{ "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while" }) |keyword| {
            if (self.is(keyword)) return self.fail("expected identifier, found keyword");
        }
        const name: []const u8 = self.token().text;
        self.advance();
        return name;
    }

    fn typeAtom(self: *Parser) Error!ast.Type {
        const offset: usize = self.token().offset;
        if (self.take("{")) {
            if (self.take("}")) return .{ .offset = offset, .data = .{ .table = .{ .fields = &.{}, .indexer = null } } };
            if (!self.is("[") and !((self.token().kind == .name or self.token().kind == .string) and std.mem.eql(u8, self.peek().text, ":"))) {
                const element: ast.Type = try self.typeName();
                try self.expect("}");
                return .{ .offset = offset, .data = .{ .array = try self.create(ast.Type, element) } };
            }
            var fields: std.ArrayList(ast.TypeField) = std.ArrayList(ast.TypeField).init(self.allocator);
            var indexer: ?*const ast.TypeIndexer = null;
            while (!self.is("}")) {
                if (self.take("[")) {
                    const key: ast.Type = try self.typeName();
                    try self.expect("]");
                    try self.expect(":");
                    if (indexer != null) return self.fail("duplicate table indexer");
                    indexer = try self.create(ast.TypeIndexer, .{ .key = key, .value = try self.typeName() });
                } else {
                    const name: []const u8 = if (self.token().kind == .string) blk: {
                        const text: []const u8 = self.token().text;
                        self.advance();
                        break :blk text;
                    } else try self.identifier();
                    try self.expect(":");
                    const value: ast.Type = try self.typeName();
                    for (fields.items) |field| {
                        if (std.mem.eql(u8, field.name, name)) return self.fail("duplicate record field");
                    }
                    try fields.append(.{ .name = name, .value = value });
                }
                if (!self.take(",") and !self.take(";")) break;
            }
            try self.expect("}");
            return .{ .offset = offset, .data = .{ .table = .{ .fields = try fields.toOwnedSlice(), .indexer = indexer } } };
        }
        if (self.take("nil")) return .{ .offset = offset, .data = .nil };
        if (self.is("true") or self.is("false")) {
            const value: bool = self.is("true");
            self.advance();
            return .{ .offset = offset, .data = .{ .boolean_literal = value } };
        }
        if (self.take("(")) {
            var parameters: std.ArrayList(ast.Type) = std.ArrayList(ast.Type).init(self.allocator);
            while (!self.is(")")) {
                if (self.token().kind == .name and std.mem.eql(u8, self.peek().text, ":")) {
                    _ = try self.identifier();
                    try self.expect(":");
                }
                try parameters.append(try self.typeName());
                if (!self.take(",")) break;
                if (self.is(")")) return self.fail("expected type after ','");
            }
            try self.expect(")");
            if (self.take("->")) return .{ .offset = offset, .data = .{ .function = .{ .parameters = try parameters.toOwnedSlice(), .result = try self.create(ast.Type, try self.typeName()) } } };
            if (parameters.items.len == 0) return .{ .offset = offset, .data = .void };
            if (parameters.items.len == 1) return parameters.items[0];
            return self.fail("multiple return types are not supported yet");
        }
        if (self.token().kind == .string) {
            const text: []const u8 = self.token().text;
            self.advance();
            return .{ .offset = offset, .data = .{ .string_literal = text } };
        }
        return .{ .offset = offset, .data = .{ .name = try self.identifier() } };
    }

    fn optionalType(self: *Parser) Error!ast.Type {
        const inner: ast.Type = try self.typeAtom();
        if (!self.take("?")) return inner;
        return .{ .offset = inner.offset, .data = .{ .optional = try self.create(ast.Type, inner) } };
    }

    fn typeName(self: *Parser) Error!ast.Type {
        var result: ast.Type = try self.optionalType();
        while (self.take("|")) {
            const right: ast.Type = try self.optionalType();
            const left: *const ast.Type = try self.create(ast.Type, result);
            result = .{ .offset = left.offset, .data = .{ .union_type = .{ .left = left, .right = try self.create(ast.Type, right) } } };
        }
        return result;
    }

    fn precedence(operator: []const u8) u8 {
        const operators: []const []const u8 = &.{ "or", "and", "==", "~=", "<", "<=", ">", ">=", "..", "+", "-", "*", "/", "//", "%", "^" };
        const levels: []const u8 = &.{ 1, 2, 3, 3, 3, 3, 3, 3, 4, 5, 5, 6, 6, 6, 6, 8 };
        for (operators, levels) |op, level| {
            if (std.mem.eql(u8, operator, op)) return level;
        }
        return 0;
    }

    fn expression(self: *Parser) Error!ast.Expression {
        return self.subexpression(0);
    }

    fn subexpression(self: *Parser, minimum: u8) Error!ast.Expression {
        var left: ast.Expression = undefined;
        if (self.is("-") or self.is("not") or self.is("#")) {
            const offset: usize = self.token().offset;
            const operator: ast.Unary = if (self.is("-")) .negate else if (self.is("not")) .not else .length;
            self.advance();
            left = .{ .offset = offset, .data = .{ .unary = .{ .operator = operator, .operand = try self.create(ast.Expression, try self.subexpression(7)) } } };
        } else left = try self.primary();
        while (self.token().kind == .name or self.token().kind == .symbol) {
            const operator: []const u8 = self.token().text;
            const offset: usize = self.token().offset;
            const level: u8 = precedence(operator);
            if (level == 0 or level < minimum) break;
            self.advance();
            const right: ast.Expression = try self.subexpression(if (std.mem.eql(u8, operator, "^") or std.mem.eql(u8, operator, "..")) level else level + 1);
            const operand: *const ast.Expression = try self.create(ast.Expression, left);
            left = .{ .offset = offset, .data = .{ .binary = .{ .operator = operator, .left = operand, .right = try self.create(ast.Expression, right) } } };
        }
        return left;
    }

    fn ifExpression(self: *Parser, offset: usize) Error!ast.Expression {
        const condition: ast.Expression = try self.expression();
        try self.expect("then");
        const then: ast.Expression = try self.expression();
        const otherwise_offset: usize = self.token().offset;
        const otherwise: ast.Expression = if (self.take("elseif")) try self.ifExpression(otherwise_offset) else blk: {
            try self.expect("else");
            break :blk try self.expression();
        };
        return .{ .offset = offset, .data = .{ .if_expression = .{ .condition = try self.create(ast.Expression, condition), .then = try self.create(ast.Expression, then), .otherwise = try self.create(ast.Expression, otherwise) } } };
    }

    fn arguments(self: *Parser) Error![]const ast.Expression {
        try self.expect("(");
        var values: std.ArrayList(ast.Expression) = std.ArrayList(ast.Expression).init(self.allocator);
        while (!self.is(")")) {
            try values.append(try self.expression());
            if (!self.take(",")) break;
            if (self.is(")")) return self.fail("expected expression after ','");
        }
        try self.expect(")");
        return values.toOwnedSlice();
    }

    fn primary(self: *Parser) Error!ast.Expression {
        var value: ast.Expression = try self.atom();
        while (self.is("(") or self.is("[") or self.is(".") or self.is(":") or self.is("::")) {
            const offset: usize = self.token().offset;
            const inner: *const ast.Expression = try self.create(ast.Expression, value);
            if (self.is("(")) {
                value = .{ .offset = offset, .data = .{ .call = .{ .callee = inner, .arguments = try self.arguments() } } };
            } else if (self.take(":")) {
                const name: []const u8 = try self.identifier();
                value = .{ .offset = offset, .data = .{ .method = .{ .object = inner, .name = name, .arguments = try self.arguments() } } };
            } else if (self.take("[")) {
                const key: ast.Expression = try self.expression();
                try self.expect("]");
                value = .{ .offset = offset, .data = .{ .index = .{ .table = inner, .key = try self.create(ast.Expression, key) } } };
            } else if (self.take(".")) {
                value = .{ .offset = offset, .data = .{ .field = .{ .table = inner, .name = try self.identifier() } } };
            } else {
                self.advance();
                value = .{ .offset = offset, .data = .{ .assertion = .{ .value = inner, .annotation = try self.typeName() } } };
            }
        }
        return value;
    }

    fn tableConstructor(self: *Parser) Error![]const ast.TableEntry {
        var entries: std.ArrayList(ast.TableEntry) = std.ArrayList(ast.TableEntry).init(self.allocator);
        while (!self.is("}")) {
            if (self.token().kind == .name and std.mem.eql(u8, self.peek().text, "=")) {
                const name: []const u8 = try self.identifier();
                try self.expect("=");
                try entries.append(.{ .named = .{ .name = name, .value = try self.expression() } });
            } else if (self.take("[")) {
                const key: ast.Expression = try self.expression();
                try self.expect("]");
                try self.expect("=");
                try entries.append(.{ .keyed = .{ .key = key, .value = try self.expression() } });
            } else try entries.append(.{ .positional = try self.expression() });
            if (!self.take(",") and !self.take(";")) break;
        }
        try self.expect("}");
        return entries.toOwnedSlice();
    }

    fn atom(self: *Parser) Error!ast.Expression {
        const current: Token = self.token();
        const offset: usize = current.offset;
        if (self.take("if")) return self.ifExpression(offset);
        if (self.take("function")) return .{ .offset = offset, .data = .{ .function = try self.function() } };
        if (self.take("{")) return .{ .offset = offset, .data = .{ .table = try self.tableConstructor() } };
        if (self.take("(")) {
            const value: ast.Expression = try self.expression();
            try self.expect(")");
            return .{ .offset = offset, .data = .{ .group = try self.create(ast.Expression, value) } };
        }
        if (current.kind == .string) {
            self.advance();
            return .{ .offset = offset, .data = .{ .string = current.text } };
        }
        if (current.kind == .number) {
            var number: f64 = undefined;
            if (std.mem.startsWith(u8, current.text, "0b") or std.mem.startsWith(u8, current.text, "0B")) {
                const integer: u64 = std.fmt.parseInt(u64, current.text[2..], 2) catch return self.fail("invalid binary number literal");
                number = @floatFromInt(integer);
            } else number = std.fmt.parseFloat(f64, current.text) catch return self.fail("invalid number literal");
            if (!std.math.isFinite(number)) return self.fail("number literal is out of range");
            self.advance();
            return .{ .offset = offset, .data = .{ .number = number } };
        }
        if (self.take("nil")) return .{ .offset = offset, .data = .nil };
        if (self.is("true") or self.is("false")) {
            const value: bool = self.is("true");
            self.advance();
            return .{ .offset = offset, .data = .{ .boolean = value } };
        }
        return .{ .offset = offset, .data = .{ .name = try self.identifier() } };
    }

    fn function(self: *Parser) Error!*const ast.Function {
        try self.expect("(");
        var parameters: std.ArrayList(ast.Parameter) = std.ArrayList(ast.Parameter).init(self.allocator);
        while (!self.is(")")) {
            const offset: usize = self.token().offset;
            const name: []const u8 = try self.identifier();
            try parameters.append(.{ .name = name, .annotation = if (self.take(":")) try self.typeName() else null, .offset = offset });
            if (!self.take(",")) break;
            if (self.is(")")) return self.fail("expected parameter after ','");
        }
        try self.expect(")");
        const result: ?ast.Type = if (self.take(":")) try self.typeName() else null;
        const body: ast.Block = try self.block();
        try self.expect("end");
        return self.create(ast.Function, .{ .parameters = try parameters.toOwnedSlice(), .result = result, .body = body });
    }

    fn block(self: *Parser) Error!ast.Block {
        var statements: std.ArrayList(ast.Statement) = std.ArrayList(ast.Statement).init(self.allocator);
        while (self.token().kind != .eof and !self.is("end") and !self.is("else") and !self.is("elseif")) try statements.append(try self.statement());
        return .{ .statements = try statements.toOwnedSlice(), .end = self.token().offset };
    }

    fn scope(self: *Parser) Error!ast.Block {
        const body: ast.Block = try self.block();
        try self.expect("end");
        return body;
    }

    fn conditional(self: *Parser) Error!ast.Conditional {
        const condition: ast.Expression = try self.expression();
        try self.expect("then");
        const then: ast.Block = try self.block();
        if (self.take("elseif")) return .{ .condition = condition, .then = then, .otherwise = .{ .conditional = try self.create(ast.Conditional, try self.conditional()) } };
        const otherwise: ?ast.Block = if (self.take("else")) try self.block() else null;
        try self.expect("end");
        return .{ .condition = condition, .then = then, .otherwise = if (otherwise) |body| .{ .block = body } else null };
    }

    fn statement(self: *Parser) Error!ast.Statement {
        const offset: usize = self.token().offset;
        if (self.take(";")) return .{ .offset = offset, .data = .empty };
        if (self.is("type") and self.peek().kind == .name) {
            self.advance();
            const name: []const u8 = try self.identifier();
            try self.expect("=");
            return .{ .offset = offset, .data = .{ .type_alias = .{ .name = name, .value = try self.typeName() } } };
        }
        if (self.take("function")) {
            const name: []const u8 = try self.identifier();
            return .{ .offset = offset, .data = .{ .function = .{ .local = false, .name = name, .function = try self.function() } } };
        }
        if (self.take("if")) return .{ .offset = offset, .data = .{ .conditional = try self.conditional() } };
        if (self.take("for")) {
            const name: []const u8 = try self.identifier();
            try self.expect("=");
            const from: ast.Expression = try self.expression();
            try self.expect(",");
            const limit: ast.Expression = try self.expression();
            const step: ?ast.Expression = if (self.take(",")) try self.expression() else null;
            try self.expect("do");
            return .{ .offset = offset, .data = .{ .numeric_for = .{ .name = name, .from = from, .limit = limit, .step = step, .body = try self.scope() } } };
        }
        if (self.take("while")) {
            const condition: ast.Expression = try self.expression();
            try self.expect("do");
            return .{ .offset = offset, .data = .{ .loop = .{ .condition = condition, .body = try self.scope() } } };
        }
        if (self.is("break") or self.is("continue")) {
            const keyword: []const u8 = self.token().text;
            self.advance();
            return .{ .offset = offset, .data = .{ .loop_control = keyword } };
        }
        if (self.take("return")) {
            const empty: bool = self.token().kind == .eof or self.is(";") or self.is("end") or self.is("else") or self.is("elseif") or self.is("until");
            return .{ .offset = offset, .data = .{ .@"return" = if (empty) null else try self.expression() } };
        }
        if (self.take("local")) {
            if (self.take("function")) {
                const name: []const u8 = try self.identifier();
                return .{ .offset = offset, .data = .{ .function = .{ .local = true, .name = name, .function = try self.function() } } };
            }
            const name: []const u8 = try self.identifier();
            const annotation: ?ast.Type = if (self.take(":")) try self.typeName() else null;
            return .{ .offset = offset, .data = .{ .local = .{ .name = name, .annotation = annotation, .value = if (self.take("=")) try self.expression() else null } } };
        }
        if (self.take("do")) return .{ .offset = offset, .data = .{ .scope = try self.scope() } };
        const target: ast.Expression = try self.primary();
        for ([_][]const u8{ "=", "+=", "-=", "*=", "/=", "//=", "%=", "^=", "..=" }) |operator| {
            if (!self.is(operator)) continue;
            if (target.data != .name and target.data != .index and target.data != .field) return self.fail("assignment target is not a variable or table field");
            self.advance();
            return .{ .offset = offset, .data = .{ .assign = .{ .target = target, .operator = operator, .value = try self.expression() } } };
        }
        if (target.data != .call and target.data != .method) return self.fail("expected assignment or function call");
        return .{ .offset = offset, .data = .{ .call = target } };
    }
};
