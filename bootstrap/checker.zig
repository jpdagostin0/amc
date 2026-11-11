const std: type = @import("std");
const ast: type = @import("ast.zig");
const ir: type = @import("ir.zig");
const diagnostic: type = @import("diagnostic.zig");
const type_system: type = @import("types.zig");

const Error: type = diagnostic.Error;
const Kind: type = type_system.Kind;

pub const Checked: type = struct { program: ir.Block, types: type_system.Store };

pub fn check(allocator: std.mem.Allocator, body: ast.Block, report: *diagnostic.Diagnostic) Error!Checked {
    var checker: Checker = .{ .allocator = allocator, .report = report, .types = .{ .allocator = allocator } };
    const program: ir.Block = (try checker.block(body, &.{})).block;
    for (checker.declarations.items) |symbol| {
        if (symbol.root or symbol.binding.mutable) markLive(symbol);
        if (symbol.binding.value.effect) for (symbol.dependencies.items) |dependency| markLive(dependency);
    }
    return .{ .program = program, .types = checker.types };
}

fn markLive(symbol: *Symbol) void {
    if (symbol.binding.live) return;
    symbol.binding.live = true;
    for (symbol.dependencies.items) |dependency| markLive(dependency);
}

const Symbol: type = struct {
    name: []const u8,
    kind: Kind,
    binding: *ir.Binding,
    depth: usize,
    root: bool = false,
    initialized: bool = true,
    version: usize = 0,
    dependencies: std.ArrayListUnmanaged(*Symbol) = .{},
};

const Refinement: type = struct { symbol: *Symbol, kind: Kind, version: usize };

const Place: type = struct { container: Value, key: Value, field: ?[]const u8, write: Kind };

const Value: type = struct {
    node: *const ir.Expression,
    symbol: ?*Symbol = null,
    when_true: []const Refinement = &.{},
    when_false: []const Refinement = &.{},
    literal: ?[]const u8 = null,
    boolean_literal: ?bool = null,
    access_symbol: ?*Symbol = null,
    access_field: ?[]const u8 = null,
    type_symbol: ?*Symbol = null,
    place: ?*const Place = null,
    called: bool = false,

    fn kind(self: Value) Kind {
        return self.node.kind;
    }
};

const Signature: type = struct {
    kind: Kind = .invalid,
    result: Kind = .void,
    infer_result: bool = false,
    returned: bool = false,
    empty_return: bool = false,
    returns: std.ArrayListUnmanaged(*ir.Expression) = .{},
};

const Frame: type = struct { depth: usize, captures: std.ArrayListUnmanaged(*const ir.Binding) = .{} };

const Builtin: type = enum { @"string.sub", @"string.byte", @"string.char", @"string.lower", @"string.upper", @"table.insert", @"table.remove", @"table.concat", @"math.floor", @"math.ceil", @"math.abs" };

