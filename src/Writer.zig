//! A writer for the Syrup data format. Can write all of the supported Syrup datatypes to an underlying
//! `std.Io.Writer`.
//!
//! There are many supported options for writing:
//! - Write a Zig type, including primitives, with `write` (most types are supported through the magic of `comptime`).
//! - You can even write an anonymous struct (defined at compile time) with `write`.
//! - You can also write primitives with the primitive methods like `writeString`, `writeBool`, etc (or just `write`).
//! - Use `dynamic.Value` to build structures at runtime to write with `writeDynamicValue` and friends (or just `write`).
//! - Build up Syrup structures manually using the structural writing methods like `writeDictionaryStart` and `writeSequenceStart`.
//!
//! Zig structs and unions can be customized to display in various ways. They can take the
//! form of a syrup Dictionary (the default), Record, or Sequence. Records have additional
//! ways of being represented. See `spec` for info on how to customize a struct or union.
//! You can also specify a `Format` in the options of `write` for one-off customizations.
//!
//! Finally, if you want *full control* of how a struct, enum or union is turned into
//! syrup format, define a public member named `syrupify` with `Writer` as the argument.

const std = @import("std");

const base32 = @import("base32.zig");
const CollectionMode = @import("collections.zig").CollectionMode;
const dynamic = @import("dynamic.zig");
const tags = @import("tags.zig");

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
///
/// JSyrup is a json-like human readable format of Syrup, that is not meant to be used as a wire protocol. It does not have stable round-trip properties. Meant for debugging and printing information about Syrup structure.
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

fn writeBytes(self: *Writer, val: []const u8, format: ?Format.Simple) FlatError!void {
    if (format) |fmt| switch (fmt) {
        .string => try self.writeString(val),
        .data => try self.writeData(val),
        .symbol => try self.writeSymbol(val),
    } else try self.writeString(val);
}

// Used to check if a child field will be serialized as a record, as it affects the logic in some scenarios.
// This won't work if the record is serialized manually, for example in the `syrupify` function.
fn isRecord(comptime T: type) bool {
    const res = switch (@typeInfo(T)) {
        .@"struct" => {
            const syrup_spec: ?spec.Struct = if (@hasDecl(T, s_syrup_spec)) T.syrup_spec else null;
            return if (syrup_spec) |s_spec|
                s_spec.format == .record
            else
                false;
        },
        .@"union" => {
            const syrup_spec: ?spec.Union = if (@hasDecl(T, s_syrup_spec)) T.syrup_spec else null;
            return if (syrup_spec) |s_spec|
                s_spec.format == .record
            else
                false;
        },
        else => false,
    };

    return res;
}

