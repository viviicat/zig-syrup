//! Low level Syrup parser, modeled after std.json.Scanner.
const std = @import("std");
const assert = std.debug.assert;
const tags = @import("tags.zig");

const Scanner = @This();

pub const Error = error{
    SyntaxError,
    UnexpectedEndOfInput,
    InvalidUtf8,
};

pub const NextError = std.Io.Reader.Error ||
    Error ||
    std.mem.Allocator.Error ||
    error{ BufferUnderrun, InvalidCharacter, Overflow };

const BytesType = union(enum) {
    full: []const u8,
    partial: []const u8,
    allocated: []const u8,
};

const Token = union(enum) {
    sequence_start,
    sequence_end,

    record_start,
    record_end,

    true,
    false,

    f32: f32,
    f64: f64,

    positive_integer: BytesType,
    negative_integer: BytesType,
    data: BytesType,
    string: BytesType,
    symbol: BytesType,

    end_of_document,
};

const State = enum {
    value,
    integer_or_length,
    data_continue,
    string_continue,
    symbol_continue,
    float_continue,
    double_continue,
};

input: []const u8 = "",
cursor: usize = 0,
value_start: usize = undefined,
state: State = .value,
stack: std.BitStack,
remaining_bytes: usize = 0,
is_end_of_input: bool,

/// Extra scratch space for floats that cross buffer boundaries
float_scratch: [8]u8 = undefined,

/// The float data from the last buffer, to combine with current float
last_buf_float_data: []const u8 = &.{},

const SEQUENCE_MODE = 0;
const RECORD_MODE = 1;

pub fn feedInput(self: *Scanner, input: []const u8) void {
    assert(self.cursor == self.input.len); // not done with last input slice.

    self.input = input;
    self.cursor = 0;
    self.value_start = 0;
}

fn takeValueSlice(self: *Scanner) []const u8 {
    const slice = self.input[self.value_start..self.cursor];
    self.value_start = self.cursor;
    return slice;
}

fn takeValueString(self: *Scanner) ![]const u8 {
    const slice = self.takeValueSlice();
    if (!std.unicode.utf8ValidateSlice(slice)) {
        return Error.InvalidUtf8;
    }
    return slice;
}

fn expectByte(self: *const Scanner) !u8 {
    if (self.cursor < self.input.len) {
        return self.input[self.cursor];
    }

    if (self.is_end_of_input) return error.UnexpectedEndOfInput;
    return error.BufferUnderrun;
}

pub fn parseFloatValue(T: anytype, slice: []const u8) T {
    const bits = @typeInfo(T).float.bits;
    const unsigned = @Type(.{
        .int = .{ .signedness = .unsigned, .bits = bits },
    });
    return @bitCast(std.mem.bigToNative(unsigned, std.mem.bytesAsValue(unsigned, slice).*));
}

