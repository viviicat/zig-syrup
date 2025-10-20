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

pub const NextError = std.Io.Reader.Error || Error || std.mem.Allocator.Error || error{ BufferUnderrun, InvalidCharacter, Overflow };

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
};

input: []const u8 = "",
cursor: usize = 0,
value_start: usize = undefined,
state: State = .value,
stack: std.BitStack,
remaining_bytes: usize = 0,
is_end_of_input: bool,

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

pub fn next(self: *Scanner) NextError!Token {
    state_loop: while (true) {
        const state = self.state;
        switch (state) {
            .value => switch (try self.expectByte()) {
                tags.True => {
                    self.cursor += 1;
                    return .true;
                },
                tags.False => {
                    self.cursor += 1;
                    return .false;
                },
                tags.Float => {
                    // FIXME: handle buffer barrier
                    self.cursor += 1;
                    self.value_start = self.cursor;
                    self.cursor += 4;
                    return .{ .f32 = try std.fmt.parseFloat(f32, self.takeValueSlice()) };
                },
                tags.Double => {
                    // FIXME: handle buffer barrier
                    self.cursor += 1;
                    self.value_start = self.cursor;
                    self.cursor += 8;
                    return .{ .f64 = try std.fmt.parseFloat(f64, self.takeValueSlice()) };
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
            },
            .integer_or_length => {
                while (self.cursor < self.input.len) : (self.cursor += 1) {
                    // FIXME: barrier!
                    const byte = try self.expectByte();
                    switch (byte) {
                        '0'...'9' => continue,
                        tags.PositiveInt => {
                            self.state = .value;
                            return Token{ .positive_integer = .{ .full = self.takeValueSlice() } };
                        },
                        tags.NegativeInt => {
                            self.state = .value;
                            return Token{ .negative_integer = .{ .full = self.takeValueSlice() } };
                        },
                        tags.Data, tags.String, tags.Symbol => {
                            const len_str = self.takeValueSlice();
                            self.cursor += 1;
                            self.remaining_bytes = try std.fmt.parseInt(usize, len_str, 10);
                            const remaining_buf_len = self.input.len - self.cursor;
                            if (self.remaining_bytes > remaining_buf_len) {
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
            .data_continue, .string_continue, .symbol_continue => {
                const remaining_buf_len = self.input.len - self.cursor;
                if (self.remaining_bytes > remaining_buf_len) {
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

test "scan primitives" {
    var scanner = Scanner.initCompleteInput(std.testing.allocator, "f");
    defer scanner.deinit();

    try expectNext(&scanner, .false);
}
