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

pub const BytesType = union(enum) {
    /// The bytes contain the full data, and are not separately allocated from the input buffer.
    terminal: []const u8,
    /// The bytes do not contain the end of the data. At least one more BytesType will be returned with more data. This field of the union is only returned if you are using the non-allocating `next`.
    non_terminal: []const u8,
    /// Contains the full data, with the slice being allocated separately from the input buffer.
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

    /// We parsed, and possibly allocated, a positive integer
    positive_integer: BytesType,
    /// We parsed, and possibly allocated, a negative integer
    negative_integer: BytesType,
    /// We parsed, and possibly allocated, data
    data: BytesType,
    /// We parsed, and possibly allocated, a string
    string: BytesType,
    /// We parsed, and possibly allocated, a symbol
    symbol: BytesType,

    /// We have reached the end of the document
    end_of_document,
};

const State = enum {
    /// We are parsing a value
    value,
    /// We are parsing what could be an integer, or a length specifier
    integer_or_length,
    /// We are in the middle of parsing data, and need to continue after allocating
    data_continue,
    /// We are in the middle of parsing a string, and need to continue after allocating
    string_continue,
    /// We are in the middle of parsing a symbol, and need to continue after allocating
    symbol_continue,
    /// We are in the middle of parsing a float, and need to continue after allocating
    float_continue,
    /// We are in the middle of parsing a double, and need to continue after allocating
    double_continue,
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

/// Extra scratch space for floats that cross buffer boundaries
float_scratch: [8]u8 = undefined,

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
    const slice = self.input[self.value_start..self.cursor];
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
    state_loop: while (true) {
        const state = self.state;
        switch (state) {
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
                            @memcpy(self.float_scratch[0..slice.len], slice);
                            self.last_buf_float_data = self.float_scratch[0..slice.len];
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
                        tags.int.Positive => {
                            self.state = .value;
                            const val = self.takeValueSlice();
                            self.cursor += 1;
                            return Token{ .positive_integer = .{ .terminal = val } };
                        },
                        tags.int.Negative => {
                            self.state = .value;
                            const val = self.takeValueSlice();
                            self.cursor += 1;
                            return Token{ .negative_integer = .{ .terminal = val } };
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
                                        return Token{ .data = .{ .non_terminal = self.takeValueSlice() } };
                                    },
                                    tags.String => {
                                        self.state = .string_continue;
                                        return Token{ .string = .{ .non_terminal = try self.takeValueString() } };
                                    },
                                    tags.Symbol => {
                                        self.state = .symbol_continue;
                                        return Token{ .symbol = .{ .non_terminal = try self.takeValueString() } };
                                    },
                                    else => unreachable,
                                };
                            } else {
                                self.cursor += self.remaining_bytes;
                                self.remaining_bytes = 0;
                                self.state = .value;
                                return switch (byte) {
                                    tags.Data => Token{ .data = .{ .terminal = self.takeValueSlice() } },
                                    tags.String => Token{ .string = .{ .terminal = try self.takeValueString() } },
                                    tags.Symbol => Token{ .symbol = .{ .terminal = try self.takeValueString() } },
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
                if (remaining_buf_len == 0) {
                    try self.refillBufferExpectMore(bits);
                    continue :state_loop;
                }

                const remaining_in_float = bits - self.last_buf_float_data.len;
                if (remaining_in_float > remaining_buf_len) {
                    self.cursor = self.input.len - 1;
                    const slice = self.takeValueSlice();
                    @memcpy(self.float_scratch[self.last_buf_float_data.len..], slice);
                    self.last_buf_float_data = self.float_scratch[0 .. self.last_buf_float_data.len + slice.len];
                    try self.refillBufferExpectMore(remaining_in_float - remaining_buf_len);
                    continue :state_loop;
                }

                self.cursor += remaining_in_float;
                const slice = self.takeValueSlice();
                @memcpy(self.float_scratch[self.last_buf_float_data.len..bits], slice);
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
                if (remaining_buf_len == 0) {
                    try self.refillBufferExpectMore(self.remaining_bytes);
                    continue :state_loop;
                }

                if (self.remaining_bytes > remaining_buf_len) {
                    if (self.is_end_of_input) return Error.UnexpectedEndOfInput;

                    self.cursor = self.input.len;
                    self.remaining_bytes -= remaining_buf_len;

                    return switch (state) {
                        .data_continue => Token{ .data = .{ .non_terminal = self.takeValueSlice() } },
                        .string_continue => Token{ .string = .{ .non_terminal = try self.takeValueString() } },
                        .symbol_continue => Token{ .symbol = .{ .non_terminal = try self.takeValueString() } },
                        else => unreachable,
                    };
                } else {
                    self.cursor += self.remaining_bytes;
                    self.remaining_bytes = 0;
                    self.state = .value;

                    return switch (state) {
                        .data_continue => Token{ .data = .{ .terminal = self.takeValueSlice() } },
                        .string_continue => Token{ .string = .{ .terminal = try self.takeValueString() } },
                        .symbol_continue => Token{ .symbol = .{ .terminal = try self.takeValueString() } },
                        else => unreachable,
                    };
                }
            },
        }
    }
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
        .integer_or_length,
        .data_continue,
        .string_continue,
        .symbol_continue,
        .float_continue,
        .double_continue,
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
            .positive_integer,
            .negative_integer,
            .data,
            .string,
            .symbol,
            => |bytes_type| switch (bytes_type) {
                .non_terminal => |slice| {
                    try appendSlice(self.gpa, &value_list, slice, max_value_len);
                },
                .terminal => |slice| {
                    if (when == .if_needed and value_list.items.len == 0) {
                        return token;
                    }

                    try appendSlice(self.gpa, &value_list, slice, max_value_len);
                    const alloc_slice = try value_list.toOwnedSlice(self.gpa);
                    return switch (token) {
                        .positive_integer => Token{ .positive_integer = .{ .allocated = alloc_slice } },
                        .negative_integer => Token{ .negative_integer = .{ .allocated = alloc_slice } },
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

fn expectEqualBytesType(expected_bytes_type: BytesType, actual_bytes_type: BytesType) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected_bytes_type), std.meta.activeTag(actual_bytes_type));
    switch (expected_bytes_type) {
        .terminal => |expected_slice| {
            try std.testing.expectEqualSlices(u8, expected_slice, actual_bytes_type.terminal);
        },
        .non_terminal => |expected_slice| {
            try std.testing.expectEqualSlices(u8, expected_slice, actual_bytes_type.non_terminal);
        },
        .allocated => |expected_slice| {
            try std.testing.expectEqualSlices(u8, expected_slice, actual_bytes_type.allocated);
        },
    }
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

test "simple datatypes" {
    var io_reader = std.Io.Reader.fixed("f");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try expectNext(&reader, .false);
    }

    io_reader = std.Io.Reader.fixed("t");
    reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try expectNext(&reader, .true);
    }

    io_reader = std.Io.Reader.fixed("502345+");
    reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try expectNext(&reader, .{ .positive_integer = .{ .terminal = "502345" } });
    }

    io_reader = std.Io.Reader.fixed("323-");
    reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try expectNext(&reader, .{ .negative_integer = .{ .terminal = "323" } });
    }
}