pub fn next(self: *Scanner) NextError!Token {
    state_loop: while (true) {
        const state = self.state;
        switch (state) {
            .value => {
                const byte = try self.expectByte();
                switch (try self.expectByte()) {
                    tags.True => {
                        self.cursor += 1;
                        return .true;
                    },
                    tags.False => {
                        self.cursor += 1;
                        return .false;
                    },
                    tags.Float, tags.Double => {
                        var bits: usize = 4;
                        var cont_state = State.float_continue;
                        if (byte == tags.Double) {
                            bits = 8;
                            cont_state = .double_continue;
                        }

                        self.cursor += 1;
                        self.value_start = self.cursor;
                        const remaining_len = self.input.len - self.cursor;
                        if (remaining_len < bits) {
                            if (self.is_end_of_input) return Error.UnexpectedEndOfInput;
                            self.cursor += remaining_len;
                            const slice = self.takeValueSlice();
                            @memcpy(&self.float_scratch, slice);
                            self.last_buf_float_data = self.float_scratch[0..slice.len];
                            self.state = cont_state;
                            return error.BufferUnderrun;
                        }
                        self.cursor += bits;
                        if (byte == tags.Float) {
                            return .{ .f32 = parseFloatValue(f32, self.takeValueSlice()) };
                        } else {
                            return .{ .f64 = parseFloatValue(f64, self.takeValueSlice()) };
                        }
                    },
                    tags.StartSequence => {
                        try self.stack.push(SEQUENCE_MODE);
                        self.cursor += 1;
                        return .sequence_start;
                    },
                    tags.EndSequence => {
                        if (self.stack.pop() != SEQUENCE_MODE) {
                            return Error.SyntaxError;
                        }
                        self.cursor += 1;
                        return .sequence_end;
                    },
                    tags.StartRecord => {
                        try self.stack.push(RECORD_MODE);
                        self.cursor += 1;
                        return .record_start;
                    },
                    tags.EndRecord => {
                        if (self.stack.pop() != RECORD_MODE) {
                            return Error.SyntaxError;
                        }
                        self.cursor += 1;
                        return .record_end;
                    },
                    '0'...'9' => {
                        self.value_start = self.cursor;
                        self.cursor += 1;
                        self.state = .integer_or_length;
                        continue :state_loop;
                    },
                    else => return Error.SyntaxError,
                }
            },
            .integer_or_length => {
                while (self.cursor < self.input.len) : (self.cursor += 1) {
                    const byte = try self.expectByte();
                    switch (byte) {
                        '0'...'9' => continue,
                        tags.PositiveInt => {
                            self.state = .value;
                            const val = self.takeValueSlice();
                            self.cursor += 1;
                            return Token{ .positive_integer = .{ .full = val } };
                        },
                        tags.NegativeInt => {
                            self.state = .value;
                            const val = self.takeValueSlice();
                            self.cursor += 1;
                            return Token{ .negative_integer = .{ .full = val } };
                        },
                        tags.Data, tags.String, tags.Symbol => {
                            const len_str = self.takeValueSlice();
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.remaining_bytes = try std.fmt.parseInt(usize, len_str, 10);
                            const remaining_buf_len = self.input.len - self.cursor;
                            if (self.remaining_bytes > remaining_buf_len) {
                                if (self.is_end_of_input) return error.UnexpectedEndOfInput;

                                self.cursor = self.input.len - 1;
                                self.remaining_bytes -= remaining_buf_len;
                                return switch (byte) {
                                    tags.Data => {
                                        self.state = .data_continue;
                                        return Token{ .data = .{ .partial = self.takeValueSlice() } };
                                    },
                                    tags.String => {
                                        self.state = .string_continue;
                                        return Token{ .string = .{ .partial = try self.takeValueString() } };
                                    },
                                    tags.Symbol => {
                                        self.state = .symbol_continue;
                                        return Token{ .symbol = .{ .partial = try self.takeValueString() } };
                                    },
                                    else => unreachable,
                                };
                            } else {
                                self.cursor += self.remaining_bytes;
                                self.remaining_bytes = 0;
                                self.state = .value;
                                return switch (byte) {
                                    tags.Data => Token{ .data = .{ .full = self.takeValueSlice() } },
                                    tags.String => Token{ .string = .{ .full = try self.takeValueString() } },
                                    tags.Symbol => Token{ .symbol = .{ .full = try self.takeValueString() } },
                                    else => unreachable,
                                };
                            }
                        },
                        else => return Error.SyntaxError,
                    }
                }
            },
            .float_continue, .double_continue => {
                const bits: usize = switch (state) {
                    .float_continue => 4,
                    .double_continue => 8,
                    else => unreachable,
                };

                const remaining_buf_len = self.input.len - self.cursor;
                const remaining_in_float = bits - self.last_buf_float_data.len;
                if (remaining_in_float > remaining_buf_len) {
                    if (self.is_end_of_input) return Error.UnexpectedEndOfInput;
                    self.cursor = self.input.len - 1;
                    const slice = self.takeValueSlice();
                    @memcpy(self.float_scratch[self.last_buf_float_data.len..], slice);
                    self.last_buf_float_data = self.float_scratch[0 .. self.last_buf_float_data.len + slice.len];
                    return error.BufferUnderrun;
                }

                self.cursor += bits;
                const slice = self.takeValueSlice();
                @memcpy(self.float_scratch[self.last_buf_float_data.len..], slice);
                self.last_buf_float_data = self.float_scratch[0 .. self.last_buf_float_data.len + slice.len];
                self.state = .value;
                return switch (state) {
                    .float_continue => Token{ .f32 = parseFloatValue(f32, self.last_buf_float_data) },
                    .double_continue => Token{ .f64 = parseFloatValue(f64, self.last_buf_float_data) },
                    else => unreachable,
                };
            },
            .data_continue, .string_continue, .symbol_continue => {
                const remaining_buf_len = self.input.len - self.cursor;
                if (self.remaining_bytes > remaining_buf_len) {
                    if (self.is_end_of_input) return Error.UnexpectedEndOfInput;

                    self.cursor = self.input.len - 1;
                    self.remaining_bytes -= remaining_buf_len;
                } else {
                    self.cursor += self.remaining_bytes;
                    self.remaining_bytes = 0;
                    self.state = .value;
                }

                return switch (state) {
                    .data_continue => Token{ .data = .{ .partial = self.takeValueSlice() } },
                    .string_continue => Token{ .string = .{ .partial = try self.takeValueString() } },
                    .symbol_continue => Token{ .symbol = .{ .partial = try self.takeValueString() } },
                    else => unreachable,
                };
            },
        }
    }
}

