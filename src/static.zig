const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Reader = @import("Reader.zig");
pub fn Parsed(comptime T: type) type {
    return struct {
        arena: *ArenaAllocator,
        value: T,

        pub fn deinit(self: @This()) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self.arena);
        }
    };
}

pub const ParseOptions = struct {
    max_value_len: ?usize = null,
};

pub const ParseFromValueError = std.fmt.ParseIntError || std.fmt.ParseFloatError || Allocator.Error || error{
    ValueTooLong,
    UnexpectedToken,
    InvalidNumber,
    Overflow,
    InvalidEnumTag,
    DuplicateField,
    UnknownField,
    MissingField,
    LengthMismatch,
};

const s_syrup_parse = "syrupParse";

pub fn ParseError(comptime Source: type) type {
    return ParseFromValueError || error{ InvalidState, UnexpectedAdditionalInput } || Source.NextError;
}

pub fn parseFromSlice(
    comptime T: type,
    allocator: Allocator,
    s: []const u8,
    options: ParseOptions,
) ParseError(Reader)!Parsed(T) {
    var parsed = Parsed(T){
        .arena = try allocator.create(ArenaAllocator),
        .value = undefined,
    };
    errdefer allocator.destroy(parsed.arena);
    parsed.arena.* = ArenaAllocator.init(allocator);
    errdefer parsed.arena.deinit();

    var input = std.Io.Reader.fixed(s);
    var source = Reader.init(parsed.arena.allocator(), &input);
    defer source.deinit();
    parsed.value = try innerParse(T, parsed.arena.allocator(), &source, options);
    const n = try source.next();
    if (n != .end_of_document) {
        return error.UnexpectedAdditionalInput;
    }
    return parsed;
}

pub fn parse(comptime T: type, allocator: Allocator, input: *std.Io.Reader, options: ParseOptions) ParseError(Reader)!Parsed(T) {
    var parsed = Parsed(T){
        .arena = try allocator.create(ArenaAllocator),
        .value = undefined,
    };
    errdefer allocator.destroy(parsed.arena);
    parsed.arena.* = ArenaAllocator.init(allocator);
    errdefer parsed.arena.deinit();

    var reader = Reader.init(parsed.arena.allocator(), input);
    defer reader.deinit();
    parsed.value = try innerParse(T, parsed.arena.allocator(), &reader, options);
    if (try reader.next() != .end_of_document) {
        return error.UnexpectedAdditionalInput;
    }
    return parsed;
}

