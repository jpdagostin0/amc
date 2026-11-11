const std: type = @import("std");
const diagnostic: type = @import("diagnostic.zig");

const Error: type = diagnostic.Error;

pub const Token: type = struct {
    kind: enum { name, number, string, symbol, eof },
    text: []const u8,
    offset: usize,
};

pub fn tokenize(allocator: std.mem.Allocator, source: []const u8, report: *diagnostic.Diagnostic) Error![]const Token {
    var tokens: std.ArrayList(Token) = std.ArrayList(Token).init(allocator);
    var cursor: usize = 0;
    while (true) {
        const token: Token = try next(allocator, source, &cursor, report);
        try tokens.append(token);
        if (token.kind == .eof) return tokens.toOwnedSlice();
    }
}

fn longDelimiter(source: []const u8, cursor: usize) ?usize {
    if (cursor == source.len or source[cursor] != '[') return null;
    var end: usize = cursor + 1;
    while (end < source.len and source[end] == '=') end += 1;
    return if (end < source.len and source[end] == '[') end - cursor + 1 else null;
}

fn longString(allocator: std.mem.Allocator, source: []const u8, cursor: *usize, delimiter: usize, start: usize, report: *diagnostic.Diagnostic) Error![]const u8 {
    const closing: []u8 = try allocator.dupe(u8, source[cursor.* .. cursor.* + delimiter]);
    closing[0] = ']';
    closing[delimiter - 1] = ']';
    cursor.* += delimiter;
    const end: usize = std.mem.indexOfPos(u8, source, cursor.*, closing) orelse return diagnostic.fail(report, start, "unterminated long string or comment");
    var result: std.ArrayList(u8) = std.ArrayList(u8).init(allocator);
    if (cursor.* < end and (source[cursor.*] == '\n' or source[cursor.*] == '\r')) {
        const first: u8 = source[cursor.*];
        cursor.* += 1;
        if (cursor.* < end and source[cursor.*] != first and (source[cursor.*] == '\n' or source[cursor.*] == '\r')) cursor.* += 1;
    }
    while (cursor.* < end) {
        const byte: u8 = source[cursor.*];
        cursor.* += 1;
        if (byte == '\r' or byte == '\n') {
            if (cursor.* < end and source[cursor.*] != byte and (source[cursor.*] == '\n' or source[cursor.*] == '\r')) cursor.* += 1;
            try result.append('\n');
        } else try result.append(byte);
    }
    cursor.* = end + delimiter;
    return result.toOwnedSlice();
}

fn quotedString(allocator: std.mem.Allocator, source: []const u8, cursor: *usize, delimiter: u8, start: usize, report: *diagnostic.Diagnostic) Error![]const u8 {
    var result: std.ArrayList(u8) = std.ArrayList(u8).init(allocator);
    while (cursor.* < source.len) {
        const byte: u8 = source[cursor.*];
        cursor.* += 1;
        if (byte == delimiter) return result.toOwnedSlice();
        if (byte == '\n' or byte == '\r') return diagnostic.fail(report, start, "unescaped newline in string");
        if (byte != '\\') {
            try result.append(byte);
            continue;
        }
        if (cursor.* == source.len) return diagnostic.fail(report, start, "unterminated string");
        const escape: u8 = source[cursor.*];
        cursor.* += 1;
        switch (escape) {
            'a' => try result.append(7),
            'b' => try result.append(8),
            'f' => try result.append(12),
            'n' => try result.append('\n'),
            'r' => try result.append('\r'),
            't' => try result.append('\t'),
            'v' => try result.append(11),
            '\\', '\'', '"' => try result.append(escape),
            '\n', '\r' => {
                if (escape == '\r' and cursor.* < source.len and source[cursor.*] == '\n') cursor.* += 1;
                try result.append('\n');
            },
            'z' => while (cursor.* < source.len and std.ascii.isWhitespace(source[cursor.*])) {
                cursor.* += 1;
            },
            'x' => {
                if (source.len - cursor.* < 2) return diagnostic.fail(report, start, "expected two hex digits in escape");
                const value: u8 = std.fmt.parseInt(u8, source[cursor.* .. cursor.* + 2], 16) catch return diagnostic.fail(report, start, "invalid hex escape");
                cursor.* += 2;
                try result.append(value);
            },
            '0'...'9' => {
                const digits: usize = cursor.* - 1;
                while (cursor.* < source.len and cursor.* - digits < 3 and std.ascii.isDigit(source[cursor.*])) cursor.* += 1;
                const value: u8 = std.fmt.parseInt(u8, source[digits..cursor.*], 10) catch return diagnostic.fail(report, start, "decimal escape exceeds 255");
                try result.append(value);
            },
            else => return diagnostic.fail(report, start, "unsupported string escape"),
        }
    }
    return diagnostic.fail(report, start, "unterminated string");
}

