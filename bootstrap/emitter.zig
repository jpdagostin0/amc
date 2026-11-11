const std: type = @import("std");
const ir: type = @import("ir.zig");
const type_system: type = @import("types.zig");

const Kind: type = type_system.Kind;
const Error: type = error{OutOfMemory};

pub fn emit(allocator: std.mem.Allocator, program: ir.Block, types: *type_system.Store) Error![]const u8 {
    var emitter: Emitter = .{ .allocator = allocator, .types = types, .declarations = std.ArrayList(u8).init(allocator), .functions = std.ArrayList(u8).init(allocator) };
    var body: std.ArrayList(u8) = std.ArrayList(u8).init(allocator);
    try emitter.block(&body, program);
    var output: std.ArrayList(u8) = std.ArrayList(u8).init(allocator);
    try output.appendSlice("const std: type = @import(\"std\");\n");
    try output.appendSlice(emitter.declarations.items);
    try output.appendSlice(emitter.functions.items);
    try output.appendSlice("pub fn main() void {\n");
    if (emitter.allocator_used) try output.appendSlice("var amc_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);\ndefer amc_arena.deinit();\nconst amc_allocator: std.mem.Allocator = amc_arena.allocator();\n");
    try output.appendSlice(body.items);
    try output.appendSlice("}\n");
    return output.toOwnedSlice();
}

