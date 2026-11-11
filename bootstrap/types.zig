const std: type = @import("std");

pub const Kind: type = enum(u32) {
    number,
    boolean,
    string,
    void,
    nil,
    optional_number,
    optional_boolean,
    optional_string,
    number_array,
    boolean_array,
    string_array,
    optional_number_array,
    optional_boolean_array,
    optional_string_array,
    input,
    optional_input,
    files,
    optional_files,
    invalid = 255,
    _,

    pub fn rich(self: Kind) bool {
        return @intFromEnum(self) >= 256;
    }

    pub fn base(self: Kind) Kind {
        return switch (self) {
            .optional_number => .number,
            .optional_boolean => .boolean,
            .optional_string => .string,
            .optional_number_array => .number_array,
            .optional_boolean_array => .boolean_array,
            .optional_string_array => .string_array,
            .optional_input => .input,
            .optional_files => .files,
            else => if (self.rich()) @enumFromInt(@intFromEnum(self) & ~@as(u32, 1)) else self,
        };
    }

    pub fn optional(self: Kind) Kind {
        return switch (self) {
            .number => .optional_number,
            .boolean => .optional_boolean,
            .string => .optional_string,
            .number_array => .optional_number_array,
            .boolean_array => .optional_boolean_array,
            .string_array => .optional_string_array,
            .input => .optional_input,
            .files => .optional_files,
            else => if (self.rich()) @enumFromInt(@intFromEnum(self) | 1) else self,
        };
    }

    pub fn acceptsNil(self: Kind) bool {
        return self == .nil or self != self.base();
    }
};

pub const Field: type = struct { name: []const u8, kind: Kind };
pub const Indexer: type = struct { key: Kind, value: Kind };
pub const Function: type = struct { parameters: []const Kind, result: Kind };
pub const Record: type = struct { fields: []const Field, indexer: ?Indexer = null };
pub const Literal: type = union(enum) { string: []const u8, boolean: bool };
pub const Type: type = union(enum) {
    record: Record,
    dictionary: Indexer,
    array: Kind,
    function: Function,
    union_type: []const Kind,
    string_literal: []const u8,
    boolean_literal: bool,
    reference: Kind,
};

const Pair: type = struct { actual: Kind, expected: Kind };

