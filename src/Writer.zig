//! A writer for the Syrup data format. Can write all of the supported Syrup datatypes to an underlying
//! `std.Io.Writer`.
//!
//! There are many supported options for writing:
//! - Write a Zig type, including primitives, with `write` (most types are supported through the magic of `comptime`).
//! - You can even write an anonymous struct (defined at compile time) with `write`.
//! - You can also write primitives with the primitive methods like `writeString`, `writeBool`, etc (or just `write`).
//! - Use `dynamic.Value` to build structures at runtime to write with `writeDynamicValue` and friends (or just `write`).
//! - Build up Syrup structures manually using the structural writing methods like `writeDictionaryStart` and `writeSequenceStart`.

const std = @import("std");

const base32 = @import("base32.zig");
const dynamic = @import("dynamic.zig");
const tags = @import("tags.zig");
const CollectionMode = @import("collections.zig").CollectionMode;

const print = std.debug.print;

const Writer = @This();

const UnderflowError = error{
    /// Tried to end a record but we are not inside a record.
    RecordUnderflow,
    /// Tried to end a sequence but we are not inside a sequence.
    SequenceUnderflow,
    /// Tried to end a dictionary but we are not inside a dictionary.
    DictionaryUnderflow,
    /// Tried to end a set but we are not inside any sets.
    SetUnderflow,
};

const ParsingError = error{
    /// Tried to close the wrong type of nested item.
    NestingMismatch,
    /// The record did not have a a label.
    RecordMissingLabel,
    /// Tried to end a dictionary immediately after adding a key, without a corresponding value
    DictionaryMissingValue,
    /// At least one duplicate entry was found in the dictionary or set.
    DuplicateEntryFound,
};

const FormatterError = std.Io.Writer.Error || std.Io.Reader.Error;
pub const FlatError = FormatterError || std.mem.Allocator.Error;
pub const WritingError = UnderflowError || ParsingError || FlatError || error{NoSpaceLeft};

pub const Error = UnderflowError || ParsingError || error{NotFinished};

pub const VTable = struct {
    /// Write a boolean Syrup value.
    writeBool: *const fn (writer: *std.Io.Writer, val: bool) FormatterError!void,
    /// Write a positive or negative integer value. The integer is passed as a string to allow for variable precision to pass through a function pointer. The string does not include the sign.
    writeInt: *const fn (writer: *std.Io.Writer, val_str: []const u8, positive: bool) FormatterError!void,
    /// Write a 32-bit floating point value.
    writeFloat: *const fn (writer: *std.Io.Writer, val: f32) FormatterError!void,
    /// Write a 64-bit floating point value.
    writeDouble: *const fn (writer: *std.Io.Writer, val: f64) FormatterError!void,
    /// Write a byte string as a syrup Data.
    writeData: *const fn (writer: *std.Io.Writer, val: []const u8) FormatterError!void,
    /// Write a byte string as a syrup String.
    writeString: *const fn (writer: *std.Io.Writer, val: []const u8) FormatterError!void,
    /// Write a byte string as a syrup Symbol.
    writeSymbol: *const fn (writer: *std.Io.Writer, val: []const u8) FormatterError!void,
    /// Begin a dictionary.
    writeDictionaryStart: *const fn (writer: *std.Io.Writer) FormatterError!void,
    /// Write a suffix after a dictionary key
    writeDictionaryKeySuffix: *const fn (writer: *std.Io.Writer) FormatterError!void,
    /// Write a delimiter between dictionary entries
    writeDictionaryDelimiter: *const fn (writer: *std.Io.Writer) FormatterError!void,
    /// End a dictionary.
    writeDictionaryEnd: *const fn (writer: *std.Io.Writer) FormatterError!void,
    /// Begin a sequence.
    writeSequenceStart: *const fn (writer: *std.Io.Writer) FormatterError!void,
    /// Write a delimiter between dictionary entries
    writeSequenceDelimiter: *const fn (writer: *std.Io.Writer) FormatterError!void,
    /// End a sequence.
    writeSequenceEnd: *const fn (writer: *std.Io.Writer) FormatterError!void,
    /// Begin a record.
    writeRecordStart: *const fn (writer: *std.Io.Writer) FormatterError!void,
    /// Write a suffix after the initial Record label.
    writeRecordLabelSuffix: *const fn (writer: *std.Io.Writer) FormatterError!void,
    /// Write a delimiter between dictionary entries
    writeRecordDelimiter: *const fn (writer: *std.Io.Writer) FormatterError!void,
    /// End a record.
    writeRecordEnd: *const fn (writer: *std.Io.Writer) FormatterError!void,
    /// Begin a set.
    writeSetStart: *const fn (writer: *std.Io.Writer) FormatterError!void,
    /// Write a delimiter between dictionary entries
    writeSetDelimiter: *const fn (writer: *std.Io.Writer) FormatterError!void,
    /// End a set.
    writeSetEnd: *const fn (writer: *std.Io.Writer) FormatterError!void,
};

/// The default Syrup formatter (writes the syrup types to the writer)
const Formatter = struct {
    pub fn writeBool(writer: *std.Io.Writer, val: bool) FormatterError!void {
        if (val) {
            try writer.writeByte(tags.syrup.True);
        } else {
            try writer.writeByte(tags.syrup.False);
        }
    }
    pub fn writeInt(writer: *std.Io.Writer, val_str: []const u8, positive: bool) FormatterError!void {
        try writer.writeAll(val_str);
        if (positive) {
            try writer.writeByte(tags.syrup.int.Positive);
        } else {
            try writer.writeByte(tags.syrup.int.Negative);
        }
    }
    pub fn writeFloat(writer: *std.Io.Writer, val: f32) FormatterError!void {
        try writer.writeByte(tags.syrup.Float);
        try writer.writeAll(&std.mem.toBytes(std.mem.nativeToBig(u32, @bitCast(val))));
    }
    pub fn writeDouble(writer: *std.Io.Writer, val: f64) FormatterError!void {
        try writer.writeByte(tags.syrup.Double);
        try writer.writeAll(&std.mem.toBytes(std.mem.nativeToBig(u64, @bitCast(val))));
    }
    pub fn writeData(writer: *std.Io.Writer, val: []const u8) FormatterError!void {
        try writeDataInternal(writer, val, tags.syrup.Data);
    }
    pub fn writeString(writer: *std.Io.Writer, val: []const u8) FormatterError!void {
        try writeDataInternal(writer, val, tags.syrup.String);
    }
    pub fn writeSymbol(writer: *std.Io.Writer, val: []const u8) FormatterError!void {
        try writeDataInternal(writer, val, tags.syrup.Symbol);
    }
    fn writeDataInternal(writer: *std.Io.Writer, val: []const u8, sep: u8) FormatterError!void {
        try writer.printInt(val.len, 10, .lower, .{});
        try writer.writeByte(sep);
        try writer.writeAll(val);
    }
    pub fn writeDictionaryStart(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeByte(tags.syrup.dictionary.Start);
    }
    pub fn writeDictionaryKeySuffix(_: *std.Io.Writer) FormatterError!void {}
    pub fn writeDictionaryDelimiter(_: *std.Io.Writer) FormatterError!void {}
    pub fn writeDictionaryEnd(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeByte(tags.syrup.dictionary.End);
    }
    pub fn writeSequenceStart(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeByte(tags.syrup.sequence.Start);
    }
    pub fn writeSequenceDelimiter(_: *std.Io.Writer) FormatterError!void {}
    pub fn writeSequenceEnd(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeByte(tags.syrup.sequence.End);
    }
    pub fn writeRecordStart(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeByte(tags.syrup.record.Start);
    }
    pub fn writeRecordLabelSuffix(_: *std.Io.Writer) FormatterError!void {}
    pub fn writeRecordDelimiter(_: *std.Io.Writer) FormatterError!void {}
    pub fn writeRecordEnd(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeByte(tags.syrup.record.End);
    }
    pub fn writeSetStart(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeByte(tags.syrup.set.Start);
    }
    pub fn writeSetDelimiter(_: *std.Io.Writer) FormatterError!void {}
    pub fn writeSetEnd(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeByte(tags.syrup.set.End);
    }
};

