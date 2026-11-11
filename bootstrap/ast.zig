pub const Type: type = struct {
    offset: usize,
    data: union(enum) {
        name: []const u8,
        nil,
        void,
        boolean_literal: bool,
        string_literal: []const u8,
        array: *const Type,
        table: TableType,
        function: FunctionType,
        optional: *const Type,
        union_type: struct { left: *const Type, right: *const Type },
    },
};

pub const TypeField: type = struct { name: []const u8, value: Type };
pub const TypeIndexer: type = struct { key: Type, value: Type };
pub const TableType: type = struct { fields: []const TypeField, indexer: ?*const TypeIndexer };
pub const FunctionType: type = struct { parameters: []const Type, result: *const Type };

pub const Unary: type = enum { negate, not, length };

pub const Expression: type = struct {
    offset: usize,
    data: union(enum) {
        nil,
        boolean: bool,
        number: f64,
        string: []const u8,
        name: []const u8,
        unary: struct { operator: Unary, operand: *const Expression },
        binary: struct { operator: []const u8, left: *const Expression, right: *const Expression },
        if_expression: struct { condition: *const Expression, then: *const Expression, otherwise: *const Expression },
        function: *const Function,
        table: []const TableEntry,
        call: struct { callee: *const Expression, arguments: []const Expression },
        method: struct { object: *const Expression, name: []const u8, arguments: []const Expression },
        index: struct { table: *const Expression, key: *const Expression },
        field: struct { table: *const Expression, name: []const u8 },
        assertion: struct { value: *const Expression, annotation: Type },
        group: *const Expression,
    },
};

pub const TableEntry: type = union(enum) {
    positional: Expression,
    named: struct { name: []const u8, value: Expression },
    keyed: struct { key: Expression, value: Expression },
};

pub const Parameter: type = struct { name: []const u8, annotation: ?Type, offset: usize };

pub const Function: type = struct {
    parameters: []const Parameter,
    result: ?Type,
    body: Block,
};

pub const Block: type = struct { statements: []const Statement, end: usize };

pub const Conditional: type = struct {
    condition: Expression,
    then: Block,
    otherwise: ?union(enum) { block: Block, conditional: *const Conditional },
};

pub const Statement: type = struct {
    offset: usize,
    data: union(enum) {
        empty,
        type_alias: struct { name: []const u8, value: Type },
        function: struct { local: bool, name: []const u8, function: *const Function },
        conditional: Conditional,
        numeric_for: struct { name: []const u8, from: Expression, limit: Expression, step: ?Expression, body: Block },
        loop: struct { condition: Expression, body: Block },
        loop_control: []const u8,
        @"return": ?Expression,
        local: struct { name: []const u8, annotation: ?Type, value: ?Expression },
        scope: Block,
        call: Expression,
        assign: struct { target: Expression, operator: []const u8, value: Expression },
    },
};
