//! A writer for the Syrup data format. Can write all of the supported Syrup datatypes to an underlying
//! `std.Io.Writer`.

const std = @import("std");
const Generic = @import("generics.zig").Generic;
const Record = @import("Record.zig");
const tags = @import("tags.zig");

const print = std.debug.print;

const Writer = @This();

pub const WriterError = error{
    /// Tried to end a record but we are not inside any records.
    RecordUnderflow,
    /// Tried to end a sequence but we are not inside any sequences.
    SequenceUnderflow,
    /// Tried to end a dictionary but we are not inside any dictionaries.
    DictionaryUnderflow,
    /// Tried to end a set but we are not inside any sets.
    SetUnderflow,
};

const WritingError = WriterError || std.Io.Writer.Error || std.mem.Allocator.Error;

/// Structure to store the indices of the key and the value of a Dictionary
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

const NestedType = enum {
    sequence,
    record,
    dictionary,
    set,
};

const NestedData = union(NestedType) {
    sequence: void,
    record: void,
    dictionary: DictData,
    set: DictData,

    pub fn deinit(self: *NestedData, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .dictionary, .set => |*value| value.deinit(gpa),
            else => {},
        }
    }
};

/// The underlying `std.Io.Writer`.
underlying_writer: *std.Io.Writer,
/// Allocator to use for the temporary memory
gpa: std.mem.Allocator,
/// A writer with an allocated buffer used for serializing dictionaries and sets, which need to be sorted after serializing the keys and values.
tmp_writer: std.Io.Writer.Allocating,
/// A stack that stores NestedDatas to keep track of what types of items we are inside, and data for some of these types.
nested_datas: std.ArrayList(NestedData) = .empty,
/// True if we are currently inside a set or dictionary
dict_or_set_depth: usize = 0,

/// Initialize a `Writer`.
pub fn init(underlying_writer: *std.Io.Writer, gpa: std.mem.Allocator) Writer {
    return .{
        .underlying_writer = underlying_writer,
        .gpa = gpa,
        .tmp_writer = std.Io.Writer.Allocating.init(gpa),
    };
}

/// Deinitialize a `Writer`.
pub fn deinit(self: *Writer) void {
    self.tmp_writer.deinit();
    self.nested_datas.deinit(self.gpa);
}

inline fn curWriter(self: *Writer) *std.Io.Writer {
    return if (self.dict_or_set_depth > 0) &self.tmp_writer.writer else self.underlying_writer;
}

/// Write a supported type to the writer.
pub fn write(self: *Writer, val: anytype) !void {
    const ValType = @TypeOf(val);
    const ValInfo = @typeInfo(ValType);

    try switch (ValType) {
        Generic => self.writeGeneric(val),
        *const Generic => self.writeGeneric(val),
        Record => self.writeRecord(val),
        *const Record => self.writeRecord(val),
        bool => self.writeBoolean(val),
        f32 => self.writeFloat(val),
        f64 => self.writeDouble(val),
        comptime_float => self.writeDouble(@as(f64, val)),
        *const []Generic => self.writeSequence(val),
        *const []u8 => @compileError("use one of writeString, writeData, writeSymbol when writing bytes, or wrap it in a Generic to specify its type."),
        else => switch (ValInfo) {
            .int => self.writeInt(val),
            .comptime_int => self.writeInt(val),
            .pointer => |ptr| switch (ptr.size) {
                .one => {
                    const child_info = @typeInfo(ptr.child);
                    return switch (child_info) {
                        .array => switch (child_info.array.child) {
                            u8 => @compileError("use one of writeString, writeData, writeSymbol when writing bytes, or wrap it in a Generic to specify its type."),
                            Generic => self.writeSequence(val),
                            else => @compileError("unsupported pointer type " ++ @typeName(ValType)),
                        },
                        else => @compileError("unsupported pointer type " ++ @typeName(ValType)),
                    };
                },
                else => @compileError("unsupported pointer type " ++ @typeName(ValType)),
            },
            else => @compileError("unsupported type! " ++ @typeName(ValType)),
        },
    };
}