/// Formatter for `jsyrup` which is a human readable form of Syrup not for the wire.
const JSyrupFormatter = struct {
    pub fn writeBool(writer: *std.Io.Writer, val: bool) FormatterError!void {
        if (val) {
            try writer.writeAll(tags.jsyrup.True);
        } else {
            try writer.writeAll(tags.jsyrup.False);
        }
    }
    pub fn writeInt(writer: *std.Io.Writer, val_str: []const u8, positive: bool) FormatterError!void {
        if (!positive) {
            try writer.writeByte(tags.jsyrup.NegativeInt);
        }
        try writer.writeAll(val_str);
    }
    pub fn writeFloat(writer: *std.Io.Writer, val: f32) FormatterError!void {
        // Not precise!
        try writer.printFloat(val, .{});
    }
    pub fn writeDouble(writer: *std.Io.Writer, val: f64) FormatterError!void {
        // Not precise!
        try writer.printFloat(val, .{});
    }
    pub fn writeData(writer: *std.Io.Writer, val: []const u8) FormatterError!void {
        try writer.writeByte(tags.jsyrup.Data);
        try base32.encodeSlice(val, writer, .{});
        try writer.writeByte(tags.jsyrup.Data);
    }

    pub inline fn escapedChar(char: u8) []const u8 {
        return switch (char) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '/' => "\\/",
            '\u{0008}' => "\\b",
            '\u{000C}' => "\\f",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => &[_]u8{char},
        };
    }

    pub fn writeString(writer: *std.Io.Writer, val: []const u8) FormatterError!void {
        try writer.writeByte(tags.jsyrup.String);
        var i: usize = 0;
        while (i < val.len) : (i += 1) {
            try writer.writeAll(if (val[i] == '"') "\\\"" else escapedChar(val[i]));
        }
        try writer.writeByte(tags.jsyrup.String);
    }
    pub fn writeSymbol(writer: *std.Io.Writer, val: []const u8) FormatterError!void {
        try writer.writeByte(tags.jsyrup.Symbol);
        var i: usize = 0;
        while (i < val.len) : (i += 1) {
            try writer.writeAll(if (val[i] == '`') "\\`" else escapedChar(val[i]));
        }
        try writer.writeByte(tags.jsyrup.Symbol);
    }
    pub fn writeDictionaryStart(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeByte(tags.jsyrup.dictionary.Start);
    }
    pub fn writeDictionaryKeySuffix(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeAll(tags.jsyrup.dictionary.KeySuffix);
    }
    pub fn writeDictionaryDelimiter(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeAll(tags.jsyrup.Delimiter);
    }
    pub fn writeDictionaryEnd(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeByte(tags.jsyrup.dictionary.End);
    }
    pub fn writeSequenceStart(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeByte(tags.jsyrup.sequence.Start);
    }
    pub fn writeSequenceDelimiter(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeAll(tags.jsyrup.Delimiter);
    }
    pub fn writeSequenceEnd(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeByte(tags.jsyrup.sequence.End);
    }
    pub fn writeRecordStart(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeByte(tags.jsyrup.record.Start);
    }
    pub fn writeRecordLabelSuffix(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeByte(' ');
    }
    pub fn writeRecordDelimiter(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeAll(tags.jsyrup.Delimiter);
    }
    pub fn writeRecordEnd(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeByte(tags.jsyrup.record.End);
    }
    pub fn writeSetStart(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeByte(tags.jsyrup.set.Start);
    }
    pub fn writeSetDelimiter(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeAll(tags.jsyrup.Delimiter);
    }
    pub fn writeSetEnd(writer: *std.Io.Writer) FormatterError!void {
        try writer.writeByte(tags.jsyrup.set.End);
    }
};

/// Structure to store the indices for entries of a Dictionary or Set.
const KeyValueIndices = struct {
    key: usize,
    value: usize = 0,
    end: usize = 0,
};

/// A structure for storing temporary data related to dictionary and set serialization.
const DictData = struct {
    start_index: usize,
    indices: std.ArrayList(KeyValueIndices) = .empty,

    pub fn deinit(self: *DictData, gpa: std.mem.Allocator) void {
        self.indices.deinit(gpa);
    }
};

const NestedData = union(CollectionMode) {
    /// Store the index of the sequence
    sequence: usize,
    /// Store the index of the record (inclusive of the initial, which is the label)
    record: usize,
    dictionary: DictData,
    set: DictData,

    pub fn deinit(self: *NestedData, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .dictionary, .set => |*value| value.deinit(gpa),
            else => {},
        }
    }
};

vtable: *const VTable,
/// The underlying `std.Io.Writer`.
underlying_writer: *std.Io.Writer,
/// Allocator to use for the temporary memory
gpa: std.mem.Allocator,
/// A writer with an allocated buffer used for serializing dictionaries and sets, which need to be sorted after serializing the keys and values.
tmp_writer: std.Io.Writer.Allocating,
/// A stack that stores NestedDatas to keep track of what types of items we are inside, and data for some of these types.
nested_datas: std.ArrayList(NestedData) = .empty,
/// The depth we are traversing inside a dictionary or set, so we know when we can flush the temp buffer.
dict_or_set_depth: usize = 0,

/// Initialize a `Writer` that writes to `syrup` format.
pub fn init(underlying_writer: *std.Io.Writer, gpa: std.mem.Allocator) Writer {
    return .{
        .underlying_writer = underlying_writer,
        .gpa = gpa,
        .tmp_writer = std.Io.Writer.Allocating.init(gpa),
        .vtable = &.{
            .writeBool = Formatter.writeBool,
            .writeInt = Formatter.writeInt,
            .writeFloat = Formatter.writeFloat,
            .writeDouble = Formatter.writeDouble,
            .writeData = Formatter.writeData,
            .writeString = Formatter.writeString,
            .writeSymbol = Formatter.writeSymbol,
            .writeDictionaryStart = Formatter.writeDictionaryStart,
            .writeDictionaryKeySuffix = Formatter.writeDictionaryKeySuffix,
            .writeDictionaryDelimiter = Formatter.writeDictionaryDelimiter,
            .writeDictionaryEnd = Formatter.writeDictionaryEnd,
            .writeSequenceStart = Formatter.writeSequenceStart,
            .writeSequenceEnd = Formatter.writeSequenceEnd,
            .writeSequenceDelimiter = Formatter.writeSequenceDelimiter,
            .writeRecordStart = Formatter.writeRecordStart,
            .writeRecordLabelSuffix = Formatter.writeRecordLabelSuffix,
            .writeRecordDelimiter = Formatter.writeRecordDelimiter,
            .writeRecordEnd = Formatter.writeRecordEnd,
            .writeSetStart = Formatter.writeSetStart,
            .writeSetDelimiter = Formatter.writeSetDelimiter,
            .writeSetEnd = Formatter.writeSetEnd,
        },
    };
}

/// Initialize a `Writer` that writes to `jsyrup` format instead of `syrup`.
pub fn initJSyrup(underlying_writer: *std.Io.Writer, gpa: std.mem.Allocator) Writer {
    return .{
        .underlying_writer = underlying_writer,
        .gpa = gpa,
        .tmp_writer = std.Io.Writer.Allocating.init(gpa),
        .vtable = &.{
            .writeBool = JSyrupFormatter.writeBool,
            .writeInt = JSyrupFormatter.writeInt,
            .writeFloat = JSyrupFormatter.writeFloat,
            .writeDouble = JSyrupFormatter.writeDouble,
            .writeData = JSyrupFormatter.writeData,
            .writeString = JSyrupFormatter.writeString,
            .writeSymbol = JSyrupFormatter.writeSymbol,
            .writeDictionaryStart = JSyrupFormatter.writeDictionaryStart,
            .writeDictionaryKeySuffix = JSyrupFormatter.writeDictionaryKeySuffix,
            .writeDictionaryDelimiter = JSyrupFormatter.writeDictionaryDelimiter,
            .writeDictionaryEnd = JSyrupFormatter.writeDictionaryEnd,
            .writeSequenceStart = JSyrupFormatter.writeSequenceStart,
            .writeSequenceEnd = JSyrupFormatter.writeSequenceEnd,
            .writeSequenceDelimiter = JSyrupFormatter.writeSequenceDelimiter,
            .writeRecordStart = JSyrupFormatter.writeRecordStart,
            .writeRecordLabelSuffix = JSyrupFormatter.writeRecordLabelSuffix,
            .writeRecordDelimiter = JSyrupFormatter.writeRecordDelimiter,
            .writeRecordEnd = JSyrupFormatter.writeRecordEnd,
            .writeSetStart = JSyrupFormatter.writeSetStart,
            .writeSetDelimiter = JSyrupFormatter.writeSetDelimiter,
            .writeSetEnd = JSyrupFormatter.writeSetEnd,
        },
    };
}

