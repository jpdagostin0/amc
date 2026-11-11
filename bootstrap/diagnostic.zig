pub const Error: type = error{ OutOfMemory, InvalidSource };

pub const Diagnostic: type = struct { offset: usize = 0, message: []const u8 = "" };

pub fn fail(report: *Diagnostic, offset: usize, message: []const u8) Error {
    report.* = .{ .offset = offset, .message = message };
    return error.InvalidSource;
}
