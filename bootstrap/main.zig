const std: type = @import("std");
const diagnostic: type = @import("diagnostic.zig");
const ast: type = @import("ast.zig");
const lexer: type = @import("lexer.zig");
const parser: type = @import("parser.zig");
const checker: type = @import("checker.zig");
const emitter: type = @import("emitter.zig");

fn compile(allocator: std.mem.Allocator, source: []const u8, report: *diagnostic.Diagnostic) diagnostic.Error![]const u8 {
    const tokens: []const lexer.Token = try lexer.tokenize(allocator, source, report);
    const tree: ast.Block = try parser.parse(allocator, tokens, report);
    var checked: checker.Checked = try checker.check(allocator, tree, report);
    return emitter.emit(allocator, checked.program, &checked.types);
}

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator: std.mem.Allocator = arena.allocator();
    const args: [][:0]u8 = try std.process.argsAlloc(allocator);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        try std.io.getStdOut().writeAll("Usage: amc-bootstrap <input.luau> [-o output.zig]\n");
        return;
    }
    if (args.len != 2 and !(args.len == 4 and std.mem.eql(u8, args[2], "-o"))) {
        try std.io.getStdErr().writeAll("Usage: amc-bootstrap <input.luau> [-o output.zig]\n");
        std.process.exit(1);
    }
    const source: []const u8 = std.fs.cwd().readFileAlloc(allocator, args[1], 16 * 1024 * 1024) catch |err| {
        try std.io.getStdErr().writer().print("{s}: {s}\n", .{ args[1], @errorName(err) });
        std.process.exit(1);
    };
    var report: diagnostic.Diagnostic = .{};
    const output: []const u8 = compile(allocator, source, &report) catch |err| {
        if (err != error.InvalidSource) return err;
        var line: usize = 1;
        var column: usize = 1;
        for (source[0..report.offset]) |byte| {
            if (byte == '\n') {
                line += 1;
                column = 1;
            } else column += 1;
        }
        try std.io.getStdErr().writer().print("{s}:{d}:{d}: {s}\n", .{ args[1], line, column, report.message });
        std.process.exit(1);
    };
    if (args.len == 4) {
        const file: std.fs.File = try std.fs.cwd().createFile(args[3], .{});
        defer file.close();
        try file.writeAll(output);
    } else try std.io.getStdOut().writeAll(output);
}