/// Write a `Generic` to the writer.
pub fn writeGeneric(self: *Writer, gen: *const Generic) !void {
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

/// Write a boolean value to the writer.
pub fn writeBoolean(self: *Writer, val: bool) !void {
    try self.startWrite();
    if (val) {
        try self.curWriter().writeByte(tags.True);
    } else {
        try self.curWriter().writeByte(tags.False);
    }
}

/// Write an integer value of any width to the writer.
pub fn writeInt(self: *Writer, val: anytype) !void {
    const ValType = @TypeOf(val);
    const ValInfo = @typeInfo(ValType);
    switch (ValInfo) {
        .int => {},
        .comptime_int => {},
        else => @compileError("writeInt must be called with integer type."),
    }

    try self.startWrite();
    if (val >= 0) {
        try self.curWriter().printInt(val, 10, .lower, .{});
        try self.curWriter().writeByte(tags.PositiveInt);
    } else {
        try self.curWriter().printInt(-val, 10, .lower, .{});
        try self.curWriter().writeByte(tags.NegativeInt);
    }
}

/// Write a f32 float to the writer.
pub fn writeFloat(self: *Writer, val: f32) !void {
    try self.startWrite();
    try self.curWriter().writeByte(tags.Float);
    try self.curWriter().writeAll(&std.mem.toBytes(std.mem.nativeToBig(u32, @bitCast(val))));
}

/// Write a f64 float to the writer.
pub fn writeDouble(self: *Writer, val: f64) !void {
    try self.startWrite();
    try self.curWriter().writeByte(tags.Double);
    try self.curWriter().writeAll(&std.mem.toBytes(std.mem.nativeToBig(u64, @bitCast(val))));
}

/// Write a byte slice to the writer as data.
pub fn writeData(self: *Writer, val: []const u8) !void {
    try self.writeDataInternal(val, tags.Data);
}

/// Write a byte slice to the writer as a string.
pub fn writeString(self: *Writer, val: []const u8) !void {
    try self.writeDataInternal(val, tags.String);
}

/// Write a byte slice to the writer as a symbol.
pub fn writeSymbol(self: *Writer, val: []const u8) !void {
    try self.writeDataInternal(val, tags.Symbol);
}

fn writeDataInternal(self: *Writer, val: []const u8, sep: u8) !void {
    try self.startWrite();
    try self.curWriter().printInt(val.len, 10, .lower, .{});
    try self.curWriter().writeByte(sep);
    try self.curWriter().writeAll(val);
}

/// Begin writing a Sequence of data. The Sequence will be populated with subsequent writes.
/// Call `writeEndSequence` to finish the Sequence.
pub fn writeStartSequence(self: *Writer) !void {
    try self.startWrite();
    try self.curWriter().writeByte(tags.StartSequence);
    try self.nested_datas.append(self.gpa, .sequence);
}

/// Return the provided error if the expected nested item isn't the current parent.
fn ensureProperNesting(self: *Writer, nested_type: NestedType, err: WriterError) !void {
    const data = self.nested_datas.pop() orelse return err;
    if (data != nested_type) {
        return err;
    }
}

/// Finish writing a Sequence. Throws `SequenceUnderflow` if we aren't in any sequences.
pub fn writeEndSequence(self: *Writer) !void {
    try self.ensureProperNesting(.sequence, error.SequenceUnderflow);
    try self.curWriter().writeByte(tags.EndSequence);
}

/// Write a full Sequence of data given a list of `Generic`.
pub fn writeSequence(self: *Writer, val: []const Generic) WritingError!void {
    try self.writeStartSequence();
    for (val) |gen| {
        try self.writeGeneric(&gen);
    }
    try self.writeEndSequence();
}

/// Begin writing a Record of data given a label. The Record will be populated with subsequent writes.
/// Call `writeEndRecord` to finish the Record.
pub fn writeStartRecord(self: *Writer, label: *const Generic) !void {
    try self.startWrite();
    try self.curWriter().writeByte(tags.StartRecord);
    try self.nested_datas.append(self.gpa, .record);
    try self.writeGeneric(label);
}

/// Finish writing a Record. Throws `RecordUnderflow` if we aren't in any records.
pub fn writeEndRecord(self: *Writer) !void {
    try self.ensureProperNesting(.record, error.RecordUnderflow);
    try self.curWriter().writeByte(tags.EndRecord);
}

/// Write a full Record.
pub fn writeRecord(self: *Writer, val: *const Record) WritingError!void {
    try self.writeStartRecord(val.label);
    for (val.fields) |field| {
        try self.writeGeneric(&field);
    }
    try self.writeEndRecord();
}

fn tmpWrittenLen(self: *Writer) usize {
    return self.tmp_writer.written().len;
}

/// Begin writing a Dictionary of data. `tmp_writer` will be filled with subsequent writes of
/// (alternately) keys and values, until the dictionary is complete.
/// Call `writeEndDictionary` to finish the Dictionary.
fn writeStartDictionary(self: *Writer) !void {
    try self.startWrite();
    try self.curWriter().writeByte(tags.StartDictionary);
    self.dict_or_set_depth += 1;
    try self.nested_datas.append(self.gpa, .{ .dictionary = .{ .start_index = self.tmpWrittenLen() } });
}

fn cmpIndices(buf: []const u8, a: KeyValueIndices, b: KeyValueIndices) bool {
    const a_slice = buf[a.key..a.value];
    const b_slice = buf[b.key..b.value];
    return std.mem.order(u8, a_slice, b_slice) == .lt;
}

fn sortIndices(self: *Writer, dict_data: *DictData) void {
    std.mem.sort(KeyValueIndices, dict_data.indices.items, self.tmp_writer.written(), cmpIndices);
}

/// Finish writing a Dictionary. Throws `DictionaryUnderflow` if we aren't in any dictionaries.
/// This sorts entries by key and then (unless we are still inside an outer Dictionary or Set) performs
/// the actual flush of keys and values to the underlying writer, as previous calls will have
/// only populated `tmp_writer` with items.
fn writeEndDictionary(self: *Writer) !void {
    var nested_data = self.nested_datas.pop() orelse return error.DictionaryUnderflow;
    if (@as(NestedType, nested_data) != .dictionary) {
        return error.DictionaryUnderflow;
    }
    defer nested_data.deinit(self.gpa);

    if (nested_data.dictionary.indices.items.len > 0) {
        var last = &nested_data.dictionary.indices.items[nested_data.dictionary.indices.items.len - 1];
        last.end = self.tmpWrittenLen();
    }

    // We can now sort the indices by their buffer order!
    self.sortIndices(&nested_data.dictionary);

    // Ensure we can fit a copy of the data after the current data.
    const start_i = nested_data.dictionary.start_index;
    const end_i = self.tmpWrittenLen();
    const collection_len = end_i - start_i;
    try self.tmp_writer.ensureUnusedCapacity(collection_len);

    const tmp_buffer = self.tmp_writer.writer.buffer;
    for (nested_data.dictionary.indices.items) |item| {
        // Because we ensured capacity above, this will never realloc, so the buffer won't invalidate.
        // Ideally there'd be a way to write while ensuring no reallocs, but that's asking too much
        // of Allocating.Writer.
        try self.tmp_writer.writer.writeAll(tmp_buffer[item.key..item.end]);
    }

    // Copy from the now-ordered portion back to the final position.
    @memcpy(tmp_buffer[start_i..end_i], tmp_buffer[collection_len + start_i .. collection_len + end_i]);

    // Rewind the buffer now that we've copied back to the original position.
    self.tmp_writer.shrinkRetainingCapacity(end_i);

    try self.maybeFlushBuffer();
    self.dict_or_set_depth -= 1;
    try self.curWriter().writeByte(tags.EndDictionary);
}

pub fn writeDictionary(self: *Writer, val: []const Generic) WritingError!void {
    try self.writeStartDictionary();
    for (val) |gen| {
        try self.writeGeneric(&gen);
    }
    try self.writeEndDictionary();
}

/// Begin writing a Set of data. `tmp_writer` will be filled with subsequent writes of
/// keys, until the set is complete.
/// Call `writeEndSet` to finish the Set.
fn writeStartSet(self: *Writer) !void {
    try self.startWrite();
    try self.curWriter().writeByte(tags.StartSet);
    self.dict_or_set_depth += 1;
    try self.nested_datas.append(self.gpa, .{ .set = .{ .start_index = self.tmpWrittenLen() } });
}

/// Finish writing a Set. Throws `SetUnderflow` if we aren't in any sets.
/// This sorts entries and then (unless we are still inside an outer Dictionary or Set) performs
/// the actual flush of keys to the underlying writer, as previous calls will have
/// only populated `tmp_writer` with items.
fn writeEndSet(self: *Writer) !void {
    var nested_data = self.nested_datas.pop() orelse return error.DictionaryUnderflow;
    if (@as(NestedType, nested_data) != .dictionary) {
        return error.DictionaryUnderflow;
    }

    defer nested_data.deinit(self.gpa);

    try self.maybeFlushBuffer();
    self.dict_or_set_depth -= 1;
    try self.curWriter().writeByte(tags.EndSet);
}

pub fn writeSet(self: *Writer, val: []const Generic) WritingError!void {
    try self.writeStartSet();
    for (val) |gen| {
        try self.writeGeneric(&gen);
    }
    try self.writeEndSet();
}

/// Start a write operation. We record index positions if we are in a Dictionary or Set.
fn startWrite(self: *Writer) !void {
    if (self.nested_datas.items.len <= 0) {
        return;
    }

    const last_nested_data = &self.nested_datas.items[self.nested_datas.items.len - 1];
    switch (last_nested_data.*) {
        .dictionary => |*dict_data| {
            if (dict_data.indices.items.len > 0) {
                var cur = &dict_data.indices.items[dict_data.indices.items.len - 1];
                if (cur.value == 0) {
                    // Value index is still zero, so we are writing the value now.
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
            }

            try dict_data.indices.append(self.gpa, .{ .key = self.tmpWrittenLen() });
        },
        else => {},
    }
}

/// If we are no longer inside any dictionaries or sets, flush the temp buffer to the Io.Writer and clear the buffer.
fn maybeFlushBuffer(self: *Writer) !void {
    if (self.tmpWrittenLen() > 0) {
        try self.underlying_writer.writeAll(self.tmp_writer.written());
        self.tmp_writer.clearRetainingCapacity();
    }
}

/// For testing: Double check we cleared all nested datas.
fn expectRootLevel(self: *Writer) !void {
    try std.testing.expectEqual(0, self.nested_datas.items.len);
}

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
    try writer.expectRootLevel();
}

test "float datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.write(14.4);
    try writer.write(@as(f32, 58.365));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 68, 64, 44, 204, 204, 204, 204, 204, 205, 70, 66, 105, 117, 195 }, output.written());
    try writer.expectRootLevel();
}