/// Write a supported type.
pub fn write(self: *Writer, val: anytype, comptime options: Options) WritingError!void {
    const T = @TypeOf(val);
    const val_info = @typeInfo(T);
    const type_name = @typeName(T);

    switch (T) {
        bool => try self.writeBool(val),
        void => try self.writeBool(false),
        f32 => try self.writeFloat(val),
        f64 => try self.writeDouble(val),
        dynamic.Value => try self.writeDynamicValue(&val),
        dynamic.Record => try self.writeDynamicRecord(&val),
        else => switch (val_info) {
            .int => try self.writeInt(val),
            .comptime_float => {
                if (@as(f64, @floatCast(val)) == val) {
                    return try self.writeDouble(@as(f64, val));
                }

                @compileError("comptime float cannot be converted to f64");
            },
            .comptime_int => try self.writeInt(val),
            .null => try self.writeBool(false),
            .optional => {
                if (val) |payload| {
                    return try self.write(payload, options);
                } else {
                    return try self.write(null, options);
                }
            },
            .array => try self.write(&val, options),
            .vector => |info| {
                const array: [info.len]info.child = val;
                return try self.write(&array, options);
            },
            .@"struct" => |struct_info| {
                if (std.meta.hasFn(T, s_syrupify)) {
                    return try val.syrupify(self);
                }

                const syrup_spec: ?spec.Struct = if (@hasDecl(T, s_syrup_spec)) T.syrup_spec else null;

                // Check if it's an instance of a HashMap, if so we can write it as a Dictionary.
                // If it has a KV declaration we assume it is. A little more fragile than I would like, but I think it's relatively okay.
                const is_hash_map_like = @hasDecl(T, "KV");
                if (syrup_spec == null and is_hash_map_like) {
                    const V = @typeInfo(@field(T, "KV")).@"struct".fields[1].type;
                    switch (V) {
                        void => {
                            const format: ?Format.Simple = if (options.format) |fmt|
                                switch (fmt) {
                                    .set => |s_fmt| s_fmt,
                                    else => @compileError(type_name ++ " was detected to be a Set (seems to be HashMap with void V), but the layout specified for it was not `.set`."),
                                }
                            else
                                null;

                            const val_options = Options{ .format = format };

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
                            return try self.writeSetEnd();
                        },
                        else => {
                            const format: Format.Dictionary = if (options.format) |fmt| switch (fmt) {
                                .dictionary => |d_fmt| d_fmt,
                                else => @compileError("Found what looks like a dictionary (has a KV decl with non-void value) but the format specified for it was not `.dictionary`."),
                            } else .{};

                            const key_options = Options{ .format = format.keys };
                            const value_options = Options{ .format = format.values };

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
                            return try self.writeDictionaryEnd();
                        },
                    }
                }

                if (syrup_spec) |s_spec| {
                    if (s_spec.fields) |field_formats| {
                        // Verify field layout count matches field count
                        if (field_formats.len != struct_info.fields.len) {
                            @compileError(std.fmt.comptimePrint(
                                "found `syrup_spec` declaration in {s}, but length of field format list ({}) doesn't match the number of fields ({}).",
                                .{ type_name, field_formats.len, struct_info.fields.len },
                            ));
                        }
                    }
                }

                const format: ?Format.Struct = if (options.format) |fmt|
                    switch (fmt) {
                        .@"struct" => |st| st,
                        else => @compileError("write options specified non-struct format for struct " ++ type_name),
                    }
                else if (syrup_spec) |s_spec|
                    s_spec.format
                else
                    null;

                // Tuples default to a sequence.
                const write_sequence = (format == null and struct_info.is_tuple) or
                    (format != null and (format.? == .sequence or format.? == .labeled_sequence));
                if (write_sequence) {
                    try self.writeSequenceStart();
                    if (format) |fmt| {
                        if (fmt == .labeled_sequence) {
                            const seq_label_format: Format = .{ .simple = fmt.labeled_sequence.label };
                            const seq_type_name = fmt.labeled_sequence.name orelse type_name;
                            try self.write(seq_type_name, .{
                                .format = seq_label_format,
                            });
                        }
                    }
                } else if (format == null or format.? == .dictionary) {
                    // Other structs default to a dictionary.
                    try self.writeDictionaryStart();
                } else if (format != null and format.? == .record) {
                    const record_label_format: Format = .{
                        .simple = if (format) |fmt|
                            fmt.record.label
                        else
                            .symbol,
                    };

                    const rec_type_name = if (format) |fmt|
                        fmt.record.name orelse type_name
                    else
                        type_name;

                    try self.writeRecordStartLabeledOptions(rec_type_name, .{
                        .format = record_label_format,
                    });
                }

                comptime var i = 0;
                inline for (struct_info.fields) |Field| {
                    if (!write_sequence and
                        (format == null or format.? == .dictionary))
                    {
                        // Default to symbols as dictionary keys
                        try self.write(
                            Field.name,
                            .{
                                .format = .{
                                    .simple = if (format) |fmt|
                                        fmt.dictionary.keys
                                    else
                                        .symbol,
                                },
                            },
                        );
                    }

                    const field_format: ?Format = if (syrup_spec) |s_spec|
                        if (s_spec.fields) |field_formats|
                            field_formats[i]
                        else if (s_spec.format == .dictionary)
                            s_spec.format.dictionary.values
                        else
                            null
                    else
                        null;

                    try self.write(@field(val, Field.name), .{ .format = field_format });
                    i += 1;
                }

                if (write_sequence) {
                    return try self.writeSequenceEnd();
                } else if (format == null or format.? == .dictionary) {
                    return try self.writeDictionaryEnd();
                }
                return try self.writeRecordEnd();
            },
            .@"enum" => |enum_info| {
                if (std.meta.hasFn(T, s_syrupify)) {
                    return try val.syrupify(self);
                }

                if (!enum_info.is_exhaustive) {
                    // Check if the value is part of the enum (print the value directly if not).
                    inline for (enum_info.fields) |field| {
                        if (val == @field(T, field.name)) {
                            break;
                        }
                    } else {
                        return try self.write(@intFromEnum(val), .{});
                    }
                }

                const enum_format: Format.Enum = if (options.format) |syrup_fmt| switch (syrup_fmt) {
                    .@"enum" => |fmt| fmt,
                    else => |fmt| @compileError("Enum's format should be either null, or the enum field, was " ++ @tagName(fmt)),
                } else .{};

                var name_buf: [128]u8 = undefined;
                const val_str = if (enum_format.namespaced)
                    try std.fmt.bufPrint(&name_buf, "{s}.{s}", .{ type_name, @tagName(val) })
                else
                    @tagName(val);

                const val_options = Options{ .format = .{ .simple = enum_format.value } };

                return try self.write(val_str, val_options);
            },
            // TODO merge with above using inline ?
            .enum_literal => {
                const enum_format: Format.Enum = if (options.format) |fmt| switch (fmt) {
                    .@"enum" => |e_fmt| e_fmt,
                    else => @compileError("Enum's format should be either null, or the enum field, was " ++ @tagName(fmt)),
                };
                const val_str = if (enum_format.namespaced) {
                    var name_buf: [128]u8 = undefined;
                    return try std.fmt.bufPrint(&name_buf, "{s}.{s}", .{ type_name, @tagName(val) });
                } else @tagName(val);

                const val_options = Options{ .format = enum_format.value };

                return try self.write(val_str, val_options);
            },
            .@"union" => |info| {
                if (std.meta.hasFn(T, s_syrupify)) {
                    return try val.syrupify(self);
                }

                const syrup_spec: ?spec.Union = if (@hasDecl(T, s_syrup_spec)) T.syrup_spec else null;

                const format: Format.Union = if (options.format) |fmt| switch (fmt) {
                    .@"union" => |u_fmt| u_fmt,
                    else => @compileError("options format should be union type."),
                } else if (syrup_spec) |s_spec| s_spec.format else .{ .dictionary = .symbol };

                if (info.tag_type) |UnionTagType| {
                    comptime var record_types: [info.fields.len]type = undefined;
                    comptime var num_record_types = 0;
                    comptime var i = 0;
                    inline for (info.fields) |u_field| {
                        const is_record = comptime isRecord(u_field.type);
                        if (format == .record_merge and is_record) {
                            inline for (record_types[0..num_record_types]) |t|
                                if (t == u_field.type) @compileError("union " ++ type_name ++ " contained multiple struct/union fields of the same type. This is not allowed when record_merge is selected, because there would be no way to differentiate them.");
                            record_types[num_record_types] = u_field.type;
                            num_record_types += 1;
                        }

                        const field_format: ?Format = if (syrup_spec) |s_spec|
                            if (s_spec.fields) |field_formats|
                                field_formats[i]
                            else
                                null
                        else
                            null;
                        i += 1;

                        if (val == @field(UnionTagType, u_field.name)) {
                            const field_val = @field(val, u_field.name);
                            switch (format) {
                                .dictionary => |key_fmt| {
                                    try self.writeDictionaryStart();
                                    try self.write(u_field.name, .{ .format = .{ .simple = key_fmt } });
                                    try self.write(field_val, .{ .format = field_format });
                                    try self.writeDictionaryEnd();
                                },
                                .record => |label_fmt| {
                                    try self.writeRecordStartLabeledOptions(u_field.name, .{ .format = .{ .simple = label_fmt } });
                                    try self.write(field_val, .{ .format = field_format });
                                    try self.writeRecordEnd();
                                },
                                .record_merge => |label_fmt| {
                                    if (!isRecord(u_field.type)) {
                                        try self.writeRecordStartLabeledOptions(u_field.name, .{ .format = .{ .simple = label_fmt } });
                                    }
                                    try self.write(field_val, .{ .format = field_format });
                                    if (!isRecord(u_field.type)) {
                                        try self.writeRecordEnd();
                                    }
                                },
                                .direct_value => {
                                    try self.write(field_val, .{ .format = field_format });
                                },
                            }
                            break;
                        }
                    } else {
                        unreachable; // No active tag?
                    }
                    return;
                } else {
                    @compileError("Unable to serialize untagged union '" ++ @typeName(T) ++ "'");
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
                            return try self.write(@as(Slice, val), options);
                        },
                        else => {
                            return try self.write(val.*, options);
                        },
                    };
                },
                .many, .slice => {
                    if (ptr_info.size == .many and ptr_info.sentinel() == null)
                        @compileError("unable to serialize type '" ++ @typeName(T) ++ "' without sentinel");
                    const slice = if (ptr_info.size == .many) std.mem.span(val) else val;
                    if (ptr_info.child == u8) {
                        if (options.format) |fmt| {
                            switch (fmt) {
                                .simple => |simple| return try self.writeBytes(slice, simple),
                                .sequence => {},
                                else => @compileError("cannot use " ++ options.format ++ " format for []u8"),
                            }
                        } else return try self.writeBytes(slice, .string);
                    }

                    switch (options.format orelse .sequence) {
                        .sequence => {
                            try self.writeSequenceStart();
                            for (slice) |item| {
                                try self.write(item, options);
                            }
                            return try self.writeSequenceEnd();
                        },
                        .set => |set| {
                            try self.writeSetStart();
                            for (slice) |item| {
                                try self.write(item, .{ .format = .{ .simple = set } });
                            }
                            return try self.writeSetEnd();
                        },
                        else => @compileError(std.fmt.comptimePrint("unsupported format {s} for slice {s}. Dictionaries and sets cannot be safely serialized from slices due to non-uniqueness", .{ @tagName(options), @typeName(T) })),
                    }
                },
                else => @compileError("unsupported pointer type " ++ @typeName(T)),
            },
            else => @compileError("unsupported type! " ++ @typeName(T)),
        },
    }
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