/// Deinitialize a `Writer`.
pub fn deinit(self: *Writer) void {
    self.tmp_writer.deinit();

    for (self.nested_datas.items) |*item| {
        item.deinit(self.gpa);
    }

    self.nested_datas.deinit(self.gpa);
}

inline fn curWriter(self: *Writer) *std.Io.Writer {
    return if (self.dict_or_set_depth > 0) &self.tmp_writer.writer else self.underlying_writer;
}

fn writeBytes(self: *Writer, val: []const u8, format: Format.Simple) FlatError!void {
    switch (format) {
        .string, .default => try self.writeString(val),
        .data => try self.writeData(val),
        .symbol => try self.writeSymbol(val),
    }
}

/// Write a supported type.
pub fn write(self: *Writer, val: anytype, comptime options: Options) WritingError!void {
    const T = @TypeOf(val);
    const val_info = @typeInfo(T);
    const type_name = @typeName(T);

    try switch (T) {
        bool => self.writeBool(val),
        f32 => self.writeFloat(val),
        f64 => self.writeDouble(val),
        dynamic.Value => self.writeDynamicValue(&val),
        dynamic.Record => self.writeDynamicRecord(&val),
        else => switch (val_info) {
            .int => self.writeInt(val),
            .comptime_float => {
                if (@as(f64, @floatCast(val)) == val) {
                    return self.writeDouble(@as(f64, val));
                }

                @compileError("comptime float cannot be converted to f64");
            },
            .comptime_int => self.writeInt(val),
            .null => self.writeBool(false),
            .optional => {
                if (val) |payload| {
                    return self.write(payload, options);
                } else {
                    return self.write(null, options);
                }
            },
            .array => self.write(&val, options),
            .vector => |info| {
                const array: [info.len]info.child = val;
                return self.write(&array, options);
            },
            .@"struct" => |struct_info| {
                // Check if it's an instance of a HashMap, if so we can write it as a Dictionary.
                // If it has a KV declaration we assume it is. A little more fragile than I would like, but I think it's relatively okay.
                const is_hash_map_like = @hasDecl(T, "KV");

                if (is_hash_map_like) {
                    const V = @typeInfo(@field(T, "KV")).@"struct".fields[1].type;
                    switch (V) {
                        void => {
                            if (options.format != .default and options.format != .set) {
                                @compileError(type_name ++ " was detected to be a Set (seems to be HashMap with void V), but the layout specified for it was not `.set`.");
                            }

                            const val_options = Options{
                                .simple = .{
                                    .set = comptime if (options.format == .set)
                                        options.format.set
                                    else
                                        .default,
                                },
                            };

                            try self.writeSetStart();

                            // Support both a standard HashMap that has a keyIterator, and the StaticStringMap which just has a keys function.
                            if (std.meta.hasFn(T, "keyIterator")) {
                                for (val.keys()) |key| {
                                    try self.write(key, val_options);
                                }
                                var i = 0;
                                var it = val.keyIterator();
                                while (it.next()) |key| {
                                    try self.write(key, val_options);
                                    i += 1;
                                }
                            } else if (std.meta.hasFn(T, "keys")) {
                                for (val.keys()) |key| {
                                    try self.write(key, val_options);
                                }
                            } else @compileError("Found what looks like a set (has a KV decl with a void value) but it doesn't have `keyIterator` or `keys` functions");
                            return self.writeSetEnd();
                        },
                        else => {
                            if (options.format != .default and options.format != .dictionary) {
                                @compileError(type_name ++ " was detected to be a Dictionary (seems to be HashMap), but the layout specified for it was not `.dictionary`.");
                            }

                            const key_options = Options{
                                .format = .{
                                    .simple = if (options.format == .dictionary)
                                        options.format.dictionary.key
                                    else
                                        .default,
                                },
                            };

                            const value_options = Options{
                                .format = .{
                                    .simple = if (options.format == .dictionary)
                                        options.format.dictionary.value
                                    else
                                        .default,
                                },
                            };

                            try self.writeDictionaryStart();
                            // Support both a standard HashMap that has an iterator, and the StaticStringMap which just has a kvs field
                            if (std.meta.hasFn(T, "iterator")) {
                                var i = 0;
                                var it = val.iterator();
                                while (it.next()) |kv| {
                                    try self.write(kv.key, key_options);
                                    try self.write(kv.value, value_options);
                                    i += 1;
                                }
                            } else if (std.meta.hasFn(T, "keys")) {
                                for (0..val.kvs.len) |i| {
                                    try self.write(val.kvs.keys[i], key_options);
                                    try self.write(val.kvs.values[i], value_options);
                                }
                            } else @compileError("Found a dictionary-like struct (has a KV decl with key and value) but it doesn't have `iterator` or `keys` functions");
                            return self.writeDictionaryEnd();
                        },
                    }
                }

                const has_syrup_format = @hasDecl(T, "syrup_format");
                if (has_syrup_format and @TypeOf(T.syrup_format) != WireFormat) {
                    @compileError("`syrup_format` declaration found in struct " ++ type_name ++ ", but it is type " ++ @typeName(T.syrup_format) ++ ". Must be " ++ @typeInfo(WireFormat) ++ ".");
                }

                if (has_syrup_format) {
                    if (T.syrup_format.fields) |field_formats| {
                        // Verify field layout count matches field count
                        if (field_formats.len != struct_info.fields.len) {
                            @compileError(std.fmt.comptimePrint(
                                "found `syrup_format` declaration in {s}, but length of field format list ({}) doesn't match the number of fields ({}).",
                                .{ type_name, field_formats.len, struct_info.fields.len },
                            ));
                        }
                    }
                }

                // Tuples default to a sequence.
                const write_sequence = (!has_syrup_format and struct_info.is_tuple) or
                    (has_syrup_format and T.syrup_format.format == .sequence);
                if (write_sequence) {
                    try self.writeSequenceStart();
                } else if (!has_syrup_format or T.syrup_format.format == .dictionary) {
                    // Other structs default to a dictionary.
                    try self.writeDictionaryStart();
                } else if (T.syrup_format.format == .record) {
                    const record_label_format: Format = .{
                        .simple = if (has_syrup_format)
                            T.syrup_format.format.record.label
                        else
                            .default,
                    };

                    const rec_type_name = if (has_syrup_format)
                        T.syrup_format.format.record.name orelse type_name
                    else
                        type_name;

                    try self.writeRecordStartLabeledOptions(rec_type_name, .{ .format = record_label_format });
                }

                comptime var i = 0;
                inline for (struct_info.fields) |Field| {
                    if (!write_sequence and
                        (!has_syrup_format or T.syrup_format.format == .dictionary))
                    {
                        // Default to symbols as dictionary keys
                        try self.write(
                            Field.name,
                            .{
                                .format = .{
                                    .simple = if (has_syrup_format)
                                        T.syrup_format.format.dictionary.key
                                    else
                                        .symbol,
                                },
                            },
                        );
                    }

                    const field_format: Format = if (has_syrup_format)
                        if (T.syrup_format.fields) |field_formats|
                            field_formats[i]
                        else if (T.syrup_format.format == .dictionary)
                            T.syrup_format.format.dictionary.value
                        else
                            .default
                    else
                        .default;

                    try self.write(@field(val, Field.name), .{ .format = field_format });
                    i += 1;
                }

                if (write_sequence) {
                    return self.writeSequenceEnd();
                } else if (!has_syrup_format or T.syrup_format.format == .dictionary) {
                    return self.writeDictionaryEnd();
                } else {
                    return self.writeRecordEnd();
                }
            },
            .@"enum" => |enum_info| {
                if (!enum_info.is_exhaustive) {
                    // Check if the value is part of the enum (print the value directly if not).
                    inline for (enum_info.fields) |field| {
                        if (val == @field(T, field.name)) {
                            break;
                        }
                    } else {
                        return self.write(@intFromEnum(val), .{});
                    }
                }

                var name_buf: [128]u8 = undefined;
                const val_str = if (options.format == .@"enum")
                    if (options.format.@"enum".namespaced)
                        try std.fmt.bufPrint(&name_buf, "{s}.{s}", .{ type_name, @tagName(val) })
                    else
                        @tagName(val)
                else
                    @tagName(val);

                const val_options = Options{
                    .format = .{
                        .simple = if (options.format == .@"enum")
                            options.format.@"enum".value
                        else
                            .symbol,
                    },
                };

                return self.write(val_str, val_options);
            },
            .enum_literal => {
                const val_str = if (options.format == .@"enum")
                    if (options.format.@"enum".namespaced)
                        type_name ++ "." ++ @tagName(val)
                    else
                        @tagName(val)
                else
                    @tagName(val);

                const val_options = Options{
                    .format = .{
                        .simple = if (options.format == .@"enum")
                            options.format.@"enum".value
                        else
                            .symbol,
                    },
                };

                return self.write(val_str, val_options);
            },
            .pointer => |ptr_info| switch (ptr_info.size) {
                .one => {
                    const ChildType = ptr_info.child;
                    const child_info = @typeInfo(ChildType);
                    return switch (child_info) {
                        .array => {
                            // Coerce `*[N]T` to `[]const T`.
                            const Slice = []const std.meta.Elem(ChildType);
                            return self.write(@as(Slice, val), options);
                        },
                        else => {
                            return self.write(val.*, options);
                        },
                    };
                },
                .many, .slice => {
                    if (ptr_info.size == .many and ptr_info.sentinel() == null)
                        @compileError("unable to serialize type '" ++ @typeName(T) ++ "' without sentinel");
                    const slice = if (ptr_info.size == .many) std.mem.span(val) else val;
                    if (ptr_info.child == u8 and options.format != .sequence) {
                        switch (options.format) {
                            .default => return self.writeBytes(slice, .string),
                            .simple => |simple| return self.writeBytes(slice, simple),
                            else => @compileError("cannot use " ++ options.format ++ " format for []u8"),
                        }
                    }

                    switch (options.format) {
                        .sequence, .default => {
                            try self.writeSequenceStart();
                            for (slice) |item| {
                                try self.write(item, options);
                            }
                            return self.writeSequenceEnd();
                        },
                        .set => {
                            try self.writeSetStart();
                            for (slice) |item| {
                                try self.write(item, .{ .format = .{ .simple = options.format.set } });
                            }
                            return self.writeSetEnd();
                        },
                        else => @compileError(std.fmt.comptimePrint("unsupported format {s} for slice {s}. Dictionaries and sets cannot be safely serialized from slices due to non-uniqueness", .{ @tagName(options), @typeName(T) })),
                    }
                },
                else => @compileError("unsupported pointer type " ++ @typeName(T)),
            },
            else => @compileError("unsupported type! " ++ @typeName(T)),
        },
    };
}