pub const Store: type = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Type) = .{},

    pub fn add(self: *Store, value: Type) error{OutOfMemory}!Kind {
        const kind: Kind = @enumFromInt(256 + @as(u32, @intCast(self.items.items.len)) * 2);
        try self.items.append(self.allocator, value);
        return kind;
    }

    pub fn get(self: *const Store, kind: Kind) ?Type {
        if (!kind.rich()) return null;
        return self.items.items[(@intFromEnum(kind.base()) - 256) / 2];
    }

    pub fn resolve(self: *const Store, input: Kind) Kind {
        var kind: Kind = input;
        var nullable: bool = false;
        var remaining: usize = self.items.items.len + 1;
        while (remaining != 0) : (remaining -= 1) {
            nullable = nullable or kind.acceptsNil();
            const value: Type = self.get(kind) orelse return if (nullable) kind.optional() else kind;
            switch (value) {
                .reference => |target| kind = target,
                else => return if (nullable) kind.optional() else kind,
            }
        }
        return .invalid;
    }

    pub fn acceptsNil(self: *const Store, kind: Kind) bool {
        return self.resolve(kind).acceptsNil();
    }

    pub fn element(self: *const Store, input: Kind) ?Kind {
        const kind: Kind = self.resolve(input).base();
        return switch (kind) {
            .number_array => .number,
            .boolean_array => .boolean,
            .string_array => .string,
            else => if (self.get(kind)) |value| switch (value) {
                .array => |element_kind| element_kind,
                else => null,
            } else null,
        };
    }

    pub fn array(self: *Store, element_kind: Kind) error{OutOfMemory}!Kind {
        return switch (self.resolve(element_kind)) {
            .number => .number_array,
            .boolean => .boolean_array,
            .string => .string_array,
            else => blk: {
                for (self.items.items, 0..) |item, index| {
                    if (item == .array and item.array == element_kind) break :blk @enumFromInt(256 + @as(u32, @intCast(index)) * 2);
                }
                break :blk try self.add(.{ .array = element_kind });
            },
        };
    }

    fn kindAt(index: usize) Kind {
        return @enumFromInt(256 + @as(u32, @intCast(index)) * 2);
    }

    pub fn dictionaryOf(self: *Store, key: Kind, value: Kind) error{OutOfMemory}!Kind {
        for (self.items.items, 0..) |item, index| {
            if (item == .dictionary and item.dictionary.key == key and item.dictionary.value == value) return kindAt(index);
        }
        return self.add(.{ .dictionary = .{ .key = key, .value = value } });
    }

    pub fn unionOf(self: *Store, members: []const Kind) error{OutOfMemory}!Kind {
        for (self.items.items, 0..) |item, index| {
            if (item == .union_type and std.mem.eql(Kind, item.union_type, members)) return kindAt(index);
        }
        return self.add(.{ .union_type = try self.allocator.dupe(Kind, members) });
    }

    pub fn variants(self: *const Store, kind: Kind) []const Kind {
        const value: Type = self.get(kind) orelse return &.{};
        return if (value == .union_type) value.union_type else &.{};
    }

    pub fn storage(self: *Store, input: Kind) error{OutOfMemory}!Kind {
        const kind: Kind = self.resolve(input);
        const nullable: bool = kind.acceptsNil() and kind != .nil;
        const base_kind: Kind = kind.base();
        const stored: Kind = if (self.get(base_kind)) |value| switch (value) {
            .string_literal => .string,
            .boolean_literal => .boolean,
            .array => |element_kind| try self.array(try self.storage(element_kind)),
            .dictionary => |entry| try self.dictionaryOf(try self.storage(entry.key), try self.storage(entry.value)),
            .function => |signature| blk: {
                const parameters: []Kind = try self.allocator.alloc(Kind, signature.parameters.len);
                for (signature.parameters, parameters) |parameter, *stored_parameter| stored_parameter.* = try self.storage(parameter);
                break :blk try self.functionKind(parameters, try self.storage(signature.result));
            },
            .record => base_kind,
            .union_type => |union_members| blk: {
                var stored_members: std.ArrayListUnmanaged(Kind) = .{};
                for (union_members) |member| {
                    const member_storage: Kind = try self.storage(member);
                    if (std.mem.indexOfScalar(Kind, stored_members.items, member_storage) == null) try stored_members.append(self.allocator, member_storage);
                }
                if (stored_members.items.len == 1) break :blk stored_members.items[0];
                break :blk try self.unionOf(stored_members.items);
            },
            .reference => unreachable,
        } else base_kind;
        return if (nullable) stored.optional() else stored;
    }

    pub fn convertible(self: *Store, from: Kind, to: Kind) error{OutOfMemory}!bool {
        const source: Kind = try self.storage(from);
        const target: Kind = try self.storage(to);
        if (source == target) return true;
        if (source == .nil) return target.acceptsNil();
        if (target == .nil) return false;
        if (source.acceptsNil()) return self.convertible(source.base(), if (target.acceptsNil()) target.base() else target);
        if (target.acceptsNil()) return self.convertible(source, target.base());
        const source_members: []const Kind = self.variants(source);
        const target_members: []const Kind = self.variants(target);
        if (source_members.len != 0 and target_members.len != 0) {
            var subset: bool = true;
            for (source_members) |member| subset = subset and std.mem.indexOfScalar(Kind, target_members, member) != null;
            var superset: bool = true;
            for (target_members) |member| superset = superset and std.mem.indexOfScalar(Kind, source_members, member) != null;
            return subset or superset;
        }
        if (target_members.len != 0) return std.mem.indexOfScalar(Kind, target_members, source) != null;
        if (source_members.len != 0) return std.mem.indexOfScalar(Kind, source_members, target) != null;
        return false;
    }

    pub fn stringLiteral(self: *Store, text: []const u8) error{OutOfMemory}!Kind {
        for (self.items.items, 0..) |item, index| {
            if (item == .string_literal and std.mem.eql(u8, item.string_literal, text)) return @enumFromInt(256 + @as(u32, @intCast(index)) * 2);
        }
        return self.add(.{ .string_literal = text });
    }

    pub fn booleanLiteral(self: *Store, value: bool) error{OutOfMemory}!Kind {
        for (self.items.items, 0..) |item, index| {
            if (item == .boolean_literal and item.boolean_literal == value) return @enumFromInt(256 + @as(u32, @intCast(index)) * 2);
        }
        return self.add(.{ .boolean_literal = value });
    }

    pub fn functionKind(self: *Store, parameters: []const Kind, result: Kind) error{OutOfMemory}!Kind {
        for (self.items.items, 0..) |item, index| {
            if (item == .function and item.function.result == result and std.mem.eql(Kind, item.function.parameters, parameters)) return @enumFromInt(256 + @as(u32, @intCast(index)) * 2);
        }
        return self.add(.{ .function = .{ .parameters = try self.allocator.dupe(Kind, parameters), .result = result } });
    }

    pub fn function(self: *const Store, kind: Kind) ?Function {
        const value: Type = self.get(self.resolve(kind)) orelse return null;
        return if (value == .function) value.function else null;
    }

    pub fn category(self: *const Store, input: Kind) ?[]const u8 {
        const kind: Kind = self.resolve(input).base();
        return switch (kind) {
            .number => "number",
            .boolean => "boolean",
            .string => "string",
            .nil => "nil",
            .number_array, .boolean_array, .string_array => "table",
            .input, .files => "userdata",
            else => if (self.get(kind)) |value| switch (value) {
                .record, .dictionary, .array => "table",
                .function => "function",
                .string_literal => "string",
                .boolean_literal => "boolean",
                else => null,
            } else null,
        };
    }

    pub fn field(self: *Store, input: Kind, name: []const u8) error{OutOfMemory}!?Kind {
        const kind: Kind = self.resolve(input);
        if (kind.acceptsNil()) return null;
        const value: Type = self.get(kind) orelse return null;
        return switch (value) {
            .record => |record| blk: {
                for (record.fields) |property| {
                    if (std.mem.eql(u8, property.name, name)) break :blk property.kind;
                }
                if (record.indexer) |record_indexer| {
                    if (try self.assignable(.string, record_indexer.key)) break :blk record_indexer.value.optional();
                }
                break :blk null;
            },
            .dictionary => |dictionary| if (try self.assignable(.string, dictionary.key)) dictionary.value.optional() else null,
            .union_type => |members| blk: {
                var result: ?Kind = null;
                for (members) |member| {
                    const member_field: Kind = (try self.field(member, name)) orelse break :blk null;
                    result = if (result) |previous| try self.join(previous, member_field) else member_field;
                }
                break :blk result;
            },
            else => null,
        };
    }

    pub fn indexer(self: *const Store, input: Kind) ?Indexer {
        const kind: Kind = self.resolve(input);
        if (self.element(kind)) |element_kind| return .{ .key = .number, .value = element_kind };
        const value: Type = self.get(kind) orelse return null;
        return switch (value) {
            .dictionary => |index| index,
            .record => |record| record.indexer,
            else => null,
        };
    }

    pub fn join(self: *Store, left_input: Kind, right_input: Kind) error{OutOfMemory}!Kind {
        const left: Kind = self.resolve(left_input);
        const right: Kind = self.resolve(right_input);
        if (left == right) return left;
        if (left == .void or right == .void or left == .invalid or right == .invalid) return .invalid;
        if (left == .nil) return right.optional();
        if (right == .nil) return left.optional();
        const nullable: bool = left.acceptsNil() or right.acceptsNil();
        if (left.base() == right.base()) return if (nullable) left.base().optional() else left.base();
        if (try self.assignable(left.base(), right.base())) return if (nullable) right.base().optional() else right.base();
        if (try self.assignable(right.base(), left.base())) return if (nullable) left.base().optional() else left.base();
        var members: std.ArrayListUnmanaged(Kind) = .{};
        for ([_]Kind{ left.base(), right.base() }) |kind| {
            if (self.get(kind)) |value| {
                if (value == .union_type) {
                    for (value.union_type) |member| {
                        if (std.mem.indexOfScalar(Kind, members.items, member) == null) try members.append(self.allocator, member);
                    }
                    continue;
                }
            }
            if (std.mem.indexOfScalar(Kind, members.items, kind) == null) try members.append(self.allocator, kind);
        }
        const result: Kind = try self.add(.{ .union_type = try members.toOwnedSlice(self.allocator) });
        return if (nullable) result.optional() else result;
    }

    pub fn assignable(self: *Store, actual: Kind, expected: Kind) error{OutOfMemory}!bool {
        var seen: std.ArrayListUnmanaged(Pair) = .{};
        defer seen.deinit(self.allocator);
        return self.assignableInner(actual, expected, &seen);
    }

    fn assignableInner(self: *Store, actual_input: Kind, expected_input: Kind, seen: *std.ArrayListUnmanaged(Pair)) error{OutOfMemory}!bool {
        const actual: Kind = self.resolve(actual_input);
        const expected: Kind = self.resolve(expected_input);
        if (actual == .invalid or expected == .invalid) return false;
        if (actual == expected) return true;
        if (actual == .nil) return expected.acceptsNil();
        if (actual.acceptsNil() and !expected.acceptsNil()) return false;
        if (actual.acceptsNil() or expected.acceptsNil()) return self.assignableInner(actual.base(), expected.base(), seen);
        for (seen.items) |pair| {
            if (pair.actual == actual and pair.expected == expected) return true;
        }
        const saved: usize = seen.items.len;
        try seen.append(self.allocator, .{ .actual = actual, .expected = expected });
        defer seen.shrinkRetainingCapacity(saved);
        const actual_type: ?Type = self.get(actual);
        const expected_type: ?Type = self.get(expected);
        if (actual_type) |value| {
            if (value == .union_type) {
                for (value.union_type) |member| {
                    if (!(try self.assignableInner(member, expected, seen))) return false;
                }
                return true;
            }
        }
        if (expected_type) |value| {
            if (value == .union_type) {
                for (value.union_type) |member| {
                    if (try self.assignableInner(actual, member, seen)) return true;
                }
                return false;
            }
        }
        if (actual_type) |value| switch (value) {
            .string_literal => |text| {
                if (expected == .string) return true;
                if (expected_type) |target| return target == .string_literal and std.mem.eql(u8, text, target.string_literal);
            },
            .boolean_literal => |boolean| {
                if (expected == .boolean) return true;
                if (expected_type) |target| return target == .boolean_literal and boolean == target.boolean_literal;
            },
            else => {},
        };
        if (self.element(actual)) |actual_element| {
            if (self.element(expected)) |expected_element| return self.assignableInner(actual_element, expected_element, seen);
        }
        if (actual_type == null or expected_type == null) return false;
        const source: Type = actual_type.?;
        const target: Type = expected_type.?;
        if (source == .function and target == .function) {
            if (source.function.parameters.len != target.function.parameters.len) return false;
            for (source.function.parameters, target.function.parameters) |source_parameter, target_parameter| {
                if (!(try self.assignableInner(target_parameter, source_parameter, seen))) return false;
            }
            return self.assignableInner(source.function.result, target.function.result, seen);
        }
        if (source == .record and target == .record) {
            for (target.record.fields) |target_field| {
                var found: ?Kind = null;
                for (source.record.fields) |source_field| {
                    if (std.mem.eql(u8, source_field.name, target_field.name)) {
                        found = source_field.kind;
                        break;
                    }
                }
                if (!(try self.assignableInner(found orelse .nil, target_field.kind, seen))) return false;
            }
            if (target.record.indexer) |target_indexer| {
                if (source.record.indexer) |source_indexer| {
                    if (!(try self.assignableInner(source_indexer.key, target_indexer.key, seen)) or !(try self.assignableInner(source_indexer.value, target_indexer.value, seen))) return false;
                }
                for (source.record.fields) |source_field| {
                    var named: bool = false;
                    for (target.record.fields) |target_field| named = named or std.mem.eql(u8, source_field.name, target_field.name);
                    if (!named and (!(try self.assignableInner(.string, target_indexer.key, seen)) or !(try self.assignableInner(source_field.kind, target_indexer.value, seen)))) return false;
                }
            }
            return true;
        }
        if (target == .dictionary) {
            if (source == .dictionary) return (try self.assignableInner(source.dictionary.key, target.dictionary.key, seen)) and (try self.assignableInner(source.dictionary.value, target.dictionary.value, seen));
            if (source == .record) {
                for (source.record.fields) |property| {
                    if (!(try self.assignableInner(.string, target.dictionary.key, seen)) or !(try self.assignableInner(property.kind, target.dictionary.value, seen))) return false;
                }
                if (source.record.indexer) |source_indexer| return (try self.assignableInner(source_indexer.key, target.dictionary.key, seen)) and (try self.assignableInner(source_indexer.value, target.dictionary.value, seen));
                return true;
            }
        }
        return false;
    }

    pub fn filter(self: *Store, input: Kind, field_name: ?[]const u8, literal: Literal, positive: bool) error{OutOfMemory}!?Kind {
        const kind: Kind = self.resolve(input);
        var result: ?Kind = null;
        if (kind.acceptsNil() and literal == .string and (std.mem.eql(u8, literal.string, "nil") == positive) and field_name == null) result = .nil;
        const value: ?Type = self.get(kind.base());
        if (value != null and value.? == .union_type) {
            for (value.?.union_type) |member| {
                if (try self.filter(member, field_name, literal, positive)) |filtered| result = if (result) |previous| try self.join(previous, filtered) else filtered;
            }
            return result;
        }
        if (field_name) |name| {
            const property: Kind = (try self.field(kind.base(), name)) orelse return result;
            const property_type: ?Type = self.get(self.resolve(property));
            const matches: ?bool = if (property_type) |property_value| switch (property_value) {
                .string_literal => |text| literal == .string and std.mem.eql(u8, text, literal.string),
                .boolean_literal => |boolean| literal == .boolean and boolean == literal.boolean,
                else => null,
            } else null;
            if ((matches orelse positive) == positive) result = if (result) |previous| try self.join(previous, kind.base()) else kind.base();
        } else if (literal == .string) {
            if (self.category(kind.base())) |category_name| {
                if (std.mem.eql(u8, category_name, literal.string) == positive) result = if (result) |previous| try self.join(previous, kind.base()) else kind.base();
            }
        }
        return result;
    }
};