test "float datatypes" {
    var io_reader = std.Io.Reader.fixed(&[_]u8{ 'D', 64, 44, 204, 204, 204, 204, 204, 205 });
    var reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try expectNext(&reader, .{ .f64 = 14.4 });
    }

    io_reader = std.Io.Reader.fixed(&[_]u8{ 'F', 66, 105, 117, 195 });
    reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try expectNext(&reader, .{ .f32 = 58.365 });
    }
}

test "string datatype" {
    var io_reader = std.Io.Reader.fixed("26\"i love you, christine 😍");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try expectNext(&reader, .{ .string = .{ .terminal = "i love you, christine 😍" } });
    }

    io_reader = std.Io.Reader.fixed("6\"björn");
    reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try expectNext(&reader, .{ .string = .{ .terminal = "björn" } });
    }
}

test "data datatype" {
    var io_reader = std.Io.Reader.fixed(&[_]u8{ '5', ':', 69, 68, 67, 66, 65 });
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();
    try expectNext(&reader, .{ .data = .{ .terminal = &[_]u8{ 69, 68, 67, 66, 65 } } });
}

test "symbol datatype" {
    var io_reader = std.Io.Reader.fixed("6'hämta");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();
    try expectNext(&reader, .{ .symbol = .{ .terminal = "hämta" } });
}

test "sequence datatype" {
    var io_reader = std.Io.Reader.fixed("[6\"a test45+5'shark[170141183460469231731687303715884105690-15\"testing nesting]]");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try expectNext(&reader, .sequence_start);
    try expectNext(&reader, .{ .string = .{ .terminal = "a test" } });
    try expectNext(&reader, .{ .positive_integer = .{ .terminal = "45" } });
    try expectNext(&reader, .{ .symbol = .{ .terminal = "shark" } });
    try expectNext(&reader, .sequence_start);
    try expectNext(&reader, .{ .negative_integer = .{ .terminal = "170141183460469231731687303715884105690" } });
    try expectNext(&reader, .{ .string = .{ .terminal = "testing nesting" } });
    try expectNext(&reader, .sequence_end);
    try expectNext(&reader, .sequence_end);
}

