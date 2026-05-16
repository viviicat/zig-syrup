//! A writer for the Syrup data format. Can write all of the supported Syrup datatypes to an underlying
//! `std.Io.Writer`.
//!
//! There are several supported options for writing:
//! - Write `Value` types to represent a structure dynamically with `writeValue`.
//! - Write primitives with the primitive methods like `writeString`, `writeBoolean`, etc.
//! - Write all of the above, and also Zig types, with `write`
//! - Write Syrup structures using the structural writing methods like `writeDictionary` and `writeSequence`.

const std = @import("std");

const base32 = @import("base32.zig");
const Value = @import("dynamic.zig").Value;
const Record = @import("Record.zig");
const tags = @import("tags.zig");
const CollectionMode = @import("collections.zig").CollectionMode;

const print = std.debug.print;

const Writer = @This();

const ParsingError = error{
    /// Tried to close the wrong type of nested item.
    NestingMismatch,
    /// Tried to end a record but we are not inside a record.
    RecordUnderflow,
    /// Tried to end a sequence but we are not inside a sequence.
    SequenceUnderflow,
    /// Tried to end a dictionary but we are not inside a dictionary.
    DictionaryUnderflow,
    /// Tried to end a dictionary immediately after adding a key, without a corresponding value
    DictionaryMissingValue,
    /// At least one duplicate entry was found in the dictionary or set.
    DuplicateEntryFound,
    /// Tried to end a set but we are not inside any sets.
    SetUnderflow,
};

const FormatterError = std.Io.Writer.Error || std.Io.Reader.Error;
pub const FlatError = FormatterError || std.mem.Allocator.Error;
pub const WritingError = ParsingError || FlatError;

