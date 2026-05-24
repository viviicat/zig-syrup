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

/// Describes where a buffer is stored in memory.
pub const BufferStorage = enum {
    /// Buffer memory is shared with the input buffer.
    buffer,
    /// Buffer memory is separately allocated on the heap.
    heap,
};

/// A complete integer stored as a bytestring.
pub const IntPacket = struct {
    const Sign = enum {
        positive,
        negative,
    };

    /// The integer as a string, stored as base10 characters. This may be allocated or a slice of the buffer depending on the value of `storage`.
    buffer: []const u8,
    /// Where the data is stored.
    storage: BufferStorage,

    sign: Sign,

    fn buffered(buf: []const u8, sign: Sign) IntPacket {
        return .{ .buffer = buf, .storage = .buffer, .sign = sign };
    }
    fn heaped(buf: []const u8, sign: Sign) IntPacket {
        return .{ .buffer = buf, .storage = .heap, .sign = sign };
    }

    /// Possibly release memory, depending on the value of `storage`.
    pub fn deinit(self: IntPacket, gpa: std.mem.Allocator) void {
        if (self.storage == .heap) {
            gpa.free(self.buffer);
        }
    }

    pub fn eql(self: IntPacket, other: IntPacket) bool {
        return self.storage == other.storage and
            self.sign == other.sign and
            std.mem.eql(u8, self.buffer, other.buffer);
    }

    /// Convert from `IntPacket` to any integer that can fit it.
    pub fn toInt(self: IntPacket, T: anytype) std.fmt.ParseIntError!T {
        const signedness = switch (@typeInfo(T)) {
            .int => |i| i.signedness,
            else => @compileError(@typeName(T) ++ " is not an integer type"),
        };

        var int = try std.fmt.parseInt(T, self.buffer, 10);
        if (self.sign == .negative) {
            if (signedness == .signed) {
                int = -int;
            } else return error.Overflow;
        }

        return int;
    }
};