/// Begin writing a Sequence.
///
/// The Sequence will be populated with subsequent writes.
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

/// Begin writing a Record given a label.
///
/// The Record will be populated with subsequent writes.
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
        if (options.format == null or
            (options.format.? == .simple and options.format.?.simple == null))
            .{ .format = .{ .simple = .symbol } }
        else
            options,
    );
}

pub const RecordError = FormatterError || NestingError || std.mem.Allocator.Error;

/// Finish writing a Record.
///
/// Throws `RecordUnderflow` if we aren't in any records.
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

/// Begin writing a Dictionary of data.
///
/// `tmp_writer` will be filled with subsequent writes of
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

/// Finish writing a Dictionary.
///
/// Throws `DictionaryUnderflow` if we aren't in any dictionaries.
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

/// Begin writing a Set of data.
///
/// `tmp_writer` will be filled with subsequent writes of
/// entries, until the set is complete.
/// Call `writeSetEnd` to finish the Set.
pub fn writeSetStart(self: *Writer) FlatError!void {
    try self.startWrite();
    try self.vtable.writeSetStart(self.curWriter());
    self.dict_or_set_depth += 1;
    try self.nested_datas.append(self.gpa, .{ .set = .{ .start_index = self.tmpWrittenLen() } });
}

pub const SetError = FormatterError || error{ DuplicateEntryFound, NestingMismatch, SetUnderflow } || std.mem.Allocator.Error;
/// Finish writing a Set.
///
/// Throws `SetUnderflow` if we aren't in any sets.
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