fn innerParse(
    comptime T: type,
    allocator: Allocator,
    source: *Reader,
    options: ParseOptions,
) ParseError(@TypeOf(source.*))!T {
    const info = @typeInfo(T);
    switch (info) {
        .bool => {
            return switch (try source.next()) {
                .true => true,
                .false => false,
                else => error.UnexpectedToken,
            };
        },
        .comptime_float => {
            const token = try source.nextAllocMax(allocator, .if_needed, options.max_value_len orelse Reader.default_max_value_len);
            defer freeAllocated(allocator, token);

            switch (token) {
                .f32, .f64 => |val| return val,
                else => return error.UnexpectedToken,
            }
        },
        .float => |f_info| {
            const token = try source.nextAllocMax(allocator, .if_needed, options.max_value_len orelse Reader.default_max_value_len);
            defer freeAllocated(allocator, token);

            switch (f_info.bits) {
                32 => {
                    switch (token) {
                        .f32 => |val| return val,
                        .f64 => return error.Overflow,
                        else => return error.UnexpectedToken,
                    }
                },
                64 => {
                    switch (token) {
                        .f32, .f64 => |val| return val,
                        else => return error.UnexpectedToken,
                    }
                },
                else => @compileError("Only 64 or 32-bit floats allowed"),
            }
        },
        .int, .comptime_int => {
            const token = try source.nextAllocMax(allocator, .if_needed, options.max_value_len orelse Reader.default_max_value_len);
            defer freeAllocated(allocator, token);
            switch (token) {
                .int => |packet| return try packet.toInt(T),
                else => return error.UnexpectedToken,
            }
        },
        .optional => |optional_info| {
            if (try source.isNextTokenFalse()) {
                _ = try source.next();
                return null;
            } else return try innerParse(optional_info.child, allocator, source, options);
        },
        .@"enum" => {
            if (std.meta.hasFn(T, s_syrup_parse)) {
                return T.syrupParse(allocator, source, options);
            }

            const token = try source.nextAllocMax(allocator, .if_needed, options.max_value_len orelse Reader.default_max_value_len);
            defer freeAllocated(allocator, token);
            switch (token) {
                .int => |int_packet| {
                    return std.enums.fromInt(T, try int_packet.toInt(usize)) orelse return error.InvalidEnumTag;
                },
                .data, .string, .symbol => |data_packet| {
                    return std.meta.stringToEnum(T, data_packet.buffer) orelse error.InvalidEnumTag;
                },
                else => return error.UnexpectedToken,
            }
        },
        .@"union" => @compileError("not impl"),
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                if (.sequence_start != try source.next()) return error.UnexpectedToken;

                var r: T = undefined;
                inline for (0..struct_info.fields.len) |i| {
                    r[i] = try innerParse(struct_info.fields[i].type, allocator, source, options);
                }

                if (.sequence_end != try source.next()) return error.UnexpectedToken;

                return r;
            }

            @compileError("only tuples right now");
        },
        .array => |array_info| {
            switch (try source.peekNextTokenType()) {
                .sequence_start => {
                    return internalParseSequence(T, array_info.child, allocator, source, options);
                },
                .decimal => {
                    if (array_info.child != u8) return error.UnexpectedToken;

                    var r: T = undefined;
                    var i: usize = 0;
                    // Keep parsing the bytestring and copying to result without unnecessary allocation.
                    while (true) {
                        switch (try source.next()) {
                            .data, .string, .symbol => |packet| {
                                if (packet.more) {
                                    if (i + packet.buffer.len > r.len) return error.LengthMismatch;
                                    @memcpy(r[i..][0..packet.buffer.len], packet.buffer);
                                } else {
                                    if (i + packet.buffer.len != r.len) return error.LengthMismatch;
                                    @memcpy(r[i..][0..packet.buffer.len], packet.buffer);
                                    break;
                                }

                                i += packet.buffer.len;
                            },
                            else => return error.UnexpectedToken,
                        }
                    }

                    return r;
                },
                else => return error.UnexpectedToken,
            }
        },
        .vector => |vector_info| {
            switch (try source.peekNextTokenType()) {
                .sequence_start => {
                    const A = [vector_info.len]vector_info.child;
                    return try internalParseSequence(A, vector_info.child, allocator, source, options);
                },
                else => return error.UnexpectedToken,
            }
        },
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .one => {
                    const r: *ptr_info.child = try allocator.create(ptr_info.child);
                    r.* = try innerParse(ptr_info.child, allocator, source, options);
                    return r;
                },
                .slice => {
                    switch (try source.peekNextTokenType()) {
                        .sequence_start => {
                            _ = try source.next();

                            var arraylist: std.ArrayList(ptr_info.child) = .empty;
                            while (true) {
                                switch (try source.peekNextTokenType()) {
                                    .sequence_end => {
                                        _ = try source.next();
                                        break;
                                    },
                                    else => {},
                                }

                                try arraylist.append(allocator, try innerParse(ptr_info.child, allocator, source, options));
                            }

                            if (ptr_info.sentinel()) |s| {
                                return try arraylist.toOwnedSliceSentinel(allocator, s);
                            }

                            return try arraylist.toOwnedSlice(allocator);
                        },
                        .decimal => {
                            // Let us hope it is a string.
                            if (ptr_info.child != u8) return error.UnexpectedToken;

                            if (ptr_info.sentinel()) |s| {
                                var value_list: std.ArrayList(u8) = .empty;
                                _ = try source.allocNextIntoArrayListMax(&value_list, .alloc_always, options.max_value_len orelse Reader.default_max_value_len);
                                return try value_list.toOwnedSliceSentinel(allocator, s);
                            }
                            if (ptr_info.is_const) {
                                switch (try source.nextAllocMax(allocator, .always, options.max_value_len orelse Reader.default_max_value_len)) {
                                    inline .string, .data, .symbol => |packet| {
                                        return packet.buffer;
                                    },
                                    else => unreachable,
                                }
                            } else {
                                switch (try source.nextAllocMax(allocator, .always, options.max_value_len orelse Reader.default_max_value_len)) {
                                    .data, .string, .symbol => |packet| return packet.buffer,
                                    else => unreachable,
                                }
                            }
                        },
                        else => return error.UnexpectedToken,
                    }
                },
                else => @compileError("Unable to parse into type '" ++ @typeName(T) ++ "'"),
            }
        },
        else => @compileError("Unable to parse into type '" ++ @typeName(T) ++ "'"),
    }
}