const Emitter: type = struct {
    allocator: std.mem.Allocator,
    types: *type_system.Store,
    declarations: std.ArrayList(u8),
    functions: std.ArrayList(u8),
    declared: std.ArrayListUnmanaged(Kind) = .{},
    serial: usize = 0,
    owner: usize = 0,
    result: Kind = .void,
    allocator_used: bool = false,
    captures_used: bool = false,

    fn fresh(self: *Emitter) usize {
        self.serial += 1;
        return self.serial;
    }

    fn memory(self: *Emitter) []const u8 {
        self.allocator_used = true;
        return "amc_allocator";
    }

    fn storage(self: *Emitter, kind: Kind) Error!Kind {
        return self.types.storage(kind);
    }

    fn zigType(self: *Emitter, kind: Kind) Error![]const u8 {
        const stored: Kind = try self.storage(kind);
        if (stored.acceptsNil() and stored != .nil) return std.fmt.allocPrint(self.allocator, "?{s}", .{try self.zigType(stored.base())});
        return switch (stored) {
            .number => "f64",
            .boolean => "bool",
            .string => "[]const u8",
            .void => "void",
            .nil => "@TypeOf(null)",
            .input => "*std.io.BufferedReader(4096, std.fs.File.Reader)",
            .files => "std.fs.Dir",
            .number_array => "*std.ArrayListUnmanaged(f64)",
            .boolean_array => "*std.ArrayListUnmanaged(bool)",
            .string_array => "*std.ArrayListUnmanaged([]const u8)",
            else => switch (self.types.get(stored).?) {
                .array => |element| std.fmt.allocPrint(self.allocator, "*std.ArrayListUnmanaged({s})", .{try self.zigType(element)}),
                .dictionary => |entry| if ((try self.storage(entry.key)) == .string)
                    std.fmt.allocPrint(self.allocator, "*std.StringHashMapUnmanaged({s})", .{try self.zigType(entry.value)})
                else
                    std.fmt.allocPrint(self.allocator, "*std.AutoHashMapUnmanaged(u64, {s})", .{try self.zigType(entry.value)}),
                .record => blk: {
                    try self.declare(stored);
                    break :blk std.fmt.allocPrint(self.allocator, "*amc_T{d}", .{@intFromEnum(stored)});
                },
                .union_type, .function => blk: {
                    try self.declare(stored);
                    break :blk std.fmt.allocPrint(self.allocator, "amc_T{d}", .{@intFromEnum(stored)});
                },
                else => unreachable,
            },
        };
    }

    fn declare(self: *Emitter, stored: Kind) Error!void {
        if (std.mem.indexOfScalar(Kind, self.declared.items, stored) != null) return;
        try self.declared.append(self.allocator, stored);
        var text: std.ArrayList(u8) = std.ArrayList(u8).init(self.allocator);
        try text.writer().print("const amc_T{d} = ", .{@intFromEnum(stored)});
        switch (self.types.get(stored).?) {
            .record => |record| {
                try text.appendSlice("struct {");
                for (record.fields) |field| try text.writer().print(" @\"{s}\": {s},", .{ field.name, try self.zigType(field.kind) });
                try text.appendSlice(" };\n");
            },
            .union_type => |members| {
                try text.appendSlice("union(enum) {");
                for (members, 0..) |member, index| try text.writer().print(" v{d}: {s},", .{ index, try self.zigType(member) });
                try text.appendSlice(" };\n");
            },
            .function => |signature| {
                try text.appendSlice("struct { context: ?*anyopaque, call: *const fn (?*anyopaque, std.mem.Allocator");
                for (signature.parameters) |parameter| try text.writer().print(", {s}", .{try self.zigType(parameter)});
                try text.writer().print(") {s} }};\n", .{try self.zigType(signature.result)});
            },
            else => unreachable,
        }
        try self.declarations.appendSlice(text.items);
    }

    fn container(self: *Emitter, kind: Kind) Error![]const u8 {
        return (try self.zigType(kind))[1..];
    }

    fn access(self: *Emitter, binding: *const ir.Binding) Error![]const u8 {
        if (!binding.captured) return std.fmt.allocPrint(self.allocator, "v{d}", .{binding.id});
        return std.fmt.allocPrint(self.allocator, "{s}.*", .{try self.cell(binding)});
    }

    fn cell(self: *Emitter, binding: *const ir.Binding) Error![]const u8 {
        if (binding.owner == self.owner) return std.fmt.allocPrint(self.allocator, "v{d}", .{binding.id});
        self.captures_used = true;
        return std.fmt.allocPrint(self.allocator, "amc_captures.v{d}", .{binding.id});
    }

    fn keep(self: *Emitter, code: []const u8, effect: bool, constant: []const u8) Error![]const u8 {
        const label: usize = self.fresh();
        if (effect) return std.fmt.allocPrint(self.allocator, "(amc_b{d}: {{ _ = {s}; break :amc_b{d} {s}; }})", .{ label, code, label, constant });
        return std.fmt.allocPrint(self.allocator, "(if (@TypeOf({s}) == noreturn) unreachable else {s})", .{ code, constant });
    }

    fn convert(self: *Emitter, code: []const u8, from: Kind, to: Kind) Error![]const u8 {
        const source: Kind = try self.storage(from);
        const target: Kind = try self.storage(to);
        if (source == target) return code;
        if (source == .nil) return std.fmt.allocPrint(self.allocator, "@as({s}, null)", .{try self.zigType(target)});
        if (source.acceptsNil()) {
            if (!target.acceptsNil()) return self.convert(try std.fmt.allocPrint(self.allocator, "({s}).?", .{code}), source.base(), target);
            const name: []const u8 = try std.fmt.allocPrint(self.allocator, "amc_t{d}", .{self.fresh()});
            return std.fmt.allocPrint(self.allocator, "(if ({s}) |{s}| @as({s}, {s}) else null)", .{ code, name, try self.zigType(target), try self.convert(name, source.base(), target.base()) });
        }
        if (target.acceptsNil()) return std.fmt.allocPrint(self.allocator, "@as({s}, {s})", .{ try self.zigType(target), try self.convert(code, source, target.base()) });
        const source_members: []const Kind = self.types.variants(source);
        const target_members: []const Kind = self.types.variants(target);
        if (source_members.len != 0 and target_members.len != 0) {
            const target_type: []const u8 = try self.zigType(target);
            var text: std.ArrayList(u8) = std.ArrayList(u8).init(self.allocator);
            try text.writer().print("(switch ({s}) {{", .{code});
            for (source_members, 0..) |member, index| {
                if (std.mem.indexOfScalar(Kind, target_members, member)) |position| {
                    const name: usize = self.fresh();
                    try text.writer().print(" .v{d} => |amc_t{d}| {s}{{ .v{d} = amc_t{d} }},", .{ index, name, target_type, position, name });
                } else try text.writer().print(" .v{d} => unreachable,", .{index});
            }
            try text.appendSlice(" })");
            return text.toOwnedSlice();
        }
        if (target_members.len != 0) return std.fmt.allocPrint(self.allocator, "{s}{{ .v{d} = {s} }}", .{ try self.zigType(target), std.mem.indexOfScalar(Kind, target_members, source).?, code });
        return std.fmt.allocPrint(self.allocator, "({s}).v{d}", .{ code, std.mem.indexOfScalar(Kind, source_members, target).? });
    }

    fn truthy(self: *Emitter, code: []const u8, kind: Kind, effect: bool) Error![]const u8 {
        const stored: Kind = try self.storage(kind);
        if (stored == .boolean) return code;
        if (stored == .optional_boolean) return std.fmt.allocPrint(self.allocator, "(({s}) orelse false)", .{code});
        if (stored == .nil) return "false";
        if (stored.acceptsNil()) {
            if (std.mem.indexOfScalar(Kind, self.types.variants(stored.base()), .boolean) == null) return std.fmt.allocPrint(self.allocator, "(({s}) != null)", .{code});
            const name: []const u8 = try std.fmt.allocPrint(self.allocator, "amc_t{d}", .{self.fresh()});
            return std.fmt.allocPrint(self.allocator, "(if ({s}) |{s}| {s} else false)", .{ code, name, try self.truthy(name, stored.base(), false) });
        }
        if (std.mem.indexOfScalar(Kind, self.types.variants(stored), .boolean)) |index| {
            const name: usize = self.fresh();
            return std.fmt.allocPrint(self.allocator, "(switch ({s}) {{ .v{d} => |amc_t{d}| amc_t{d}, else => true }})", .{ code, index, name, name });
        }
        return self.keep(code, effect, "true");
    }

    fn condition(self: *Emitter, value: *const ir.Expression) Error![]const u8 {
        return self.truthy(try self.expression(value), value.kind, value.effect);
    }

    fn toString(self: *Emitter, code: []const u8, kind: Kind) Error![]const u8 {
        const stored: Kind = try self.storage(kind);
        switch (stored) {
            .number => return std.fmt.allocPrint(self.allocator, "(std.fmt.allocPrint({s}, \"{{d}}\", .{{{s}}}) catch @panic(\"out of memory\"))", .{ self.memory(), code }),
            .string => return code,
            .boolean => return std.fmt.allocPrint(self.allocator, "(if ({s}) \"true\" else \"false\")", .{code}),
            .nil => return "\"nil\"",
            else => {},
        }
        const name: []const u8 = try std.fmt.allocPrint(self.allocator, "amc_t{d}", .{self.fresh()});
        if (stored.acceptsNil()) return std.fmt.allocPrint(self.allocator, "(if ({s}) |{s}| {s} else \"nil\")", .{ code, name, try self.toString(name, stored.base()) });
        var text: std.ArrayList(u8) = std.ArrayList(u8).init(self.allocator);
        try text.writer().print("(switch ({s}) {{", .{code});
        for (self.types.variants(stored), 0..) |member, index| try text.writer().print(" .v{d} => |{s}| {s},", .{ index, name, try self.toString(name, member) });
        try text.appendSlice(" })");
        return text.toOwnedSlice();
    }

    fn typeName(self: *Emitter, code: []const u8, kind: Kind, effect: bool) Error![]const u8 {
        const stored: Kind = try self.storage(kind);
        if (stored == .nil) return "\"nil\"";
        if (stored.acceptsNil()) {
            if (self.types.variants(stored.base()).len == 0) return std.fmt.allocPrint(self.allocator, "(if (({s}) == null) \"nil\" else \"{s}\")", .{ code, self.types.category(stored.base()).? });
            const name: []const u8 = try std.fmt.allocPrint(self.allocator, "amc_t{d}", .{self.fresh()});
            return std.fmt.allocPrint(self.allocator, "(if ({s}) |{s}| {s} else \"nil\")", .{ code, name, try self.typeName(name, stored.base(), false) });
        }
        const members: []const Kind = self.types.variants(stored);
        if (members.len == 0) return self.keep(code, effect, try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{self.types.category(stored).?}));
        var text: std.ArrayList(u8) = std.ArrayList(u8).init(self.allocator);
        try text.writer().print("(switch ({s}) {{", .{code});
        for (members, 0..) |member, index| try text.writer().print(" .v{d} => \"{s}\",", .{ index, self.types.category(member).? });
        try text.appendSlice(" })");
        return text.toOwnedSlice();
    }

    fn same(self: *Emitter, left: []const u8, right: []const u8, kind: Kind) Error![]const u8 {
        return switch (try self.storage(kind)) {
            .string => std.fmt.allocPrint(self.allocator, "std.mem.eql(u8, {s}, {s})", .{ left, right }),
            .files => std.fmt.allocPrint(self.allocator, "({s}.fd == {s}.fd)", .{ left, right }),
            else => |stored| if (self.types.get(stored) != null and self.types.get(stored).? == .function)
                std.fmt.allocPrint(self.allocator, "({s}.call == {s}.call and {s}.context == {s}.context)", .{ left, right, left, right })
            else
                std.fmt.allocPrint(self.allocator, "({s} == {s})", .{ left, right }),
        };
    }

    fn equal(self: *Emitter, left: *const ir.Expression, right: *const ir.Expression, negate: bool) Error![]const u8 {
        const stored: Kind = try self.storage(left.kind);
        const label: usize = self.fresh();
        const left_code: []const u8 = try self.expression(left);
        const right_code: []const u8 = try self.expression(right);
        const prefix: []const u8 = if (negate) "!" else "";
        if (stored != try self.storage(right.kind)) {
            const left_discard: []const u8 = if (left.effect) left_code else try std.fmt.allocPrint(self.allocator, "@TypeOf({s})", .{left_code});
            const right_discard: []const u8 = if (right.effect) right_code else try std.fmt.allocPrint(self.allocator, "@TypeOf({s})", .{right_code});
            return std.fmt.allocPrint(self.allocator, "(amc_b{d}: {{ _ = {s}; _ = {s}; break :amc_b{d} {}; }})", .{ label, left_discard, right_discard, label, negate });
        }
        if (stored == .nil) return if (negate) "false" else "true";
        const left_name: []const u8 = try std.fmt.allocPrint(self.allocator, "amc_l{d}", .{label});
        const right_name: []const u8 = try std.fmt.allocPrint(self.allocator, "amc_r{d}", .{label});
        const comparison: []const u8 = if (stored.acceptsNil())
            try std.fmt.allocPrint(self.allocator, "(if ({[l]s}) |amc_x{[n]d}| (if ({[r]s}) |amc_y{[n]d}| {[same]s} else false) else {[r]s} == null)", .{
                .l = left_name,
                .r = right_name,
                .n = label,
                .same = try self.same(try std.fmt.allocPrint(self.allocator, "amc_x{d}", .{label}), try std.fmt.allocPrint(self.allocator, "amc_y{d}", .{label}), stored.base()),
            })
        else
            try self.same(left_name, right_name, stored);
        return std.fmt.allocPrint(self.allocator, "(amc_b{[n]d}: {{ const {[l]s} = {[left]s}; const {[r]s} = {[right]s}; break :amc_b{[n]d} {[prefix]s}{[comparison]s}; }})", .{ .n = label, .l = left_name, .r = right_name, .left = left_code, .right = right_code, .prefix = prefix, .comparison = comparison });
    }

    fn list(self: *Emitter, values: []const *const ir.Expression) Error![]const u8 {
        var code: std.ArrayList(u8) = std.ArrayList(u8).init(self.allocator);
        for (values, 0..) |value, index| {
            if (index != 0) try code.appendSlice(", ");
            try code.appendSlice(try self.expression(value));
        }
        return code.toOwnedSlice();
    }

    fn numberKey(self: *Emitter, code: []const u8) Error![]const u8 {
        return std.fmt.allocPrint(self.allocator, "@as(u64, @bitCast(({s}) + 0.0))", .{code});
    }

    fn dictionaryKey(self: *Emitter, map: Kind, code: []const u8) Error![]const u8 {
        const entry: type_system.Indexer = self.types.get(try self.storage(map)).?.dictionary;
        if ((try self.storage(entry.key)) == .string) return code;
        return self.numberKey(code);
    }

    fn optional(self: *Emitter, value: ?*const ir.Expression, fallback: []const u8) Error![]const u8 {
        const present: *const ir.Expression = value orelse return fallback;
        return std.fmt.allocPrint(self.allocator, "(({s}) orelse {s})", .{ try self.expression(present), fallback });
    }

    fn concatOperand(self: *Emitter, value: *const ir.Expression) Error![]const u8 {
        const code: []const u8 = try self.expression(value);
        if ((try self.storage(value.kind)) == .number) return self.toString(code, .number);
        return code;
    }

    fn expression(self: *Emitter, value: *const ir.Expression) Error![]const u8 {
        return switch (value.op) {
            .nil => "null",
            .undefined => "undefined",
            .boolean => |boolean| if (boolean) "true" else "false",
            .number => |number| if (std.math.isInf(number)) (if (number > 0) "std.math.inf(f64)" else "-std.math.inf(f64)") else std.fmt.allocPrint(self.allocator, "@as(f64, {e})", .{number}),
            .string => |text| std.fmt.allocPrint(self.allocator, "\"{}\"", .{std.zig.fmtEscapes(text)}),
            .read => |binding| self.convert(try self.access(binding), binding.kind, value.kind),
            .counter => |binding| std.fmt.allocPrint(self.allocator, "amc_index_{d}", .{binding.id}),
            .place_container => |id| std.fmt.allocPrint(self.allocator, "amc_c{d}", .{id}),
            .place_key => |id| std.fmt.allocPrint(self.allocator, "amc_k{d}", .{id}),
            .convert => |inner| self.convert(try self.expression(inner), inner.kind, value.kind),
            .not => |inner| std.fmt.allocPrint(self.allocator, "(!{s})", .{try self.condition(inner)}),
            .negate => |inner| std.fmt.allocPrint(self.allocator, "(-{s})", .{try self.expression(inner)}),
            .length => |inner| std.fmt.allocPrint(self.allocator, "@as(f64, @floatFromInt(({s}).{s}len))", .{ try self.expression(inner), if ((try self.storage(inner.kind)) == .string) "" else "items." }),
            .logic => |logic| blk: {
                const left_code: []const u8 = try self.expression(logic.left);
                const right_code: []const u8 = try self.expression(logic.right);
                const left_storage: Kind = try self.storage(logic.left.kind);
                if (left_storage == .boolean and (try self.storage(logic.right.kind)) == .boolean) break :blk std.fmt.allocPrint(self.allocator, "({s} {s} {s})", .{ left_code, if (logic.is_or) "or" else "and", right_code });
                const label: usize = self.fresh();
                const temporary: []const u8 = try std.fmt.allocPrint(self.allocator, "amc_t{d}", .{label});
                const present: Kind = self.types.resolve(logic.left.kind).base();
                const truthy_value: []const u8 = if (logic.is_or)
                    try self.convert(if (left_storage.acceptsNil()) try std.fmt.allocPrint(self.allocator, "{s}.?", .{temporary}) else temporary, present, value.kind)
                else
                    right_code;
                const falsy_value: []const u8 = if (logic.is_or)
                    right_code
                else if ((try self.storage(present)) == .boolean)
                    try self.convert(temporary, logic.left.kind, value.kind)
                else if (left_storage.acceptsNil())
                    try self.convert("null", .nil, value.kind)
                else
                    "unreachable";
                break :blk std.fmt.allocPrint(self.allocator, "(amc_b{d}: {{ const {s} = {s}; break :amc_b{d} if ({s}) {s} else {s}; }})", .{ label, temporary, left_code, label, try self.truthy(temporary, logic.left.kind, false), truthy_value, falsy_value });
            },
            .equal => |equality| self.equal(equality.left, equality.right, equality.negate),
            .concat => |pair| std.fmt.allocPrint(self.allocator, "(std.mem.concat({s}, u8, &.{{ {s}, {s} }}) catch @panic(\"out of memory\"))", .{ self.memory(), try self.concatOperand(pair.left), try self.concatOperand(pair.right) }),
            .compare => |operation| if ((try self.storage(operation.left.kind)) == .string)
                std.fmt.allocPrint(self.allocator, "std.mem.order(u8, {s}, {s}).compare(.{s})", .{ try self.expression(operation.left), try self.expression(operation.right), if (std.mem.eql(u8, operation.operator, "<")) "lt" else if (std.mem.eql(u8, operation.operator, "<=")) "lte" else if (std.mem.eql(u8, operation.operator, ">")) "gt" else "gte" })
            else
                std.fmt.allocPrint(self.allocator, "({s} {s} {s})", .{ try self.expression(operation.left), operation.operator, try self.expression(operation.right) }),
            .arithmetic => |operation| blk: {
                const left_code: []const u8 = try self.expression(operation.left);
                const right_code: []const u8 = try self.expression(operation.right);
                if (std.mem.eql(u8, operation.operator, "//")) break :blk std.fmt.allocPrint(self.allocator, "@floor({s} / {s})", .{ left_code, right_code });
                if (std.mem.eql(u8, operation.operator, "^")) break :blk std.fmt.allocPrint(self.allocator, "std.math.pow(f64, {s}, {s})", .{ left_code, right_code });
                if (std.mem.eql(u8, operation.operator, "%")) {
                    const label: usize = self.fresh();
                    break :blk std.fmt.allocPrint(self.allocator, "(amc_b{[n]d}: {{ const amc_l{[n]d}: f64 = {[left]s}; const amc_r{[n]d}: f64 = {[right]s}; break :amc_b{[n]d} amc_l{[n]d} - @floor(amc_l{[n]d} / amc_r{[n]d}) * amc_r{[n]d}; }})", .{ .n = label, .left = left_code, .right = right_code });
                }
                break :blk std.fmt.allocPrint(self.allocator, "({s} {s} {s})", .{ left_code, operation.operator, right_code });
            },
            .if_expression => |branch| std.fmt.allocPrint(self.allocator, "(if ({s}) {s} else {s})", .{ try self.condition(branch.condition), try self.expression(branch.then), try self.expression(branch.otherwise) }),
            .index => |pair| blk: {
                const container_code: []const u8 = try self.expression(pair.left);
                const key_code: []const u8 = try self.expression(pair.right);
                if (self.types.element(self.types.resolve(pair.left.kind)) == null) break :blk std.fmt.allocPrint(self.allocator, "({s}).get({s})", .{ container_code, try self.dictionaryKey(pair.left.kind, key_code) });
                const label: usize = self.fresh();
                break :blk std.fmt.allocPrint(self.allocator, "@as({[type]s}, (amc_b{[n]d}: {{ const amc_a{[n]d} = {[container]s}; const amc_i{[n]d}: f64 = {[key]s}; break :amc_b{[n]d} if (amc_i{[n]d} >= 1 and amc_i{[n]d} <= @as(f64, @floatFromInt(amc_a{[n]d}.items.len)) and amc_i{[n]d} == @floor(amc_i{[n]d})) amc_a{[n]d}.items[@intFromFloat(amc_i{[n]d} - 1)] else null; }}))", .{ .type = try self.zigType(value.kind), .n = label, .container = container_code, .key = key_code });
            },
            .field => |access_value| blk: {
                const code: []const u8 = try self.expression(access_value.value);
                const stored: Kind = try self.storage(access_value.value.kind);
                const members: []const Kind = self.types.variants(stored);
                if (members.len == 0) break :blk std.fmt.allocPrint(self.allocator, "({s}).@\"{s}\"", .{ code, access_value.name });
                var text: std.ArrayList(u8) = std.ArrayList(u8).init(self.allocator);
                try text.writer().print("(switch ({s}) {{", .{code});
                for (members, 0..) |member, index| {
                    const name: []const u8 = try std.fmt.allocPrint(self.allocator, "amc_t{d}", .{self.fresh()});
                    const field_kind: Kind = (try self.types.field(member, access_value.name)).?;
                    try text.writer().print(" .v{d} => |{s}| {s},", .{ index, name, try self.convert(try std.fmt.allocPrint(self.allocator, "{s}.@\"{s}\"", .{ name, access_value.name }), field_kind, value.kind) });
                }
                try text.appendSlice(" })");
                break :blk text.toOwnedSlice();
            },
            .array => |items| blk: {
                const label: usize = self.fresh();
                const allocator_name: []const u8 = self.memory();
                break :blk std.fmt.allocPrint(self.allocator, "(amc_b{[n]d}: {{ const amc_a{[n]d} = {[memory]s}.create({[type]s}) catch @panic(\"out of memory\"); amc_a{[n]d}.* = .{{}}; amc_a{[n]d}.appendSlice({[memory]s}, &.{{ {[items]s} }}) catch @panic(\"out of memory\"); break :amc_b{[n]d} amc_a{[n]d}; }})", .{ .n = label, .memory = allocator_name, .type = try self.container(value.kind), .items = try self.list(items) });
            },
            .record => |fields| blk: {
                const label: usize = self.fresh();
                var text: std.ArrayList(u8) = std.ArrayList(u8).init(self.allocator);
                for (fields) |field| try text.writer().print(" .@\"{s}\" = {s},", .{ field.name, try self.expression(field.value) });
                break :blk std.fmt.allocPrint(self.allocator, "(amc_b{[n]d}: {{ const amc_r{[n]d} = {[memory]s}.create({[type]s}) catch @panic(\"out of memory\"); amc_r{[n]d}.* = .{{{[fields]s} }}; break :amc_b{[n]d} amc_r{[n]d}; }})", .{ .n = label, .memory = self.memory(), .type = try self.container(value.kind), .fields = text.items });
            },
            .dictionary => |pairs| blk: {
                const label: usize = self.fresh();
                const allocator_name: []const u8 = self.memory();
                var text: std.ArrayList(u8) = std.ArrayList(u8).init(self.allocator);
                for (pairs) |pair| try text.writer().print(" amc_d{d}.put({s}, {s}, {s}) catch @panic(\"out of memory\");", .{ label, allocator_name, try self.dictionaryKey(value.kind, try self.expression(pair.left)), try self.expression(pair.right) });
                break :blk std.fmt.allocPrint(self.allocator, "(amc_b{[n]d}: {{ const amc_d{[n]d} = {[memory]s}.create({[type]s}) catch @panic(\"out of memory\"); amc_d{[n]d}.* = .{{}};{[puts]s} break :amc_b{[n]d} amc_d{[n]d}; }})", .{ .n = label, .memory = allocator_name, .type = try self.container(value.kind), .puts = text.items });
            },
            .closure => |function_value| self.closure(function_value, value.kind),
            .call => |call| blk: {
                const label: usize = self.fresh();
                var arguments: std.ArrayList(u8) = std.ArrayList(u8).init(self.allocator);
                for (call.arguments) |argument| try arguments.writer().print(", {s}", .{try self.expression(argument)});
                break :blk std.fmt.allocPrint(self.allocator, "(amc_b{[n]d}: {{ const amc_f{[n]d} = {[callee]s}; break :amc_b{[n]d} amc_f{[n]d}.call(amc_f{[n]d}.context, {[memory]s}{[arguments]s}); }})", .{ .n = label, .callee = try self.expression(call.callee), .memory = self.memory(), .arguments = arguments.items });
            },
            .print => |values| blk: {
                var template: std.ArrayList(u8) = std.ArrayList(u8).init(self.allocator);
                var arguments: std.ArrayList(u8) = std.ArrayList(u8).init(self.allocator);
                for (values, 0..) |item, index| {
                    if (index != 0) {
                        try template.appendSlice("\\t");
                        try arguments.appendSlice(", ");
                    }
                    const code: []const u8 = try self.expression(item);
                    switch (try self.storage(item.kind)) {
                        .number => try template.appendSlice("{d}"),
                        .boolean => try template.appendSlice("{}"),
                        else => try template.appendSlice("{s}"),
                    }
                    try arguments.appendSlice(if ((try self.storage(item.kind)) == .number or (try self.storage(item.kind)) == .boolean) code else try self.toString(code, item.kind));
                }
                break :blk std.fmt.allocPrint(self.allocator, "(std.io.getStdOut().writer().print(\"{s}\\n\", .{{ {s} }}) catch @panic(\"stdout write failed\"))", .{ template.items, arguments.items });
            },
            .to_string => |inner| self.toString(try self.expression(inner), inner.kind),
            .type_name => |inner| self.typeName(try self.expression(inner), inner.kind, inner.effect),
            .string_sub => |call| blk: {
                const label: usize = self.fresh();
                break :blk std.fmt.allocPrint(self.allocator, "(amc_b{[n]d}: {{ const amc_s{[n]d}: []const u8 = {[string]s}; const amc_l{[n]d}: f64 = @floatFromInt(amc_s{[n]d}.len); const amc_f{[n]d}: f64 = @trunc({[first]s}); const amc_t{[n]d}: f64 = @trunc({[last]s}); const amc_i{[n]d}: f64 = @max(1, if (amc_f{[n]d} < 0) amc_l{[n]d} + amc_f{[n]d} + 1 else amc_f{[n]d}); const amc_j{[n]d}: f64 = @min(amc_l{[n]d}, if (amc_t{[n]d} < 0) amc_l{[n]d} + amc_t{[n]d} + 1 else amc_t{[n]d}); break :amc_b{[n]d} if (amc_i{[n]d} > amc_j{[n]d}) \"\" else amc_s{[n]d}[@intFromFloat(amc_i{[n]d} - 1)..@intFromFloat(amc_j{[n]d})]; }})", .{ .n = label, .string = try self.expression(call.string), .first = try self.expression(call.first), .last = try self.optional(call.last, "@as(f64, -1)") });
            },
            .string_byte => |call| blk: {
                const label: usize = self.fresh();
                break :blk std.fmt.allocPrint(self.allocator, "@as({[type]s}, (amc_b{[n]d}: {{ const amc_s{[n]d}: []const u8 = {[string]s}; const amc_l{[n]d}: f64 = @floatFromInt(amc_s{[n]d}.len); const amc_i{[n]d}: f64 = @trunc({[index]s}); const amc_r{[n]d}: f64 = if (amc_i{[n]d} < 0) amc_l{[n]d} + amc_i{[n]d} + 1 else amc_i{[n]d}; break :amc_b{[n]d} if (amc_r{[n]d} < 1 or amc_r{[n]d} > amc_l{[n]d}) null else @as(f64, @floatFromInt(amc_s{[n]d}[@intFromFloat(amc_r{[n]d} - 1)])); }}))", .{ .type = try self.zigType(value.kind), .n = label, .string = try self.expression(call.string), .index = try self.optional(call.index, "@as(f64, 1)") });
            },
            .string_case => |call| std.fmt.allocPrint(self.allocator, "(std.ascii.alloc{s}String({s}, {s}) catch @panic(\"out of memory\"))", .{ if (call.upper) "Upper" else "Lower", self.memory(), try self.expression(call.string) }),
            .string_char => |codes| blk: {
                const label: usize = self.fresh();
                break :blk std.fmt.allocPrint(self.allocator, "(amc_b{[n]d}: {{ const amc_c{[n]d} = [_]f64{{ {[codes]s} }}; const amc_o{[n]d} = {[memory]s}.alloc(u8, amc_c{[n]d}.len) catch @panic(\"out of memory\"); for (amc_c{[n]d}, amc_o{[n]d}) |amc_x{[n]d}, *amc_y{[n]d}| {{ if (amc_x{[n]d} < 0 or amc_x{[n]d} > 255 or amc_x{[n]d} != @trunc(amc_x{[n]d})) @panic(\"invalid value in string.char\"); amc_y{[n]d}.* = @intFromFloat(amc_x{[n]d}); }} break :amc_b{[n]d} amc_o{[n]d}; }})", .{ .n = label, .codes = try self.list(codes), .memory = self.memory() });
            },
            .array_insert => |call| blk: {
                const allocator_name: []const u8 = self.memory();
                const array_code: []const u8 = try self.expression(call.array);
                const value_code: []const u8 = try self.expression(call.value);
                const position: *const ir.Expression = call.position orelse break :blk std.fmt.allocPrint(self.allocator, "(({s}).append({s}, {s}) catch @panic(\"out of memory\"))", .{ array_code, allocator_name, value_code });
                break :blk std.fmt.allocPrint(self.allocator, "(amc_b{[n]d}: {{ const amc_a{[n]d} = {[array]s}; const amc_p{[n]d}: f64 = @trunc(({[position]s}) orelse @as(f64, @floatFromInt(amc_a{[n]d}.items.len + 1))); if (amc_p{[n]d} < 1 or amc_p{[n]d} > @as(f64, @floatFromInt(amc_a{[n]d}.items.len + 1))) @panic(\"position out of bounds\"); amc_a{[n]d}.insert({[memory]s}, @intFromFloat(amc_p{[n]d} - 1), {[value]s}) catch @panic(\"out of memory\"); break :amc_b{[n]d}; }})", .{ .n = self.fresh(), .array = array_code, .position = try self.expression(position), .memory = allocator_name, .value = value_code });
            },
            .array_remove => |call| blk: {
                const label: usize = self.fresh();
                break :blk std.fmt.allocPrint(self.allocator, "@as({[type]s}, (amc_b{[n]d}: {{ const amc_a{[n]d} = {[array]s}; const amc_l{[n]d}: f64 = @floatFromInt(amc_a{[n]d}.items.len); const amc_p{[n]d}: f64 = @trunc({[position]s}); break :amc_b{[n]d} if (amc_p{[n]d} < 1 or amc_p{[n]d} > amc_l{[n]d}) null else amc_a{[n]d}.orderedRemove(@intFromFloat(amc_p{[n]d} - 1)); }}))", .{ .type = try self.zigType(value.kind), .n = label, .array = try self.expression(call.array), .position = try self.optional(call.position, try std.fmt.allocPrint(self.allocator, "amc_l{d}", .{label})) });
            },
            .table_concat => |call| blk: {
                const label: usize = self.fresh();
                const element: Kind = self.types.element(self.types.resolve(call.array.kind)).?;
                const item: []const u8 = try std.fmt.allocPrint(self.allocator, "amc_a{d}.items[@intFromFloat(amc_i{d} - 1)]", .{ label, label });
                break :blk std.fmt.allocPrint(self.allocator, "(amc_b{[n]d}: {{ const amc_a{[n]d} = {[array]s}; const amc_l{[n]d}: f64 = @floatFromInt(amc_a{[n]d}.items.len); const amc_s{[n]d}: []const u8 = {[separator]s}; const amc_e{[n]d}: f64 = @trunc({[last]s}); var amc_o{[n]d}: std.ArrayListUnmanaged(u8) = .{{}}; var amc_i{[n]d}: f64 = @trunc({[first]s}); while (amc_i{[n]d} <= amc_e{[n]d}) : (amc_i{[n]d} += 1) {{ if (amc_i{[n]d} < 1 or amc_i{[n]d} > amc_l{[n]d}) @panic(\"invalid value in table.concat\"); amc_o{[n]d}.appendSlice({[memory]s}, {[item]s}) catch @panic(\"out of memory\"); if (amc_i{[n]d} < amc_e{[n]d}) amc_o{[n]d}.appendSlice({[memory]s}, amc_s{[n]d}) catch @panic(\"out of memory\"); }} break :amc_b{[n]d} amc_o{[n]d}.items; }})", .{
                    .n = label,
                    .array = try self.expression(call.array),
                    .separator = try self.optional(call.separator, "\"\""),
                    .last = try self.optional(call.last, try std.fmt.allocPrint(self.allocator, "amc_l{d}", .{label})),
                    .first = try self.optional(call.first, "@as(f64, 1)"),
                    .memory = self.memory(),
                    .item = if ((try self.storage(element)) == .number) try self.toString(item, .number) else item,
                });
            },
            .math => |call| std.fmt.allocPrint(self.allocator, "@{s}({s})", .{ call.name, try self.expression(call.argument) }),
            .read_line => |input| std.fmt.allocPrint(self.allocator, "(({s}).reader().readUntilDelimiterOrEofAlloc({s}, '\\n', std.math.maxInt(usize)) catch @panic(\"input read failed\"))", .{ try self.expression(input), self.memory() }),
            .read_all => |input| std.fmt.allocPrint(self.allocator, "(({s}).reader().readAllAlloc({s}, std.math.maxInt(usize)) catch @panic(\"input read failed\"))", .{ try self.expression(input), self.memory() }),
            .read_count => |pair| blk: {
                const label: usize = self.fresh();
                break :blk std.fmt.allocPrint(self.allocator, "@as({[type]s}, (amc_b{[n]d}: {{ const amc_r{[n]d} = {[input]s}; const amc_l{[n]d}: f64 = @trunc({[count]s}); const amc_o{[n]d} = {[memory]s}.alloc(u8, if (amc_l{[n]d} >= 1) @as(usize, @intFromFloat(amc_l{[n]d})) else 0) catch @panic(\"out of memory\"); const amc_c{[n]d} = amc_r{[n]d}.reader().readAll(amc_o{[n]d}) catch @panic(\"input read failed\"); break :amc_b{[n]d} if (amc_c{[n]d} == 0 and amc_o{[n]d}.len != 0) null else amc_o{[n]d}[0..amc_c{[n]d}]; }}))", .{ .type = try self.zigType(value.kind), .n = label, .input = try self.expression(pair.left), .count = try self.expression(pair.right), .memory = self.memory() });
            },
            .read_file => |pair| blk: {
                const label: usize = self.fresh();
                break :blk std.fmt.allocPrint(self.allocator, "(amc_b{[n]d}: {{ break :amc_b{[n]d} @as(?[]const u8, ({[files]s}).readFileAlloc({[memory]s}, {[path]s}, std.math.maxInt(usize)) catch |amc_e{[n]d}| switch (amc_e{[n]d}) {{ error.OutOfMemory => @panic(\"out of memory\"), else => break :amc_b{[n]d} null }}); }})", .{ .n = label, .files = try self.expression(pair.left), .memory = self.memory(), .path = try self.expression(pair.right) });
            },
        };
    }

    fn closure(self: *Emitter, function_value: *const ir.Function, kind: Kind) Error![]const u8 {
        try self.function(function_value);
        var fields: std.ArrayList(u8) = std.ArrayList(u8).init(self.allocator);
        for (function_value.captures) |binding| {
            if (binding.live) try fields.writer().print(" .v{d} = {s},", .{ binding.id, try self.cell(binding) });
        }
        const context: []const u8 = if (fields.items.len == 0) "null" else blk: {
            const label: usize = self.fresh();
            break :blk try std.fmt.allocPrint(self.allocator, "(amc_b{[n]d}: {{ const amc_x{[n]d} = {[memory]s}.create(amc_C{[id]d}) catch @panic(\"out of memory\"); amc_x{[n]d}.* = .{{{[fields]s} }}; break :amc_b{[n]d} amc_x{[n]d}; }})", .{ .n = label, .memory = self.memory(), .id = function_value.id, .fields = fields.items });
        };
        return std.fmt.allocPrint(self.allocator, "{s}{{ .context = {s}, .call = &amc_fn_{d} }}", .{ try self.zigType(kind), context, function_value.id });
    }

    fn function(self: *Emitter, function_value: *const ir.Function) Error!void {
        const saved_owner: usize = self.owner;
        const saved_result: Kind = self.result;
        const saved_allocator: bool = self.allocator_used;
        const saved_captures: bool = self.captures_used;
        defer {
            self.owner = saved_owner;
            self.result = saved_result;
            self.allocator_used = saved_allocator;
            self.captures_used = saved_captures;
        }
        self.owner = function_value.id;
        self.result = self.types.function(function_value.kind).?.result;
        self.allocator_used = false;
        self.captures_used = false;
        var body: std.ArrayList(u8) = std.ArrayList(u8).init(self.allocator);
        try self.block(&body, function_value.body);
        if (function_value.falls_through and (try self.storage(self.result)).acceptsNil()) try body.appendSlice("return null;\n");
        var captures: std.ArrayList(u8) = std.ArrayList(u8).init(self.allocator);
        for (function_value.captures) |binding| {
            if (binding.live) try captures.writer().print(" v{d}: *{s},", .{ binding.id, try self.zigType(binding.kind) });
        }
        if (captures.items.len != 0) try self.declarations.writer().print("const amc_C{d} = struct {{{s} }};\n", .{ function_value.id, captures.items });
        var parameters: std.ArrayList(u8) = std.ArrayList(u8).init(self.allocator);
        for (function_value.parameters) |parameter| {
            const name: []const u8 = if (!parameter.live) "_" else if (parameter.captured or parameter.mutable) try std.fmt.allocPrint(self.allocator, "p{d}", .{parameter.id}) else try std.fmt.allocPrint(self.allocator, "v{d}", .{parameter.id});
            try parameters.writer().print(", {s}: {s}", .{ name, try self.zigType(parameter.kind) });
        }
        try self.functions.writer().print("fn amc_fn_{d}({s}: ?*anyopaque, {s}: std.mem.Allocator{s}) {s} {{\n", .{ function_value.id, if (self.captures_used) "amc_context" else "_", if (self.allocator_used) "amc_allocator" else "_", parameters.items, try self.zigType(self.result) });
        if (self.captures_used) try self.functions.writer().print("const amc_captures: *amc_C{d} = @ptrCast(@alignCast(amc_context.?));\n", .{function_value.id});
        try self.functions.appendSlice(body.items);
        try self.functions.appendSlice("}\n");
    }

    fn block(self: *Emitter, out: *std.ArrayList(u8), value: ir.Block) Error!void {
        for (value.declarations) |binding| try self.declareBinding(out, binding);
        for (value.statements) |item| try self.statement(out, item);
    }

    fn declareBinding(self: *Emitter, out: *std.ArrayList(u8), binding: *const ir.Binding) Error!void {
        if (!binding.live) {
            if (!binding.parameter and binding.value.effect) try out.writer().print("_ = {s};\n", .{try self.expression(binding.value)});
            return;
        }
        const value_code: []const u8 = if (binding.parameter) blk: {
            if (!binding.captured and !binding.mutable) return;
            break :blk try std.fmt.allocPrint(self.allocator, "p{d}", .{binding.id});
        } else try self.expression(binding.value);
        const zig_type: []const u8 = try self.zigType(binding.kind);
        if (binding.captured) {
            try out.writer().print("const v{d} = {s}.create({s}) catch @panic(\"out of memory\");\nv{d}.* = {s};\n", .{ binding.id, self.memory(), zig_type, binding.id, value_code });
        } else try out.writer().print("{s} v{d}: {s} = {s};\n", .{ if (binding.mutable) "var" else "const", binding.id, zig_type, value_code });
    }

    fn conditional(self: *Emitter, out: *std.ArrayList(u8), value: *const ir.Conditional) Error!void {
        try out.writer().print("if ({s}) {{\n", .{try self.condition(value.condition)});
        try self.block(out, value.then);
        if (value.otherwise) |otherwise| {
            try out.appendSlice("} else {\n");
            switch (otherwise) {
                .block => |body| try self.block(out, body),
                .conditional => |nested| try self.conditional(out, nested),
            }
        }
        try out.appendSlice("}\n");
    }

    fn entryPoint(self: *Emitter, out: *std.ArrayList(u8), value: ir.Entry) Error!void {
        const label: usize = self.fresh();
        const allocator_name: []const u8 = self.memory();
        try out.writer().print("{{\nconst amc_entry = {s};\n", .{try self.expression(value.function)});
        var argument: []const u8 = "";
        if (value.context) |context| {
            try out.writer().print("const amc_context = {s}.create({s}) catch @panic(\"out of memory\");\namc_context.* = .{{", .{ allocator_name, try self.container(context) });
            for (self.types.get(context).?.record.fields) |field| {
                const code: []const u8 = if (std.mem.eql(u8, field.name, "args"))
                    try std.fmt.allocPrint(self.allocator, "(amc_b{[n]d}: {{ const amc_v{[n]d} = std.process.argsAlloc({[memory]s}) catch @panic(\"out of memory\"); const amc_l{[n]d} = {[memory]s}.create(std.ArrayListUnmanaged([]const u8)) catch @panic(\"out of memory\"); amc_l{[n]d}.* = .{{}}; for (amc_v{[n]d}[1..]) |amc_x{[n]d}| amc_l{[n]d}.append({[memory]s}, amc_x{[n]d}) catch @panic(\"out of memory\"); break :amc_b{[n]d} amc_l{[n]d}; }})", .{ .n = label, .memory = allocator_name })
                else if (std.mem.eql(u8, field.name, "env"))
                    try std.fmt.allocPrint(self.allocator, "(amc_e{[n]d}: {{ const amc_m{[n]d} = std.process.getEnvMap({[memory]s}) catch @panic(\"environment unavailable\"); const amc_d{[n]d} = {[memory]s}.create(std.StringHashMapUnmanaged([]const u8)) catch @panic(\"out of memory\"); amc_d{[n]d}.* = .{{}}; var amc_i{[n]d} = amc_m{[n]d}.iterator(); while (amc_i{[n]d}.next()) |amc_x{[n]d}| amc_d{[n]d}.put({[memory]s}, amc_x{[n]d}.key_ptr.*, amc_x{[n]d}.value_ptr.*) catch @panic(\"out of memory\"); break :amc_e{[n]d} amc_d{[n]d}; }})", .{ .n = label, .memory = allocator_name })
                else if (std.mem.eql(u8, field.name, "stdin"))
                    try std.fmt.allocPrint(self.allocator, "(amc_s{[n]d}: {{ const amc_r{[n]d} = {[memory]s}.create(std.io.BufferedReader(4096, std.fs.File.Reader)) catch @panic(\"out of memory\"); amc_r{[n]d}.* = std.io.bufferedReader(std.io.getStdIn().reader()); break :amc_s{[n]d} amc_r{[n]d}; }})", .{ .n = label, .memory = allocator_name })
                else
                    "std.fs.cwd()";
                try out.writer().print(" .@\"{s}\" = {s},", .{ field.name, code });
            }
            try out.appendSlice(" };\n");
            argument = ", amc_context";
        }
        const invocation: []const u8 = try std.fmt.allocPrint(self.allocator, "amc_entry.call(amc_entry.context, {s}{s})", .{ allocator_name, argument });
        if ((try self.storage(value.result)) == .number) {
            try out.writer().print("std.process.exit(@as(u8, @intFromFloat({s})));\n}}\n", .{invocation});
        } else try out.writer().print("{s};\n}}\n", .{invocation});
    }

    fn statement(self: *Emitter, out: *std.ArrayList(u8), value: ir.Statement) Error!void {
        switch (value) {
            .declare => |binding| try self.declareBinding(out, binding),
            .evaluate => |expression_value| try out.writer().print("_ = {s};\n", .{try self.expression(expression_value)}),
            .assign => |assignment| try out.writer().print("{s} = {s};\n", .{ try self.access(assignment.binding), try self.expression(assignment.value) }),
            .assign_index => |assignment| {
                try out.writer().print("{{\nconst amc_c{d} = {s};\nconst amc_k{d} = {s};\nconst amc_v{d} = {s};\n", .{ assignment.id, try self.expression(assignment.container), assignment.id, try self.expression(assignment.key), assignment.id, try self.expression(assignment.value) });
                const id: usize = assignment.id;
                if (self.types.element(self.types.resolve(assignment.container.kind)) != null) {
                    try out.writer().print("const amc_n{[n]d}: f64 = @floatFromInt(amc_c{[n]d}.items.len);\nif (amc_k{[n]d} == amc_n{[n]d} + 1) {{\namc_c{[n]d}.append({[memory]s}, amc_v{[n]d}) catch @panic(\"out of memory\");\n}} else if (amc_k{[n]d} >= 1 and amc_k{[n]d} <= amc_n{[n]d} and amc_k{[n]d} == @floor(amc_k{[n]d})) {{\namc_c{[n]d}.items[@intFromFloat(amc_k{[n]d} - 1)] = amc_v{[n]d};\n}} else @panic(\"array index out of range\");\n", .{ .n = id, .memory = self.memory() });
                } else {
                    const key: []const u8 = try self.dictionaryKey(assignment.container.kind, try std.fmt.allocPrint(self.allocator, "amc_k{d}", .{id}));
                    if ((try self.storage(assignment.value.kind)).acceptsNil()) {
                        try out.writer().print("if (amc_v{[n]d}) |amc_x{[n]d}| {{\namc_c{[n]d}.put({[memory]s}, {[key]s}, amc_x{[n]d}) catch @panic(\"out of memory\");\n}} else {{\n_ = amc_c{[n]d}.remove({[key]s});\n}}\n", .{ .n = id, .memory = self.memory(), .key = key });
                    } else try out.writer().print("amc_c{d}.put({s}, {s}, amc_v{d}) catch @panic(\"out of memory\");\n", .{ id, self.memory(), key, id });
                }
                try out.appendSlice("}\n");
            },
            .assign_field => |assignment| try out.writer().print("{{\nconst amc_c{d} = {s};\namc_c{d}.@\"{s}\" = {s};\n}}\n", .{ assignment.id, try self.expression(assignment.record), assignment.id, assignment.name, try self.expression(assignment.value) }),
            .conditional => |conditional_value| try self.conditional(out, conditional_value),
            .loop => |loop| {
                try out.writer().print("while ({s}) {{\n", .{try self.condition(loop.condition)});
                try self.block(out, loop.body);
                try out.appendSlice("}\n");
            },
            .numeric_for => |loop| {
                const index: []const u8 = try std.fmt.allocPrint(self.allocator, "amc_index_{d}", .{loop.binding.id});
                try out.writer().print(
                    "{{\nvar {s}: f64 = {s};\nconst e{s}: f64 = {s};\nconst s{s}: f64 = {s};\nwhile (if (s{s} > 0) {s} <= e{s} else {s} >= e{s}) : ({s} += s{s}) {{\n",
                    .{ index, try self.expression(loop.from), index, try self.expression(loop.limit), index, try self.expression(loop.step), index, index, index, index, index, index, index },
                );
                try self.block(out, loop.body);
                try out.appendSlice("}\n}\n");
            },
            .scope => |body| {
                try out.appendSlice("{\n");
                try self.block(out, body);
                try out.appendSlice("}\n");
            },
            .loop_control => |keyword| try out.writer().print("{s};\n", .{keyword}),
            .exit => try out.appendSlice("return;\n"),
            .@"return" => |returned| if ((try self.storage(self.result)) == .void) try out.appendSlice("return;\n") else try out.writer().print("return {s};\n", .{try self.expression(returned)}),
            .entry => |entry_value| try self.entryPoint(out, entry_value),
        }
    }
};