fn expectEqualBytesType(expected_bytes_type: BytesType, actual_bytes_type: BytesType) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected_bytes_type), std.meta.activeTag(actual_bytes_type));
    switch (expected_bytes_type) {
        .full => |expected_slice| {
            try std.testing.expectEqualSlices(u8, expected_slice, actual_bytes_type.full);
        },
        .partial => |expected_slice| {
            try std.testing.expectEqualSlices(u8, expected_slice, actual_bytes_type.partial);
        },
        .allocated => |expected_slice| {
            try std.testing.expectEqualSlices(u8, expected_slice, actual_bytes_type.allocated);
        },
    }
}

pub fn initCompleteInput(allocator: std.mem.Allocator, complete_input: []const u8) Scanner {
    return .{
        .stack = std.BitStack.init(allocator),
        .input = complete_input,
        .is_end_of_input = true,
    };
}

pub fn deinit(self: *Scanner) void {
    self.stack.deinit();
    self.* = undefined;
}

fn expectEqualTokens(expected_token: Token, actual_token: Token) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected_token), std.meta.activeTag(actual_token));
    switch (expected_token) {
        .f32 => |expected_value| {
            try std.testing.expectEqual(expected_value, actual_token.f32);
        },
        .f64 => |expected_value| {
            try std.testing.expectEqual(expected_value, actual_token.f64);
        },
        .positive_integer => |expected_bytes_type| {
            try expectEqualBytesType(expected_bytes_type, actual_token.positive_integer);
        },
        .negative_integer => |expected_bytes_type| {
            try expectEqualBytesType(expected_bytes_type, actual_token.negative_integer);
        },
        .data => |expected_bytes_type| {
            try expectEqualBytesType(expected_bytes_type, actual_token.data);
        },
        .string => |expected_bytes_type| {
            try expectEqualBytesType(expected_bytes_type, actual_token.string);
        },
        .symbol => |expected_bytes_type| {
            try expectEqualBytesType(expected_bytes_type, actual_token.symbol);
        },

        .sequence_start,
        .sequence_end,
        .record_start,
        .record_end,
        .true,
        .false,
        .end_of_document,
        => {},
    }
}

fn expectNext(scanner: *Scanner, expected_token: Token) !void {
    return expectEqualTokens(expected_token, try scanner.next());
}

test "primitive datatypes" {
    var scanner = Scanner.initCompleteInput(std.testing.allocator, "f");
    {
        defer scanner.deinit();
        try expectNext(&scanner, .false);
    }

    scanner = Scanner.initCompleteInput(std.testing.allocator, "t");
    {
        defer scanner.deinit();
        try expectNext(&scanner, .true);
    }

    scanner = Scanner.initCompleteInput(std.testing.allocator, "502345+");
    {
        defer scanner.deinit();
        try expectNext(&scanner, .{ .positive_integer = .{ .full = "502345" } });
    }

    scanner = Scanner.initCompleteInput(std.testing.allocator, "323-");
    {
        defer scanner.deinit();
        try expectNext(&scanner, .{ .negative_integer = .{ .full = "323" } });
    }
}

test "float datatypes" {
    var scanner = Scanner.initCompleteInput(std.testing.allocator, &[_]u8{ 68, 64, 44, 204, 204, 204, 204, 204, 205 });
    {
        defer scanner.deinit();
        try expectNext(&scanner, .{ .f64 = 14.4 });
    }

    scanner = Scanner.initCompleteInput(std.testing.allocator, &[_]u8{ 70, 66, 105, 117, 195 });
    {
        defer scanner.deinit();
        try expectNext(&scanner, .{ .f32 = 58.365 });
    }
}

