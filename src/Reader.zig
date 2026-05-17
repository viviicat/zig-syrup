//! Low level Syrup parser, modeled after `std.json.Reader` and `std.json.Scanner`.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const tags = @import("tags.zig").syrup;
const CollectionMode = @import("collections.zig").CollectionMode;

const Reader = @This();

pub const Error = error{
    SyntaxError,
    UnexpectedEndOfInput,
    InvalidUtf8,
};

/// An enum used to specify whether to perform an allocation of a collection.
/// If you do not need to store the item to use later, and only need to check
/// its value immediately, you can try to avoid the work of allocating the memory.
pub const AllocWhen = enum {
    /// Only allocate if necessary because the collection is too long to fit in the input buffer.
    if_needed,
    /// Always allocate the memory for the collection to a new location in memory.
    always,
};

pub const NextError = std.Io.Reader.Error ||
    Error ||
    Allocator.Error ||
    error{ InvalidCharacter, Overflow };

/// Union for determining where a complete integer bytestring is stored.
pub const Integer = union(enum) {
    /// The data is stored in the buffer and will be invalidated upon further parsing.
    buffered: []const u8,
    /// The data is stored in separately-allocated memory and can be used after further parsing.
    allocated: []const u8,
};

/// Union for determining where data, strings, symbols are being stored.
pub const Data = union(enum) {
    /// The data is stored in the buffer and will be invalidated upon further parsing.
    buffered: []const u8,
    /// The bytes do not contain the end of the data. At least one more BytesType will be returned with more data. This field of the union is only returned if you are using the non-allocating `next`.
    buffered_partial: []const u8,
    /// The data is stored in separately-allocated memory and can be used after further parsing.
    allocated: []const u8,
};

pub const Token = union(enum) {
    /// We are at the beginning of a sequence
    sequence_start,
    /// We are at the end of a sequence
    sequence_end,

    /// We are at the beginning of a record
    record_start,
    /// We are at the end of a record
    record_end,

    /// We are at the beginning of a set
    set_start,
    /// We are at the end of a set
    set_end,

    /// We are at the beginning of a dictionary
    dictionary_start,
    /// We are at the end of a dictionary
    dictionary_end,

    true,
    false,

    f32: f32,
    f64: f64,

    /// We encountered a decimal number but the buffer ran out before we could determine what it was.
    /// It could be a positive or negative integer, or a length specifier for data.
    /// In order to continue, we must keep reading.
    /// The reader attempts to avoid this case by using `boundary_scratch`, but if it's too long it gives up.
    partial_decimal: []const u8,

    /// We parsed, and possibly allocated, a positive integer
    positive_integer: Integer,
    /// We parsed, and possibly allocated, a negative integer
    negative_integer: Integer,
    /// We parsed, and possibly allocated, data
    data: Data,
    /// We parsed, and possibly allocated, a string
    string: Data,
    /// We parsed, and possibly allocated, a symbol
    symbol: Data,

    /// We have reached the end of the document
    end_of_document,
};

const State = enum {
    /// We are parsing a value
    value,
    /// We are parsing what could be an integer, or a length specifier
    decimal,
    /// We are in the middle of parsing data, and need to continue after allocating
    data_continue,
    /// We are in the middle of parsing a string, and need to continue after allocating
    string_continue,
    /// We are in the middle of parsing a symbol, and need to continue after allocating
    symbol_continue,
    /// We are in the middle of parsing a float, and need to continue using boundary_scratch
    float_continue,
    /// We are in the middle of parsing a double, and need to continue using boundary_scratch
    double_continue,
    /// We have finished parsing the syrup value.
    end_of_document,
};

underlying_reader: *std.Io.Reader,
gpa: Allocator,
/// The current input buffer provided by `underlying_reader`
input: []const u8 = "",
/// The position in the input buffer
cursor: usize = 0,
/// Position in the buffer where the current value begins
value_start: usize = undefined,
/// The current state of the parser
state: State = .value,
/// Stack used to track the type of collection we're parsing.
collection_stack: std.ArrayList(CollectionMode),
/// Bytes remaining in the current value
remaining_bytes: usize = 0,
/// True if we've reached the end of the input.
is_end_of_input: bool = false,