test init {
    var io_reader = std.Io.Reader.fixed("<[5\"hello2456+]tf13'dogs-and-cats>");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try expectNext(&reader, .record_start);
    try expectNext(&reader, .sequence_start);
    try expectNext(&reader, .{ .string = .{ .terminal = "hello" } });
    try expectNext(&reader, .{ .positive_integer = .{ .terminal = "2456" } });
    try expectNext(&reader, .sequence_end);
    try expectNext(&reader, .true);
    try expectNext(&reader, .false);
    try expectNext(&reader, .{ .symbol = .{ .terminal = "dogs-and-cats" } });
    try expectNext(&reader, .record_end);
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
    try expectNext(&reader, .{ .string = .{ .terminal = "hello" } });
    try expectNext(&reader, .{ .positive_integer = .{ .terminal = "2456" } });
    try expectNext(&reader, .sequence_end);
    try expectNext(&reader, .false);
    try expectNext(&reader, .true);
    try expectNext(&reader, .{ .symbol = .{ .terminal = "cats-and-dogs" } });
    try expectNext(&reader, .set_end);
}

test "set missing end token" {
    var io_reader = std.Io.Reader.fixed("#5\"hello");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try expectNext(&reader, .set_start);
    try expectNext(&reader, .{ .string = .{ .terminal = "hello" } });
    try std.testing.expectError(error.UnexpectedEndOfInput, reader.next());
}

test "dictionary datatype" {
    var io_reader = std.Io.Reader.fixed("{7'cabbage[22\"i love a good cabbage!3456-]5'shoes[22\"new shoes are the best23+]}");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try expectNext(&reader, .dictionary_start);
    try expectNext(&reader, .{ .symbol = .{ .terminal = "cabbage" } });
    try expectNext(&reader, .sequence_start);
    try expectNext(&reader, .{ .string = .{ .terminal = "i love a good cabbage!" } });
    try expectNext(&reader, .{ .negative_integer = .{ .terminal = "3456" } });
    try expectNext(&reader, .sequence_end);
    try expectNext(&reader, .{ .symbol = .{ .terminal = "shoes" } });
    try expectNext(&reader, .sequence_start);
    try expectNext(&reader, .{ .string = .{ .terminal = "new shoes are the best" } });
    try expectNext(&reader, .{ .positive_integer = .{ .terminal = "23" } });
    try expectNext(&reader, .sequence_end);
    try expectNext(&reader, .dictionary_end);
}

test "malformed record" {
    var io_reader = std.Io.Reader.fixed("<[5\"hello2456+]]tf13'dogs-and-cats>");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try expectNext(&reader, .record_start);
    try expectNext(&reader, .sequence_start);
    try expectNext(&reader, .{ .string = .{ .terminal = "hello" } });
    try expectNext(&reader, .{ .positive_integer = .{ .terminal = "2456" } });
    try expectNext(&reader, .sequence_end);
    try std.testing.expectError(Error.SyntaxError, reader.next());
}

test "malformed record 2" {
    var io_reader = std.Io.Reader.fixed("<[5\"hello2456+>]tf13'dogs-and-cats>");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try expectNext(&reader, .record_start);
    try expectNext(&reader, .sequence_start);
    try expectNext(&reader, .{ .string = .{ .terminal = "hello" } });
    try expectNext(&reader, .{ .positive_integer = .{ .terminal = "2456" } });
    try std.testing.expectError(Error.SyntaxError, reader.next());
}

test "incomplete string" {
    var io_reader = std.Io.Reader.fixed("5000\"nasty");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try expectNext(&reader, .{ .string = .{ .non_terminal = "nasty" } });
    try std.testing.expectError(Error.UnexpectedEndOfInput, reader.next());
}

var read_buf: [256]u8 = undefined;
test "boundary float" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = &.{ 'F', 66, 105 } },
        .{ .buffer = &.{ 117, 195 } },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();

    try expectNext(&reader, .{ .f32 = 58.365 });
}

test "boundary double" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = &.{ 'D', 64, 44, 204, 204 } },
        .{ .buffer = &.{ 204, 204, 204, 205 } },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();
    try expectNext(&reader, .{ .f64 = 14.4 });
}

test "boundary double 2" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = &.{'D'} },
        .{ .buffer = &.{ 64, 44, 204, 204, 204, 204, 204, 205 } },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();
    try expectNext(&reader, .{ .f64 = 14.4 });
}

test "boundary string" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = "20\"hello this is" },
        .{ .buffer = " a test" },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();

    try expectNext(&reader, .{ .string = .{ .non_terminal = "hello this is" } });
    try expectNext(&reader, .{ .string = .{ .terminal = " a test" } });
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
    defer std.testing.allocator.free(alloc.string.allocated);
    try expectEqualTokens(
        .{ .string = .{ .allocated = "hello this is a test of the buffering system!" } },
        alloc,
    );
}