/// Write a `dynamic.Value`.
pub fn writeDynamicValue(self: *Writer, gen: *const dynamic.Value) WritingError!void {
    return try switch (gen.*) {
        .true => self.writeBool(true),
        .false => self.writeBool(false),
        .f32 => |val| self.writeFloat(val),
        .f64 => |val| self.writeDouble(val),
        .data => |val| self.writeData(val),
        .string => |val| self.writeString(val),
        .symbol => |val| self.writeSymbol(val),
        .int => |int| switch (int) {
            .i32 => |val| self.writeInt(val),
            .i64 => |val| self.writeInt(val),
            .i128 => |val| self.writeInt(val),
        },
        .sequence => |val| self.writeDynamicSequence(val),
        .record => |val| self.writeDynamicRecord(&val),
        .dictionary => |val| self.writeDynamicDictionary(val),
        .set => |val| self.writeDynamicSet(val),
    };
}

/// Write a boolean value.
pub fn writeBool(self: *Writer, val: bool) FlatError!void {
    try self.startWrite();
    try self.vtable.writeBool(self.curWriter(), val);
}

/// Write an integer value of any width.
pub fn writeInt(self: *Writer, val: anytype) FlatError!void {
    const T = @TypeOf(val);
    const type_info = @typeInfo(T);
    switch (type_info) {
        .int => |i| {
            if (i.bits > 3400) {
                @compileError(std.fmt.comptimePrint(
                    "That integer is... very big ({} bits > 3400) so it doesn't fit in the buffer. Do we need to support this? it's freakin' huge, man!",
                    .{i.bits},
                ));
            }
        },
        .comptime_int => {},
        else => @compileError("writeInt must be called with integer type."),
    }

    try self.startWrite();
    var buf: [1024]u8 = undefined;
    const len = std.fmt.printInt(&buf, @abs(val), 10, .lower, .{});
    try self.vtable.writeInt(self.curWriter(), buf[0..len], val >= 0);
}

/// Write a `f32` float.
pub fn writeFloat(self: *Writer, val: f32) FlatError!void {
    try self.startWrite();
    try self.vtable.writeFloat(self.curWriter(), val);
}

/// Write a `f64` float.
pub fn writeDouble(self: *Writer, val: f64) FlatError!void {
    try self.startWrite();
    try self.vtable.writeDouble(self.curWriter(), val);
}

/// Write a byte slice as data.
pub fn writeData(self: *Writer, val: []const u8) FlatError!void {
    try self.startWrite();
    try self.vtable.writeData(self.curWriter(), val);
}

/// Write a byte slice as a string.
pub fn writeString(self: *Writer, val: []const u8) FlatError!void {
    try self.startWrite();
    try self.vtable.writeString(self.curWriter(), val);
}

/// Write a byte slice as a symbol.
pub fn writeSymbol(self: *Writer, val: []const u8) FlatError!void {
    try self.startWrite();
    try self.vtable.writeSymbol(self.curWriter(), val);
}

/// Begin writing a Sequence. The Sequence will be populated with subsequent writes.
/// Call `writeSequenceEnd` to finish the Sequence.
pub fn writeSequenceStart(self: *Writer) FlatError!void {
    try self.startWrite();
    try self.vtable.writeSequenceStart(self.curWriter());
    try self.nested_datas.append(self.gpa, .{ .sequence = 0 });
}

const NestingError = error{ NestingMismatch, RecordMissingLabel } || UnderflowError;

/// Return the provided error if the expected nested item isn't the current parent.
fn ensureProperNesting(self: *Writer, mode: CollectionMode, err: UnderflowError) NestingError!void {
    const data = self.nested_datas.pop() orelse return err;
    if (data != mode) {
        return error.NestingMismatch;
    }

    if (data == .record and data.record == 0) {
        return error.RecordMissingLabel;
    }
}

pub const SequenceError = FormatterError || NestingError || std.mem.Allocator.Error;

/// Finish writing a Sequence. Throws `SequenceUnderflow` if we aren't in any sequences.
pub fn writeSequenceEnd(self: *Writer) SequenceError!void {
    try self.ensureProperNesting(.sequence, error.SequenceUnderflow);
    try self.vtable.writeSequenceEnd(self.curWriter());
}

/// Write a full Sequence given a list of `dynamic.Value`.
pub fn writeDynamicSequence(self: *Writer, val: []const dynamic.Value) WritingError!void {
    try self.writeSequenceStart();
    for (val) |gen| {
        try self.writeDynamicValue(&gen);
    }
    try self.writeSequenceEnd();
}

/// Begin writing a record. The next write will be the record's label.
/// Call `writeRecordEnd` to finish the Record.
pub fn writeRecordStart(self: *Writer) FlatError!void {
    try self.startWrite();
    try self.vtable.writeRecordStart(self.curWriter());
    try self.nested_datas.append(self.gpa, .{ .record = 0 });
}

/// Begin writing a Record given a label. The Record will be populated with subsequent writes.
/// Call `writeRecordEnd` to finish the Record.
pub fn writeRecordStartLabeled(self: *Writer, label: anytype) WritingError!void {
    try self.writeRecordStartLabeledOptions(label, .{});
}

fn writeRecordStartLabeledOptions(self: *Writer, label: anytype, comptime options: Options) WritingError!void {
    try self.startWrite();
    try self.vtable.writeRecordStart(self.curWriter());
    try self.nested_datas.append(self.gpa, .{ .record = 0 });
    try self.write(
        label,
        if (options.format == .default)
            .{ .format = .{ .simple = .symbol } }
        else
            options,
    );
}