/// Extra scratch space for floats and integers that cross buffer boundaries
/// For integers, we attempt to use this but if the integer is humongous we will give up, as it could be any length
boundary_scratch: [32]u8 = undefined,
/// The amount we have written to the scratch buffer so far.
written_to_scratch: usize = 0,

/// The float data from the last buffer, to combine with current float
last_buf_float_data: []const u8 = &.{},

/// For security, the maximum size allocated to store a single string or number value is limited to 4MiB by default.
/// This limit can be specified by using the Max versions of the alloc functions.
pub const default_max_value_len = 4 * 1024 * 1024;

fn refillBuffer(self: *Reader) !void {
    assert(self.cursor == self.input.len); // not done with last input slice.

    self.input = self.underlying_reader.peekGreedy(1) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.EndOfStream => {
            self.is_end_of_input = true;
            self.input = "";
            return {};
        },
    };
    self.underlying_reader.toss(self.input.len);

    self.cursor = 0;
    self.value_start = 0;
}

fn refillBufferExpectMore(self: *Reader, remaining: usize) !void {
    try self.refillBuffer();
    if (remaining > self.input.len and self.is_end_of_input) return Error.UnexpectedEndOfInput;
}

fn takeValueSlice(self: *Reader) []const u8 {
    const slice = if (self.written_to_scratch > 0)
        self.boundary_scratch[0..self.written_to_scratch]
    else
        return self.input[self.value_start..self.cursor];

    self.written_to_scratch = 0;
    self.value_start = self.cursor;
    return slice;
}

fn takeValueString(self: *Reader) ![]const u8 {
    const slice = self.takeValueSlice();
    if (!std.unicode.utf8ValidateSlice(slice)) {
        return Error.InvalidUtf8;
    }
    return slice;
}

fn expectByte(self: *Reader) !u8 {
    if (self.cursor >= self.input.len) {
        try self.refillBufferExpectMore(1);
    }

    return self.input[self.cursor];
}

fn parseFloatValue(T: anytype, slice: []const u8) T {
    const bits = @typeInfo(T).float.bits;
    const unsigned = @Type(.{
        .int = .{ .signedness = .unsigned, .bits = bits },
    });
    return @bitCast(std.mem.bigToNative(unsigned, std.mem.bytesAsValue(unsigned, slice).*));
}

/// Read the next token without allocating anything. Tokens may be non-terminal, and need to be read further.
pub fn next(self: *Reader) NextError!Token {
    const result = try self.nextInternal();
    if (self.isFinalToken(result)) {
        self.state = .end_of_document;
    }

    return result;
}