test "string datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.writeString("i love you, christine 😍");
    try writer.writeString("björn");

    try std.testing.expectEqualStrings("26\"i love you, christine 😍6\"björn", output.written());
    try writer.expectRootLevel();
}

test "data datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.writeData(&[_]u8{ 69, 68, 67, 66, 65 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 53, 58, 69, 68, 67, 66, 65 }, output.written());
    try writer.expectRootLevel();
}

test "symbol datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    try writer.writeSymbol("hämta");
    try std.testing.expectEqualStrings("6'hämta", output.written());
    try writer.expectRootLevel();
}

test "sequence datatype" {
    const sequence = [_]Generic{
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
    try writer.expectRootLevel();
}

test "record datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    const record = Record{
        .label = &.{
            .sequence = &[_]Generic{
                .{ .string = "hello" },
                .{ .int = .{ .i32 = 2456 } },
            },
        },
        .fields = &[_]Generic{
            .true,
            .false,
            .{ .symbol = "dogs-and-cats" },
        },
    };

    try writer.write(&record);
    try std.testing.expectEqualStrings("<[5\"hello2456+]tf13'dogs-and-cats>", output.written());
    try writer.expectRootLevel();
}

test "simple dictionary datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    const dict = [_]Generic{
        .{ .string = "key2" },
        .{ .int = .{ .i32 = 45 } },
        .{ .string = "key1" },
        .{ .int = .{ .i32 = 42 } },
        .{ .string = "key8" },
        .{ .int = .{ .i32 = 2 } },
        .{ .string = "key3" },
        .{ .int = .{ .i32 = 4 } },
    };

    try writer.writeDictionary(&dict);
    try std.testing.expectEqualStrings("{4\"key142+4\"key245+4\"key34+4\"key82+}", output.written());
    try writer.expectRootLevel();
}

test "nested dictionary datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer.init(&output.writer, std.testing.allocator);
    defer output.deinit();
    defer writer.deinit();

    // Dictionary which has *nested* dictionaries as a key (gross, but allowed)
    // and a dictionary as a value for fun as well.
    const dict = [_]Generic{
        .{ .string = "key2" },
        .{ .int = .{ .i32 = 45 } },
        .{ .string = "key1" },
        .{ .int = .{ .i32 = 42 } },
        .{ .string = "key8" },
        .{ .int = .{ .i32 = 2 } },
        .{ .string = "key3" },
        .{ .int = .{ .i32 = 4 } },
    };

    try writer.writeDictionary(&dict);
    try std.testing.expectEqualStrings("{4\"key142+4\"key245+4\"key34+4\"key82+}", output.written());

    try writer.expectRootLevel();
}