pub const RecordError = FormatterError || NestingError || std.mem.Allocator.Error;

/// Finish writing a Record. Throws `RecordUnderflow` if we aren't in any records.
pub fn writeRecordEnd(self: *Writer) RecordError!void {
    try self.ensureProperNesting(.record, error.RecordUnderflow);
    try self.vtable.writeRecordEnd(self.curWriter());
}

/// Write a full `dynamic.Record`.
pub fn writeDynamicRecord(self: *Writer, val: *const dynamic.Record) WritingError!void {
    try self.writeRecordStartLabeled(val.label);
    for (val.fields) |field| {
        try self.writeDynamicValue(&field);
    }
    try self.writeRecordEnd();
}

fn tmpWrittenLen(self: *Writer) usize {
    return self.tmp_writer.written().len;
}

/// Begin writing a Dictionary of data. `tmp_writer` will be filled with subsequent writes of
/// (alternately) keys and values, until the dictionary is complete.
/// Call `writeDictionaryEnd` to finish the Dictionary.
pub fn writeDictionaryStart(self: *Writer) FlatError!void {
    try self.startWrite();
    try self.vtable.writeDictionaryStart(self.curWriter());
    self.dict_or_set_depth += 1;
    try self.nested_datas.append(self.gpa, .{ .dictionary = .{ .start_index = self.tmpWrittenLen() } });
}

const CompData = struct {
    buf: []const u8,
    found_duplicates: bool = false,
};

fn cmpIndices(data: *CompData, a: KeyValueIndices, b: KeyValueIndices) bool {
    const a_slice = data.buf[a.key..a.value];
    const b_slice = data.buf[b.key..b.value];
    const order = std.mem.order(u8, a_slice, b_slice);
    if (order == .eq) {
        data.found_duplicates = true;
    }

    return order == .lt;
}

pub const SortingError = FormatterError || error{DuplicateEntryFound};
fn sortIndices(self: *Writer, dict_data: *DictData) SortingError!void {
    var comp_data = CompData{ .buf = self.tmp_writer.written() };
    std.mem.sort(KeyValueIndices, dict_data.indices.items, &comp_data, cmpIndices);
    if (comp_data.found_duplicates) {
        return error.DuplicateEntryFound;
    }
}

pub const DictionaryError = FormatterError || DictDataError || error{ NestingMismatch, DictionaryUnderflow, DictionaryMissingValue };
/// Finish writing a Dictionary. Throws `DictionaryUnderflow` if we aren't in any dictionaries.
/// This sorts entries by key and then (unless we are still inside an outer Dictionary or Set) performs
/// the actual flush of keys and values to the underlying writer, as previous calls will have
/// only populated `tmp_writer` with items.
pub fn writeDictionaryEnd(self: *Writer) DictionaryError!void {
    // TODO: should we repair the state if we throw a NestingMismatch, or do we accept that the Writer
    // is now busted? For now, the writer state becomes jumbled.
    // I am leaning towards not caring, because the streaming nature of this means that it would be hard
    // for the user to keep track of what's been sent.
    var nested_data = self.nested_datas.pop() orelse return error.DictionaryUnderflow;
    if (nested_data != .dictionary) {
        return error.NestingMismatch;
    }
    defer nested_data.deinit(self.gpa);

    if (nested_data.dictionary.indices.items.len > 0) {
        var last = &nested_data.dictionary.indices.items[nested_data.dictionary.indices.items.len - 1];

        // Ensure that we already wrote the last value
        if (last.value == 0) {
            return error.DictionaryMissingValue;
        }

        last.end = self.tmpWrittenLen();
    }

    try self.finalizeDictData(&nested_data.dictionary, self.vtable.writeDictionaryDelimiter);

    try self.vtable.writeDictionaryEnd(self.curWriter());
}

const DictDataError = FormatterError || SortingError || std.mem.Allocator.Error;
/// Given the dictionary data, finalize it by sorting by keys and putting the sorted bytes into the
/// right position in the buffer.
fn finalizeDictData(
    self: *Writer,
    dict_data: *DictData,
    write_delimiter: *const fn (writer: *std.Io.Writer) FormatterError!void,
) DictDataError!void {
    // Sort the indices by their buffer order!
    try self.sortIndices(dict_data);

    // Ensure we can fit a copy of the data after the current data.
    const orig_start_i = dict_data.start_index;
    const orig_end_i = self.tmpWrittenLen();
    const orig_collection_len = orig_end_i - orig_start_i;

    // XXX: If we have delimiters (jsyrup), the added delimiters might require extra capacity, but we don't
    // have a way to know the space used by them currently, so we might need a little more capacity than this.
    // See below additional ensure.
    try self.tmp_writer.ensureUnusedCapacity(orig_collection_len);

    var i: usize = 0;
    for (dict_data.indices.items) |item| {
        if (i > 0) {
            try write_delimiter(self.curWriter());
        }

        // Now that we added the delimiter for the previous entry, we need to ensure there's enough space
        // to copy, so that the temp buffer doesn't get invalidated mid_copy as the memory is shared.
        try self.tmp_writer.ensureUnusedCapacity(item.end - item.key);
        try self.tmp_writer.writer.writeAll(self.tmp_writer.writer.buffer[item.key..item.end]);

        i += 1;
    }

    // Copy from the now-ordered portion back to the final position.
    // Note that the regions may overlap due to the added length of the delimiters, hence @memmove.
    const tmp_buffer = self.tmp_writer.writer.buffer;
    const final_end = self.tmpWrittenLen();
    const resized_len = final_end - orig_end_i;
    @memmove(
        tmp_buffer[orig_start_i .. orig_start_i + resized_len],
        tmp_buffer[orig_start_i + orig_collection_len .. final_end],
    );

    // Rewind the buffer now that we've copied back to the original position.
    self.tmp_writer.shrinkRetainingCapacity(orig_start_i + resized_len);

    self.dict_or_set_depth -= 1;
    try self.maybeFlushBuffer();
}

/// Write a full Dictionary given a list of `dynamic.Value`.
pub fn writeDynamicDictionary(self: *Writer, val: []const dynamic.Value) WritingError!void {
    try self.writeDictionaryStart();
    for (val) |gen| {
        try self.writeDynamicValue(&gen);
    }
    try self.writeDictionaryEnd();
}

/// Begin writing a Set of data. `tmp_writer` will be filled with subsequent writes of
/// entries, until the set is complete.
/// Call `writeSetEnd` to finish the Set.
pub fn writeSetStart(self: *Writer) FlatError!void {
    try self.startWrite();
    try self.vtable.writeSetStart(self.curWriter());
    self.dict_or_set_depth += 1;
    try self.nested_datas.append(self.gpa, .{ .set = .{ .start_index = self.tmpWrittenLen() } });
}

pub const SetError = FormatterError || error{ DuplicateEntryFound, NestingMismatch, SetUnderflow } || std.mem.Allocator.Error;
/// Finish writing a Set. Throws `SetUnderflow` if we aren't in any sets.
/// This sorts entries and then (unless we are still inside an outer Dictionary or Set) performs
/// the actual flush of items to the underlying writer, as previous calls will have
/// only populated `tmp_writer` with items.
pub fn writeSetEnd(self: *Writer) SetError!void {
    var nested_data = self.nested_datas.pop() orelse return error.SetUnderflow;
    if (nested_data != .set) {
        return error.NestingMismatch;
    }

    if (nested_data.set.indices.items.len > 0) {
        var last = &nested_data.set.indices.items[nested_data.set.indices.items.len - 1];
        last.end = self.tmpWrittenLen();
        last.value = last.end;
    }

    defer nested_data.deinit(self.gpa);

    try self.finalizeDictData(&nested_data.set, self.vtable.writeSetDelimiter);
    try self.vtable.writeSetEnd(self.curWriter());
}

/// Write a full Set given a list of `dynamic.Value`.
pub fn writeDynamicSet(self: *Writer, val: []const dynamic.Value) WritingError!void {
    try self.writeSetStart();
    for (val) |gen| {
        try self.writeDynamicValue(&gen);
    }
    try self.writeSetEnd();
}