/// A packet of data for a string, data object, or symbol.
pub const DataPacket = struct {
    /// The data. If `more` is true, subsequent `DataPacket`s will contain more data for the same object, until `more` is false.
    buffer: []const u8,
    /// Where the data is stored. When using `next`, this is always `BufferStorage.buffer`. When using `nextAlloc`, it may be `BufferStorage.heap` depending on the settings.
    storage: BufferStorage,
    /// If true, there will be more packets associated with the bytestring, string or symbol.
    /// `more` is never true when using `nextAlloc` or `nextAllocMax`.
    more: bool,

    fn buffered(buffer: []const u8) DataPacket {
        return .{
            .buffer = buffer,
            .storage = .buffer,
            .more = false,
        };
    }

    fn bufferedPartial(buffer: []const u8) DataPacket {
        return .{
            .buffer = buffer,
            .storage = .buffer,
            .more = true,
        };
    }

    fn heaped(buffer: []const u8) DataPacket {
        return .{
            .buffer = buffer,
            .storage = .heap,
            .more = false,
        };
    }

    /// Possibly release memory, depending on the value of `storage`.
    pub fn deinit(self: DataPacket, gpa: std.mem.Allocator) void {
        if (self.storage == .heap) {
            gpa.free(self.buffer);
        }
    }
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
    /// The reader attempts to avoid this case by using `boundary_scratch`, but if the number string doesn't fit in 64 bytes, it gives up and returns this.
    /// This slice is not allocated.
    partial_decimal: []const u8,

    /// We parsed, and possibly allocated, an integer
    int: IntPacket,
    /// We parsed, and possibly allocated, data
    data: DataPacket,
    /// We parsed, and possibly allocated, a string
    string: DataPacket,
    /// We parsed, and possibly allocated, a symbol
    symbol: DataPacket,

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
/// TODO: don't allocate for this? Can we just have a ludicrous depth like 1024?
collection_stack: std.ArrayList(CollectionMode),
/// Bytes remaining in the current value
remaining_bytes: usize = 0,
/// True if we've reached the end of the input.
is_end_of_input: bool = false,

/// Extra scratch space for floats and integers that cross buffer boundaries
/// For integers, we attempt to use this but if the integer is humongous we will give up, as it could be any length
boundary_scratch: [64]u8 = undefined,
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
    const unsigned = @Int(.signed, bits);
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

                        if (self.cursor == self.input.len) {
                            // dang, we ran out of input before even getting to .decimal.
                            // Throw it in scratch!
                            self.boundary_scratch[0] = byte;
                            self.written_to_scratch = 1;
                        }

                        continue :state_loop;
                    },
                    else => return Error.SyntaxError,
                }
            },
            .decimal => {
                // infinite loop shouldn't be possible as we are always advancing and will eventually hit an error.
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
                            return Token{ .int = .buffered(val, .positive) };
                        },
                        tags.int.Negative => {
                            self.state = .value;
                            const val = self.takeValueSlice();
                            self.cursor += 1;
                            return Token{ .int = .buffered(val, .negative) };
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
                                        return Token{ .data = .bufferedPartial(self.takeValueSlice()) };
                                    },
                                    tags.String => {
                                        self.state = .string_continue;
                                        return Token{ .string = .bufferedPartial(try self.takeValueString()) };
                                    },
                                    tags.Symbol => {
                                        self.state = .symbol_continue;
                                        return Token{ .symbol = .bufferedPartial(try self.takeValueString()) };
                                    },
                                    else => unreachable,
                                };
                            } else {
                                self.cursor += self.remaining_bytes;
                                self.remaining_bytes = 0;
                                self.state = .value;
                                return switch (byte) {
                                    tags.Data => Token{ .data = .buffered(self.takeValueSlice()) },
                                    tags.String => Token{ .string = .buffered(try self.takeValueString()) },
                                    tags.Symbol => Token{ .symbol = .buffered(try self.takeValueString()) },
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
                        .data_continue => Token{ .data = .bufferedPartial(self.takeValueSlice()) },
                        .string_continue => Token{ .string = .bufferedPartial(try self.takeValueString()) },
                        .symbol_continue => Token{ .symbol = .bufferedPartial(try self.takeValueString()) },
                        else => unreachable,
                    };
                } else {
                    self.cursor += self.remaining_bytes;
                    self.remaining_bytes = 0;
                    self.state = .value;

                    return switch (state) {
                        .data_continue => Token{ .data = .buffered(self.takeValueSlice()) },
                        .string_continue => Token{ .string = .buffered(try self.takeValueString()) },
                        .symbol_continue => Token{ .symbol = .buffered(try self.takeValueString()) },
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
            .int,
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
            => |packet| return !packet.more,
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

/// If true, the next token will be False.
pub fn isNextTokenFalse(self: *Reader) !bool {
    return switch (self.state) {
        .value => switch (try self.expectByte()) {
            tags.False => true,
            else => false,
        },
        .decimal,
        .data_continue,
        .string_continue,
        .symbol_continue,
        .float_continue,
        .double_continue,
        .end_of_document,
        => false,
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
            .int,
            => |int| {
                if (when == .if_needed and value_list.items.len == 0) {
                    return token;
                }

                try appendSlice(self.gpa, &value_list, int.buffer, max_value_len);
                const alloc_slice = try value_list.toOwnedSlice(self.gpa);
                return Token{ .int = .heaped(alloc_slice, token.int.sign) };
            },
            .data,
            .string,
            .symbol,
            => |packet| if (packet.more) {
                try appendSlice(self.gpa, &value_list, packet.buffer, max_value_len);
            } else {
                if (when == .if_needed and value_list.items.len == 0) {
                    return token;
                }

                try appendSlice(self.gpa, &value_list, packet.buffer, max_value_len);
                const alloc_slice = try value_list.toOwnedSlice(self.gpa);
                return switch (token) {
                    .data => Token{ .data = .heaped(alloc_slice) },
                    .string => Token{ .string = .heaped(alloc_slice) },
                    .symbol => Token{ .symbol = .heaped(alloc_slice) },
                    else => unreachable,
                };
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

fn expectEqualIntPacket(expected_packet: IntPacket, actual_packet: IntPacket) !void {
    try std.testing.expectEqual(expected_packet.storage, actual_packet.storage);
    try std.testing.expectEqualSlices(u8, expected_packet.buffer, actual_packet.buffer);
}

fn expectEqualDataPacket(expected_packet: DataPacket, actual_packet: DataPacket) !void {
    try std.testing.expectEqual(expected_packet.storage, actual_packet.storage);
    try std.testing.expectEqual(expected_packet.more, actual_packet.more);
    try std.testing.expectEqualSlices(u8, expected_packet.buffer, actual_packet.buffer);
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
        .int => |expected_packet| {
            try expectEqualIntPacket(expected_packet, actual_token.int);
        },
        .data => |expected_packet| {
            try expectEqualDataPacket(expected_packet, actual_token.data);
        },
        .string => |expected_packet| {
            try expectEqualDataPacket(expected_packet, actual_token.string);
        },
        .symbol => |expected_packet| {
            try expectEqualDataPacket(expected_packet, actual_token.symbol);
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
    try expectEqualTokens(expected_token, try self.next());
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
        _ = try reader.expectLast(.false);
    }

    io_reader = std.Io.Reader.fixed("t");
    reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try reader.expectLast(.true);
    }

    io_reader = std.Io.Reader.fixed("502345+");
    reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try reader.expectLast(.{ .int = .buffered("502345", .positive) });
    }

    io_reader = std.Io.Reader.fixed("323-");
    reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try reader.expectLast(.{ .int = .buffered("323", .negative) });
    }
}

test "float datatypes" {
    var io_reader = std.Io.Reader.fixed(&[_]u8{ 'D', 64, 44, 204, 204, 204, 204, 204, 205 });
    var reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try reader.expectLast(.{ .f64 = 14.4 });
    }

    io_reader = std.Io.Reader.fixed(&[_]u8{ 'F', 66, 105, 117, 195 });
    reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try reader.expectLast(.{ .f32 = 58.365 });
    }
}