fn nextInternal(self: *Reader) NextError!Token {
    state_loop: while (true) {
        const state = self.state;
        switch (state) {
            .end_of_document => return .end_of_document,
            .value => {
                const byte = try self.expectByte();
                switch (byte) {
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
                            @memcpy(self.boundary_scratch[0..slice.len], slice);
                            self.last_buf_float_data = self.boundary_scratch[0..slice.len];
                            self.state = cont_state;
                            try self.refillBufferExpectMore(bits - remaining_len);
                            continue :state_loop;
                        }
                        self.cursor += bits;
                        if (byte == tags.Float) {
                            return .{ .f32 = parseFloatValue(f32, self.takeValueSlice()) };
                        } else {
                            return .{ .f64 = parseFloatValue(f64, self.takeValueSlice()) };
                        }
                    },
                    tags.sequence.Start => {
                        try self.collection_stack.append(self.gpa, .sequence);
                        self.cursor += 1;
                        return .sequence_start;
                    },
                    tags.sequence.End => {
                        if (self.collection_stack.pop() != .sequence) {
                            return Error.SyntaxError;
                        }
                        self.cursor += 1;
                        return .sequence_end;
                    },
                    tags.record.Start => {
                        try self.collection_stack.append(self.gpa, .record);
                        self.cursor += 1;
                        return .record_start;
                    },
                    tags.record.End => {
                        if (self.collection_stack.pop() != .record) {
                            return Error.SyntaxError;
                        }
                        self.cursor += 1;
                        return .record_end;
                    },
                    tags.set.Start => {
                        try self.collection_stack.append(self.gpa, .set);
                        self.cursor += 1;
                        return .set_start;
                    },
                    tags.set.End => {
                        if (self.collection_stack.pop() != .set) {
                            return Error.SyntaxError;
                        }
                        self.cursor += 1;
                        return .set_end;
                    },
                    tags.dictionary.Start => {
                        try self.collection_stack.append(self.gpa, .dictionary);
                        self.cursor += 1;
                        return .dictionary_start;
                    },
                    tags.dictionary.End => {
                        if (self.collection_stack.pop() != .dictionary) {
                            return Error.SyntaxError;
                        }
                        self.cursor += 1;
                        return .dictionary_end;
                    },
                    '0'...'9' => {
                        self.value_start = self.cursor;
                        self.cursor += 1;
                        self.state = .decimal;
                        continue :state_loop;
                    },
                    else => return Error.SyntaxError,
                }
            },
            .decimal => {
                // We should break out with an error
                while (true) {
                    const byte = try self.expectByte();

                    switch (byte) {
                        '0'...'9' => {
                            self.cursor += 1;

                            // Are we already writing to the scratch?
                            if (self.written_to_scratch > 0) {
                                // Write more!
                                // TODO: maybe use buffer writers instead to avoid tracking offsets.
                                self.boundary_scratch[self.written_to_scratch] = byte;
                                self.written_to_scratch += 1;

                                // Did we run out now? Give up.
                                if (self.written_to_scratch >= self.boundary_scratch.len) {
                                    return Token{ .partial_decimal = self.takeValueSlice() };
                                }
                                continue;
                            }

                            // Can we still consume the input?
                            if (self.cursor < self.input.len) {
                                continue;
                            }

                            // Ran out of input. Check if we can start using scratch buffer.
                            const slice = self.takeValueSlice();

                            // If boundary_scratch is too short to hold what we have so far (a big buffer for a big integer), give up
                            if (slice.len > self.boundary_scratch.len) {
                                return Token{ .partial_decimal = slice };
                            }

                            // We can use `boundary_scratch` to hold the string as we continue to parse.
                            @memcpy(self.boundary_scratch[0..slice.len], slice);
                            self.written_to_scratch = slice.len;
                            continue;
                        },
                        tags.int.Positive => {
                            self.state = .value;
                            const val = self.takeValueSlice();
                            self.cursor += 1;
                            return Token{ .positive_integer = .{ .buffered = val } };
                        },
                        tags.int.Negative => {
                            self.state = .value;
                            const val = self.takeValueSlice();
                            self.cursor += 1;
                            return Token{ .negative_integer = .{ .buffered = val } };
                        },
                        tags.Data, tags.String, tags.Symbol => {
                            const len_str = self.takeValueSlice();
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.remaining_bytes = try std.fmt.parseInt(usize, len_str, 10);
                            const remaining_buf_len = self.input.len - self.cursor;
                            if (self.remaining_bytes > remaining_buf_len) {
                                if (self.is_end_of_input) return error.UnexpectedEndOfInput;

                                self.cursor = self.input.len;
                                self.remaining_bytes -= remaining_buf_len;
                                return switch (byte) {
                                    tags.Data => {
                                        self.state = .data_continue;
                                        return Token{ .data = .{ .buffered_partial = self.takeValueSlice() } };
                                    },
                                    tags.String => {
                                        self.state = .string_continue;
                                        return Token{ .string = .{ .buffered_partial = try self.takeValueString() } };
                                    },
                                    tags.Symbol => {
                                        self.state = .symbol_continue;
                                        return Token{ .symbol = .{ .buffered_partial = try self.takeValueString() } };
                                    },
                                    else => unreachable,
                                };
                            } else {
                                self.cursor += self.remaining_bytes;
                                self.remaining_bytes = 0;
                                self.state = .value;
                                return switch (byte) {
                                    tags.Data => Token{ .data = .{ .buffered = self.takeValueSlice() } },
                                    tags.String => Token{ .string = .{ .buffered = try self.takeValueString() } },
                                    tags.Symbol => Token{ .symbol = .{ .buffered = try self.takeValueString() } },
                                    else => unreachable,
                                };
                            }
                        },
                        else => return Error.SyntaxError,
                    }

                    unreachable;
                }
                return Error.SyntaxError;
            },
            .float_continue, .double_continue => {
                const bits: usize = switch (state) {
                    .float_continue => 4,
                    .double_continue => 8,
                    else => unreachable,
                };

                const remaining_buf_len = self.input.len - self.cursor;
                if (remaining_buf_len == 0) {
                    try self.refillBufferExpectMore(bits);
                    continue :state_loop;
                }

                const remaining_in_float = bits - self.last_buf_float_data.len;
                if (remaining_in_float > remaining_buf_len) {
                    self.cursor = self.input.len - 1;
                    const slice = self.takeValueSlice();
                    @memcpy(self.boundary_scratch[self.last_buf_float_data.len..], slice);
                    self.last_buf_float_data = self.boundary_scratch[0 .. self.last_buf_float_data.len + slice.len];
                    try self.refillBufferExpectMore(remaining_in_float - remaining_buf_len);
                    continue :state_loop;
                }

                self.cursor += remaining_in_float;
                const slice = self.takeValueSlice();
                @memcpy(self.boundary_scratch[self.last_buf_float_data.len..bits], slice);
                self.last_buf_float_data = self.boundary_scratch[0 .. self.last_buf_float_data.len + slice.len];
                self.state = .value;
                return switch (state) {
                    .float_continue => Token{ .f32 = parseFloatValue(f32, self.last_buf_float_data) },
                    .double_continue => Token{ .f64 = parseFloatValue(f64, self.last_buf_float_data) },
                    else => unreachable,
                };
            },
            .data_continue, .string_continue, .symbol_continue => {
                const remaining_buf_len = self.input.len - self.cursor;
                if (remaining_buf_len == 0) {
                    try self.refillBufferExpectMore(self.remaining_bytes);
                    continue :state_loop;
                }

                if (self.remaining_bytes > remaining_buf_len) {
                    if (self.is_end_of_input) return Error.UnexpectedEndOfInput;

                    self.cursor = self.input.len;
                    self.remaining_bytes -= remaining_buf_len;

                    return switch (state) {
                        .data_continue => Token{ .data = .{ .buffered_partial = self.takeValueSlice() } },
                        .string_continue => Token{ .string = .{ .buffered_partial = try self.takeValueString() } },
                        .symbol_continue => Token{ .symbol = .{ .buffered_partial = try self.takeValueString() } },
                        else => unreachable,
                    };
                } else {
                    self.cursor += self.remaining_bytes;
                    self.remaining_bytes = 0;
                    self.state = .value;

                    return switch (state) {
                        .data_continue => Token{ .data = .{ .buffered = self.takeValueSlice() } },
                        .string_continue => Token{ .string = .{ .buffered = try self.takeValueString() } },
                        .symbol_continue => Token{ .symbol = .{ .buffered = try self.takeValueString() } },
                        else => unreachable,
                    };
                }
            },
        }
    }
}