/// Start a write operation. We record index positions if we are in a Dictionary or Set.
fn startWrite(self: *Writer) FlatError!void {
    if (self.nested_datas.items.len <= 0) {
        return;
    }

    // Info on delimiters (jsyrup specific)
    // Dictionaries and Sets: Don't write delimiters here, we need to do that after sorting.
    // (we don't know which items need delimiters and which are the first or last entries)
    // Records and sequences: We write the delimiters as we go.
    const last_nested_data = &self.nested_datas.items[self.nested_datas.items.len - 1];
    switch (last_nested_data.*) {
        .dictionary => |*dict_data| {
            if (dict_data.indices.items.len > 0) {
                var cur = &dict_data.indices.items[dict_data.indices.items.len - 1];
                if (cur.value == 0) {
                    // Value index is still zero, so we are writing the value now.
                    // But first we gotta write the key suffix.
                    try self.vtable.writeDictionaryKeySuffix(self.curWriter());
                    cur.value = self.tmpWrittenLen();
                    return;
                } else {
                    // Otherwise we write the end index of the current item, and then afterwards add.
                    cur.end = self.tmpWrittenLen();
                }
            }

            try dict_data.indices.append(self.gpa, .{ .key = self.tmpWrittenLen() });
        },
        .set => |*dict_data| {
            if (dict_data.indices.items.len > 0) {
                var cur = &dict_data.indices.items[dict_data.indices.items.len - 1];
                // We write the end index of the current item, and then afterwards add.
                cur.end = self.tmpWrittenLen();
                cur.value = cur.end;
            }

            try dict_data.indices.append(self.gpa, .{ .key = self.tmpWrittenLen() });
        },
        .record => |*i| {
            if (i.* == 1) {
                // First entry is the label, and gets a LabelSuffix *after* it
                try self.vtable.writeRecordLabelSuffix(self.curWriter());
            } else if (i.* > 0) {
                // The rest get a delimiter.
                try self.vtable.writeRecordDelimiter(self.curWriter());
            }

            i.* += 1;
        },
        .sequence => |*i| {
            if (i.* > 0) {
                try self.vtable.writeSequenceDelimiter(self.curWriter());
            }

            i.* += 1;
        },
    }
}

/// If we are no longer inside any dictionaries or sets, flush the temp buffer to the Io.Writer and clear the buffer.
fn maybeFlushBuffer(self: *Writer) FormatterError!void {
    if (self.dict_or_set_depth == 0) {
        try self.underlying_writer.writeAll(self.tmp_writer.written());
        self.tmp_writer.clearRetainingCapacity();
    }
}

const syrup_format = "syrup_format";

pub const Options = struct {
    format: Format = .default,
};

pub const WireFormat = struct {
    format: Format.Struct = .{ .dictionary = .{} },
    fields: ?[]const Format = null,
};

pub const Format = union(enum) {
    pub const Simple = enum {
        default,
        string,
        symbol,
        data,
    };

    pub const Dictionary = struct {
        key: Simple = .default,
        value: Simple = .default,
    };

    pub const Record = struct {
        label: Simple = .symbol,
        name: ?[]const u8 = null,
    };

    pub const Struct = union(enum) {
        dictionary: Dictionary,
        record: Record,
        sequence,
    };

    pub const Enum = struct {
        value: Simple = .symbol,
        namespaced: bool = false,
    };

    default,
    sequence,
    simple: Simple,
    dictionary: Dictionary,
    set: Simple,
    @"struct": Struct,
    @"enum": Enum,
};

/// While not strictly necessary, this function can be used to assert that all nested structures have been
/// written properly. Run it when the structure is done being written.
pub fn finish(self: *Writer) error{NotFinished}!void {
    if (self.nested_datas.items.len > 0) {
        return error.NotFinished;
    }
}

/// For testing: Double check we cleared all nested datas.
fn expectCleanWriterState(self: *Writer) !void {
    try std.testing.expectEqual(0, self.nested_datas.items.len);
    try std.testing.expectEqual(0, self.dict_or_set_depth);
}

const zoo_bin = @embedFile("test-data/zoo.bin");

test "basic datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.write(false, .{});
    try writer.write(true, .{});
    try writer.write(502345, .{});
    try writer.write(-42069, .{});

    try std.testing.expectEqualStrings("ft502345+42069-", output.written());
    try writer.expectCleanWriterState();
}

test "float datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.write(14.4, .{});
    try writer.write(@as(f32, 58.365), .{});
    try std.testing.expectEqualSlices(u8, &[_]u8{ 68, 64, 44, 204, 204, 204, 204, 204, 205, 70, 66, 105, 117, 195 }, output.written());
    try writer.expectCleanWriterState();
}

test "string datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.writeString("i love you, christine 😍");
    try writer.writeString("björn");

    try std.testing.expectEqualStrings("26\"i love you, christine 😍6\"björn", output.written());
    try writer.expectCleanWriterState();
}

test "data datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.writeData(&[_]u8{ 69, 68, 67, 66, 65 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 53, 58, 69, 68, 67, 66, 65 }, output.written());
    try writer.expectCleanWriterState();
}

test "symbol datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.writeSymbol("hämta");
    try std.testing.expectEqualStrings("6'hämta", output.written());
    try writer.expectCleanWriterState();
}

test "sequence datatype" {
    const sequence = [_]dynamic.Value{
        .{ .string = "a test" },
        .{ .int = .{ .i32 = 45 } },
        .{ .symbol = "shark" },
        .{ .sequence = &.{
            .{ .int = .{ .i128 = -170_141_183_460_469_231_731_687_303_715_884_105_690 } },
            .{ .string = "testing nesting" },
        } },
    };

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.write(&sequence, .{});
    try std.testing.expectEqualStrings("[6\"a test45+5'shark[170141183460469231731687303715884105690-15\"testing nesting]]", output.written());
    try writer.expectCleanWriterState();
}

test writeRecordStart {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.writeRecordStart();
    try writer.writeSetStart();
    try writer.writeString("hey there");
    try writer.writeSetEnd();
    try writer.writeBool(true);
    try writer.writeBool(false);
    try writer.writeSymbol("dogs-and-cats");
    try writer.writeRecordEnd();

    try std.testing.expectEqualStrings("<#9\"hey there$tf13'dogs-and-cats>", output.written());
    try writer.expectCleanWriterState();
}

test "no record label causes error" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.writeRecordStart();
    try std.testing.expectError(error.RecordMissingLabel, writer.writeRecordEnd());
    try writer.expectCleanWriterState();
}

test writeRecordStartLabeled {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.writeRecordStartLabeled(dynamic.Value{ .sequence = &[_]dynamic.Value{
        .{ .string = "hi" },
    } });
    try writer.writeBool(true);
    try writer.writeBool(false);
    try writer.writeSymbol("dogs-and-cats");
    try writer.writeRecordEnd();

    try std.testing.expectEqualStrings("<[2\"hi]tf13'dogs-and-cats>", output.written());
    try writer.expectCleanWriterState();
}

test "record datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    const record = dynamic.Record{
        .label = &.{
            .sequence = &[_]dynamic.Value{
                .{ .string = "hello" },
                .{ .int = .{ .i32 = 2456 } },
            },
        },
        .fields = &[_]dynamic.Value{
            .true,
            .false,
            .{ .symbol = "dogs-and-cats" },
        },
    };

    try writer.write(&record, .{});
    try std.testing.expectEqualStrings("<[5\"hello2456+]tf13'dogs-and-cats>", output.written());
    try writer.expectCleanWriterState();
}

test "simple dictionary datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    const dict = dynamic.Value{
        .dictionary = &[_]dynamic.Value{
            .{ .string = "key2" },
            .{ .int = .{ .i32 = 45 } },
            .{ .string = "key1" },
            .{ .int = .{ .i32 = 42 } },
            .{ .string = "key8" },
            .{ .int = .{ .i32 = 2 } },
            .{ .string = "key3" },
            .{ .int = .{ .i32 = 4 } },
        },
    };

    try writer.write(&dict, .{});
    try std.testing.expectEqualStrings("{4\"key142+4\"key245+4\"key34+4\"key82+}", output.written());

    try writer.expectCleanWriterState();
}

