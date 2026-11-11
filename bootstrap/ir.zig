const Kind: type = @import("types.zig").Kind;

pub const Binding: type = struct {
    id: usize,
    owner: usize,
    kind: Kind,
    value: *const Expression,
    parameter: bool = false,
    live: bool = false,
    mutable: bool = false,
    captured: bool = false,
};

pub const Function: type = struct {
    id: usize,
    kind: Kind,
    parameters: []const *const Binding,
    captures: []const *const Binding,
    body: Block,
    falls_through: bool,
};

pub const Block: type = struct {
    declarations: []const *const Binding,
    statements: []const Statement,
};

pub const Pair: type = struct { left: *const Expression, right: *const Expression };
pub const Operation: type = struct { operator: []const u8, left: *const Expression, right: *const Expression };
pub const Field: type = struct { name: []const u8, value: *const Expression };

pub const Expression: type = struct {
    kind: Kind,
    effect: bool = false,
    op: Op,
};

pub const Op: type = union(enum) {
    nil,
    undefined,
    boolean: bool,
    number: f64,
    string: []const u8,
    read: *const Binding,
    counter: *const Binding,
    place_container: usize,
    place_key: usize,
    convert: *const Expression,
    not: *const Expression,
    negate: *const Expression,
    length: *const Expression,
    logic: struct { is_or: bool, left: *const Expression, right: *const Expression },
    equal: struct { negate: bool, left: *const Expression, right: *const Expression },
    concat: Pair,
    compare: Operation,
    arithmetic: Operation,
    if_expression: struct { condition: *const Expression, then: *const Expression, otherwise: *const Expression },
    index: Pair,
    field: struct { value: *const Expression, name: []const u8 },
    array: []const *const Expression,
    record: []const Field,
    dictionary: []const Pair,
    closure: *const Function,
    call: struct { callee: *const Expression, arguments: []const *const Expression },
    print: []const *const Expression,
    to_string: *const Expression,
    type_name: *const Expression,
    string_sub: struct { string: *const Expression, first: *const Expression, last: ?*const Expression },
    string_byte: struct { string: *const Expression, index: ?*const Expression },
    string_case: struct { upper: bool, string: *const Expression },
    string_char: []const *const Expression,
    array_insert: struct { array: *const Expression, position: ?*const Expression, value: *const Expression },
    array_remove: struct { array: *const Expression, position: ?*const Expression },
    table_concat: struct { array: *const Expression, separator: ?*const Expression, first: ?*const Expression, last: ?*const Expression },
    math: struct { name: []const u8, argument: *const Expression },
    read_line: *const Expression,
    read_all: *const Expression,
    read_count: Pair,
    read_file: Pair,
};

pub const Conditional: type = struct {
    condition: *const Expression,
    then: Block,
    otherwise: ?union(enum) { block: Block, conditional: *const Conditional },
};

pub const Entry: type = struct { function: *const Expression, context: ?Kind, result: Kind };

pub const Statement: type = union(enum) {
    declare: *const Binding,
    evaluate: *const Expression,
    assign: struct { binding: *const Binding, value: *const Expression },
    assign_index: struct { id: usize, container: *const Expression, key: *const Expression, value: *const Expression },
    assign_field: struct { id: usize, record: *const Expression, name: []const u8, value: *const Expression },
    conditional: *const Conditional,
    loop: struct { condition: *const Expression, body: Block },
    numeric_for: struct { binding: *const Binding, from: *const Expression, limit: *const Expression, step: *const Expression, body: Block },
    scope: Block,
    loop_control: []const u8,
    exit,
    @"return": *const Expression,
    entry: Entry,
};