fn isFinalToken(self: *Reader, token: Token) bool {
    // See if we are done, based on the state and the token.
    if (self.collection_stack.items.len == 0) {
        switch (token) {
            // If the stack is empty, these are always terminal states:
            .sequence_end,
            .record_end,
            .set_end,
            .dictionary_end,
            .positive_integer,
            .negative_integer,
            .true,
            .false,
            .f32,
            .f64,
            .end_of_document,
            => return true,
            // These may be terminal if they are at their end.
            .data,
            .string,
            .symbol,
            => |bytes| switch (bytes) {
                .buffered, .allocated => return true,
                else => return false,
            },
            // These are mid-process states.
            .sequence_start,
            .record_start,
            .set_start,
            .dictionary_start,
            .partial_decimal,
            => return false,
        }
    }

    return false;
}

fn appendSlice(gpa: Allocator, list: *std.ArrayList(u8), buf: []const u8, max_value_len: usize) !void {
    const new_len = std.math.add(usize, list.items.len, buf.len) catch return error.ValueTooLong;
    if (new_len > max_value_len) return error.ValueTooLong;
    try list.appendSlice(gpa, buf);
}

/// Check if the next token is a type that can be allocated. This check is not necessary to run before `nextAlloc` or `nextAllocMax`.
pub fn isNextTokenAllocatable(self: *Reader) !bool {
    return switch (self.state) {
        .value => switch (try self.expectByte()) {
            '0'...'9' => true, // in value mode, the only allocatable items begin with a numeral.
            else => false,
        },
        .decimal,
        .data_continue,
        .string_continue,
        .symbol_continue,
        .float_continue,
        .double_continue,
        .end_of_document,
        => false, // if we are already in the midst of getting a value, it's not allocatable.
    };
}