pub const VTable = struct {
    /// Write a boolean Syrup value.
    writeBoolean: *const fn (writer: *std.Io.Writer, val: bool) FormatterError!void,
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
    pub fn writeBoolean(writer: *std.Io.Writer, val: bool) FormatterError!void {
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
    pub fn writeBoolean(writer: *std.Io.Writer, val: bool) FormatterError!void {
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
    fn writeEscapedChar(writer: *std.Io.Writer, char: u8) FormatterError!void {
        try writer.writeByte('\\');
        try writer.writeByte(char);
    }
    pub fn writeString(writer: *std.Io.Writer, val: []const u8) FormatterError!void {
        try writer.writeByte(tags.jsyrup.String);
        var i: usize = 0;
        while (i < val.len) : (i += 1) {
            switch (val[i]) {
                '"', '\\', '/', '\u{0008}', '\u{000C}', '\n', '\r', '\t' => try writeEscapedChar(writer, val[i]),
                else => try writer.writeByte(val[i]),
            }
        }
        try writer.writeByte(tags.jsyrup.String);
    }
    pub fn writeSymbol(writer: *std.Io.Writer, val: []const u8) FormatterError!void {
        try writer.writeByte(tags.jsyrup.Symbol);
        var i: usize = 0;
        while (i < val.len) : (i += 1) {
            switch (val[i]) {
                '`', '\\', '/', '\u{0008}', '\u{000C}', '\n', '\r', '\t' => try writeEscapedChar(writer, val[i]),
                else => try writer.writeByte(val[i]),
            }
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
            .writeBoolean = Formatter.writeBoolean,
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
            .writeBoolean = JSyrupFormatter.writeBoolean,
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

/// Write a supported type.
pub fn write(self: *Writer, val: anytype) WritingError!void {
    return self.writeWithFieldType(val, .default);
}

fn writeBytesWithType(self: *Writer, val: []const u8, field_type: FieldType) FlatError!void {
    switch (field_type) {
        .string, .default => try self.writeString(val),
        .data => try self.writeData(val),
        .symbol => try self.writeSymbol(val),
        .sequence, .set, .dictionary => unreachable,
    }
}

fn writeRecordStartWithType(self: *Writer, val: []const u8, field_type: FieldType) WritingError!void {
    const val_value = switch (field_type) {
        .string, .default => Value{ .string = val },
        .data => Value{ .data = val },
        .symbol => Value{ .symbol = val },
        .sequence, .set, .dictionary => unreachable,
    };

    try self.writeRecordStart(&val_value);
}

fn writeWithFieldType(self: *Writer, val: anytype, comptime field_type: FieldType) WritingError!void {
    const ValType = @TypeOf(val);
    const val_info = @typeInfo(ValType);

    try switch (ValType) {
        Value => self.writeValue(&val),
        *const Value => self.writeValue(val),
        Record => self.writeRecord(val),
        *const Record => self.writeRecord(val),
        bool => self.writeBoolean(val),
        f32 => self.writeFloat(val),
        f64 => self.writeDouble(val),
        else => switch (val_info) {
            .int => self.writeInt(val),
            .comptime_float => {
                if (@as(f64, @floatCast(val)) == val) {
                    return self.writeDouble(@as(f64, val));
                }

                @compileError("comptime float cannot be converted to f64");
            },
            .comptime_int => self.writeInt(val),
            .null => self.writeBoolean(false),
            .optional => {
                if (val) |payload| {
                    return self.writeWithFieldType(payload, field_type);
                } else {
                    return self.writeWithFieldType(null, field_type);
                }
            },
            .array => self.writeWithFieldType(&val, field_type),
            .vector => |info| {
                const array: [info.len]info.child = val;
                return self.writeWithFieldType(&array, field_type);
            },
            .@"struct" => |structure| {
                const TypeName = @typeName(ValType);

                // Check if it's an instance of a HashMap, if so we can write it as a Dictionary.
                // If it has a KV declaration we assume it is. A little more fragile than I would like, but I think it's relatively okay.
                const is_hash_map_like = @hasDecl(ValType, "KV");

                if (is_hash_map_like) {
                    const V = @typeInfo(@field(ValType, "KV")).@"struct".fields[1].type;
                    switch (V) {
                        void => {
                            if (field_type != .default and field_type != .set) {
                                @compileError(TypeName ++ " was detected to be a Set (seems to be HashMap with void V), but the field type specified for it was not `.set`.");
                            }

                            const set_type = comptime if (field_type == .set)
                                field_type.set.toFieldType()
                            else
                                .default;

                            try self.writeSetStart();

                            // Support both a standard HashMap that has a keyIterator, and the StaticStringMap which just has a keys function.
                            if (std.meta.hasFn(ValType, "keyIterator")) {
                                for (val.keys()) |key| {
                                    try self.writeWithFieldType(key, set_type);
                                }
                                var i = 0;
                                var it = val.keyIterator();
                                while (it.next()) |key| {
                                    try self.writeWithFieldType(key, set_type);
                                    i += 1;
                                }
                            } else if (std.meta.hasFn(ValType, "keys")) {
                                for (val.keys()) |key| {
                                    try self.writeWithFieldType(key, set_type);
                                }
                            } else @compileError("Found what looks like a set (has a KV decl with a void value) but it doesn't have `keyIterator` or `keys` functions");
                            return self.writeSetEnd();
                        },
                        else => {
                            if (field_type != .default and field_type != .dictionary) {
                                @compileError(TypeName ++ " was detected to be a Dictionary (seems to be HashMap), but the field type specified for it was not `.dictionary`.");
                            }

                            const dict_key_type = if (field_type == .dictionary) field_type.dictionary.key.toFieldType() else .default;
                            const dict_value_type = if (field_type == .dictionary) field_type.dictionary.value.toFieldType() else .default;

                            try self.writeDictionaryStart();
                            // Support both a standard HashMap that has an iterator, and the StaticStringMap which just has a kvs field
                            if (std.meta.hasFn(ValType, "iterator")) {
                                var i = 0;
                                var it = val.iterator();
                                while (it.next()) |kv| {
                                    try self.writeWithFieldType(kv.key, dict_key_type);
                                    try self.writeWithFieldType(kv.value, dict_value_type);
                                    i += 1;
                                }
                            } else if (std.meta.hasFn(ValType, "keys")) {
                                for (0..val.kvs.len) |i| {
                                    try self.writeWithFieldType(val.kvs.keys[i], dict_key_type);
                                    try self.writeWithFieldType(val.kvs.values[i], dict_value_type);
                                }
                            } else @compileError("Found a dictionary-like struct (has a KV decl with key and value) but it doesn't have `iterator` or `keys` functions");
                            return self.writeDictionaryEnd();
                        },
                    }
                }

                const has_wire_format = @hasDecl(ValType, "wire_format");

                if (has_wire_format) {
                    if (ValType.wire_format.fields) |field_types| {
                        // Verify wire format count matches field count
                        if (field_types.len != structure.fields.len) {
                            @compileError(std.fmt.comptimePrint(
                                "found wire_format declaration in {s}, length of field type list ({}) doesn't match the number of fields ({}).",
                                .{ TypeName, field_types.len, structure.fields.len },
                            ));
                        }
                    }
                }

                if (!has_wire_format or ValType.wire_format.layout == .record) {
                    const record_label_type: FieldType = if (has_wire_format)
                        ValType.wire_format.layout.record.label
                    else
                        .default;

                    const type_name = if (has_wire_format)
                        ValType.wire_format.layout.record.name orelse TypeName
                    else
                        TypeName;

                    try self.writeRecordStartWithType(type_name, record_label_type);
                } else {
                    switch (ValType.wire_format.layout) {
                        .sequence => try self.writeSequenceStart(),
                        .dictionary => try self.writeDictionaryStart(),
                        .record => {},
                    }
                }

                comptime var i = 0;
                inline for (structure.fields) |Field| {
                    if (has_wire_format and ValType.wire_format.layout == .dictionary) {
                        try self.writeWithFieldType(Field.name, ValType.wire_format.layout.dictionary);
                    }

                    const ft = if (has_wire_format)
                        if (ValType.wire_format.fields) |field_types|
                            field_types[i]
                        else
                            .default
                    else
                        .default;

                    try self.writeWithFieldType(@field(val, Field.name), ft);
                    i += 1;
                }

                if (!has_wire_format or ValType.wire_format.layout == .record) {
                    return self.writeRecordEnd();
                } else {
                    switch (ValType.wire_format.layout) {
                        .sequence => return self.writeSequenceEnd(),
                        .dictionary => return self.writeDictionaryEnd(),
                        .record => {},
                    }
                }
            },
            .pointer => |ptr_info| switch (ptr_info.size) {
                .one => {
                    const ChildType = ptr_info.child;
                    const child_info = @typeInfo(ChildType);
                    return switch (child_info) {
                        .array => {
                            // Coerce `*[N]T` to `[]const T`.
                            const Slice = []const std.meta.Elem(ChildType);
                            return self.writeWithFieldType(@as(Slice, val), field_type);
                        },
                        else => {
                            return self.writeWithFieldType(val.*, field_type);
                        },
                    };
                },
                .many, .slice => {
                    if (ptr_info.size == .many and ptr_info.sentinel() == null)
                        @compileError("unable to syrupify type '" ++ @typeName(ValType) ++ "' without sentinel");
                    const slice = if (ptr_info.size == .many) std.mem.span(val) else val;
                    if (ptr_info.child == u8 and field_type != .sequence) {
                        switch (field_type) {
                            .default, .string, .symbol, .data => {
                                return self.writeBytesWithType(slice, field_type);
                            },
                            else => {},
                        }
                    }

                    switch (field_type) {
                        .sequence, .default => {
                            try self.writeSequenceStart();
                            for (slice) |item| {
                                try self.writeWithFieldType(item, field_type);
                            }
                            return self.writeSequenceEnd();
                        },
                        .set => {
                            try self.writeSetStart();
                            for (slice) |item| {
                                try self.writeWithFieldType(item, field_type.set.toFieldType());
                            }
                            return self.writeSetEnd();
                        },
                        else => @compileError(std.fmt.comptimePrint("unsupported field type {s} for slice {s}. Dictionaries and sets cannot be safely serialized from slices due to non-uniqueness", .{ @tagName(field_type), @typeName(ValType) })),
                    }
                },
                else => @compileError("unsupported pointer type " ++ @typeName(ValType)),
            },
            else => @compileError("unsupported type! " ++ @typeName(ValType)),
        },
    };
}

/// Write a `Value`.
pub fn writeValue(self: *Writer, gen: *const Value) WritingError!void {
    return try switch (gen.*) {
        .true => self.writeBoolean(true),
        .false => self.writeBoolean(false),
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
        .sequence => |val| self.writeSequence(val),
        .record => |val| self.writeRecord(&val),
        .dictionary => |val| self.writeDictionary(val),
        .set => |val| self.writeSet(val),
    };
}

/// Write a boolean value.
pub fn writeBoolean(self: *Writer, val: bool) FlatError!void {
    try self.startWrite();
    try self.vtable.writeBoolean(self.curWriter(), val);
}

/// Write an integer value of any width.
pub fn writeInt(self: *Writer, val: anytype) FlatError!void {
    const ValType = @TypeOf(val);
    const ValInfo = @typeInfo(ValType);
    switch (ValInfo) {
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

/// Return the provided error if the expected nested item isn't the current parent.
fn ensureProperNesting(self: *Writer, mode: CollectionMode, err: ParsingError) WritingError!void {
    const data = self.nested_datas.pop() orelse return err;
    if (data != mode) {
        return error.NestingMismatch;
    }
}

/// Finish writing a Sequence. Throws `SequenceUnderflow` if we aren't in any sequences.
pub fn writeSequenceEnd(self: *Writer) WritingError!void {
    try self.ensureProperNesting(.sequence, error.SequenceUnderflow);
    try self.vtable.writeSequenceEnd(self.curWriter());
}

/// Write a full Sequence given a list of `Value`.
pub fn writeSequence(self: *Writer, val: []const Value) WritingError!void {
    try self.writeSequenceStart();
    for (val) |gen| {
        try self.writeValue(&gen);
    }
    try self.writeSequenceEnd();
}

/// Begin writing a Record given a label. The Record will be populated with subsequent writes.
/// Call `writeRecordEnd` to finish the Record.
pub fn writeRecordStart(self: *Writer, label: *const Value) WritingError!void {
    try self.startWrite();
    try self.vtable.writeRecordStart(self.curWriter());
    try self.nested_datas.append(self.gpa, .{ .record = 0 });
    try self.writeValue(label);
}

/// Finish writing a Record. Throws `RecordUnderflow` if we aren't in any records.
pub fn writeRecordEnd(self: *Writer) WritingError!void {
    try self.ensureProperNesting(.record, error.RecordUnderflow);
    try self.vtable.writeRecordEnd(self.curWriter());
}

/// Write a full Record.
pub fn writeRecord(self: *Writer, val: *const Record) WritingError!void {
    try self.writeRecordStart(val.label);
    for (val.fields) |field| {
        try self.writeValue(&field);
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

fn sortIndices(self: *Writer, dict_data: *DictData) WritingError!void {
    var comp_data = CompData{ .buf = self.tmp_writer.written() };
    std.mem.sort(KeyValueIndices, dict_data.indices.items, &comp_data, cmpIndices);
    if (comp_data.found_duplicates) {
        return error.DuplicateEntryFound;
    }
}

/// Finish writing a Dictionary. Throws `DictionaryUnderflow` if we aren't in any dictionaries.
/// This sorts entries by key and then (unless we are still inside an outer Dictionary or Set) performs
/// the actual flush of keys and values to the underlying writer, as previous calls will have
/// only populated `tmp_writer` with items.
pub fn writeDictionaryEnd(self: *Writer) WritingError!void {
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

/// Given the dictionary data, finalize it by sorting by keys and putting the sorted bytes into the
/// right position in the buffer.
fn finalizeDictData(
    self: *Writer,
    dict_data: *DictData,
    write_delimiter: *const fn (writer: *std.Io.Writer) WritingError!void,
) WritingError!void {
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

/// Write a full Dictionary given a list of `Value`.
pub fn writeDictionary(self: *Writer, val: []const Value) WritingError!void {
    try self.writeDictionaryStart();
    for (val) |gen| {
        try self.writeValue(&gen);
    }
    try self.writeDictionaryEnd();
}

/// Begin writing a Set of data. `tmp_writer` will be filled with subsequent writes of
/// entries, until the set is complete.
/// Call `writeSetEnd` to finish the Set.
pub fn writeSetStart(self: *Writer) WritingError!void {
    try self.startWrite();
    try self.vtable.writeSetStart(self.curWriter());
    self.dict_or_set_depth += 1;
    try self.nested_datas.append(self.gpa, .{ .set = .{ .start_index = self.tmpWrittenLen() } });
}

/// Finish writing a Set. Throws `SetUnderflow` if we aren't in any sets.
/// This sorts entries and then (unless we are still inside an outer Dictionary or Set) performs
/// the actual flush of items to the underlying writer, as previous calls will have
/// only populated `tmp_writer` with items.
pub fn writeSetEnd(self: *Writer) WritingError!void {
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

/// Write a full Set given a list of `Value`.
pub fn writeSet(self: *Writer, val: []const Value) WritingError!void {
    try self.writeSetStart();
    for (val) |gen| {
        try self.writeValue(&gen);
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
fn maybeFlushBuffer(self: *Writer) WritingError!void {
    if (self.dict_or_set_depth == 0) {
        try self.underlying_writer.writeAll(self.tmp_writer.written());
        self.tmp_writer.clearRetainingCapacity();
    }
}

/// Enum for specifying the type to use when serializing a Zig field to Syrup.
pub const FieldType = union(enum) {
    /// Simplified field type for types that are used inside Dictionaries and Maps.
    ///
    /// Note: If you need to customize settings for a Dictionary that contains a Set or a Dictionary,
    /// that's not possible this way, because of circular dependencies in the `FieldType` union.
    /// In the future a `syrupify` function will be used for custom serialization of complex types.
    pub const SimpleFieldType = enum {
        /// The field is serialized with the default options.
        /// `[]const u8` fields are serialized as strings by default.
        /// `[]const u8` keys for Sets and Dictionaries, and values for Dictionaries are serialized as strings by default.
        /// The label of a Record type is serialized as a symbol by default.
        /// All other array-like fields are serialized as a Sequence.
        default,
        /// `[]const u8` field serialized as a string.
        string,
        /// `[]const u8` field serialized as a symbol.
        symbol,
        /// `[]const u8` field serialized as data.
        data,
        /// array-like field serialized as a sequence.
        sequence,

        pub fn toFieldType(comptime self: SimpleFieldType) FieldType {
            return switch (self) {
                .default => .default,
                .string => .string,
                .symbol => .symbol,
                .data => .data,
                .sequence => .sequence,
            };
        }
    };

    /// Field type for Dictionaries, containing both a key and a value type.
    ///
    /// Note: If you need to customize settings for a Dictionary that contains a Set or a Dictionary,
    /// that's not possible this way, because of circular dependencies in the `FieldType` union.
    /// In the future a `syrupify` function will be used for custom serialization of complex types.
    pub const DictionaryFieldType = struct {
        /// The type of the key for the dictionary.
        key: SimpleFieldType = .default,
        /// The type of the value for the dictionary.
        value: SimpleFieldType = .default,
    };

    /// The field is serialized with the default options.
    /// `[]const u8` fields are serialized as strings by default.
    /// `[]const u8` keys for Sets and Dictionaries, and values for Dictionaries are serialized as strings by default.
    /// The label of a Record type is serialized as a symbol by default.
    /// All other array-like fields are serialized as a Sequence.
    default,
    /// Field serialized as a string.
    string,
    /// Field serialized as a symbol.
    symbol,
    /// Field serialized as raw data.
    data,
    /// Single array-like field serialized as a sequence.
    sequence,
    /// The field is a dictionary.
    dictionary: DictionaryFieldType,
    /// The field is a set of the given field type.
    set: SimpleFieldType,
};

/// A structure that can be defined as a compile time constant in a structure with the name `wire_format`.
/// This will be detected at compile time and used to determine the types to use when serializing bytes.
pub const WireFormat = struct {
    /// Structure for defining the layout for Zig struct when serialized to Syrup.
    const ContainerLayout = union(enum) {
        /// Options for when a Zig struct is serialized as a Syrup Record.
        pub const RecordOptions = struct {
            /// Name to use for the struct in the Record's label.
            name: ?[]const u8 = null,
            /// The type to use for the record's label.
            label: FieldType = .symbol,
        };

        /// Serialize the structure as a Record, with the specified `FieldType` as the type of the record' label. The label's value will be the type name of the struct.
        record: RecordOptions,
        /// Serialize the structure's fields as a sequence without emitting the structure's type name or the field names.
        sequence,
        /// Serialize the structure's fields as a dictionary without emitting the structure's type name. The specified `FieldType` is the type to use for each field's name.
        dictionary: FieldType,
    };

    /// The layout that the structure is serialized in.
    layout: ContainerLayout = .{ .record = .{} },
    /// List of types to use for each field. The length must match the number of fields in the structure.
    fields: ?[]const FieldType = null,
};

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

    try writer.write(false);
    try writer.write(true);
    try writer.write(502345);
    try writer.write(-42069);

    try std.testing.expectEqualStrings("ft502345+42069-", output.written());
    try writer.expectCleanWriterState();
}

test "float datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.write(14.4);
    try writer.write(@as(f32, 58.365));
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
    const sequence = [_]Value{
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

    try writer.write(&sequence);
    try std.testing.expectEqualStrings("[6\"a test45+5'shark[170141183460469231731687303715884105690-15\"testing nesting]]", output.written());
    try writer.expectCleanWriterState();
}

test "record datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    const record = Record{
        .label = &.{
            .sequence = &[_]Value{
                .{ .string = "hello" },
                .{ .int = .{ .i32 = 2456 } },
            },
        },
        .fields = &[_]Value{
            .true,
            .false,
            .{ .symbol = "dogs-and-cats" },
        },
    };

    try writer.write(&record);
    try std.testing.expectEqualStrings("<[5\"hello2456+]tf13'dogs-and-cats>", output.written());
    try writer.expectCleanWriterState();
}

test "simple dictionary datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    const dict = Value{
        .dictionary = &[_]Value{
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

    try writer.write(&dict);
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
    const dict = Value{
        .dictionary = &[_]Value{
            .{ .dictionary = &[_]Value{
                .{ .dictionary = &[_]Value{
                    .{ .int = .{ .i32 = 100 } },
                    .{ .int = .{ .i32 = 88888 } },
                    .{ .int = .{ .i32 = 99 } },
                    .{ .int = .{ .i32 = 99999 } },
                } },
                .{ .string = "hello world" },
                .{ .dictionary = &[_]Value{
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

    try writer.write(&dict);
    try std.testing.expectEqualStrings("{4\"key142+4\"key34+4\"key82+{{100+88888+99+99999+}11\"hello world{33+55555+508+44444+}20\"values values values}45+}", output.written());

    try writer.expectCleanWriterState();
}

test "ensure dictionaries don't allow duplicate keys" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    // Same complex nested dictionary, but it has a problem, a duplicate key deep in the nesting.
    const dict = Value{
        .dictionary = &[_]Value{
            .{ .dictionary = &[_]Value{
                .{ .dictionary = &[_]Value{
                    .{ .int = .{ .i32 = 99 } },
                    .{ .int = .{ .i32 = 88888 } },
                    .{ .int = .{ .i32 = 99 } },
                    .{ .int = .{ .i32 = 99999 } },
                } },
                .{ .string = "hello world" },
                .{ .dictionary = &[_]Value{
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

    try std.testing.expectError(error.DuplicateEntryFound, writer.write(&dict));
}

test "ensure the user entered a value for every dictionary entry" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    const dict = Value{ .dictionary = &[_]Value{
        .{ .symbol = "one" },
        .{ .int = .{ .i32 = 45 } },
        .{ .symbol = "two" },
    } };

    try std.testing.expectError(error.DictionaryMissingValue, writer.write(&dict));
}

test "simple set" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    const set = Value{
        .set = &[_]Value{
            .{ .symbol = "one" },
            .{ .symbol = "five" },
            .{ .symbol = "two" },
        },
    };

    try writer.write(&set);
    try std.testing.expectEqualStrings("#3'one3'two4'five$", output.written());
    try writer.expectCleanWriterState();
}

test "same octets with shorter length come first" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    const set = Value{ .set = &[_]Value{
        .{ .int = .{ .i32 = 234 } },
        .{ .int = .{ .i32 = 2342356 } },
    } };

    try writer.write(&set);
    try std.testing.expectEqualStrings("#234+2342356+$", output.written());

    try writer.expectCleanWriterState();
}

test "complex set" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    const set = Value{
        .set = &[_]Value{
            .{ .symbol = "one" },
            .{ .int = .{ .i64 = 2342356 } },
            .{ .dictionary = &[_]Value{
                .{ .f64 = 67.98 },
                .{ .f64 = 67.89 },
                .{ .data = "boop" },
                .{ .f64 = 99.999 },
                .{ .set = &[_]Value{
                    .{ .string = "hey" },
                    .{ .string = "there" },
                } },
                .{ .string = "stranger" },
            } },
        },
    };

    try writer.write(&set);
    try std.testing.expectEqualStrings(
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

    const set = Value{
        .set = &[_]Value{
            .{ .symbol = "one" },
            .{ .symbol = "five" },
            .{ .symbol = "five" },
            .{ .symbol = "two" },
        },
    };

    try std.testing.expectError(error.DuplicateEntryFound, writer.write(&set));
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
    const menagerie = Value{
        .record = .{
            .label = &.{ .data = "zoo" },
            .fields = &[_]Value{
                .{ .string = "The Grand Menagerie" },
                .{ .sequence = &[_]Value{
                    .{ .dictionary = &[_]Value{
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
                        .{ .set = &[_]Value{
                            .{ .data = "mice" },
                            .{ .data = "fish" },
                            .{ .data = "kibble" },
                        } },
                    } },
                    .{ .dictionary = &[_]Value{
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
                        .{ .set = &[_]Value{
                            .{ .data = "bananas" },
                            .{ .data = "insects" },
                        } },
                    } },
                    .{ .dictionary = &[_]Value{
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
                        .{ .set = &[0]Value{} },
                    } },
                } },
            },
        },
    };

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.write(&menagerie);

    try std.testing.expectEqualStrings(zoo_bin, output.written());
}

const MyStruct = struct {
    const wire_format = WireFormat{
        .layout = .{ .record = .{ .label = .string } },
        .fields = &[_]FieldType{
            .string,
            .symbol,
            .default,
            .default,
            .data,
            .sequence,
        },
    };

    name: []const u8,
    id: []const u8,
    age: i32,
    description: []const u8,
    image_data: []const u8,
    favorite_numbers: [3]i64,
};

test "wire format" {
    const my_struct = MyStruct{
        .name = "vivi",
        .id = "vv",
        .age = 35,
        .description = "vivi is a human",
        .image_data = &[_]u8{ 42, 45, 46 },
        .favorite_numbers = [_]i64{ 42, 69, 67 },
    };

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.write(&my_struct);

    try std.testing.expectEqualStrings(
        "<15\"Writer.MyStruct4\"vivi2'vv35+15\"vivi is a human3:" ++ .{
            42,
            45,
            46,
        } ++ "[42+69+67+]>",
        output.written(),
    );
}

const TestSet = std.StaticStringMap(void);
const TestKVSet = struct { []const u8 };

const Zoo = struct {
    const wire_format = WireFormat{
        .layout = .{
            .record = .{
                .name = "zoo",
                .label = .data,
            },
        },
    };

    const Animal = struct {
        const wire_format = WireFormat{
            .layout = .{ .dictionary = .symbol },
            .fields = &[_]FieldType{
                .data,
                .string,
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

    try writer.write(&menagerie);

    try std.testing.expectEqualStrings(zoo_bin, output.written());
}

// TODO!
test "non-static hashmap" {}
test "static dictionary hashmap" {}
test "non-static dictionary hashmap" {}

test "zon to menagerie" {
    // TODO: lots of copies of this embedded file lol
    const zoo_zon = @embedFile("test-data/zoo.zon");

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    const menagerie = try std.zon.parse.fromSlice(Zoo, std.testing.allocator, zoo_zon, null, .{});
    defer std.zon.parse.free(std.testing.allocator, menagerie);
    try writer.write(&menagerie);

    try std.testing.expectEqualStrings(zoo_bin, output.written());
}

test "small buffer/resize to catch realloc bugs" {}

// Begin tests for JSyrup

const zoo_jsyrup = @embedFile("test-data/zoo.jsyrup");

test "Grand Menagerie in JSyrup" {
    const menagerie = Value{
        .record = .{
            .label = &.{ .data = "zoo" },
            .fields = &[_]Value{
                .{ .string = "The Grand Menagerie" },
                .{ .sequence = &[_]Value{
                    .{ .dictionary = &[_]Value{
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
                        .{ .set = &[_]Value{
                            .{ .data = "mice" },
                            .{ .data = "fish" },
                            .{ .data = "kibble" },
                        } },
                    } },
                    .{ .dictionary = &[_]Value{
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
                        .{ .set = &[_]Value{
                            .{ .data = "bananas" },
                            .{ .data = "insects" },
                        } },
                    } },
                    .{ .dictionary = &[_]Value{
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
                        .{ .set = &[0]Value{} },
                    } },
                } },
            },
        },
    };

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.initJSyrup(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.write(&menagerie);

    try std.testing.expectEqualStrings(zoo_jsyrup, output.written());
}