test "string datatype" {
    var io_reader = std.Io.Reader.fixed("26\"i love you, christine 😍");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try reader.expectLast(.{ .string = .buffered("i love you, christine 😍") });
    }

    io_reader = std.Io.Reader.fixed("6\"björn");
    reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        try reader.expectLast(.{ .string = .buffered("björn") });
    }
}

test "data datatype" {
    var io_reader = std.Io.Reader.fixed(&[_]u8{ '5', ':', 69, 68, 67, 66, 65 });
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();
    try reader.expectLast(.{ .data = .buffered(&[_]u8{ 69, 68, 67, 66, 65 }) });
}

test "symbol datatype" {
    var io_reader = std.Io.Reader.fixed("6'hämta");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();
    try reader.expectLast(.{ .symbol = .buffered("hämta") });
}

test "sequence datatype" {
    var io_reader = std.Io.Reader.fixed("[6\"a test45+5'shark[170141183460469231731687303715884105690-15\"testing nesting]]");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try reader.expectNext(.sequence_start);
    try reader.expectNext(.{ .string = .buffered("a test") });
    try reader.expectNext(.{ .int = .buffered("45", .positive) });
    try reader.expectNext(.{ .symbol = .buffered("shark") });
    try reader.expectNext(.sequence_start);
    try reader.expectNext(.{ .int = .buffered("170141183460469231731687303715884105690", .negative) });
    try reader.expectNext(.{ .string = .buffered("testing nesting") });
    try reader.expectNext(.sequence_end);
    try reader.expectLast(.sequence_end);
}