/// Read the next token, possibly performing allocations with `default_max_value_len` as the max allocatable length.
/// `when` is used to detemine whether to always separately allocate collections.
pub fn nextAlloc(self: *Reader, allocator: Allocator, when: AllocWhen) !Token {
    return self.nextAllocMax(allocator, when, default_max_value_len);
}

/// Read the next token, possibly performing allocations with a given `max_value_len` for the longest allocatable length.
/// `when` is used to detemine whether to always separately allocate collections.
pub fn nextAllocMax(self: *Reader, allocator: Allocator, when: AllocWhen, max_value_len: usize) !Token {
    if (!try self.isNextTokenAllocatable()) {
        return self.next();
    }

    var value_list = std.ArrayList(u8).empty;
    errdefer value_list.deinit(allocator);

    while (true) {
        const token = try self.next();
        switch (token) {
            .partial_decimal => |slice| {
                try appendSlice(self.gpa, &value_list, slice, max_value_len);
            },
            .positive_integer,
            .negative_integer,
            => |int| {
                const slice = int.buffered;
                if (when == .if_needed and value_list.items.len == 0) {
                    return token;
                }

                try appendSlice(self.gpa, &value_list, slice, max_value_len);
                const alloc_slice = try value_list.toOwnedSlice(self.gpa);
                return switch (token) {
                    .positive_integer => Token{ .positive_integer = .{ .allocated = alloc_slice } },
                    .negative_integer => Token{ .negative_integer = .{ .allocated = alloc_slice } },
                    else => unreachable,
                };
            },
            .data,
            .string,
            .symbol,
            => |bytes_type| switch (bytes_type) {
                .buffered_partial => |slice| {
                    try appendSlice(self.gpa, &value_list, slice, max_value_len);
                },
                .buffered => |slice| {
                    if (when == .if_needed and value_list.items.len == 0) {
                        return token;
                    }

                    try appendSlice(self.gpa, &value_list, slice, max_value_len);
                    const alloc_slice = try value_list.toOwnedSlice(self.gpa);
                    return switch (token) {
                        .data => Token{ .data = .{ .allocated = alloc_slice } },
                        .string => Token{ .string = .{ .allocated = alloc_slice } },
                        .symbol => Token{ .symbol = .{ .allocated = alloc_slice } },
                        else => unreachable,
                    };
                },
                .allocated => unreachable,
            },

            .sequence_start,
            .sequence_end,
            .record_start,
            .record_end,
            .set_start,
            .set_end,
            .dictionary_start,
            .dictionary_end,
            .true,
            .false,
            .f32,
            .f64,
            .end_of_document,
            => unreachable, // Only integers, data, strings, symbols are allowed here. Check isNextTokenTypeAllocatable() first.
        }
    }
}

pub fn init(gpa: Allocator, reader: *std.Io.Reader) Reader {
    return .{
        .collection_stack = .empty,
        .gpa = gpa,
        .underlying_reader = reader,
    };
}