fn freeAllocated(allocator: Allocator, token: Reader.Token) void {
    switch (token) {
        .string, .symbol, .data => |data_packet| {
            data_packet.deinit(allocator);
        },
        .int => |int_packet| {
            int_packet.deinit(allocator);
        },
        else => {},
    }
}

fn internalParseSequence(
    comptime T: type,
    comptime Child: type,
    allocator: Allocator,
    source: *Reader,
    options: ParseOptions,
) !T {
    std.debug.assert(.sequence_start == try source.next());

    var r: T = undefined;
    for (&r) |*elem| {
        elem.* = try innerParse(Child, allocator, source, options);
    }

    if (.sequence_end != try source.next()) return error.UnexpectedToken;

    return r;
}

test parseFromSlice {
    const parsed_int = try parseFromSlice(i64, std.testing.allocator, "456+", .{});
    defer parsed_int.deinit();

    try std.testing.expectEqual(456, parsed_int.value);

    const parsed_f64 = try parseFromSlice(f64, std.testing.allocator, &[_]u8{ 68, 64, 76, 55, 10, 61, 112, 163, 215 }, .{});
    defer parsed_f64.deinit();
    try std.testing.expectEqual(@as(f64, 56.43), parsed_f64.value);

    const parsed_optional = try parseFromSlice(?f64, std.testing.allocator, "f", .{});
    defer parsed_optional.deinit();
    try std.testing.expectEqual(null, parsed_optional.value);
}

const TestEnum = enum {
    one,
    two,
    six,
};

const TestNonExhaustEnum = enum(u32) {
    one,
    two,
    three,
    _,
};

test "enum" {
    const parsed_enum = try parseFromSlice(TestEnum, std.testing.allocator, "3\"one", .{});
    defer parsed_enum.deinit();
    try std.testing.expectEqual(.one, parsed_enum.value);
}

test "non-exhaustive enum" {
    const parsed_enum = try parseFromSlice(TestNonExhaustEnum, std.testing.allocator, "685+", .{});
    defer parsed_enum.deinit();
    try std.testing.expectEqual(685, @intFromEnum(parsed_enum.value));
}

test "arrays" {
    const parsed_slice = try parseFromSlice([3]i23, std.testing.allocator, "[685+11-89+]", .{});
    defer parsed_slice.deinit();
    try std.testing.expectEqual([_]i23{ 685, -11, 89 }, parsed_slice.value);
}

test "bytestrings" {
    const parsed_slice = try parseFromSlice([3][3]u8, std.testing.allocator, "[3'sym3\"str3:byt]", .{});
    defer parsed_slice.deinit();
    try std.testing.expectEqualStrings("sym", &parsed_slice.value[0]);
    try std.testing.expectEqualStrings("str", &parsed_slice.value[1]);
    try std.testing.expectEqualStrings("byt", &parsed_slice.value[2]);
}

test "string slices" {
    const parsed_slice = try parseFromSlice([]const u8, std.testing.allocator, "6'foobar", .{});
    defer parsed_slice.deinit();
    try std.testing.expectEqualStrings("foobar", parsed_slice.value);
}

test "nested slices" {
    const parsed_slice = try parseFromSlice([][]const u8, std.testing.allocator, "[2'hi5:there]", .{});
    defer parsed_slice.deinit();
    try std.testing.expectEqualDeep(&[_][]const u8{ "hi", "there" }, parsed_slice.value);
}

var read_buf: [256]u8 = undefined;
test "parse with reader" {
    var reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = "31\"this is a test! " },
        .{ .buffer = "of some text :)" },
    });
    const result = try parse([]const u8, std.testing.allocator, &reader.interface, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings("this is a test! of some text :)", result.value);
}

test "parse vector" {
    var reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = "[3+4" },
        .{ .buffer = "-8" },
        .{ .buffer = "+]" },
    });
    const result = try parse(@Vector(3, i64), std.testing.allocator, &reader.interface, .{});
    defer result.deinit();

    try std.testing.expectEqual(@Vector(3, i64){ 3, -4, 8 }, result.value);
}

test "tuples" {
    const parsed_slice = try parseFromSlice(struct { []const u8, []const u8, u8 }, std.testing.allocator, "[2'ab3'bab20+]", .{});
    defer parsed_slice.deinit();
    try std.testing.expectEqualDeep(.{ "ab", "bab", 20 }, parsed_slice.value);
}

test "simple pointer" {
    const parsed_slice = try parseFromSlice(*i3, std.testing.allocator, "3+", .{});
    defer parsed_slice.deinit();
    try std.testing.expectEqualDeep(3, parsed_slice.value.*);
}