test init {
    var io_reader = std.Io.Reader.fixed("<[5\"hello2456+]tf13'dogs-and-cats>");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try reader.expectNext(.record_start);
    try reader.expectNext(.sequence_start);
    try reader.expectNext(.{ .string = .buffered("hello") });
    try reader.expectNext(.{ .int = .buffered("2456", .positive) });
    try reader.expectNext(.sequence_end);
    try reader.expectNext(.true);
    try reader.expectNext(.false);
    try reader.expectNext(.{ .symbol = .buffered("dogs-and-cats") });
    try reader.expectLast(.record_end);
}

test "sets" {
    // Note that we do not validate set uniqueness - this would be difficult to do
    // without allocations. Could store a stack of sets, but it would make more sense
    // to validate when actually building structures instead of just returning tokens.
    var io_reader = std.Io.Reader.fixed("#[5\"hello2456+]ft13'cats-and-dogs$");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try reader.expectNext(.set_start);
    try reader.expectNext(.sequence_start);
    try reader.expectNext(.{ .string = .buffered("hello") });
    try reader.expectNext(.{ .int = .buffered("2456", .positive) });
    try reader.expectNext(.sequence_end);
    try reader.expectNext(.false);
    try reader.expectNext(.true);
    try reader.expectNext(.{ .symbol = .buffered("cats-and-dogs") });
    try reader.expectLast(.set_end);
}

test "set missing end token" {
    var io_reader = std.Io.Reader.fixed("#5\"hello");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try reader.expectNext(.set_start);
    try reader.expectNext(.{ .string = .buffered("hello") });
    try std.testing.expectError(error.UnexpectedEndOfInput, reader.next());
}

test "dictionary datatype" {
    var io_reader = std.Io.Reader.fixed("{7'cabbage[22\"i love a good cabbage!3456-]5'shoes[22\"new shoes are the best23+]}");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try reader.expectNext(.dictionary_start);
    try reader.expectNext(.{ .symbol = .buffered("cabbage") });
    try reader.expectNext(.sequence_start);
    try reader.expectNext(.{ .string = .buffered("i love a good cabbage!") });
    try reader.expectNext(.{ .int = .buffered("3456", .negative) });
    try reader.expectNext(.sequence_end);
    try reader.expectNext(.{ .symbol = .buffered("shoes") });
    try reader.expectNext(.sequence_start);
    try reader.expectNext(.{ .string = .buffered("new shoes are the best") });
    try reader.expectNext(.{ .int = .buffered("23", .positive) });
    try reader.expectNext(.sequence_end);
    try reader.expectLast(.dictionary_end);
}

test "malformed record" {
    var io_reader = std.Io.Reader.fixed("<[5\"hello2456+]]tf13'dogs-and-cats>");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try reader.expectNext(.record_start);
    try reader.expectNext(.sequence_start);
    try reader.expectNext(.{ .string = .buffered("hello") });
    try reader.expectNext(.{ .int = .buffered("2456", .positive) });
    try reader.expectNext(.sequence_end);
    try std.testing.expectError(Error.SyntaxError, reader.next());
}

test "malformed record 2" {
    var io_reader = std.Io.Reader.fixed("<[5\"hello2456+>]tf13'dogs-and-cats>");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try reader.expectNext(.record_start);
    try reader.expectNext(.sequence_start);
    try reader.expectNext(.{ .string = .buffered("hello") });
    try reader.expectNext(.{ .int = .buffered("2456", .positive) });
    try std.testing.expectError(Error.SyntaxError, reader.next());
}

test "incomplete string" {
    var io_reader = std.Io.Reader.fixed("5000\"nasty");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    defer reader.deinit();

    try reader.expectNext(.{ .string = .bufferedPartial("nasty") });
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

    try reader.expectLast(.{ .int = .buffered("234235234234234234", .negative) });
}