pub fn deinit(self: *Reader) void {
    self.collection_stack.deinit(self.gpa);
    self.* = undefined;
}

// Testing methods follow.

fn expectEqualInteger(expected_integer: Integer, actual_integer: Integer) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected_integer), std.meta.activeTag(actual_integer));
    switch (expected_integer) {
        .buffered => |expected_slice| {
            try std.testing.expectEqualSlices(u8, expected_slice, actual_integer.buffered);
        },
        .allocated => |expected_slice| {
            try std.testing.expectEqualSlices(u8, expected_slice, actual_integer.allocated);
        },
    }
}

fn expectEqualData(expected_data: Data, actual_data: Data) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected_data), std.meta.activeTag(actual_data));
    switch (expected_data) {
        .buffered => |expected_slice| {
            try std.testing.expectEqualSlices(u8, expected_slice, actual_data.buffered);
        },
        .buffered_partial => |expected_slice| {
            try std.testing.expectEqualSlices(u8, expected_slice, actual_data.buffered_partial);
        },
        .allocated => |expected_slice| {
            try std.testing.expectEqualSlices(u8, expected_slice, actual_data.allocated);
        },
    }
}

fn expectEqualTokens(expected_token: Token, actual_token: Token) !void {
    std.testing.expectEqual(std.meta.activeTag(expected_token), std.meta.activeTag(actual_token)) catch |err| {
        return err;
    };
    switch (expected_token) {
        .f32 => |expected_value| {
            try std.testing.expectEqual(expected_value, actual_token.f32);
        },
        .f64 => |expected_value| {
            try std.testing.expectEqual(expected_value, actual_token.f64);
        },
        .positive_integer => |expected_integer| {
            try expectEqualInteger(expected_integer, actual_token.positive_integer);
        },
        .negative_integer => |expected_integer| {
            try expectEqualInteger(expected_integer, actual_token.negative_integer);
        },
        .data => |expected_data| {
            try expectEqualData(expected_data, actual_token.data);
        },
        .string => |expected_data| {
            try expectEqualData(expected_data, actual_token.string);
        },
        .symbol => |expected_data| {
            try expectEqualData(expected_data, actual_token.symbol);
        },
        .partial_decimal => |expected_data| {
            try std.testing.expectEqualSlices(u8, expected_data, actual_token.partial_decimal);
        },

        .sequence_start,
        .sequence_end,
        .record_start,
        .record_end,
        .set_start,
        .set_end,
        .dictionary_start,
        .dictionary_end,
        .true,
        .false,
        .end_of_document,
        => {},
    }
}

fn expectNext(self: *Reader, expected_token: Token) !void {
    return expectEqualTokens(expected_token, try self.next());
}

fn expectLast(self: *Reader, expected_token: Token) !void {
    try self.expectNext(expected_token);
    try self.expectEndOfDocument();
}

fn expectEndOfDocument(self: *Reader) !void {
    try std.testing.expectEqual(Token.end_of_document, try self.next());
}

test "simple datatypes" {
    var io_reader = std.Io.Reader.fixed("f");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try expectLast(&reader, .false);
    }

    io_reader = std.Io.Reader.fixed("t");
    reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try expectLast(&reader, .true);
    }

    io_reader = std.Io.Reader.fixed("502345+");
    reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try expectLast(&reader, .{ .positive_integer = .{ .buffered = "502345" } });
    }

    io_reader = std.Io.Reader.fixed("323-");
    reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try expectLast(&reader, .{ .negative_integer = .{ .buffered = "323" } });
    }
}

test "float datatypes" {
    var io_reader = std.Io.Reader.fixed(&[_]u8{ 'D', 64, 44, 204, 204, 204, 204, 204, 205 });
    var reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try expectLast(&reader, .{ .f64 = 14.4 });
    }

    io_reader = std.Io.Reader.fixed(&[_]u8{ 'F', 66, 105, 117, 195 });
    reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try expectLast(&reader, .{ .f32 = 58.365 });
    }
}