const Checker: type = struct {
    allocator: std.mem.Allocator,
    report: *diagnostic.Diagnostic,
    types: type_system.Store,
    bindings: std.ArrayListUnmanaged(*Symbol) = .{},
    declarations: std.ArrayListUnmanaged(*Symbol) = .{},
    aliases: std.ArrayListUnmanaged(struct { name: []const u8, kind: Kind }) = .{},
    refinements: std.ArrayListUnmanaged(Refinement) = .{},
    frames: std.ArrayListUnmanaged(*Frame) = .{},
    serial: usize = 0,
    owner: usize = 0,
    depth: usize = 0,
    scope_depth: usize = 0,
    loop_depth: usize = 0,
    signature: ?*Signature = null,
    initializer: ?*std.ArrayListUnmanaged(*Symbol) = null,

    fn fail(self: *Checker, offset: usize, message: []const u8) Error {
        return diagnostic.fail(self.report, offset, message);
    }

    fn id(self: *Checker) usize {
        self.serial += 1;
        return self.serial;
    }

    fn node(self: *Checker, expression_value: ir.Expression) Error!*ir.Expression {
        const pointer: *ir.Expression = try self.allocator.create(ir.Expression);
        pointer.* = expression_value;
        return pointer;
    }

    fn none(self: *Checker, kind: Kind) Error!Value {
        return .{ .node = try self.node(.{ .kind = kind, .op = .nil }) };
    }

    fn refinement(self: *Checker, symbol: *Symbol, kind: Kind) Error![]const Refinement {
        return self.allocator.dupe(Refinement, &.{.{ .symbol = symbol, .kind = kind, .version = symbol.version }});
    }

    fn join(self: *Checker, left: Kind, right: Kind, offset: usize) Error!Kind {
        const kind: Kind = try self.types.join(left, right);
        if (kind == .invalid) return self.fail(offset, "cannot form a union containing void or an unresolved type");
        return kind;
    }

    fn storage(self: *Checker, kind: Kind) Error!Kind {
        return self.types.storage(kind);
    }

    fn dictionaryKey(self: *Checker, kind: Kind, offset: usize) Error!void {
        const stored: Kind = try self.storage(kind);
        if (stored != .string and stored != .number) return self.fail(offset, "dictionary keys must be strings or numbers");
    }

    fn resolveType(self: *Checker, annotation: ast.Type) Error!Kind {
        return switch (annotation.data) {
            .name => |name| blk: {
                if (std.mem.eql(u8, name, "number")) break :blk .number;
                if (std.mem.eql(u8, name, "boolean")) break :blk .boolean;
                if (std.mem.eql(u8, name, "string")) break :blk .string;
                if (std.mem.eql(u8, name, "Input")) break :blk .input;
                if (std.mem.eql(u8, name, "Files")) break :blk .files;
                var index: usize = self.aliases.items.len;
                while (index != 0) {
                    index -= 1;
                    if (std.mem.eql(u8, name, self.aliases.items[index].name)) break :blk self.aliases.items[index].kind;
                }
                break :blk self.fail(annotation.offset, "unsupported type; expected a primitive type, capability, or known type alias");
            },
            .nil => .nil,
            .void => .void,
            .boolean_literal => |value| self.types.booleanLiteral(value),
            .string_literal => |text| self.types.stringLiteral(text),
            .array => |element| blk: {
                const element_kind: Kind = try self.resolveType(element.*);
                if (self.types.acceptsNil(element_kind)) break :blk self.fail(annotation.offset, "array elements cannot be optional");
                break :blk self.types.array(element_kind);
            },
            .table => |table| blk: {
                const fields: []type_system.Field = try self.allocator.alloc(type_system.Field, table.fields.len);
                for (table.fields, fields) |field, *resolved| resolved.* = .{ .name = field.name, .kind = try self.resolveType(field.value) };
                if (table.indexer) |indexer| {
                    if (fields.len != 0) break :blk self.fail(annotation.offset, "records with indexers are not supported");
                    const key: Kind = try self.resolveType(indexer.key);
                    try self.dictionaryKey(key, indexer.key.offset);
                    break :blk self.types.add(.{ .dictionary = .{ .key = key, .value = try self.resolveType(indexer.value) } });
                }
                break :blk self.types.add(.{ .record = .{ .fields = fields } });
            },
            .function => |function| blk: {
                const parameters: []Kind = try self.allocator.alloc(Kind, function.parameters.len);
                for (function.parameters, parameters) |parameter, *kind| kind.* = try self.resolveType(parameter);
                break :blk self.types.functionKind(parameters, try self.resolveType(function.result.*));
            },
            .optional => |inner| (try self.resolveType(inner.*)).optional(),
            .union_type => |pair| self.join(try self.resolveType(pair.left.*), try self.resolveType(pair.right.*), annotation.offset),
        };
    }

    fn literalOf(value: Value) ?type_system.Literal {
        if (value.literal) |text| return .{ .string = text };
        if (value.boolean_literal) |boolean| return .{ .boolean = boolean };
        return null;
    }

    fn literalKind(self: *Checker, value: Value) Error!Kind {
        if (value.literal) |literal| return self.types.stringLiteral(literal);
        if (value.boolean_literal) |literal| return self.types.booleanLiteral(literal);
        return value.kind();
    }

    fn asKind(self: *Checker, value: Value, expected: Kind) Error!Value {
        if (value.kind() == expected) return value;
        var result: Value = value;
        if ((try self.storage(value.kind())) == (try self.storage(expected))) {
            var copy: ir.Expression = value.node.*;
            copy.kind = expected;
            result.node = try self.node(copy);
        } else result.node = try self.node(.{ .kind = expected, .effect = value.node.effect, .op = .{ .convert = value.node } });
        return result;
    }

    fn require(self: *Checker, actual: Kind, expected: Kind, offset: usize) Error!void {
        if (!(try self.types.assignable(actual, expected))) return self.fail(offset, try std.fmt.allocPrint(self.allocator, "type mismatch: expected {s}, got {s}", .{ self.types.category(expected) orelse "structured type", self.types.category(actual) orelse "union or structured type" }));
    }

    fn convert(self: *Checker, value: Value, expected: Kind, offset: usize) Error!Value {
        if (!(try self.types.convertible(value.kind(), expected))) return self.fail(offset, "incompatible value representations; use a shared type alias");
        return self.asKind(value, expected);
    }

    fn coerce(self: *Checker, value: Value, expected: Kind, offset: usize) Error!Value {
        try self.require(try self.literalKind(value), expected, offset);
        return self.convert(value, expected, offset);
    }

    fn requireCondition(self: *Checker, value: Value, offset: usize) Error!void {
        if (value.kind() == .void) return self.fail(offset, "cannot use a void value as a condition");
    }

    fn printable(self: *Checker, kind: Kind) Error!bool {
        const stored: Kind = try self.storage(kind);
        if (stored == .nil) return true;
        const base: Kind = stored.base();
        if (base == .number or base == .boolean or base == .string) return true;
        const members: []const Kind = self.types.variants(base);
        if (members.len == 0) return false;
        for (members) |member| {
            if (!(try self.printable(member))) return false;
        }
        return true;
    }

    fn findBinding(self: *Checker, name: []const u8) ?*Symbol {
        var index: usize = self.bindings.items.len;
        while (index != 0) {
            index -= 1;
            if (std.mem.eql(u8, name, self.bindings.items[index].name)) return self.bindings.items[index];
        }
        return null;
    }

    fn lookup(self: *Checker, name: []const u8, offset: usize) Error!*Symbol {
        if (self.findBinding(name)) |symbol| return symbol;
        return self.fail(offset, try std.fmt.allocPrint(self.allocator, "unknown name '{s}'", .{name}));
    }

    fn builtinNamespace(self: *Checker, expression_value: *const ast.Expression) ?[]const u8 {
        if (expression_value.data != .name) return null;
        const name: []const u8 = expression_value.data.name;
        if (self.findBinding(name) != null) return null;
        for ([_][]const u8{ "string", "table", "math" }) |namespace| {
            if (std.mem.eql(u8, name, namespace)) return name;
        }
        return null;
    }

    fn currentKind(self: *Checker, symbol: *Symbol) Kind {
        var index: usize = self.refinements.items.len;
        while (index != 0) {
            index -= 1;
            const item: Refinement = self.refinements.items[index];
            if (item.symbol == symbol and item.version == symbol.version) return item.kind;
        }
        return symbol.kind;
    }

    fn capture(self: *Checker, symbol: *Symbol) Error!void {
        for (self.frames.items) |frame| {
            if (frame.depth <= symbol.depth) continue;
            symbol.binding.captured = true;
            if (std.mem.indexOfScalar(*const ir.Binding, frame.captures.items, symbol.binding) == null) try frame.captures.append(self.allocator, symbol.binding);
        }
    }

    fn bindingValue(self: *Checker, symbol: *Symbol, assignment_target: bool, offset: usize) Error!Value {
        if (!symbol.initialized and symbol.depth == self.depth and !assignment_target) return self.fail(offset, "local used before initialization");
        if (self.initializer) |dependencies| {
            try dependencies.append(self.allocator, symbol);
        } else symbol.root = true;
        try self.capture(symbol);
        const kind: Kind = self.currentKind(symbol);
        const resolved: Kind = self.types.resolve(kind);
        const optional: bool = resolved.acceptsNil() and resolved != .nil;
        return .{
            .node = try self.node(.{ .kind = kind, .op = .{ .read = symbol.binding } }),
            .symbol = symbol,
            .when_true = if (optional) try self.refinement(symbol, resolved.base()) else &.{},
            .when_false = if (optional and resolved.base() != .boolean) try self.refinement(symbol, .nil) else &.{},
        };
    }

    fn stringKey(self: *Checker, name: []const u8) Error!Value {
        return .{ .node = try self.node(.{ .kind = .string, .op = .{ .string = name } }), .literal = name };
    }

    fn printNode(self: *Checker, arguments: []const Value, offset: usize) Error!Value {
        const items: []*const ir.Expression = try self.allocator.alloc(*const ir.Expression, arguments.len);
        for (arguments, items) |argument, *item| {
            if (argument.kind() == .void) return self.fail(offset, "cannot print a void value");
            if (!(try self.printable(argument.kind()))) return self.fail(offset, "cannot print a table or function value");
            item.* = argument.node;
        }
        return .{ .node = try self.node(.{ .kind = .void, .effect = true, .op = .{ .print = items } }), .called = true };
    }

    fn describe(self: *Checker, name: []const u8, value: Value, offset: usize) Error!Value {
        if (std.mem.eql(u8, name, "tostring")) {
            if (!(try self.printable(value.kind()))) return self.fail(offset, "cannot convert a table or function value to a string");
            return .{ .node = try self.node(.{ .kind = .string, .effect = value.node.effect, .op = .{ .to_string = value.node } }), .called = true };
        }
        if (value.kind() == .void) return self.fail(offset, "cannot inspect a void value");
        return .{ .node = try self.node(.{ .kind = .string, .effect = value.node.effect, .op = .{ .type_name = value.node } }), .type_symbol = value.symbol, .called = true };
    }

    fn expression(self: *Checker, source: *const ast.Expression, expected: ?Kind) Error!Value {
        const offset: usize = source.offset;
        switch (source.data) {
            .nil => return self.none(.nil),
            .boolean => |boolean| return .{ .node = try self.node(.{ .kind = .boolean, .op = .{ .boolean = boolean } }), .boolean_literal = boolean },
            .number => |number| return .{ .node = try self.node(.{ .kind = .number, .op = .{ .number = number } }) },
            .string => |text| return self.stringKey(text),
            .name => |name| {
                if (self.builtinNamespace(source) != null) return self.fail(offset, "expected '.'");
                if (self.findBinding(name) == null) {
                    for ([_][]const u8{ "print", "type", "typeof", "tostring" }) |builtin_name| {
                        if (std.mem.eql(u8, name, builtin_name)) return self.builtinReference(name, expected, offset);
                    }
                }
                return self.bindingValue(try self.lookup(name, offset), false, offset);
            },
            .unary => |unary| {
                const operand: Value = try self.expression(unary.operand, expected);
                const effect: bool = operand.node.effect;
                switch (unary.operator) {
                    .not => {
                        try self.requireCondition(operand, offset);
                        return .{ .node = try self.node(.{ .kind = .boolean, .effect = effect, .op = .{ .not = operand.node } }), .when_true = operand.when_false, .when_false = operand.when_true };
                    },
                    .length => {
                        const resolved: Kind = self.types.resolve(operand.kind());
                        if (self.types.element(resolved) == null or resolved.acceptsNil()) try self.require(operand.kind(), .string, offset);
                        return .{ .node = try self.node(.{ .kind = .number, .effect = effect, .op = .{ .length = operand.node } }) };
                    },
                    .negate => {
                        const number: Value = try self.coerce(operand, .number, offset);
                        return .{ .node = try self.node(.{ .kind = .number, .effect = effect, .op = .{ .negate = number.node } }) };
                    },
                }
            },
            .binary => |binary_value| {
                const operator: []const u8 = binary_value.operator;
                const is_and: bool = std.mem.eql(u8, operator, "and");
                const is_or: bool = std.mem.eql(u8, operator, "or");
                const left: Value = try self.expression(binary_value.left, expected);
                const saved_refinements: usize = self.refinements.items.len;
                if (is_and) {
                    try self.refinements.appendSlice(self.allocator, left.when_true);
                } else if (is_or) try self.refinements.appendSlice(self.allocator, left.when_false);
                var discarded: std.ArrayListUnmanaged(*Symbol) = .{};
                const saved_initializer: ?*std.ArrayListUnmanaged(*Symbol) = self.initializer;
                if (left.kind() == .nil and is_and) self.initializer = &discarded;
                const right: Value = try self.expression(binary_value.right, expected);
                self.initializer = saved_initializer;
                self.refinements.shrinkRetainingCapacity(saved_refinements);
                var result: Value = try self.binary(operator, left, right, offset);
                if (is_and) {
                    result.when_true = try std.mem.concat(self.allocator, Refinement, &.{ left.when_true, right.when_true });
                    result.when_false = &.{};
                } else if (is_or) {
                    result.when_true = &.{};
                    result.when_false = try std.mem.concat(self.allocator, Refinement, &.{ left.when_false, right.when_false });
                }
                return result;
            },
            .if_expression => |branch| return self.ifExpression(branch.condition, branch.then, branch.otherwise, expected, offset),
            .function => |function_value| return self.functionExpression(function_value, null, expected),
            .table => |entries| return self.tableConstructor(entries, expected, offset),
            .call => |call_value| {
                if (call_value.callee.data == .name and self.findBinding(call_value.callee.data.name) == null) {
                    const name: []const u8 = call_value.callee.data.name;
                    if (self.builtinNamespace(call_value.callee) != null) return self.fail(call_value.callee.offset, "expected '.'");
                    const describing: bool = std.mem.eql(u8, name, "tostring") or std.mem.eql(u8, name, "type") or std.mem.eql(u8, name, "typeof");
                    if (describing or std.mem.eql(u8, name, "print")) {
                        const arguments: []Value = try self.allocator.alloc(Value, call_value.arguments.len);
                        for (call_value.arguments, arguments) |*argument, *value| value.* = try self.expression(argument, expected);
                        if (!describing) return self.printNode(arguments, offset);
                        if (arguments.len != 1) return self.fail(offset, "incorrect number of builtin arguments");
                        return self.describe(name, arguments[0], offset);
                    }
                }
                if (call_value.callee.data == .field) {
                    const field: []const u8 = call_value.callee.data.field.name;
                    if (self.builtinNamespace(call_value.callee.data.field.table)) |namespace| {
                        if (std.mem.eql(u8, namespace, "math") and std.mem.eql(u8, field, "huge")) return self.call(.{ .node = try self.node(.{ .kind = .number, .op = .{ .number = std.math.inf(f64) } }) }, call_value.arguments, offset);
                        const arguments: []Value = try self.allocator.alloc(Value, call_value.arguments.len);
                        for (call_value.arguments, arguments) |*argument, *value| value.* = try self.expression(argument, expected);
                        return self.builtinCall(try self.builtin(namespace, field, offset), field, arguments, offset);
                    }
                }
                return self.call(try self.expression(call_value.callee, expected), call_value.arguments, offset);
            },
            .method => |method| {
                const object: Value = try self.expression(method.object, expected);
                const stored: Kind = try self.storage(object.kind());
                if (stored == .optional_input or stored == .optional_files) return self.fail(offset, "cannot call a method on an optional capability");
                if (stored != .input and stored != .files) return self.fail(offset, "method calls are only supported on capabilities");
                const arguments: []Value = try self.allocator.alloc(Value, method.arguments.len);
                for (method.arguments, arguments) |*argument_source, *argument| argument.* = try self.expression(argument_source, null);
                const name: []const u8 = method.name;
                var kind: Kind = .optional_string;
                var count: usize = 1;
                var op: ir.Op = undefined;
                if (stored == .input and std.mem.eql(u8, name, "readLine")) {
                    count = 0;
                    op = .{ .read_line = object.node };
                } else if (stored == .input and std.mem.eql(u8, name, "readAll")) {
                    count = 0;
                    kind = .string;
                    op = .{ .read_all = object.node };
                } else if (stored == .input and std.mem.eql(u8, name, "read")) {
                    if (arguments.len != 1) return self.fail(offset, "incorrect number of method arguments");
                    op = .{ .read_count = .{ .left = object.node, .right = (try self.coerce(arguments[0], .number, offset)).node } };
                } else if (stored == .files and std.mem.eql(u8, name, "read")) {
                    if (arguments.len != 1) return self.fail(offset, "incorrect number of method arguments");
                    op = .{ .read_file = .{ .left = object.node, .right = (try self.coerce(arguments[0], .string, offset)).node } };
                } else return self.fail(offset, try std.fmt.allocPrint(self.allocator, "unknown {s} method '{s}'", .{ if (stored == .input) "Input" else "Files", name }));
                if (arguments.len != count) return self.fail(offset, "incorrect number of method arguments");
                return .{ .node = try self.node(.{ .kind = kind, .effect = true, .op = op }), .called = true };
            },
            .index => |access| {
                const container: Value = try self.expression(access.table, expected);
                return self.indexed(container, try self.expression(access.key, expected), null, offset);
            },
            .field => |access| {
                if (self.builtinNamespace(access.table)) |namespace| {
                    if (std.mem.eql(u8, namespace, "math") and std.mem.eql(u8, access.name, "huge")) return .{ .node = try self.node(.{ .kind = .number, .op = .{ .number = std.math.inf(f64) } }) };
                    return self.builtinReference(@tagName(try self.builtin(namespace, access.name, offset)), expected, offset);
                }
                const container: Value = try self.expression(access.table, expected);
                return self.indexed(container, try self.stringKey(access.name), access.name, offset);
            },
            .assertion => |assertion| {
                const value: Value = try self.expression(assertion.value, expected);
                const kind: Kind = try self.resolveType(assertion.annotation);
                if (!(try self.types.assignable(try self.literalKind(value), kind)) and !(try self.types.assignable(kind, value.kind()))) return self.fail(offset, "incompatible type assertion");
                return self.convert(value, kind, offset);
            },
            .group => |inner| return self.expression(inner, expected),
        }
    }

    fn binary(self: *Checker, operator: []const u8, left_input: Value, right_input: Value, offset: usize) Error!Value {
        var left: Value = left_input;
        var right: Value = right_input;
        var kind: Kind = .boolean;
        var op: ir.Op = undefined;
        if (std.mem.eql(u8, operator, "and") or std.mem.eql(u8, operator, "or")) {
            const is_or: bool = std.mem.eql(u8, operator, "or");
            if (left.kind() == .nil) return if (is_or) right else self.none(.nil);
            if ((try self.storage(left.kind())) != .boolean or (try self.storage(right.kind())) != .boolean) {
                const resolved: Kind = self.types.resolve(left.kind());
                const present: Kind = resolved.base();
                if (is_or) {
                    kind = try self.join(present, right.kind(), offset);
                    if (!(try self.types.convertible(present, kind))) return self.fail(offset, "incompatible value representations in 'or'");
                } else {
                    const falsy: ?Kind = if ((try self.storage(present)) == .boolean) left.kind() else if (resolved.acceptsNil()) .nil else null;
                    kind = if (falsy) |value| try self.join(value, right.kind(), offset) else right.kind();
                    if (falsy) |value| {
                        if (!(try self.types.convertible(value, kind))) return self.fail(offset, "incompatible value representations in 'and'");
                    }
                }
                right = try self.convert(right, kind, offset);
            }
            op = .{ .logic = .{ .is_or = is_or, .left = left.node, .right = right.node } };
        } else if (std.mem.eql(u8, operator, "==") or std.mem.eql(u8, operator, "~=")) {
            if (left.kind() == .void or right.kind() == .void) return self.fail(offset, "cannot compare void values");
            const left_storage: Kind = try self.storage(left.kind());
            const right_storage: Kind = try self.storage(right.kind());
            if (left_storage != right_storage) {
                if (right_storage.acceptsNil() and try self.types.convertible(left.kind(), right.kind()) and try self.types.assignable(try self.literalKind(left), right.kind())) {
                    left = try self.asKind(left, right.kind());
                } else if (left_storage.acceptsNil() and try self.types.convertible(right.kind(), left.kind()) and try self.types.assignable(try self.literalKind(right), left.kind())) {
                    right = try self.asKind(right, left.kind());
                }
            }
            const compared: Kind = try self.storage(left.kind());
            if (compared == (try self.storage(right.kind())) and self.types.variants(compared.base()).len != 0) return self.fail(offset, "cannot compare union values");
            op = .{ .equal = .{ .negate = std.mem.eql(u8, operator, "~="), .left = left.node, .right = right.node } };
        } else if (std.mem.eql(u8, operator, "..")) {
            for ([_]Value{ left, right }) |operand| {
                const stored: Kind = try self.storage(operand.kind());
                if (stored != .string and stored != .number) return self.fail(offset, "concatenation requires strings or numbers");
            }
            kind = .string;
            op = .{ .concat = .{ .left = left.node, .right = right.node } };
        } else if (std.mem.indexOfScalar(u8, "<>", operator[0]) != null and (try self.storage(left.kind())) == .string and (try self.storage(right.kind())) == .string) {
            op = .{ .compare = .{ .operator = operator, .left = left.node, .right = right.node } };
        } else {
            left = try self.coerce(left, .number, offset);
            right = try self.coerce(right, .number, offset);
            if (std.mem.indexOfScalar(u8, "<>", operator[0]) != null) {
                op = .{ .compare = .{ .operator = operator, .left = left.node, .right = right.node } };
            } else {
                kind = .number;
                op = .{ .arithmetic = .{ .operator = operator, .left = left.node, .right = right.node } };
            }
        }
        var result: Value = .{ .node = try self.node(.{ .kind = kind, .effect = left.node.effect or right.node.effect, .op = op }) };
        if (std.mem.eql(u8, operator, "==") or std.mem.eql(u8, operator, "~=")) {
            const unequal: bool = std.mem.eql(u8, operator, "~=");
            const symbol: ?*Symbol = if (left_input.kind() == .nil) right.symbol else if (right_input.kind() == .nil) left.symbol else null;
            if (symbol) |optional_symbol| {
                if (self.types.acceptsNil(optional_symbol.kind)) {
                    const present: Kind = self.types.resolve(optional_symbol.kind).base();
                    result.when_true = try self.refinement(optional_symbol, if (unequal) present else .nil);
                    result.when_false = try self.refinement(optional_symbol, if (unequal) .nil else present);
                }
            }
            const right_literal: ?type_system.Literal = literalOf(right);
            const tested: Value = if (right_literal != null) left else right;
            if (right_literal orelse literalOf(left)) |text| {
                if (tested.access_symbol orelse tested.type_symbol) |owner| {
                    if (try self.types.filter(self.currentKind(owner), tested.access_field, text, !unequal)) |filtered| result.when_true = try self.refinement(owner, filtered);
                    if (try self.types.filter(self.currentKind(owner), tested.access_field, text, unequal)) |filtered| result.when_false = try self.refinement(owner, filtered);
                }
            }
        }
        return result;
    }

    fn ifExpression(self: *Checker, condition_source: *const ast.Expression, then_source: *const ast.Expression, otherwise_source: *const ast.Expression, expected: ?Kind, offset: usize) Error!Value {
        const condition: Value = try self.expression(condition_source, expected);
        try self.requireCondition(condition, offset);
        const saved_refinements: usize = self.refinements.items.len;
        try self.refinements.appendSlice(self.allocator, condition.when_true);
        const then_value: Value = try self.expression(then_source, expected);
        self.refinements.shrinkRetainingCapacity(saved_refinements);
        try self.refinements.appendSlice(self.allocator, condition.when_false);
        const otherwise_value: Value = try self.expression(otherwise_source, expected);
        self.refinements.shrinkRetainingCapacity(saved_refinements);
        if (then_value.kind() == .void or otherwise_value.kind() == .void) return self.fail(offset, "if expression branches must produce values");
        const kind: Kind = try self.join(then_value.kind(), otherwise_value.kind(), offset);
        return .{ .node = try self.node(.{
            .kind = kind,
            .effect = condition.node.effect or then_value.node.effect or otherwise_value.node.effect,
            .op = .{ .if_expression = .{ .condition = condition.node, .then = (try self.coerce(then_value, kind, offset)).node, .otherwise = (try self.coerce(otherwise_value, kind, offset)).node } },
        }) };
    }

    fn indexed(self: *Checker, container: Value, key_input: Value, property: ?[]const u8, offset: usize) Error!Value {
        const resolved: Kind = self.types.resolve(container.kind());
        if (resolved.acceptsNil()) return self.fail(offset, "cannot index an optional array or table");
        const structure: ?type_system.Type = self.types.get(try self.storage(resolved));
        const effect: bool = container.node.effect or key_input.node.effect;
        const place: *Place = try self.allocator.create(Place);
        var result: Value = undefined;
        if (self.types.element(resolved)) |element| {
            if (property != null) return self.fail(offset, "arrays have no fields");
            const key: Value = try self.coerce(key_input, .number, offset);
            place.* = .{ .container = container, .key = key, .field = null, .write = element };
            result = .{ .node = try self.node(.{ .kind = element.optional(), .effect = effect, .op = .{ .index = .{ .left = container.node, .right = key.node } } }), .place = place };
        } else if (structure != null and structure.? == .dictionary) {
            const entry: type_system.Indexer = self.types.indexer(resolved).?;
            const key: Value = try self.coerce(key_input, entry.key, offset);
            place.* = .{ .container = container, .key = key, .field = null, .write = entry.value.optional() };
            result = .{ .node = try self.node(.{ .kind = entry.value.optional(), .effect = effect, .op = .{ .index = .{ .left = container.node, .right = key.node } } }), .place = place };
        } else if (structure != null and (structure.? == .record or structure.? == .union_type)) {
            const name: []const u8 = property orelse key_input.literal orelse return self.fail(offset, "records can only be indexed by field name");
            const declared: Kind = (try self.types.field(resolved, name)) orelse return self.fail(offset, try std.fmt.allocPrint(self.allocator, "unknown record field '{s}'", .{name}));
            place.* = .{ .container = container, .key = key_input, .field = name, .write = declared };
            result = .{ .node = try self.node(.{ .kind = declared, .effect = effect, .op = .{ .field = .{ .value = container.node, .name = name } } }), .place = if (structure.? == .record) place else null };
        } else return self.fail(offset, "indexing requires an array, dictionary, or record");
        result.access_symbol = container.symbol;
        result.access_field = property orelse key_input.literal;
        if (container.symbol) |owner| {
            if (result.access_field != null and try self.types.assignable(result.kind(), .boolean)) {
                if (try self.types.filter(self.currentKind(owner), result.access_field, .{ .boolean = true }, true)) |filtered| result.when_true = try self.refinement(owner, filtered);
                if (try self.types.filter(self.currentKind(owner), result.access_field, .{ .boolean = true }, false)) |filtered| result.when_false = try self.refinement(owner, filtered);
            }
        }
        return result;
    }

    fn tableLike(self: *Checker, kind: Kind) bool {
        if (self.types.element(kind) != null) return true;
        const structure: type_system.Type = self.types.get(kind) orelse return false;
        return structure == .record or structure == .dictionary;
    }

    fn entryName(entry: ast.TableEntry) ?[]const u8 {
        return switch (entry) {
            .named => |item| item.name,
            .keyed => |item| if (item.key.data == .string) item.key.data.string else null,
            .positional => null,
        };
    }

    fn tableTarget(self: *Checker, entries: []const ast.TableEntry, expected: Kind, offset: usize) Error!?Kind {
        const resolved: Kind = self.types.resolve(expected).base();
        const members: []const Kind = self.types.variants(resolved);
        if (members.len == 0) return if (self.tableLike(resolved)) resolved else null;
        var chosen: ?Kind = null;
        candidates: for (members) |member_kind| {
            const member: Kind = self.types.resolve(member_kind);
            if (!self.tableLike(member)) continue;
            if (self.types.get(member) != null and self.types.get(member).? == .record) {
                for (entries) |entry| {
                    const name: []const u8 = entryName(entry) orelse continue;
                    const value: ast.Expression = switch (entry) {
                        .named => |item| item.value,
                        .keyed => |item| item.value,
                        .positional => unreachable,
                    };
                    const field: Kind = (try self.types.field(member, name)) orelse continue :candidates;
                    const literal: ?type_system.Type = self.types.get(self.types.resolve(field));
                    if (literal == null) continue;
                    switch (value.data) {
                        .string => |text| if (literal.? == .string_literal and !std.mem.eql(u8, literal.?.string_literal, text)) continue :candidates,
                        .boolean => |boolean| if (literal.? == .boolean_literal and literal.?.boolean_literal != boolean) continue :candidates,
                        else => {},
                    }
                }
            }
            if (chosen != null) return self.fail(offset, "ambiguous table literal for union; add a literal tag field");
            chosen = member;
        }
        return chosen orelse self.fail(offset, "table literal matches no member of the expected union");
    }

    fn tableConstructor(self: *Checker, entries: []const ast.TableEntry, expected: ?Kind, offset: usize) Error!Value {
        if (expected) |kind| {
            if (try self.tableTarget(entries, kind, offset)) |target| return self.tableAs(entries, target, offset);
        }
        return self.tableInferred(entries, offset);
    }

    fn arrayItem(self: *Checker, source: *const ast.Expression, expected: ?Kind) Error!Value {
        const value: Value = try self.expression(source, expected);
        if (value.kind() == .void) return self.fail(source.offset, "table fields cannot contain void values");
        if (self.types.acceptsNil(value.kind())) return self.fail(source.offset, "array literals cannot contain nil");
        return value;
    }

    fn tableAs(self: *Checker, entries: []const ast.TableEntry, target: Kind, offset: usize) Error!Value {
        var effect: bool = false;
        if (self.types.element(target)) |element| {
            const items: []*const ir.Expression = try self.allocator.alloc(*const ir.Expression, entries.len);
            for (entries, items) |*entry, *item| {
                if (entry.* != .positional) return self.fail(offset, "array literals only take positional items");
                const value: Value = try self.coerce(try self.arrayItem(&entry.positional, element), element, entry.positional.offset);
                effect = effect or value.node.effect;
                item.* = value.node;
            }
            return .{ .node = try self.node(.{ .kind = target, .effect = effect, .op = .{ .array = items } }) };
        }
        switch (self.types.get(target).?) {
            .dictionary => |entry| {
                const pairs: []ir.Pair = try self.allocator.alloc(ir.Pair, entries.len);
                for (entries, pairs) |*source, *pair| {
                    if (source.* == .positional) return self.fail(offset, "dictionary literals need keys");
                    const key: Value = if (source.* == .named) try self.stringKey(source.named.name) else try self.expression(&source.keyed.key, entry.key);
                    const value_source: *const ast.Expression = if (source.* == .named) &source.named.value else &source.keyed.value;
                    const value: Value = try self.coerce(try self.expression(value_source, entry.value), entry.value, value_source.offset);
                    const converted_key: Value = try self.coerce(key, entry.key, offset);
                    effect = effect or converted_key.node.effect or value.node.effect;
                    pair.* = .{ .left = converted_key.node, .right = value.node };
                }
                return .{ .node = try self.node(.{ .kind = target, .effect = effect, .op = .{ .dictionary = pairs } }) };
            },
            .record => |record| {
                const provided: []?*const ir.Expression = try self.allocator.alloc(?*const ir.Expression, record.fields.len);
                @memset(provided, null);
                for (entries) |*source| {
                    const name: []const u8 = entryName(source.*) orelse return self.fail(offset, "record literals need field names");
                    const value_source: *const ast.Expression = switch (source.*) {
                        .named => |*item| &item.value,
                        .keyed => |*item| &item.value,
                        .positional => unreachable,
                    };
                    const index: usize = for (record.fields, 0..) |field, position| {
                        if (std.mem.eql(u8, field.name, name)) break position;
                    } else return self.fail(value_source.offset, try std.fmt.allocPrint(self.allocator, "unknown record field '{s}'", .{name}));
                    if (provided[index] != null) return self.fail(value_source.offset, "duplicate record field");
                    const value: Value = try self.coerce(try self.expression(value_source, record.fields[index].kind), record.fields[index].kind, value_source.offset);
                    effect = effect or value.node.effect;
                    provided[index] = value.node;
                }
                const fields: []ir.Field = try self.allocator.alloc(ir.Field, record.fields.len);
                for (record.fields, provided, fields) |field, value, *item| {
                    const resolved_value: *const ir.Expression = value orelse if (self.types.acceptsNil(field.kind)) (try self.convert(try self.none(.nil), field.kind, offset)).node else return self.fail(offset, try std.fmt.allocPrint(self.allocator, "missing record field '{s}'", .{field.name}));
                    item.* = .{ .name = field.name, .value = resolved_value };
                }
                return .{ .node = try self.node(.{ .kind = target, .effect = effect, .op = .{ .record = fields } }) };
            },
            else => unreachable,
        }
    }

    fn tableInferred(self: *Checker, entries: []const ast.TableEntry, offset: usize) Error!Value {
        if (entries.len == 0) return self.fail(offset, "empty table needs a type annotation");
        var positional: usize = 0;
        var named: usize = 0;
        for (entries) |entry| {
            if (entry == .positional) positional += 1 else if (entryName(entry) != null) named += 1;
        }
        var effect: bool = false;
        if (positional == entries.len) {
            const values: []Value = try self.allocator.alloc(Value, entries.len);
            var element: ?Kind = null;
            for (entries, values) |*entry, *value| {
                value.* = try self.arrayItem(&entry.positional, null);
                element = if (element) |previous| try self.join(previous, value.kind(), offset) else value.kind();
            }
            const items: []*const ir.Expression = try self.allocator.alloc(*const ir.Expression, entries.len);
            for (values, items) |value, *item| {
                const converted: Value = try self.coerce(value, element.?, offset);
                effect = effect or converted.node.effect;
                item.* = converted.node;
            }
            return .{ .node = try self.node(.{ .kind = try self.types.array(element.?), .effect = effect, .op = .{ .array = items } }) };
        }
        if (positional != 0) return self.fail(offset, "tables cannot mix array items and fields");
        if (named == entries.len) {
            const fields: []type_system.Field = try self.allocator.alloc(type_system.Field, entries.len);
            const values: []ir.Field = try self.allocator.alloc(ir.Field, entries.len);
            for (entries, fields, values, 0..) |*entry, *field, *item, index| {
                const name: []const u8 = entryName(entry.*).?;
                for (fields[0..index]) |previous| {
                    if (std.mem.eql(u8, previous.name, name)) return self.fail(offset, "duplicate record field");
                }
                const value: Value = try self.fieldValue(entry);
                effect = effect or value.node.effect;
                field.* = .{ .name = name, .kind = try self.literalKind(value) };
                item.* = .{ .name = name, .value = value.node };
            }
            return .{ .node = try self.node(.{ .kind = try self.types.add(.{ .record = .{ .fields = fields } }), .effect = effect, .op = .{ .record = values } }) };
        }
        const keys: []Value = try self.allocator.alloc(Value, entries.len);
        const values: []Value = try self.allocator.alloc(Value, entries.len);
        var key_kind: ?Kind = null;
        var value_kind: ?Kind = null;
        for (entries, keys, values) |*entry, *key, *value| {
            key.* = switch (entry.*) {
                .named => |item| try self.stringKey(item.name),
                .keyed => |*item| try self.expression(&item.key, null),
                .positional => unreachable,
            };
            value.* = try self.fieldValue(entry);
            key_kind = if (key_kind) |previous| try self.join(previous, key.kind(), offset) else key.kind();
            value_kind = if (value_kind) |previous| try self.join(previous, value.kind(), offset) else value.kind();
        }
        try self.dictionaryKey(key_kind.?, offset);
        const kind: Kind = try self.types.dictionaryOf(key_kind.?, value_kind.?);
        const pairs: []ir.Pair = try self.allocator.alloc(ir.Pair, entries.len);
        for (keys, values, pairs) |key, value, *pair| {
            const converted_key: Value = try self.coerce(key, key_kind.?, offset);
            const converted_value: Value = try self.coerce(value, value_kind.?, offset);
            effect = effect or converted_key.node.effect or converted_value.node.effect;
            pair.* = .{ .left = converted_key.node, .right = converted_value.node };
        }
        return .{ .node = try self.node(.{ .kind = kind, .effect = effect, .op = .{ .dictionary = pairs } }) };
    }

    fn fieldValue(self: *Checker, entry: *const ast.TableEntry) Error!Value {
        const source: *const ast.Expression = if (entry.* == .named) &entry.named.value else &entry.keyed.value;
        const value: Value = try self.expression(source, null);
        if (value.kind() == .void) return self.fail(source.offset, "table fields cannot contain void values");
        return value;
    }

    fn builtin(self: *Checker, namespace: []const u8, member: []const u8, offset: usize) Error!Builtin {
        const qualified: []const u8 = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ namespace, member });
        return std.meta.stringToEnum(Builtin, qualified) orelse self.fail(offset, try std.fmt.allocPrint(self.allocator, "unsupported builtin '{s}'", .{qualified}));
    }

    fn builtinReference(self: *Checker, name: []const u8, expected_kind: ?Kind, offset: usize) Error!Value {
        const expected: ?type_system.Function = if (expected_kind) |kind| self.types.function(kind) else null;
        var parameters: []const Kind = undefined;
        var result: Kind = .string;
        if (std.mem.eql(u8, name, "math.abs") or std.mem.eql(u8, name, "math.floor") or std.mem.eql(u8, name, "math.ceil")) {
            parameters = &.{.number};
            result = .number;
        } else if (std.mem.eql(u8, name, "string.lower") or std.mem.eql(u8, name, "string.upper")) {
            parameters = &.{.string};
        } else if (std.mem.eql(u8, name, "string.sub")) {
            const count: usize = if (expected) |function| function.parameters.len else 3;
            if (count < 2 or count > 3) return self.fail(offset, "incorrect builtin function type arity");
            parameters = (&[_]Kind{ .string, .number, .optional_number })[0..count];
        } else if (std.mem.eql(u8, name, "string.byte")) {
            const count: usize = if (expected) |function| function.parameters.len else 2;
            if (count < 1 or count > 2) return self.fail(offset, "incorrect builtin function type arity");
            parameters = (&[_]Kind{ .string, .optional_number })[0..count];
            result = .optional_number;
        } else if (std.mem.eql(u8, name, "string.char")) {
            const count: usize = if (expected) |function| function.parameters.len else 1;
            const kinds: []Kind = try self.allocator.alloc(Kind, count);
            @memset(kinds, .number);
            parameters = kinds;
        } else if (std.mem.startsWith(u8, name, "table.")) {
            const function: type_system.Function = expected orelse return self.fail(offset, "table builtin references need a function type annotation");
            if (function.parameters.len == 0) return self.fail(offset, "table builtin function needs an array parameter");
            const array_kind: Kind = function.parameters[0];
            const element: Kind = self.types.element(array_kind) orelse return self.fail(offset, "table builtin function needs an array parameter");
            const kinds: []Kind = try self.allocator.alloc(Kind, function.parameters.len);
            kinds[0] = array_kind;
            if (std.mem.eql(u8, name, "table.insert")) {
                if (kinds.len < 2 or kinds.len > 3) return self.fail(offset, "incorrect builtin function type arity");
                if (kinds.len == 3) kinds[1] = .optional_number;
                kinds[kinds.len - 1] = element;
                result = .void;
            } else if (std.mem.eql(u8, name, "table.remove")) {
                if (kinds.len > 2) return self.fail(offset, "incorrect builtin function type arity");
                if (kinds.len == 2) kinds[1] = .optional_number;
                result = element.optional();
            } else {
                if (kinds.len > 4) return self.fail(offset, "incorrect builtin function type arity");
                if (kinds.len >= 2) kinds[1] = .optional_string;
                if (kinds.len >= 3) kinds[2] = .optional_number;
                if (kinds.len >= 4) kinds[3] = .optional_number;
            }
            parameters = kinds;
        } else {
            const function: type_system.Function = expected orelse return self.fail(offset, "builtin reference needs a function type annotation");
            if (std.mem.eql(u8, name, "print")) {
                result = .void;
            } else if (function.parameters.len != 1) return self.fail(offset, "incorrect builtin function type arity");
            parameters = function.parameters;
        }
        const function_id: usize = self.id();
        const bindings: []*const ir.Binding = try self.allocator.alloc(*const ir.Binding, parameters.len);
        const arguments: []Value = try self.allocator.alloc(Value, parameters.len);
        for (parameters, bindings, arguments) |kind, *binding, *argument| {
            const parameter: *ir.Binding = try self.allocator.create(ir.Binding);
            parameter.* = .{ .id = self.id(), .owner = function_id, .kind = kind, .value = (try self.none(kind)).node, .parameter = true, .live = true };
            binding.* = parameter;
            argument.* = .{ .node = try self.node(.{ .kind = kind, .op = .{ .read = parameter } }) };
        }
        const value: Value = if (std.mem.eql(u8, name, "print"))
            try self.printNode(arguments, offset)
        else if (std.mem.indexOfScalar(u8, name, '.')) |dot|
            try self.builtinCall(std.meta.stringToEnum(Builtin, name).?, name[dot + 1 ..], arguments, offset)
        else
            try self.describe(name, arguments[0], offset);
        const statement_value: ir.Statement = if (result == .void) .{ .evaluate = value.node } else .{ .@"return" = (try self.coerce(value, result, offset)).node };
        const function_value: *ir.Function = try self.allocator.create(ir.Function);
        const kind: Kind = try self.types.functionKind(parameters, result);
        function_value.* = .{ .id = function_id, .kind = kind, .parameters = bindings, .captures = &.{}, .body = .{ .declarations = bindings, .statements = try self.allocator.dupe(ir.Statement, &.{statement_value}) }, .falls_through = false };
        return .{ .node = try self.node(.{ .kind = kind, .op = .{ .closure = function_value } }) };
    }

    fn optionalArgument(self: *Checker, arguments: []const Value, index: usize, kind: Kind, offset: usize) Error!?*const ir.Expression {
        if (index >= arguments.len) return null;
        return (try self.coerce(arguments[index], kind, offset)).node;
    }

    fn builtinCall(self: *Checker, builtin_kind: Builtin, member: []const u8, args: []const Value, offset: usize) Error!Value {
        const minimum: usize = switch (builtin_kind) {
            .@"string.char" => 0,
            .@"string.sub", .@"table.insert" => 2,
            else => 1,
        };
        const maximum: usize = switch (builtin_kind) {
            .@"string.char" => std.math.maxInt(usize),
            .@"string.sub", .@"table.insert" => 3,
            .@"string.byte", .@"table.remove" => 2,
            .@"table.concat" => 4,
            else => 1,
        };
        if (args.len < minimum or args.len > maximum) return self.fail(offset, "incorrect number of builtin arguments");
        var kind: Kind = .string;
        var op: ir.Op = undefined;
        switch (builtin_kind) {
            .@"string.sub", .@"string.byte", .@"string.lower", .@"string.upper" => {
                const string: *const ir.Expression = (try self.coerce(args[0], .string, offset)).node;
                switch (builtin_kind) {
                    .@"string.sub" => op = .{ .string_sub = .{ .string = string, .first = (try self.coerce(args[1], .number, offset)).node, .last = try self.optionalArgument(args, 2, .optional_number, offset) } },
                    .@"string.byte" => {
                        op = .{ .string_byte = .{ .string = string, .index = try self.optionalArgument(args, 1, .optional_number, offset) } };
                        kind = .optional_number;
                    },
                    else => op = .{ .string_case = .{ .upper = builtin_kind == .@"string.upper", .string = string } },
                }
            },
            .@"string.char" => {
                const codes: []*const ir.Expression = try self.allocator.alloc(*const ir.Expression, args.len);
                for (args, codes) |argument, *code| code.* = (try self.coerce(argument, .number, offset)).node;
                op = .{ .string_char = codes };
            },
            .@"table.insert", .@"table.remove", .@"table.concat" => {
                const resolved: Kind = self.types.resolve(args[0].kind());
                const element: Kind = self.types.element(resolved) orelse return self.fail(offset, "table builtin requires an array");
                if (resolved.acceptsNil()) return self.fail(offset, "table builtin requires a nonoptional array");
                if (builtin_kind == .@"table.insert") {
                    kind = .void;
                    const position: ?*const ir.Expression = if (args.len == 3) (try self.coerce(args[1], .optional_number, offset)).node else null;
                    op = .{ .array_insert = .{ .array = args[0].node, .position = position, .value = (try self.coerce(args[args.len - 1], element, offset)).node } };
                } else if (builtin_kind == .@"table.remove") {
                    kind = element.optional();
                    op = .{ .array_remove = .{ .array = args[0].node, .position = try self.optionalArgument(args, 1, .optional_number, offset) } };
                } else {
                    const stored: Kind = try self.storage(element);
                    if (stored != .string and stored != .number) return self.fail(offset, "table.concat requires an array of strings or numbers");
                    op = .{ .table_concat = .{
                        .array = args[0].node,
                        .separator = try self.optionalArgument(args, 1, .optional_string, offset),
                        .first = try self.optionalArgument(args, 2, .optional_number, offset),
                        .last = try self.optionalArgument(args, 3, .optional_number, offset),
                    } };
                }
            },
            .@"math.floor", .@"math.ceil", .@"math.abs" => {
                kind = .number;
                op = .{ .math = .{ .name = member, .argument = (try self.coerce(args[0], .number, offset)).node } };
            },
        }
        return .{ .node = try self.node(.{ .kind = kind, .effect = true, .op = op }), .called = true };
    }

    fn call(self: *Checker, callable: Value, sources: []const ast.Expression, offset: usize) Error!Value {
        if (self.types.acceptsNil(callable.kind())) return self.fail(offset, "cannot call an optional function");
        const function: type_system.Function = self.types.function(callable.kind()) orelse return self.fail(offset, "expected a function value");
        if (sources.len > function.parameters.len) return self.fail(sources[function.parameters.len].offset, "too many function arguments");
        const arguments: []*const ir.Expression = try self.allocator.alloc(*const ir.Expression, function.parameters.len);
        for (function.parameters, arguments, 0..) |parameter, *argument, index| {
            if (index < sources.len) {
                argument.* = (try self.coerce(try self.expression(&sources[index], parameter), parameter, sources[index].offset)).node;
            } else {
                if (!self.types.acceptsNil(parameter)) return self.fail(offset, "too few function arguments");
                argument.* = (try self.convert(try self.none(.nil), parameter, offset)).node;
            }
        }
        for (self.bindings.items) |symbol| {
            if (symbol.binding.mutable) symbol.version += 1;
        }
        return .{ .node = try self.node(.{ .kind = function.result, .effect = true, .op = .{ .call = .{ .callee = callable.node, .arguments = arguments } } }), .called = true };
    }

    fn functionExpression(self: *Checker, source: *const ast.Function, recursive: ?*Symbol, expected_kind: ?Kind) Error!Value {
        const expected: ?type_system.Function = if (expected_kind) |kind| self.types.function(kind) else null;
        const function_id: usize = self.id();
        const saved: usize = self.bindings.items.len;
        defer self.bindings.shrinkRetainingCapacity(saved);
        var frame: Frame = .{ .depth = self.depth + 1 };
        try self.frames.append(self.allocator, &frame);
        defer _ = self.frames.pop();
        const parameters: []*Symbol = try self.allocator.alloc(*Symbol, source.parameters.len);
        const parameter_bindings: []*const ir.Binding = try self.allocator.alloc(*const ir.Binding, source.parameters.len);
        const parameter_kinds: []Kind = try self.allocator.alloc(Kind, source.parameters.len);
        for (source.parameters, parameters, parameter_bindings, parameter_kinds, 0..) |parameter, *symbol, *binding, *kind, index| {
            kind.* = if (parameter.annotation) |annotation| try self.resolveType(annotation) else if (expected != null and index < expected.?.parameters.len) expected.?.parameters[index] else return self.fail(parameter.offset, "function parameters need types or a function type annotation");
            const parameter_binding: *ir.Binding = try self.allocator.create(ir.Binding);
            parameter_binding.* = .{ .id = self.id(), .owner = function_id, .kind = kind.*, .value = (try self.none(kind.*)).node, .parameter = true };
            symbol.* = try self.allocator.create(Symbol);
            symbol.*.* = .{ .name = parameter.name, .kind = kind.*, .binding = parameter_binding, .depth = self.depth + 1 };
            binding.* = parameter_binding;
            try self.bindings.append(self.allocator, symbol.*);
        }
        var signature: Signature = .{};
        if (source.result) |annotation| {
            signature.result = try self.resolveType(annotation);
        } else if (expected) |function| {
            signature.result = function.result;
        } else signature.infer_result = true;
        signature.kind = try self.types.add(.{ .function = .{ .parameters = parameter_kinds, .result = signature.result } });
        if (recursive) |symbol| symbol.kind = signature.kind;
        const saved_signature: ?*Signature = self.signature;
        const saved_depth: usize = self.depth;
        const saved_loop: usize = self.loop_depth;
        const saved_owner: usize = self.owner;
        const saved_refinements: std.ArrayListUnmanaged(Refinement) = self.refinements;
        self.signature = &signature;
        self.depth += 1;
        self.loop_depth = 0;
        self.owner = function_id;
        self.refinements = .{};
        defer {
            self.signature = saved_signature;
            self.depth = saved_depth;
            self.loop_depth = saved_loop;
            self.owner = saved_owner;
            self.refinements = saved_refinements;
        }
        const body: Scope = try self.block(source.body, parameters);
        if (signature.infer_result and signature.returned and (signature.empty_return or !body.terminal)) signature.result = try self.join(signature.result, .nil, source.body.end);
        if (!body.terminal and signature.result != .void and !self.types.acceptsNil(signature.result)) return self.fail(source.body.end, "function must return a value on every path");
        self.types.items.items[(@intFromEnum(signature.kind) - 256) / 2].function.result = signature.result;
        if (signature.infer_result and signature.result != .void) {
            for (signature.returns.items) |returned| {
                if (returned.kind == signature.result) continue;
                if (!(try self.types.convertible(returned.kind, signature.result))) return self.fail(source.body.end, "incompatible value representations in returned values");
                const inner: *ir.Expression = try self.node(returned.*);
                returned.* = .{ .kind = signature.result, .effect = inner.effect, .op = .{ .convert = inner } };
            }
        }
        const function_value: *ir.Function = try self.allocator.create(ir.Function);
        function_value.* = .{ .id = function_id, .kind = signature.kind, .parameters = parameter_bindings, .captures = frame.captures.items, .body = body.block, .falls_through = !body.terminal };
        return .{ .node = try self.node(.{ .kind = signature.kind, .op = .{ .closure = function_value } }) };
    }

    const Scope: type = struct { block: ir.Block, terminal: bool };

    fn block(self: *Checker, source: ast.Block, initial: []const *Symbol) Error!Scope {
        const saved: usize = self.bindings.items.len;
        const saved_aliases: usize = self.aliases.items.len;
        const saved_refinements: usize = self.refinements.items.len;
        self.scope_depth += 1;
        defer {
            self.bindings.shrinkRetainingCapacity(saved);
            self.scope_depth -= 1;
            self.aliases.shrinkRetainingCapacity(saved_aliases);
            self.refinements.shrinkRetainingCapacity(saved_refinements);
        }
        const declarations: []*const ir.Binding = try self.allocator.alloc(*const ir.Binding, initial.len);
        for (initial, declarations) |symbol, *declaration| declaration.* = symbol.binding;
        try self.declarations.appendSlice(self.allocator, initial);
        var statements: std.ArrayList(ir.Statement) = std.ArrayList(ir.Statement).init(self.allocator);
        var terminal: bool = false;
        for (source.statements) |*item| {
            if (terminal and item.data != .empty) return self.fail(item.offset, "unreachable statement");
            terminal = (try self.statement(item, &statements)) or terminal;
        }
        return .{ .block = .{ .declarations = declarations, .statements = try statements.toOwnedSlice() }, .terminal = terminal };
    }

    const Branch: type = struct { conditional: *const ir.Conditional, terminal: bool };

    fn conditional(self: *Checker, source: *const ast.Conditional) Error!Branch {
        const condition: Value = try self.expression(&source.condition, null);
        try self.requireCondition(condition, source.condition.offset);
        const saved_refinements: usize = self.refinements.items.len;
        try self.refinements.appendSlice(self.allocator, condition.when_true);
        const then: Scope = try self.block(source.then, &.{});
        self.refinements.shrinkRetainingCapacity(saved_refinements);
        try self.refinements.appendSlice(self.allocator, condition.when_false);
        const result: *ir.Conditional = try self.allocator.create(ir.Conditional);
        result.* = .{ .condition = condition.node, .then = then.block, .otherwise = null };
        var otherwise_terminal: bool = false;
        if (source.otherwise) |otherwise| switch (otherwise) {
            .conditional => |nested| {
                const branch: Branch = try self.conditional(nested);
                result.otherwise = .{ .conditional = branch.conditional };
                otherwise_terminal = branch.terminal;
            },
            .block => |body| {
                const scope: Scope = try self.block(body, &.{});
                result.otherwise = .{ .block = scope.block };
                otherwise_terminal = scope.terminal;
            },
        };
        self.refinements.shrinkRetainingCapacity(saved_refinements);
        if (then.terminal and !otherwise_terminal) {
            try self.refinements.appendSlice(self.allocator, condition.when_false);
        } else if (otherwise_terminal and !then.terminal) try self.refinements.appendSlice(self.allocator, condition.when_true);
        return .{ .conditional = result, .terminal = then.terminal and otherwise_terminal };
    }

    fn declareSymbol(self: *Checker, name: []const u8, kind: Kind) Error!*Symbol {
        const binding: *ir.Binding = try self.allocator.create(ir.Binding);
        binding.* = .{ .id = self.id(), .owner = self.owner, .kind = kind, .value = undefined };
        const symbol: *Symbol = try self.allocator.create(Symbol);
        symbol.* = .{ .name = name, .kind = kind, .binding = binding, .depth = self.depth };
        return symbol;
    }

    fn entryPoint(self: *Checker, source: *const ast.Expression, out: *std.ArrayList(ir.Statement)) Error!void {
        const value: Value = try self.expression(source, null);
        if (self.types.acceptsNil(value.kind())) return self.fail(source.offset, "a program can only return its entry function");
        const function: type_system.Function = self.types.function(value.kind()) orelse return self.fail(source.offset, "a program can only return its entry function");
        if (function.parameters.len > 1) return self.fail(source.offset, "an entry function takes a single capability context");
        var context: ?Kind = null;
        if (function.parameters.len == 1) {
            const resolved: Kind = self.types.resolve(function.parameters[0]);
            const structure: ?type_system.Type = self.types.get(resolved);
            if (structure == null or structure.? != .record) return self.fail(source.offset, "the entry context must be a record of capabilities");
            for (structure.?.record.fields) |field| {
                const names: []const []const u8 = &.{ "args", "env", "stdin", "files" };
                const descriptions: []const []const u8 = &.{ "{string}", "{[string]: string}", "Input", "Files" };
                const required: []const Kind = &.{ try self.types.array(.string), try self.types.dictionaryOf(.string, .string), .input, .files };
                const index: usize = for (names, 0..) |name, position| {
                    if (std.mem.eql(u8, field.name, name)) break position;
                } else return self.fail(source.offset, try std.fmt.allocPrint(self.allocator, "unsupported capability '{s}'", .{field.name}));
                if ((try self.storage(field.kind)) != (try self.storage(required[index]))) return self.fail(source.offset, try std.fmt.allocPrint(self.allocator, "capability '{s}' must be {s}", .{ field.name, descriptions[index] }));
            }
            context = resolved;
        }
        const result: Kind = try self.storage(function.result);
        if (result != .void and result != .number) return self.fail(source.offset, "an entry function must return nothing or an exit code");
        try out.append(.{ .entry = .{ .function = value.node, .context = context, .result = function.result } });
    }

    fn statement(self: *Checker, source: *const ast.Statement, out: *std.ArrayList(ir.Statement)) Error!bool {
        const offset: usize = source.offset;
        switch (source.data) {
            .empty => return false,
            .type_alias => |alias| {
                const placeholder: Kind = try self.types.add(.{ .reference = .invalid });
                const index: usize = self.aliases.items.len;
                try self.aliases.append(self.allocator, .{ .name = alias.name, .kind = placeholder });
                const kind: Kind = try self.resolveType(alias.value);
                self.types.items.items[(@intFromEnum(placeholder) - 256) / 2] = .{ .reference = kind };
                if (self.types.resolve(placeholder) == .invalid) return self.fail(offset, "cyclic type alias without a record or function");
                self.aliases.items[index].kind = kind;
                return false;
            },
            .function => |declaration| {
                if (!declaration.local and (self.depth != 0 or self.scope_depth != 1)) return self.fail(offset, "global function declarations must be top-level");
                if (!declaration.local and (self.findBinding(declaration.name) != null or std.mem.eql(u8, declaration.name, "print"))) return self.fail(offset, "global function rebinding is not supported");
                const symbol: *Symbol = try self.declareSymbol(declaration.name, .invalid);
                try self.bindings.append(self.allocator, symbol);
                const saved_initializer: ?*std.ArrayListUnmanaged(*Symbol) = self.initializer;
                self.initializer = &symbol.dependencies;
                defer self.initializer = saved_initializer;
                const value: Value = try self.functionExpression(declaration.function, symbol, null);
                symbol.binding.value = value.node;
                symbol.binding.kind = value.kind();
                symbol.kind = value.kind();
                try self.declarations.append(self.allocator, symbol);
                try out.append(.{ .declare = symbol.binding });
                return false;
            },
            .conditional => |*source_conditional| {
                const branch: Branch = try self.conditional(source_conditional);
                try out.append(.{ .conditional = branch.conditional });
                return branch.terminal;
            },
            .numeric_for => |*loop| {
                const from: Value = try self.coerce(try self.expression(&loop.from, null), .number, loop.from.offset);
                const limit: Value = try self.coerce(try self.expression(&loop.limit, null), .number, loop.limit.offset);
                const step: Value = if (loop.step) |*step_source| try self.coerce(try self.expression(step_source, null), .number, step_source.offset) else .{ .node = try self.node(.{ .kind = .number, .op = .{ .number = 1 } }) };
                const symbol: *Symbol = try self.declareSymbol(loop.name, .number);
                symbol.binding.value = try self.node(.{ .kind = .number, .op = .{ .counter = symbol.binding } });
                const saved: usize = self.bindings.items.len;
                try self.bindings.append(self.allocator, symbol);
                defer self.bindings.shrinkRetainingCapacity(saved);
                self.loop_depth += 1;
                const body: Scope = try self.block(loop.body, &.{symbol});
                self.loop_depth -= 1;
                try out.append(.{ .numeric_for = .{ .binding = symbol.binding, .from = from.node, .limit = limit.node, .step = step.node, .body = body.block } });
                return false;
            },
            .loop => |*loop| {
                const condition: Value = try self.expression(&loop.condition, null);
                try self.requireCondition(condition, loop.condition.offset);
                const saved_refinements: usize = self.refinements.items.len;
                try self.refinements.appendSlice(self.allocator, condition.when_true);
                self.loop_depth += 1;
                const body: Scope = try self.block(loop.body, &.{});
                self.loop_depth -= 1;
                self.refinements.shrinkRetainingCapacity(saved_refinements);
                try out.append(.{ .loop = .{ .condition = condition.node, .body = body.block } });
                return false;
            },
            .loop_control => |keyword| {
                if (self.loop_depth == 0) return self.fail(offset, "loop control outside a loop");
                try out.append(.{ .loop_control = keyword });
                return true;
            },
            .@"return" => |*returned| {
                if (self.depth == 0) {
                    if (returned.*) |*source_value| {
                        try self.entryPoint(source_value, out);
                    } else try out.append(.exit);
                    return true;
                }
                const signature: *Signature = self.signature.?;
                var value: Value = try self.none(.nil);
                var empty: bool = true;
                if (returned.*) |*source_value| {
                    const returned_value: Value = try self.expression(source_value, if (signature.infer_result) null else signature.result);
                    if (returned_value.kind() == .void) {
                        if (!returned_value.called) return self.fail(offset, "cannot return a void value");
                        try out.append(.{ .evaluate = returned_value.node });
                    } else {
                        value = returned_value;
                        empty = false;
                    }
                }
                if (signature.infer_result) {
                    if (empty) {
                        signature.empty_return = true;
                    } else {
                        signature.result = if (signature.returned) try self.join(signature.result, value.kind(), offset) else value.kind();
                        signature.returned = true;
                        self.types.items.items[(@intFromEnum(signature.kind) - 256) / 2].function.result = signature.result;
                    }
                } else if (signature.result == .void) {
                    if (!empty) return self.fail(offset, "void function cannot return a value");
                } else value = try self.coerce(value, signature.result, offset);
                const slot: *ir.Expression = try self.node(value.node.*);
                if (signature.infer_result) try signature.returns.append(self.allocator, slot);
                try out.append(.{ .@"return" = slot });
                return true;
            },
            .local => |*local| {
                const annotation: ?Kind = if (local.annotation) |source_annotation| try self.resolveType(source_annotation) else null;
                const has_initializer: bool = local.value != null;
                if (!has_initializer and (annotation == null or (!self.types.acceptsNil(annotation.?) and self.types.function(annotation.?) == null))) return self.fail(offset, "expected '='");
                const symbol: *Symbol = try self.declareSymbol(local.name, .void);
                const saved_initializer: ?*std.ArrayListUnmanaged(*Symbol) = self.initializer;
                self.initializer = &symbol.dependencies;
                defer self.initializer = saved_initializer;
                var value: Value = if (local.value) |*source_value| try self.expression(source_value, annotation) else if (self.types.acceptsNil(annotation.?)) try self.none(.nil) else .{ .node = try self.node(.{ .kind = annotation.?, .op = .undefined }) };
                if (value.kind() == .void) return self.fail(offset, "cannot bind a void value");
                if (annotation) |kind| value = try self.coerce(value, kind, offset);
                symbol.kind = annotation orelse value.kind();
                if ((try self.storage(symbol.kind)) == .nil) return self.fail(offset, "cannot infer a type from nil; add a type annotation");
                symbol.binding.kind = symbol.kind;
                symbol.binding.value = value.node;
                symbol.initialized = has_initializer or self.types.acceptsNil(symbol.kind);
                try self.bindings.append(self.allocator, symbol);
                try self.declarations.append(self.allocator, symbol);
                try out.append(.{ .declare = symbol.binding });
                return false;
            },
            .scope => |body| {
                const scope: Scope = try self.block(body, &.{});
                try out.append(.{ .scope = scope.block });
                return scope.terminal;
            },
            .call => |*call_source| {
                try out.append(.{ .evaluate = (try self.expression(call_source, null)).node });
                return false;
            },
            .assign => |*assignment| {
                const operator: []const u8 = assignment.operator;
                const compound: bool = !std.mem.eql(u8, operator, "=");
                const left: Value = if (assignment.target.data == .name) try self.bindingValue(try self.lookup(assignment.target.data.name, assignment.target.offset), !compound, assignment.target.offset) else try self.expression(&assignment.target, null);
                const expected: Kind = if (left.place) |place| place.write else if (left.symbol) |symbol| symbol.kind else return self.fail(assignment.target.offset, "assignment target is not a variable or table field");
                var value: Value = try self.expression(&assignment.value, expected);
                if (left.place) |place| {
                    try self.assignPlace(place.*, operator, value, offset, out);
                    return false;
                }
                const symbol: *Symbol = left.symbol.?;
                if (compound) value = try self.binary(operator[0 .. operator.len - 1], left, value, offset);
                value = try self.coerce(value, symbol.kind, offset);
                symbol.binding.mutable = true;
                symbol.initialized = true;
                symbol.version += 1;
                try out.append(.{ .assign = .{ .binding = symbol.binding, .value = value.node } });
                return false;
            },
        }
    }

    fn assignPlace(self: *Checker, place: Place, operator: []const u8, right: Value, offset: usize, out: *std.ArrayList(ir.Statement)) Error!void {
        const place_id: usize = self.id();
        const container: Value = .{ .node = try self.node(.{ .kind = place.container.kind(), .op = .{ .place_container = place_id } }) };
        const key: Value = .{ .node = try self.node(.{ .kind = place.key.kind(), .op = .{ .place_key = place_id } }), .literal = place.key.literal };
        var value: Value = right;
        if (!std.mem.eql(u8, operator, "=")) {
            var old: Value = try self.indexed(container, key, place.field, offset);
            if (place.field == null) old = try self.asKind(old, old.kind().base());
            value = try self.binary(operator[0 .. operator.len - 1], old, right, offset);
        }
        value = try self.coerce(value, place.write, offset);
        if (place.field) |name| {
            try out.append(.{ .assign_field = .{ .id = place_id, .record = place.container.node, .name = name, .value = value.node } });
        } else try out.append(.{ .assign_index = .{ .id = place_id, .container = place.container.node, .key = place.key.node, .value = value.node } });
        if (place.container.symbol orelse place.container.access_symbol) |symbol| symbol.version += 1;
    }
};