test "nested dictionary datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    // Dictionary which has *nested* dictionaries as a key (gross, but allowed)
    // and a dictionary as a value for fun as well.
    // Let's hope this is not something someone would want to do, but at least it's possible.
    const dict = dynamic.Value{
        .dictionary = &[_]dynamic.Value{
            .{ .dictionary = &[_]dynamic.Value{
                .{ .dictionary = &[_]dynamic.Value{
                    .{ .int = .{ .i32 = 100 } },
                    .{ .int = .{ .i32 = 88888 } },
                    .{ .int = .{ .i32 = 99 } },
                    .{ .int = .{ .i32 = 99999 } },
                } },
                .{ .string = "hello world" },
                .{ .dictionary = &[_]dynamic.Value{
                    .{ .int = .{ .i32 = 33 } },
                    .{ .int = .{ .i32 = 55555 } },
                    .{ .int = .{ .i32 = 508 } },
                    .{ .int = .{ .i32 = 44444 } },
                } },
                .{ .string = "values values values" },
            } },
            .{ .int = .{ .i32 = 45 } },
            .{ .string = "key1" },
            .{ .int = .{ .i32 = 42 } },
            .{ .string = "key8" },
            .{ .int = .{ .i32 = 2 } },
            .{ .string = "key3" },
            .{ .int = .{ .i32 = 4 } },
        },
    };

    try writer.write(&dict, .{});
    try std.testing.expectEqualStrings("{4\"key142+4\"key34+4\"key82+{{100+88888+99+99999+}11\"hello world{33+55555+508+44444+}20\"values values values}45+}", output.written());

    try writer.expectCleanWriterState();
}

test "ensure dictionaries don't allow duplicate keys" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    // Same complex nested dictionary, but it has a problem, a duplicate key deep in the nesting.
    const dict = dynamic.Value{
        .dictionary = &[_]dynamic.Value{
            .{ .dictionary = &[_]dynamic.Value{
                .{ .dictionary = &[_]dynamic.Value{
                    .{ .int = .{ .i32 = 99 } },
                    .{ .int = .{ .i32 = 88888 } },
                    .{ .int = .{ .i32 = 99 } },
                    .{ .int = .{ .i32 = 99999 } },
                } },
                .{ .string = "hello world" },
                .{ .dictionary = &[_]dynamic.Value{
                    .{ .int = .{ .i32 = 33 } },
                    .{ .int = .{ .i32 = 55555 } },
                    .{ .int = .{ .i32 = 508 } },
                    .{ .int = .{ .i32 = 44444 } },
                } },
                .{ .string = "values values values" },
            } },
            .{ .int = .{ .i32 = 45 } },
            .{ .string = "key1" },
            .{ .int = .{ .i32 = 42 } },
            .{ .string = "key8" },
            .{ .int = .{ .i32 = 2 } },
            .{ .string = "key3" },
            .{ .int = .{ .i32 = 4 } },
        },
    };

    try std.testing.expectError(error.DuplicateEntryFound, writer.write(&dict, .{}));
}

test "ensure the user entered a value for every dictionary entry" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    const dict = dynamic.Value{ .dictionary = &[_]dynamic.Value{
        .{ .symbol = "one" },
        .{ .int = .{ .i32 = 45 } },
        .{ .symbol = "two" },
    } };

    try std.testing.expectError(error.DictionaryMissingValue, writer.write(&dict, .{}));
}

test "simple set" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    const set = dynamic.Value{
        .set = &[_]dynamic.Value{
            .{ .symbol = "one" },
            .{ .symbol = "five" },
            .{ .symbol = "two" },
        },
    };

    try writer.write(&set, .{});
    try std.testing.expectEqualStrings("#3'one3'two4'five$", output.written());
    try writer.expectCleanWriterState();
}

test "same octets with shorter length come first" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    const set = dynamic.Value{ .set = &[_]dynamic.Value{
        .{ .int = .{ .i32 = 234 } },
        .{ .int = .{ .i32 = 2342356 } },
    } };

    try writer.write(&set, .{});
    try std.testing.expectEqualStrings("#234+2342356+$", output.written());

    try writer.expectCleanWriterState();
}

test "complex set" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    const set = dynamic.Value{
        .set = &[_]dynamic.Value{
            .{ .symbol = "one" },
            .{ .int = .{ .i64 = 2342356 } },
            .{ .dictionary = &[_]dynamic.Value{
                .{ .f64 = 67.98 },
                .{ .f64 = 67.89 },
                .{ .data = "boop" },
                .{ .f64 = 99.999 },
                .{ .set = &[_]dynamic.Value{
                    .{ .string = "hey" },
                    .{ .string = "there" },
                } },
                .{ .string = "stranger" },
            } },
        },
    };

    try writer.write(&set, .{});
    try std.testing.expectEqualSlices(
        u8,
        "#2342356+3'one{#3\"hey5\"there$8\"stranger4:boop" ++
            "D" ++ .{ 64, 88, 255, 239, 157, 178, 45, 14 } ++
            "D" ++ .{ 64, 80, 254, 184, 81, 235, 133, 31 } ++
            "D" ++ .{ 64, 80, 248, 245, 194, 143, 92, 41 } ++ "}$",
        output.written(),
    );
    try writer.expectCleanWriterState();
}

test "ensure sets don't allow duplicate entries" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    const set = dynamic.Value{
        .set = &[_]dynamic.Value{
            .{ .symbol = "one" },
            .{ .symbol = "five" },
            .{ .symbol = "five" },
            .{ .symbol = "two" },
        },
    };

    try std.testing.expectError(error.DuplicateEntryFound, writer.write(&set, .{}));
}

test "detection of mismatched nesting levels" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.writeDictionaryStart();
    try writer.writeSetStart();

    try std.testing.expectError(error.NestingMismatch, writer.writeDictionaryEnd());
}

test "The Grand Menagerie (ocapn spec test data)" {
    const menagerie = dynamic.Value{
        .record = .{
            .label = &.{ .data = "zoo" },
            .fields = &[_]dynamic.Value{
                .{ .string = "The Grand Menagerie" },
                .{ .sequence = &[_]dynamic.Value{
                    .{ .dictionary = &[_]dynamic.Value{
                        .{ .symbol = "species" },
                        .{ .data = "cat" },
                        .{ .symbol = "name" },
                        .{ .string = "Tabatha" },
                        .{ .symbol = "age" },
                        .{ .int = .{ .i32 = 12 } },
                        .{ .symbol = "weight" },
                        .{ .f64 = 8.2 },
                        .{ .symbol = "alive?" },
                        .true,
                        .{ .symbol = "eats" },
                        .{ .set = &[_]dynamic.Value{
                            .{ .data = "mice" },
                            .{ .data = "fish" },
                            .{ .data = "kibble" },
                        } },
                    } },
                    .{ .dictionary = &[_]dynamic.Value{
                        .{ .symbol = "species" },
                        .{ .data = "monkey" },
                        .{ .symbol = "name" },
                        .{ .string = "George" },
                        .{ .symbol = "age" },
                        .{ .int = .{ .i32 = 6 } },
                        .{ .symbol = "weight" },
                        .{ .f64 = 17.24 },
                        .{ .symbol = "alive?" },
                        .false,
                        .{ .symbol = "eats" },
                        .{ .set = &[_]dynamic.Value{
                            .{ .data = "bananas" },
                            .{ .data = "insects" },
                        } },
                    } },
                    .{ .dictionary = &[_]dynamic.Value{
                        .{ .symbol = "species" },
                        .{ .data = "ghost" },
                        .{ .symbol = "name" },
                        .{ .string = "Casper" },
                        .{ .symbol = "age" },
                        .{ .int = .{ .i32 = -12 } },
                        .{ .symbol = "weight" },
                        .{ .f64 = -34.5 },
                        .{ .symbol = "alive?" },
                        .false,
                        .{ .symbol = "eats" },
                        .{ .set = &[0]dynamic.Value{} },
                    } },
                } },
            },
        },
    };

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.write(&menagerie, .{});

    try std.testing.expectEqualSlices(u8, zoo_bin, output.written());
}

const MyStruct = struct {
    const Coord = struct {
        const syrup_format = WireFormat{
            .format = .sequence,
        };

        lat: f64,
        lon: f64,
    };

    const syrup_format = WireFormat{
        .format = .{ .record = .{ .label = .string } },
        .fields = &[_]Format{
            .{ .simple = .string },
            .{ .simple = .symbol },
            .default,
            .default,
            .{ .simple = .data },
            .sequence,
            .default,
        },
    };

    name: []const u8,
    id: []const u8,
    age: i32,
    description: []const u8,
    image_data: []const u8,
    favorite_numbers: [3]i64,
    location: Coord,
};