test "string datatype" {
    var io_reader = std.Io.Reader.fixed("26\"i love you, christine 😍");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try expectLast(&reader, .{ .string = .{ .buffered = "i love you, christine 😍" } });
    }

    io_reader = std.Io.Reader.fixed("6\"björn");
    reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try expectLast(&reader, .{ .string = .{ .buffered = "björn" } });
    }
}

test "data datatype" {
    var io_reader = std.Io.Reader.fixed(&[_]u8{ '5', ':', 69, 68, 67, 66, 65 });
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();
    try expectLast(&reader, .{ .data = .{ .buffered = &[_]u8{ 69, 68, 67, 66, 65 } } });
}

test "symbol datatype" {
    var io_reader = std.Io.Reader.fixed("6'hämta");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();
    try expectLast(&reader, .{ .symbol = .{ .buffered = "hämta" } });
}

test "sequence datatype" {
    var io_reader = std.Io.Reader.fixed("[6\"a test45+5'shark[170141183460469231731687303715884105690-15\"testing nesting]]");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try expectNext(&reader, .sequence_start);
    try expectNext(&reader, .{ .string = .{ .buffered = "a test" } });
    try expectNext(&reader, .{ .positive_integer = .{ .buffered = "45" } });
    try expectNext(&reader, .{ .symbol = .{ .buffered = "shark" } });
    try expectNext(&reader, .sequence_start);
    try expectNext(&reader, .{ .negative_integer = .{ .buffered = "170141183460469231731687303715884105690" } });
    try expectNext(&reader, .{ .string = .{ .buffered = "testing nesting" } });
    try expectNext(&reader, .sequence_end);
    try expectLast(&reader, .sequence_end);
}

test init {
    var io_reader = std.Io.Reader.fixed("<[5\"hello2456+]tf13'dogs-and-cats>");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try expectNext(&reader, .record_start);
    try expectNext(&reader, .sequence_start);
    try expectNext(&reader, .{ .string = .{ .buffered = "hello" } });
    try expectNext(&reader, .{ .positive_integer = .{ .buffered = "2456" } });
    try expectNext(&reader, .sequence_end);
    try expectNext(&reader, .true);
    try expectNext(&reader, .false);
    try expectNext(&reader, .{ .symbol = .{ .buffered = "dogs-and-cats" } });
    try expectLast(&reader, .record_end);
}

test "sets" {
    // Note that we do not validate set uniqueness - this would be difficult to do
    // without allocations. Could store a stack of sets, but it would make more sense
    // to validate when actually building structures instead of just returning tokens.
    var io_reader = std.Io.Reader.fixed("#[5\"hello2456+]ft13'cats-and-dogs$");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try expectNext(&reader, .set_start);
    try expectNext(&reader, .sequence_start);
    try expectNext(&reader, .{ .string = .{ .buffered = "hello" } });
    try expectNext(&reader, .{ .positive_integer = .{ .buffered = "2456" } });
    try expectNext(&reader, .sequence_end);
    try expectNext(&reader, .false);
    try expectNext(&reader, .true);
    try expectNext(&reader, .{ .symbol = .{ .buffered = "cats-and-dogs" } });
    try expectLast(&reader, .set_end);
}

test "set missing end token" {
    var io_reader = std.Io.Reader.fixed("#5\"hello");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try expectNext(&reader, .set_start);
    try expectNext(&reader, .{ .string = .{ .buffered = "hello" } });
    try std.testing.expectError(error.UnexpectedEndOfInput, reader.next());
}

test "dictionary datatype" {
    var io_reader = std.Io.Reader.fixed("{7'cabbage[22\"i love a good cabbage!3456-]5'shoes[22\"new shoes are the best23+]}");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try expectNext(&reader, .dictionary_start);
    try expectNext(&reader, .{ .symbol = .{ .buffered = "cabbage" } });
    try expectNext(&reader, .sequence_start);
    try expectNext(&reader, .{ .string = .{ .buffered = "i love a good cabbage!" } });
    try expectNext(&reader, .{ .negative_integer = .{ .buffered = "3456" } });
    try expectNext(&reader, .sequence_end);
    try expectNext(&reader, .{ .symbol = .{ .buffered = "shoes" } });
    try expectNext(&reader, .sequence_start);
    try expectNext(&reader, .{ .string = .{ .buffered = "new shoes are the best" } });
    try expectNext(&reader, .{ .positive_integer = .{ .buffered = "23" } });
    try expectNext(&reader, .sequence_end);
    try expectLast(&reader, .dictionary_end);
}