test "boundary int overflowing scratch" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = "0123456789" },
        .{ .buffer = "0123456789" },
        .{ .buffer = "0123456789" },
        .{ .buffer = "0123456789" },
        .{ .buffer = "0123456789" },
        .{ .buffer = "0123456789" },
        .{ .buffer = "0123456789" },
        .{ .buffer = "012345-" },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();

    try reader.expectNext(.{ .partial_decimal = "0123456789012345678901234567890123456789012345678901234567890123" });
    try reader.expectLast(.{ .int = .buffered("456789012345", .negative) });
}

test "boundary int alloc" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = "234235234234" },
        .{ .buffer = "234234-" },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();

    const token = try reader.nextAlloc(std.testing.allocator, .always);
    defer token.int.deinit(std.testing.allocator);
    try expectEqualTokens(.{ .int = .heaped("234235234234234234", .negative) }, token);
    try reader.expectEndOfDocument();
}

test "boundary float" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = &.{ 'F', 66, 105 } },
        .{ .buffer = &.{ 117, 195 } },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();

    try reader.expectLast(.{ .f32 = 58.365 });
}

test "boundary double" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = &.{ 'D', 64, 44, 204, 204 } },
        .{ .buffer = &.{ 204, 204, 204, 205 } },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();
    try reader.expectLast(.{ .f64 = 14.4 });
}

test "boundary double 2" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = &.{'D'} },
        .{ .buffer = &.{ 64, 44, 204, 204, 204, 204, 204, 205 } },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();
    try reader.expectLast(.{ .f64 = 14.4 });
}

test "boundary string" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = "20\"hello this is" },
        .{ .buffer = " a test" },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();

    try reader.expectNext(.{ .string = .bufferedPartial("hello this is") });
    try reader.expectLast(.{ .string = .buffered(" a test") });
}

// Test if the string length crosses a boundary (complicated!)
test "boundary string length" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = "10" },
        .{ .buffer = "5\"i like to eat peanut butter and jelly " },
        .{ .buffer = "sandwiches and eat peas and carrots, and " },
        .{ .buffer = "then for dessert, peaches." },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();

    try reader.expectNext(.{ .string = .bufferedPartial("i like to eat peanut butter and jelly ") });
    try reader.expectNext(.{ .string = .bufferedPartial("sandwiches and eat peas and carrots, and ") });
    try reader.expectLast(.{ .string = .buffered("then for dessert, peaches.") });
}

// Test if the string length crosses a boundary on the first digit (shromplicated!)
test "boundary string length first-digit" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = "2" },
        .{ .buffer = "0\"hello this is" },
        .{ .buffer = " a test" },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();

    try reader.expectNext(.{ .string = .bufferedPartial("hello this is") });
    try reader.expectLast(.{ .string = .buffered(" a test") });
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
    defer alloc.string.deinit(std.testing.allocator);
    try expectEqualTokens(
        .{ .string = .heaped("hello this is a test of the buffering system!") },
        alloc,
    );

    try reader.expectEndOfDocument();
}

test "unreasonably large buffer boundary length specifier" {
    var io_reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = "4526" },
        .{ .buffer = "9999" },
        .{ .buffer = "999999999999'According to all known" },
    });
    var reader = Reader.init(std.testing.allocator, &io_reader.interface);
    defer reader.deinit();

    try std.testing.expectError(error.Overflow, reader.next());
}

test "to int conversion" {
    var io_reader = std.Io.Reader.fixed("502345+");
    var reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        const token = try reader.next();
        try std.testing.expectEqual(502345, try token.int.toInt(i64));
    }

    io_reader = std.Io.Reader.fixed("323-");
    reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        const token = try reader.next();
        try std.testing.expectEqual(-323, try token.int.toInt(i64));
    }

    io_reader = std.Io.Reader.fixed("323-");
    reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        const token = try reader.next();
        try std.testing.expectError(error.Overflow, token.int.toInt(u64));
    }

    io_reader = std.Io.Reader.fixed("32399299299299299929929929-");
    reader = Reader.init(std.testing.allocator, &io_reader);
    {
        defer reader.deinit();
        const token = try reader.next();
        try std.testing.expectError(error.Overflow, token.int.toInt(i32));
    }
}