/// Start a write operation.
///
/// We record index positions if we are in a Dictionary or Set.
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

/// While not strictly necessary, this function can be used to assert that all nested structures have been
/// written properly. Run it when the structure is done being written.
pub fn finish(self: *Writer) error{NotFinished}!void {
    if (self.nested_datas.items.len > 0) {
        return error.NotFinished;
    }
}

pub const s_syrup_spec = "syrup_spec";
const s_syrupify = "syrupify";

/// Options for `write`.
pub const Options = struct {
    /// The `Format` to use for the structure.
    format: ?Format = null,
};

/// Custom format specification for a type.
///
/// This lets you customize how Zig types are saved in Syrup format,
/// including whether to use save byte slices as strings, symbols or data, and what container to store structs in.
/// The system is very flexible and gives you granular control over how a type should be specified. The goal is to
/// make it easy to implement an externally-specified Syrup model.
///
/// You can specify a value of `Format` in the `options` argument of `write`, or customize an existing struct with a `spec.Struct` declaration.
pub const Format = union(enum) {
    /// Format specification for strings and primitives.
    pub const Simple = enum {
        /// Write as a string.
        string,
        /// Write as a symbol.
        symbol,
        /// Write as data.
        data,
    };

    /// Format specification for a dictionary type.
    pub const Dictionary = struct {
        /// The format of the dictionary keys.
        keys: ?Simple = null,
        /// The format of the dictionary values.
        values: ?Simple = null,
    };

    /// Format specification for a record type.
    pub const Record = struct {
        /// The format of the record's label.
        label: ?Simple = null,
        /// Custom name for the record (will appear as the label).
        name: ?[]const u8 = null,
    };

    /// Format specification for a struct type.
    pub const Struct = union(enum) {
        /// Format the struct as a dictionary (field names as keys, field values as values).
        dictionary: Dictionary,
        /// Format the struct as a Record and a set of values (no field names).
        record: Record,
        /// Format the struct as a sequence of field values.
        sequence,
        /// Format the struct as a sequence starting with a label and followed by the field values.
        labeled_sequence: Record,
    };

    /// Format specification for an enum type.
    pub const Enum = struct {
        // TODO: we may want to support writing the value as an int

        /// The format of the enum's value.
        value: Simple = .symbol,
        /// Whether or not to prefix the value with a type name ("EnumType.foo" instead of "foo")
        namespaced: bool = false,
    };

    /// Format specification for a union type.
    ///
    /// For the below examples, assume the following Zig structure:
    /// ```zig
    /// const Union = union(enum) {
    ///      string: []const u8,
    ///      inner_record: InnerRecord,
    /// };
    ///
    /// const InnerRecord = struct {
    ///     // Tell Syrup to write this struct as a record.
    ///     pub const syrup_spec = spec.Struct{
    ///        .format = .{ .record = .{} },
    ///     }
    ///
    ///     a: []const u8,
    ///     b: []const u8,
    /// };
    ///
    /// const foo: Union = .{ .string = "this is a string" };
    /// const bar: Union = .{ .inner_record = .{ .a = "is a", .b = "record with 2 string fields" }};
    /// ```
    pub const Union = union(enum) {
        /// Format as a single-item Dictionary with the key being the union's active field name
        /// and the value being the child value.
        ///
        /// Examples:
        /// - ```{`string`: "this is a string"}```
        /// - ```{`inner_record`: <`Namespace.InnerRecord` "is a" "record with 2 string fields">}```
        dictionary: Simple,
        /// Format as a single-item Record with the label being the union's active field name
        /// with specified `Simple` type of string and the record's only entry being the child value.
        /// Children that are Records become a full record inside this parent record. This could be
        /// undesirable in some cases--use `Union.record_merge` for such cases.
        ///
        /// Examples:
        /// - ```<`string` "this is a string">```
        /// - ```<`inner_record` <`Namespace.InnerRecord` "is a" "record with 2 string fields">>```
        record: Simple,
        /// Same as `Union.record` for all child types *except* record. Child records replace the
        /// parent (union)'s record, i.e., they are written instead of the union record.
        ///
        /// Examples:
        /// - ```<`string` "this is a string">```
        /// - ```<`Namespace.InnerRecord` "is a" "record with 2 string fields">```
        record_merge: Simple,
        /// Format as the value directly, without the field name of the union included.
        /// this is useful for unions where each field is a unique type and the types are Records,
        /// or if you don't need to know the active field type and want to avoid nesting.
        ///
        /// Examples:
        /// - ```"this is a string"```
        /// - ```<`inner_record` "is a" "record with 2 string fields">```
        direct_value,
    };

    /// We are formatting a sequence.
    sequence,
    /// We are formatting a simple object like a string or primitive
    simple: ?Simple,
    /// We are formatting a dictionary.
    dictionary: Dictionary,
    /// We are formatting a set.
    set: ?Simple,
    /// We are formatting a struct.
    @"struct": Struct,
    /// We are formatting an enum.
    @"enum": Enum,
    /// We are formatting a union.
    @"union": Union,
};