fn next(allocator: std.mem.Allocator, source: []const u8, cursor: *usize, report: *diagnostic.Diagnostic) Error!Token {
    while (true) {
        while (cursor.* < source.len and std.ascii.isWhitespace(source[cursor.*])) cursor.* += 1;
        if (!std.mem.startsWith(u8, source[cursor.*..], "--")) break;
        const comment: usize = cursor.*;
        cursor.* += 2;
        if (longDelimiter(source, cursor.*)) |delimiter| {
            _ = try longString(allocator, source, cursor, delimiter, comment, report);
        } else while (cursor.* < source.len and source[cursor.*] != '\n' and source[cursor.*] != '\r') {
            cursor.* += 1;
        }
    }
    const start: usize = cursor.*;
    if (start == source.len) return .{ .kind = .eof, .text = "", .offset = start };
    const byte: u8 = source[start];
    if (longDelimiter(source, start)) |delimiter| return .{ .kind = .string, .text = try longString(allocator, source, cursor, delimiter, start, report), .offset = start };
    cursor.* += 1;
    if (std.ascii.isAlphabetic(byte) or byte == '_') {
        while (cursor.* < source.len and (std.ascii.isAlphanumeric(source[cursor.*]) or source[cursor.*] == '_')) cursor.* += 1;
        return .{ .kind = .name, .text = source[start..cursor.*], .offset = start };
    }
    if (byte == '"' or byte == '\'') return .{ .kind = .string, .text = try quotedString(allocator, source, cursor, byte, start, report), .offset = start };
    if (std.ascii.isDigit(byte) or (byte == '.' and cursor.* < source.len and std.ascii.isDigit(source[cursor.*]))) {
        const hex: bool = std.mem.startsWith(u8, source[start..], "0x") or std.mem.startsWith(u8, source[start..], "0X");
        while (cursor.* < source.len) {
            const current: u8 = source[cursor.*];
            const previous: u8 = source[cursor.* - 1];
            const exponent: bool = if (hex) previous == 'p' or previous == 'P' else previous == 'e' or previous == 'E';
            if (std.ascii.isAlphanumeric(current) or current == '_' or current == '.') {
                cursor.* += 1;
            } else if ((current == '+' or current == '-') and exponent) {
                cursor.* += 1;
            } else break;
        }
        return .{ .kind = .number, .text = source[start..cursor.*], .offset = start };
    }
    if (std.mem.startsWith(u8, source[start..], "//=") or std.mem.startsWith(u8, source[start..], "..=")) {
        cursor.* = start + 3;
    } else if (cursor.* < source.len) {
        const pair: []const u8 = source[start .. cursor.* + 1];
        for ([_][]const u8{ "==", "~=", "<=", ">=", "//", "+=", "-=", "*=", "/=", "%=", "^=", "..", "::", "->" }) |operator| {
            if (std.mem.eql(u8, pair, operator)) {
                cursor.* += 1;
                break;
            }
        }
    }
    return .{ .kind = .symbol, .text = source[start..cursor.*], .offset = start };
}
