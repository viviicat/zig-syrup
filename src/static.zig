const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const CollectionMode = @import("collections.zig").CollectionMode;
const Reader = @import("Reader.zig");
const Writer = @import("Writer.zig");
const dynamic = @import("dynamic.zig");

// XXX TODO WARNING: This can potentially result in an infinitely large structure,
// dictated by the input. We need to establish limits.

/// A value that has been parsed by `parse` or similar.
pub fn Parsed(comptime T: type) type {
    return struct {
        arena: *ArenaAllocator,
        value: T,

        /// Free all resources allocated inside the value.
        pub fn deinit(self: @This()) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self.arena);
        }
    };
}

/// Options for parsing.
pub const ParseOptions = struct {
    /// The maximum length a string-like value can have. If not set, defaults to 4MB.
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
    return ParseFromValueError || error{ InvalidState, UnexpectedAdditionalInput, MismatchedTypes } || Source.NextError;
}

/// Parse a value of the provided type directly from a slice of Syrup.
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

/// Parse a value of the provided type from a `std.Io.Reader` that is outputting binary Syrup.
pub fn parse(
    comptime T: type,
    allocator: Allocator,
    input: *std.Io.Reader,
    options: ParseOptions,
) ParseError(Reader)!Parsed(T) {
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
            defer token.deinit(allocator);

            switch (token) {
                .f32, .f64 => |val| return val,
                else => return error.UnexpectedToken,
            }
        },
        .float => |f_info| {
            const token = try source.nextAllocMax(allocator, .if_needed, options.max_value_len orelse Reader.default_max_value_len);
            defer token.deinit(allocator);

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
            defer token.deinit(allocator);
            switch (token) {
                .int => |packet| return try packet.toInt(T),
                else => return error.UnexpectedToken,
            }
        },
        .optional => |optional_info| {
            if (try source.peekNextTokenType() == .false) {
                _ = try source.next();
                return null;
            } else return try innerParse(optional_info.child, allocator, source, options);
        },
        .@"enum" => {
            if (std.meta.hasFn(T, s_syrup_parse)) {
                return T.syrupParse(allocator, source, options);
            }

            const token = try source.nextAllocMax(allocator, .if_needed, options.max_value_len orelse Reader.default_max_value_len);
            defer token.deinit(allocator);
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
        .@"union" => |union_info| {
            if (std.meta.hasFn(T, s_syrup_parse)) {
                return T.syrupParse(allocator, source, options);
            }

            if (T == dynamic.Value) {
                return try internalParseValue(allocator, source, options);
            }

            if (union_info.tag_type == null) @compileError("Unable to parse into untagged union '" ++ @typeName(T) ++ "'");

            const syrup_spec: ?Writer.spec.Union = if (@hasDecl(T, Writer.s_syrup_spec)) T.syrup_spec else null;
            const start_token = try source.next();
            const read_record_field_label: bool = blk: switch (start_token) {
                .dictionary_start => true,
                .record_start => {
                    if (syrup_spec) |spec| {
                        if (spec.format == .record_merge) {
                            break :blk false;
                        }
                    }
                    break :blk true;
                },
                else => {
                    return error.UnexpectedToken;
                },
            };

            const name_token: Reader.Token = try source.nextAllocMax(allocator, .if_needed, options.max_value_len orelse Reader.default_max_value_len);
            const name_label_packet = switch (name_token) {
                inline .data, .symbol, .string => |packet| packet,
                else => return error.UnexpectedToken,
            };

            var result: T = undefined;
            inline for (union_info.fields) |u_field| {
                const field_info = @typeInfo(u_field.type);

                if (syrup_spec) |spec| {
                    if (spec.format == .record_merge and field_info == .@"union") @compileError("Unable to deserialize unions which contain unions in record_merge mode!");
                }

                // Need to check this at comptime to avoid comptime evaluation of the 'else' case for managed dictionaries!
                const is_hash_map_like = field_info == .@"struct" and
                    @hasDecl(u_field.type, "KV") and
                    (@hasDecl(u_field.type, "empty") or std.meta.hasFn(u_field.type, "init"));

                if (read_record_field_label or is_hash_map_like or field_info != .@"struct") {
                    if (std.mem.eql(u8, u_field.name, name_label_packet.buffer)) {
                        name_label_packet.deinit(allocator);

                        result = @unionInit(T, u_field.name, try innerParse(u_field.type, allocator, source, options));
                        break;
                    }
                } else {
                    // In this branch of code, we definitely read a struct in record format, and we
                    // need to match on the type based on the parsed label. Need to check for a spec,
                    // in case the struct was renamed.
                    const field_spec: ?Writer.spec.Struct = if (@hasDecl(u_field.type, Writer.s_syrup_spec)) u_field.type.syrup_spec else null;
                    const type_name = if (field_spec) |spec|
                        switch (spec.format) {
                            .record => |rec| rec.name orelse @typeName(u_field.type),
                            else => @typeName(u_field.type),
                        }
                    else
                        @typeName(u_field.type);

                    if (std.mem.eql(u8, type_name, name_label_packet.buffer)) {
                        name_label_packet.deinit(allocator);
                        // We matched. Cannot call unionInit directly, because we already parsed the
                        // record start and label! So we will manually assign fields.
                        var f: u_field.type = undefined;
                        inline for (@typeInfo(u_field.type).@"struct".fields) |inner_field| {
                            if (inner_field.is_comptime) @compileError("comptime fields are not supported: " ++ @typeName(T) ++ "." ++ inner_field.name);
                            @field(f, inner_field.name) = try innerParse(inner_field.type, allocator, source, options);
                        }

                        result = @unionInit(T, u_field.name, f);
                        break;
                    }
                }
            } else {
                return error.UnknownField;
            }

            const end_token = try source.next();
            switch (start_token) {
                .dictionary_start => if (end_token != .dictionary_end) return error.UnexpectedToken,
                .record_start => if (end_token != .record_end) return error.UnexpectedToken,
                else => unreachable,
            }

            return result;
        },
        .@"struct" => |struct_info| {
            if (std.meta.hasFn(T, s_syrup_parse)) {
                return T.syrupParse(allocator, source, options);
            }

            if (struct_info.is_tuple) {
                if (.sequence_start != try source.next()) return error.UnexpectedToken;

                var r: T = undefined;
                inline for (struct_info.fields, 0..) |field, i| {
                    r[i] = try innerParse(field.type, allocator, source, options);
                }

                if (.sequence_end != try source.next()) return error.UnexpectedToken;

                return r;
            }

            const syrup_spec: ?Writer.spec.Struct = if (@hasDecl(T, Writer.s_syrup_spec)) T.syrup_spec else null;

            const start_token = try source.next();

            const is_hash_map_like = @hasDecl(T, "KV");
            if (syrup_spec == null and is_hash_map_like) {
                const is_managed = std.meta.hasFn(T, "init");

                var r: T = if (is_managed)
                    .init(allocator)
                else if (@hasDecl(T, "empty"))
                    .empty
                else
                    @compileError("found hashmap or set-like structure '" ++ @typeName(T) ++ "', but it was missing .empty decl or init() function");

                const kv_fields = @typeInfo(@field(T, "KV")).@"struct".fields;
                const K = kv_fields[0].type;
                const V = kv_fields[1].type;
                switch (V) {
                    void => {
                        if (start_token != .set_start) {
                            return error.UnexpectedToken;
                        }

                        // TODO: we may want to have an error for duplicate keys,
                        // for now we just clobber.
                        if (std.meta.hasFn(T, "put")) {
                            while (true) {
                                switch (try source.peekNextTokenType()) {
                                    .set_end => break,
                                    .dictionary_end,
                                    .record_end,
                                    .sequence_end,
                                    .end_of_document,
                                    => return error.UnexpectedToken,
                                    else => {},
                                }

                                const key = try innerParse(K, allocator, source, options);
                                if (is_managed) {
                                    try r.put(key, {});
                                } else {
                                    try r.put(allocator, key, {});
                                }
                            }
                        } else @compileError("Found what looks like a set (has a KV decl with a void value) but it doesn't have `put` function");
                    },
                    else => {
                        if (start_token != .dictionary_start) {
                            return error.UnexpectedToken;
                        }

                        // TODO: we may want to have an error for duplicate keys,
                        // for now we just clobber.
                        if (std.meta.hasFn(T, "put")) {
                            while (true) {
                                switch (try source.peekNextTokenType()) {
                                    .dictionary_end => break,
                                    .set_end,
                                    .record_end,
                                    .sequence_end,
                                    .end_of_document,
                                    => return error.UnexpectedToken,
                                    else => {},
                                }

                                const key = try innerParse(K, allocator, source, options);
                                const value = try innerParse(V, allocator, source, options);
                                if (is_managed) {
                                    try r.put(key, value);
                                } else {
                                    try r.put(allocator, key, value);
                                }
                            }
                        } else @compileError("Found what looks like a dictionary (has a KV decl with non-void value) but it doesn't have `put` function");
                    },
                }

                // consume the end token.
                _ = try source.next();
                return r;
            }

            const structure_type: CollectionMode = switch (start_token) {
                .sequence_start => if (syrup_spec) |spec| switch (spec.format) {
                    .sequence => .sequence,
                    .sequence_record => .record,
                    .sequence_dictionary => .dictionary,
                    else => return error.UnexpectedToken,
                } else if (struct_info.is_tuple) .sequence else .dictionary,
                .dictionary_start => .dictionary,
                .record_start => .record,
                else => return error.UnexpectedToken,
            };

            var r: T = undefined;

            if (structure_type == .record) {
                const type_name = if (syrup_spec) |spec|
                    switch (spec.format) {
                        inline .record, .sequence_record => |rec| rec.name orelse @typeName(T),
                        else => @typeName(T),
                    }
                else
                    @typeName(T);

                if (!try source.compareNext(type_name)) {
                    return error.MismatchedTypes;
                }
            }

            if (structure_type != .dictionary) {
                inline for (struct_info.fields) |field| {
                    if (field.is_comptime) @compileError("comptime fields are not supported: " ++ @typeName(T) ++ "." ++ field.name);
                    @field(r, field.name) = try innerParse(field.type, allocator, source, options);
                }
            } else {
                var fields_seen: [struct_info.fields.len]bool = @splat(false);

                while (true) {
                    const name_token: Reader.Token = try source.nextAllocMax(allocator, .if_needed, options.max_value_len orelse Reader.default_max_value_len);
                    const parsed_field_name_packet: Reader.DataPacket = switch (name_token) {
                        inline .string, .data, .symbol => |packet| packet,

                        .dictionary_end => if (start_token == .dictionary_start)
                            break
                        else
                            return error.UnexpectedToken,

                        .sequence_end => if (start_token == .sequence_start)
                            break
                        else
                            return error.UnexpectedToken,

                        else => return error.UnexpectedToken,
                    };

                    inline for (struct_info.fields, 0..) |field, i| {
                        if (field.is_comptime) @compileError("comptime fields are not supported: " ++ @typeName(T) ++ "." ++ field.name);
                        if (std.mem.eql(u8, field.name, parsed_field_name_packet.buffer)) {
                            parsed_field_name_packet.deinit(allocator);

                            if (fields_seen[i]) {
                                // For now this is the only option, json parser has some options we might want.
                                return error.DuplicateField;
                            }

                            @field(r, field.name) = try innerParse(field.type, allocator, source, options);
                            fields_seen[i] = true;
                            break;
                        }
                    }
                }

                try fillDefaultStructValues(T, &r, &fields_seen);

                return r; // Already parsed the end token.
            }

            const end_token = try source.next();
            switch (start_token) {
                .dictionary_start => if (end_token != .dictionary_end) return error.UnexpectedToken,
                .sequence_start => if (end_token != .sequence_end) return error.UnexpectedToken,
                .record_start => if (end_token != .record_end) return error.UnexpectedToken,
                else => unreachable,
            }

            return r;
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
                                _ = try source.allocNextIntoArrayListMax(&value_list, .always, options.max_value_len orelse Reader.default_max_value_len);
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

/// Parse a `dynamic.Value` from the source.
fn internalParseValue(allocator: Allocator, source: *Reader, options: ParseOptions) !dynamic.Value {
    switch (try source.peekNextTokenType()) {
        .true => {
            _ = try source.next();
            return .true;
        },
        .false => {
            _ = try source.next();
            return .false;
        },
        .dictionary_start,
        .record_start,
        .sequence_start,
        .set_start,
        => |start_token| {
            _ = try source.next();

            const label: ?*const dynamic.Value = if (start_token == .record_start)
                try innerParse(*const dynamic.Value, allocator, source, options)
            else
                null;

            var array_list: std.ArrayList(dynamic.Value) = .empty;
            while (true) {
                switch (try source.peekNextTokenType()) {
                    .dictionary_end => if (start_token == .dictionary_start)
                        break
                    else
                        return error.UnexpectedToken,
                    .set_end => if (start_token == .set_start)
                        break
                    else
                        return error.UnexpectedToken,
                    .sequence_end => if (start_token == .sequence_start)
                        break
                    else
                        return error.UnexpectedToken,
                    .record_end => if (start_token == .record_start)
                        break
                    else
                        return error.UnexpectedToken,
                    .sequence_start,
                    .record_start,
                    .set_start,
                    .dictionary_start,
                    .true,
                    .false,
                    .f32,
                    .f64,
                    .decimal,
                    => {},
                    else => return error.UnexpectedToken,
                }

                try array_list.append(allocator, try innerParse(dynamic.Value, allocator, source, options));
            }

            // Consume end token matched above
            _ = try source.next();

            const slice = try array_list.toOwnedSlice(allocator);

            switch (start_token) {
                .dictionary_start => return .{ .dictionary = slice },
                .set_start => return .{ .set = slice },
                .sequence_start => return .{ .sequence = slice },
                .record_start => return .{
                    .record = .{
                        .label = label.?,
                        .fields = slice,
                    },
                },
                else => unreachable,
            }
        },
        .f32 => {
            return .{ .f32 = try innerParse(f32, allocator, source, options) };
        },
        .f64 => {
            return .{ .f64 = try innerParse(f64, allocator, source, options) };
        },
        .decimal => {
            // Either it's a number, or a string-like. Let's figure out which it is.
            const token = try source.nextAllocMax(allocator, .always, options.max_value_len orelse Reader.default_max_value_len);
            switch (token) {
                .int => |packet| {
                    const val = packet.toIntValue();
                    token.deinit(allocator); // no longer needed.
                    return val;
                },
                .string => |packet| return .{ .string = packet.buffer },
                .data => |packet| return .{ .data = packet.buffer },
                .symbol => |packet| return .{ .symbol = packet.buffer },
                else => return error.UnexpectedToken,
            }
        },
        .sequence_end,
        .set_end,
        .dictionary_end,
        .record_end,
        .end_of_document,
        => return error.UnexpectedToken,
    }
}

fn fillDefaultStructValues(comptime T: type, r: *T, fields_seen: *[@typeInfo(T).@"struct".fields.len]bool) !void {
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        if (!fields_seen[i]) {
            if (field.defaultValue()) |default| {
                @field(r, field.name) = default;
            } else {
                return error.MissingField;
            }
        }
    }
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

test "slice of strings" {
    const parsed_slice = try parseFromSlice([][]const u8, std.testing.allocator, "[2'hi5:there]", .{});
    defer parsed_slice.deinit();
    try std.testing.expectEqualDeep(&[_][]const u8{ "hi", "there" }, parsed_slice.value);
}

test "nested data slices" {
    const parsed_slice = try parseFromSlice([]const []const u64, std.testing.allocator, "[[42+420+][67+69+]]", .{});
    defer parsed_slice.deinit();
    try std.testing.expectEqualDeep(&[_][]const u64{ &[_]u64{ 42, 420 }, &[_]u64{ 67, 69 } }, parsed_slice.value);
}

var read_buf: [256]u8 = undefined;
test parse {
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

const TestingRecord = struct {
    pub const syrup_spec = Writer.spec.Struct{
        .format = .{ .record = .{} },
    };

    const Pronoun = struct {
        pub const syrup_spec = Writer.spec.Struct{
            .format = .{ .sequence_record = .{ .name = "rec:prn" } },
        };

        const Form = enum {
            singular,
            plural,
        };

        value: []const u8,
        form: Form,
    };

    const Flags = struct {
        happy: bool = false,
        hungry: bool = true,
        tired: bool,
        excited: bool,
    };

    const User = struct {
        pub const syrup_spec = Writer.spec.Struct{
            .format = .sequence,
        };

        name: []const u8,
        pronouns: []const Pronoun,
        flags: Flags,
    };

    user: User,
    free_mem: usize,
};

test "struct!" {
    const parsed_slice = try parseFromSlice(TestingRecord, std.testing.allocator, "<20'static.TestingRecord[2\"vv[[7'rec:prn3\"she8'singular][7'rec:prn4\"vaer6'plural]]{5'happyf6'hungryt5'tiredf7'excitedt}]256+>", .{});
    defer parsed_slice.deinit();
    try std.testing.expectEqualDeep(TestingRecord{
        .free_mem = 256,
        .user = .{
            .name = "vv",
            .flags = .{ .excited = true, .tired = false },
            .pronouns = &[_]TestingRecord.Pronoun{
                .{ .form = .singular, .value = "she" },
                .{ .form = .plural, .value = "vaer" },
            },
        },
    }, parsed_slice.value);
}

const UnionTest = union(enum) {
    const syrup_spec = Writer.spec.Union{ .format = .{ .record_merge = .symbol } };
    const Foo = struct {
        const syrup_spec = Writer.spec.Struct{ .format = .{ .record = .{} } };

        a: i64,
        b: i64,
    };

    foo: Foo,
    bar: u64,
    multi_foo: []const Foo,
};

test "union" {
    const parsed_slice = try parseFromSlice([]const UnionTest, std.testing.allocator, "[<20'static.UnionTest.Foo42+56+><3'bar45+><9'multi_foo[<20'static.UnionTest.Foo48+56+><20'static.UnionTest.Foo43+51->]>]", .{});
    defer parsed_slice.deinit();
    try std.testing.expectEqualDeep(&[_]UnionTest{
        .{ .foo = .{ .a = 42, .b = 56 } },
        .{ .bar = 45 },
        .{ .multi_foo = &[_]UnionTest.Foo{
            .{ .a = 48, .b = 56 },
            .{ .a = 43, .b = -51 },
        } },
    }, parsed_slice.value);
}

const DictUnionTest = union(enum) {
    const Foo = struct {
        a: i64,
        b: i64,
    };

    foo: Foo,
    bar: u64,
    multi_foo: []const Foo,
};

test "dictionary union" {
    const parsed_slice = try parseFromSlice([]const DictUnionTest, std.testing.allocator, "[{3'foo{1'a55+1'b99-}}{3'bar45+}{9'multi_foo[{1'a48+1'b56+}{1'a43+1'b51-}]}]", .{});
    defer parsed_slice.deinit();
    try std.testing.expectEqualDeep(&[_]DictUnionTest{
        .{ .foo = .{ .a = 55, .b = -99 } },
        .{ .bar = 45 },
        .{ .multi_foo = &[_]DictUnionTest.Foo{
            .{ .a = 48, .b = 56 },
            .{ .a = 43, .b = -51 },
        } },
    }, parsed_slice.value);
}

test "dynamic" {
    const parsed_slice = try parseFromSlice(dynamic.Value, std.testing.allocator, "56-", .{});
    defer parsed_slice.deinit();
    try std.testing.expectEqual(dynamic.Value{ .int = .{ .i32 = -56 } }, parsed_slice.value);
}

const DynamicyStruct = struct {
    a: i32,
    b: []const u8,
    c: dynamic.Value,
};

test "struct with dynamic" {
    const parsed_slice = try parseFromSlice(DynamicyStruct, std.testing.allocator, "{1'a303903-1'b5\"hello1'c<5'c-val68+4\"beep>}", .{});
    defer parsed_slice.deinit();
    try std.testing.expectEqualDeep(DynamicyStruct{
        .a = -303903,
        .b = "hello",
        .c = .{
            .record = .{
                .label = &.{ .symbol = "c-val" },
                .fields = &[_]dynamic.Value{
                    .{ .int = .{ .i32 = 68 } },
                    .{ .string = "beep" },
                },
            },
        },
    }, parsed_slice.value);
}

const DictArr = struct {
    const syrup_spec = Writer.spec.Struct{ .format = .{ .sequence_dictionary = .{} } };
    s: [32]u8,
    q: [32]u8,
};

test "dictionary-like array of bytestrings" {
    const parsed = try parseFromSlice(DictArr, std.testing.allocator, "[1's32:588483848485838484838382838582831'q32:99999999999999999999999999999999]", .{});
    defer parsed.deinit();

    const res: [32]u8 = "58848384848583848483838283858283".*;
    try std.testing.expectEqual(res, parsed.value.s);
}

test "parse to hashmap of dynamic values" {
    const parsed = try parseFromSlice(std.StringHashMapUnmanaged(dynamic.Value), std.testing.allocator, "{3'hey6\"catcat4'hiya[45+46-]}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualDeep(dynamic.Value{ .string = "catcat" }, parsed.value.get("hey").?);
    try std.testing.expectEqualDeep(dynamic.Value{
        .sequence = &[_]dynamic.Value{
            .{ .int = .{ .i32 = 45 } },
            .{ .int = .{ .i32 = -46 } },
        },
    }, parsed.value.get("hiya").?);
}

test "parse to set" {
    const parsed = try parseFromSlice(std.StringHashMapUnmanaged(void), std.testing.allocator, "#2'fo7\"bafjisz2'go3\"goo$", .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.contains("go"));
    try std.testing.expect(parsed.value.contains("fo"));
}

const HashmapUnion = union(enum) {
    first: std.AutoHashMap(u32, DictArr),
    second: std.AutoHashMap([2]i32, []const u8),
};

test "parse to union of hashmaps" {
    const parsed = try parseFromSlice([2]HashmapUnion, std.testing.allocator, "[{6'second{[11-11-]4\"boop[56-82+]7\"fkalsfk}}{5'first{3+[1'q32:abababababababababababababababab1's32:fjfjfjfjfjfjfjfjfjfjfjfjfjfjfjfj]}}]", .{});
    defer parsed.deinit();

    try std.testing.expectEqualDeep(DictArr{ .q = "abababababababababababababababab".*, .s = "fjfjfjfjfjfjfjfjfjfjfjfjfjfjfjfj".* }, parsed.value[1].first.get(3));
    try std.testing.expectEqualDeep("fkalsfk", parsed.value[0].second.get([2]i32{ -56, 82 }));
    try std.testing.expectEqualDeep("boop", parsed.value[0].second.get([2]i32{ -11, -11 }));
}