test "malformed record" {
    var io_reader = std.Io.Reader.fixed("<[5\"hello2456+]]tf13'dogs-and-cats>");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try expectNext(&reader, .record_start);
    try expectNext(&reader, .sequence_start);
    try expectNext(&reader, .{ .string = .{ .buffered = "hello" } });
    try expectNext(&reader, .{ .positive_integer = .{ .buffered = "2456" } });
    try expectNext(&reader, .sequence_end);
    try std.testing.expectError(Error.SyntaxError, reader.next());
}

test "malformed record 2" {
    var io_reader = std.Io.Reader.fixed("<[5\"hello2456+>]tf13'dogs-and-cats>");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try expectNext(&reader, .record_start);
    try expectNext(&reader, .sequence_start);
    try expectNext(&reader, .{ .string = .{ .buffered = "hello" } });
    try expectNext(&reader, .{ .positive_integer = .{ .buffered = "2456" } });
    try std.testing.expectError(Error.SyntaxError, reader.next());
}

test "incomplete string" {
    var io_reader = std.Io.Reader.fixed("5000\"nasty");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try expectNext(&reader, .{ .string = .{ .buffered_partial = "nasty" } });
    try std.testing.expectError(Error.UnexpectedEndOfInput, reader.next());
}

var read_buf: [256]u8 = undefined;

test "boundary int using scratch" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = "234235234234" },
        .{ .buffer = "234234-" },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();

    try expectLast(&reader, .{ .negative_integer = .{ .buffered = "234235234234234234" } });
}

test "boundary int overflowing scratch" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = "0123456789" },
        .{ .buffer = "0123456789" },
        .{ .buffer = "0123456789" },
        .{ .buffer = "012345-" },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();

    try expectNext(&reader, .{ .partial_decimal = "01234567890123456789012345678901" });
    try expectLast(&reader, .{ .negative_integer = .{ .buffered = "2345" } });
}

test "boundary int alloc" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = "234235234234" },
        .{ .buffer = "234234-" },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();

    const token = try reader.nextAlloc(std.testing.allocator, .always);
    defer std.testing.allocator.free(token.negative_integer.allocated);
    try expectEqualTokens(.{ .negative_integer = .{ .allocated = "234235234234234234" } }, token);
    try reader.expectEndOfDocument();
}

test "boundary float" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = &.{ 'F', 66, 105 } },
        .{ .buffer = &.{ 117, 195 } },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();

    try expectLast(&reader, .{ .f32 = 58.365 });
}

test "boundary double" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = &.{ 'D', 64, 44, 204, 204 } },
        .{ .buffer = &.{ 204, 204, 204, 205 } },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();
    try expectLast(&reader, .{ .f64 = 14.4 });
}

test "boundary double 2" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = &.{'D'} },
        .{ .buffer = &.{ 64, 44, 204, 204, 204, 204, 204, 205 } },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();
    try expectLast(&reader, .{ .f64 = 14.4 });
}

test "boundary string" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = "20\"hello this is" },
        .{ .buffer = " a test" },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();

    try expectNext(&reader, .{ .string = .{ .buffered_partial = "hello this is" } });
    try expectLast(&reader, .{ .string = .{ .buffered = " a test" } });
}

test nextAlloc {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = "45\"hello this is" },
        .{ .buffer = " a test of the" },
        .{ .buffer = " buffering system!" },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();

    const alloc = try reader.nextAlloc(std.testing.allocator, .if_needed);
    try reader.expectEndOfDocument();
    defer std.testing.allocator.free(alloc.string.allocated);
    try expectEqualTokens(
        .{ .string = .{ .allocated = "hello this is a test of the buffering system!" } },
        alloc,
    );
}