test "wire format" {
    const my_struct = MyStruct{
        .name = "vivi",
        .id = "vv",
        .age = 35,
        .description = "vivi is a human",
        .image_data = &[_]u8{ 42, 45, 46 },
        .favorite_numbers = [_]i64{ 42, 69, 67 },
        .location = .{ .lat = 45.238, .lon = 923.1239929 },
    };

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.write(&my_struct, .{});

    try std.testing.expectEqualSlices(
        u8,
        "<15\"Writer.MyStruct4\"vivi2'vv35+15\"vivi is a human3:" ++ .{
            42,
            45,
            46,
        } ++ "[42+69+67+][" ++
            "D" ++ .{ 64, 70, 158, 118, 200, 180, 57, 88 } ++
            "D" ++ .{ 64, 140, 216, 253, 239, 253, 83, 125 } ++
            "]>",
        output.written(),
    );
}

const TestSet = std.StaticStringMap(void);
const TestKVSet = struct { []const u8 };

const Zoo = struct {
    const syrup_format = WireFormat{
        .format = .{
            .record = .{
                .name = "zoo",
                .label = .data,
            },
        },
    };

    const Animal = struct {
        const syrup_format = WireFormat{
            .format = .{ .dictionary = .{ .key = .symbol } },
            .fields = &[_]Format{
                .{ .simple = .data },
                .{ .simple = .string },
                .default,
                .default,
                .default,
                .{ .set = .data },
            },
        };

        species: []const u8,
        name: []const u8,
        age: i32,
        weight: f64,
        @"alive?": bool,
        eats: []const []const u8,
    };

    name: []const u8,
    animals: []const Animal,
};

test "zig type menagerie" {

    //const tabatha_eats = TestSet.initComptime(
    //    &[_]TestKVSet{ .{"mice"}, .{"fish"}, .{"kibble"} },
    //);
    //const george_eats = TestSet.initComptime(
    //    &[_]TestKVSet{ .{"bananas"}, .{"insects"} },
    //);
    //const casper_eats = TestSet.initComptime(
    //    &[_]TestKVSet{},
    //);

    const menagerie = Zoo{
        .name = "The Grand Menagerie",
        .animals = &[_]Zoo.Animal{
            .{
                .species = "cat",
                .name = "Tabatha",
                .age = 12,
                .weight = 8.2,
                .@"alive?" = true,
                .eats = &.{ "mice", "fish", "kibble" },
            },
            .{
                .species = "monkey",
                .name = "George",
                .age = 6,
                .weight = 17.24,
                .@"alive?" = false,
                .eats = &.{ "bananas", "insects" },
            },
            .{
                .species = "ghost",
                .name = "Casper",
                .age = -12,
                .weight = -34.5,
                .@"alive?" = false,
                .eats = &.{},
            },
        },
    };

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.write(&menagerie, .{});

    try std.testing.expectEqualSlices(u8, zoo_bin, output.written());
}

// TODO!
test "non-static hashmap" {}
test "static dictionary hashmap" {}
test "non-static dictionary hashmap" {}

test "zon to menagerie" {
    const zoo_zon = @embedFile("test-data/zoo.zon");

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    const menagerie = try std.zon.parse.fromSlice(Zoo, std.testing.allocator, zoo_zon, null, .{});
    defer std.zon.parse.free(std.testing.allocator, menagerie);
    try writer.write(&menagerie, .{});

    try std.testing.expectEqualSlices(u8, zoo_bin, output.written());
}

test "small buffer/resize to catch realloc bugs" {}

// Begin tests for JSyrup

const zoo_jsyrup = @embedFile("test-data/zoo.jsyrup");

test "Grand Menagerie in JSyrup" {
    const menagerie = dynamic.Value{
        .record = .{
            .label = &.{ .data = "zoo" },
            .fields = &[_]dynamic.Value{
                .{ .string = "The Grand Menagerie" },
                .{ .sequence = &[_]dynamic.Value{
                    .{ .dictionary = &[_]dynamic.Value{
                        .{ .symbol = "species" },
                        .{ .data = "cat" },
                        .{ .symbol = "name" },
                        .{ .string = "Tabatha" },
                        .{ .symbol = "age" },
                        .{ .int = .{ .i32 = 12 } },
                        .{ .symbol = "weight" },
                        .{ .f64 = 8.2 },
                        .{ .symbol = "alive?" },
                        .true,
                        .{ .symbol = "eats" },
                        .{ .set = &[_]dynamic.Value{
                            .{ .data = "mice" },
                            .{ .data = "fish" },
                            .{ .data = "kibble" },
                        } },
                    } },
                    .{ .dictionary = &[_]dynamic.Value{
                        .{ .symbol = "species" },
                        .{ .data = "monkey" },
                        .{ .symbol = "name" },
                        .{ .string = "George" },
                        .{ .symbol = "age" },
                        .{ .int = .{ .i32 = 6 } },
                        .{ .symbol = "weight" },
                        .{ .f64 = 17.24 },
                        .{ .symbol = "alive?" },
                        .false,
                        .{ .symbol = "eats" },
                        .{ .set = &[_]dynamic.Value{
                            .{ .data = "bananas" },
                            .{ .data = "insects" },
                        } },
                    } },
                    .{ .dictionary = &[_]dynamic.Value{
                        .{ .symbol = "species" },
                        .{ .data = "ghost" },
                        .{ .symbol = "name" },
                        .{ .string = "Casper" },
                        .{ .symbol = "age" },
                        .{ .int = .{ .i32 = -12 } },
                        .{ .symbol = "weight" },
                        .{ .f64 = -34.5 },
                        .{ .symbol = "alive?" },
                        .false,
                        .{ .symbol = "eats" },
                        .{ .set = &[0]dynamic.Value{} },
                    } },
                } },
            },
        },
    };

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.initJSyrup(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.write(&menagerie, .{});

    try std.testing.expectEqualStrings(zoo_jsyrup, output.written());
}

test "jsyrup with escaped characters" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.initJSyrup(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.write(.{ .@"`title`" = "How to run", .text = "\tRun the \"Copy\" command.\n" }, .{});
    try std.testing.expectEqualStrings("{`\\`title\\``: \"How to run\", `text`: \"\\tRun the \\\"Copy\\\" command.\\n\"}", output.written());
}

test "tuples and compiler-generated structs" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.initJSyrup(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.write(.{ .name = "vivi", .interests = .{
        "ocapn",
        "goblins",
        "spritely",
        "music",
    }, .languages = .{ .{
        .name = "guile",
        .garbage_collected = true,
    }, .{
        .name = "zig",
        .garbage_collected = false,
    } } }, .{});
    try std.testing.expectEqualStrings("{`interests`: [\"ocapn\", \"goblins\", \"spritely\", \"music\"], `languages`: [{`garbage_collected`: true, `name`: \"guile\"}, {`garbage_collected`: false, `name`: \"zig\"}], `name`: \"vivi\"}", output.written());
}

const TestEnum = enum {
    one,
    @"test",
    after,
    another,
};

test "enum" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.write(.{ TestEnum.one, TestEnum.another }, .{});
    try std.testing.expectEqualStrings("[3'one7'another]", output.written());
}

const CustomTestEnum = enum {
    one,
    @"test",
    after,
    another,
};

const FancyCustomEnum = enum {
    one,
    @"\"test",
    after,
    another,
};

test "enum with custom layout" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.writeSequenceStart();
    try writer.write(CustomTestEnum.one, .{ .format = .{ .@"enum" = .{ .value = .symbol } } });
    try writer.write(FancyCustomEnum.@"\"test", .{
        .format = .{
            .@"enum" = .{ .value = .data, .namespaced = true },
        },
    });
    try writer.writeSequenceEnd();

    try std.testing.expectEqualStrings("[3'one28:Writer.FancyCustomEnum.\"test]", output.written());
}

test "enum literal" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.initJSyrup(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.write(.{ .@"`title`" = "How to run", .text = "\tRun the \"Copy\" command.\n" }, .{});
    try std.testing.expectEqualStrings("{`\\`title\\``: \"How to run\", `text`: \"\\tRun the \\\"Copy\\\" command.\\n\"}", output.written());
}