test "string datatype" {
    var scanner = Scanner.initCompleteInput(std.testing.allocator, "26\"i love you, christine 😍");
    {
        defer scanner.deinit();
        try expectNext(&scanner, .{ .string = .{ .full = "i love you, christine 😍" } });
    }

    scanner = Scanner.initCompleteInput(std.testing.allocator, "6\"björn");
    {
        defer scanner.deinit();
        try expectNext(&scanner, .{ .string = .{ .full = "björn" } });
    }
}

test "data datatype" {
    var scanner = Scanner.initCompleteInput(std.testing.allocator, &[_]u8{ 53, 58, 69, 68, 67, 66, 65 });
    defer scanner.deinit();
    try expectNext(&scanner, .{ .data = .{ .full = &[_]u8{ 69, 68, 67, 66, 65 } } });
}

test "symbol datatype" {
    var scanner = Scanner.initCompleteInput(std.testing.allocator, "6'hämta");
    defer scanner.deinit();
    try expectNext(&scanner, .{ .symbol = .{ .full = "hämta" } });
}

test "sequence datatype" {
    var scanner = Scanner.initCompleteInput(std.testing.allocator, "[6\"a test45+5'shark[170141183460469231731687303715884105690-15\"testing nesting]]");
    defer scanner.deinit();

    try expectNext(&scanner, .sequence_start);
    try expectNext(&scanner, .{ .string = .{ .full = "a test" } });
    try expectNext(&scanner, .{ .positive_integer = .{ .full = "45" } });
    try expectNext(&scanner, .{ .symbol = .{ .full = "shark" } });
    try expectNext(&scanner, .sequence_start);
    try expectNext(&scanner, .{ .negative_integer = .{ .full = "170141183460469231731687303715884105690" } });
    try expectNext(&scanner, .{ .string = .{ .full = "testing nesting" } });
    try expectNext(&scanner, .sequence_end);
    try expectNext(&scanner, .sequence_end);
}

test "record datatype" {
    var scanner = Scanner.initCompleteInput(std.testing.allocator, "<[5\"hello2456+]tf13'dogs-and-cats>");
    defer scanner.deinit();

    try expectNext(&scanner, .record_start);
    try expectNext(&scanner, .sequence_start);
    try expectNext(&scanner, .{ .string = .{ .full = "hello" } });
    try expectNext(&scanner, .{ .positive_integer = .{ .full = "2456" } });
    try expectNext(&scanner, .sequence_end);
    try expectNext(&scanner, .true);
    try expectNext(&scanner, .false);
    try expectNext(&scanner, .{ .symbol = .{ .full = "dogs-and-cats" } });
    try expectNext(&scanner, .record_end);
}

test "malformed record" {
    var scanner = Scanner.initCompleteInput(std.testing.allocator, "<[5\"hello2456+]]tf13'dogs-and-cats>");
    defer scanner.deinit();

    try expectNext(&scanner, .record_start);
    try expectNext(&scanner, .sequence_start);
    try expectNext(&scanner, .{ .string = .{ .full = "hello" } });
    try expectNext(&scanner, .{ .positive_integer = .{ .full = "2456" } });
    try expectNext(&scanner, .sequence_end);
    try std.testing.expectError(Error.SyntaxError, scanner.next());
}

test "malformed record 2" {
    var scanner = Scanner.initCompleteInput(std.testing.allocator, "<[5\"hello2456+>]tf13'dogs-and-cats>");
    defer scanner.deinit();

    try expectNext(&scanner, .record_start);
    try expectNext(&scanner, .sequence_start);
    try expectNext(&scanner, .{ .string = .{ .full = "hello" } });
    try expectNext(&scanner, .{ .positive_integer = .{ .full = "2456" } });
    try std.testing.expectError(Error.SyntaxError, scanner.next());
}

test "incomplete string" {
    var scanner = Scanner.initCompleteInput(std.testing.allocator, "5000\"nasty");
    defer scanner.deinit();

    try std.testing.expectError(Error.UnexpectedEndOfInput, scanner.next());
}