/// Custom specifications for the format of structs and unions.
///
/// Declare a `syrup_spec` constant with these types inside a Struct or Union you wish
/// to customize.
pub const spec = struct {
    /// Custom wire format of a struct and its fields.
    ///
    /// Declare a constant named `syrup_spec` with this type inside a struct to customize it.
    ///
    /// Example:
    /// ```
    /// const Struct = struct {
    ///     pub const syrup_spec = spec.Struct {
    ///         .format = .{ .record = .{ .name = "op:deliver" },
    ///     };
    ///
    ///     ...
    /// }
    /// ```
    pub const Struct = struct {
        /// The `Format.Struct` to use for this struct.
        format: Format.Struct = .{ .dictionary = .{} },
        /// The list of `Format` settings for each field, in order. Count must match the field count.
        fields: ?[]const ?Format = null,
    };

    /// Custom wire format of a union and its fields.
    ///
    /// Declare a constant named `syrup_spec` with this type inside a struct to customize it.
    ///
    /// Example:
    /// ```
    /// const Foo = union(enum) {
    ///     pub const syrup_spec = spec.Union{
    ///         .format = .{ .record_merge = .string },
    ///     };
    ///
    ///     ...
    /// }
    /// ```
    pub const Union = struct {
        format: Format.Union = .{ .dictionary = .symbol },
        /// The list of `Format` settings for each field, in order. Count must match the field count.
        fields: ?[]const ?Format = null,
    };
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
        pub const syrup_spec = spec.Struct{
            .format = .sequence,
        };

        lat: f64,
        lon: f64,
    };

    pub const syrup_spec = spec.Struct{
        .format = .{ .record = .{ .label = .string } },
        .fields = &[_]?Format{
            .{ .simple = .string },
            .{ .simple = .symbol },
            null,
            null,
            .{ .simple = .data },
            .sequence,
            null,
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
    pub const syrup_spec = spec.Struct{
        .format = .{
            .record = .{
                .name = "zoo",
                .label = .data,
            },
        },
    };

    const Animal = struct {
        pub const syrup_spec = spec.Struct{
            .format = .{ .dictionary = .{ .keys = .symbol } },
            .fields = &[_]?Format{
                .{ .simple = .data },
                .{ .simple = .string },
                null,
                null,
                null,
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

    const menagerie = try std.zon.parse.fromSliceAlloc(Zoo, std.testing.allocator, zoo_zon, null, .{});
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

const SpecialDate = struct {
    pub fn syrupify(self: SpecialDate, writer: *Writer) !void {
        var buf: [64]u8 = undefined;
        try writer.writeString(try std.fmt.bufPrint(&buf, "{}:{}:{}", .{ self.hours, self.minutes, self.seconds }));
    }

    hours: usize,
    minutes: usize,
    seconds: usize,
};

test "struct with syrupify" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();
    try writer.write(SpecialDate{
        .hours = 23,
        .minutes = 35,
        .seconds = 59,
    }, .{});
    try std.testing.expectEqualStrings("8\"23:35:59", output.written());
}

test "union .. why not test ourselves" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.initJSyrup(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();
    try writer.write(spec.Struct{
        .format = .{ .dictionary = .{ .keys = .symbol } },
        .fields = &[_]?Format{
            .{ .simple = .data },
            .{ .simple = .string },
            null,
            null,
            null,
            .{ .set = .data },
        },
    }, .{
        .format = .{
            .@"struct" = .{ .record = .{ .label = .string, .name = "MyFunRecord" } },
        },
    });
    try std.testing.expectEqualStrings("<\"MyFunRecord\" {`dictionary`: {`keys`: `symbol`, `values`: false}}, [{`simple`: `data`}, {`simple`: `string`}, false, false, false, {`set`: `data`}]>", output.written());
}

// Is there a way to use unit tests to test for a compile error??? probably not?
// This should fail to compile.
// const BadUnion = union(enum) {
//     const Inner = struct {
//         pub const syrup_spec = spec.Struct{
//             .format = .{ .record = .{ .label = .string } },
//         };
//
//         foo: bool,
//     };
//
//     a: Inner,
//     b: Inner,
// };
//
// test "record_merge invalid union with multiple of same type" {
//     var output = std.Io.Writer.Allocating.init(std.testing.allocator);
//     var writer = Writer.initJSyrup(&output.writer, std.testing.allocator);
//     defer output.deinit();
//     defer writer.deinit();
//     try writer.write(BadUnion{ .a = .{ .foo = false } }, .{ .format = .{ .@"union" = .{ .record_merge = .string } } });
// }

// Roll your own ocapn (just a toy set of a couple ocapn models, nothing fancy)

const Desc = struct {
    fn PosObject(name: []const u8) type {
        return struct {
            pub const syrup_spec = spec.Struct{
                .format = .{ .record = .{ .name = name } },
            };

            position: u64,
        };
    }

    const ImportObject = PosObject("desc:import-object");
    const ImportPromise = PosObject("desc:import-promise");
    const Export = PosObject("desc:export");
    const Answer = PosObject("desc:answer");

    const ImportObjectOrPromise = union(enum) {
        pub const syrup_spec = spec.Union{
            .format = .{ .record_merge = .string },
        };

        object: ImportObject,
        promise: ImportPromise,
    };
};

const Op = struct {
    const Deliver = struct {
        pub const syrup_spec = spec.Struct{
            .format = .{ .record = .{ .name = "op:deliver" } },
        };

        to_desc: Desc.Export,
        args: []const dynamic.Value,
        answer_pos: ?u64 = null,
        @"resolve-me-desc": ?Desc.ImportObjectOrPromise = null,
    };
};

test "roll your own ocapn" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.initJSyrup(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();
    try writer.write(Op.Deliver{ .to_desc = .{ .position = 5 }, .args = &[_]dynamic.Value{.{ .symbol = "make-car-factory" }}, .answer_pos = 3, .@"resolve-me-desc" = .{ .promise = .{ .position = 45 } } }, .{});
    try std.testing.expectEqualStrings("<`op:deliver` <`desc:export` 5>, [`make-car-factory`], 3, <`desc:import-promise` 45>>", output.written());
}

const FancyUnion = union(enum) {
    pub const syrup_spec = spec.Union{
        .fields = &[_]?Format{
            .{ .simple = .string },
            .{ .simple = .symbol },
            .{ .simple = .data },
        },
    };

    a: []const u8,
    b: []const u8,
    c: []const u8,
};

test "union with custom formatted field" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.initJSyrup(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();
    try writer.write(&[_]FancyUnion{
        .{ .a = "hello" },
        .{ .b = "there" },
        .{ .c = "general" },
    }, .{});
    try std.testing.expectEqualStrings("[{`a`: \"hello\"}, {`b`: `there`}, {`c`: |m5sw4zlsmfwa|}]", output.written());
}

const SequenceStruct = struct {
    party_time: bool,
    num_friends: u64,
};

test "struct with labeled sequence" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();
    try writer.write(
        SequenceStruct{ .party_time = true, .num_friends = 45 },
        .{
            .format = .{
                .@"struct" = .{ .labeled_sequence = .{ .name = "fun-sequence", .label = .symbol } },
            },
        },
    );
    try std.testing.expectEqualStrings("[12'fun-sequencet45+]", output.written());
}
