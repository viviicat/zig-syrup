//! A writer for the Syrup data format. Can write all of the supported Syrup datatypes to an underlying
//! `std.Io.Writer`.

const std = @import("std");
const Generic = @import("generics.zig").Generic;
const Record = @import("Record.zig");
const tags = @import("tags.zig");

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

const WritingError = WriterError || std.Io.Writer.Error;

/// A structure for storing index data for a key and a value in a Dictionary (or Set)
const KeyValueData = struct {
    /// The index in the temporary buffer of the key
    key_index: usize,
    /// The index in the temporary buffer of the value (unused for Sets)
    value_index: usize = 0,
    /// The length of all data for the entry including key and value.
    len: usize = 0,
};

/// A structure for storing temporary data related to dictionary and set serialization.
const DictData = struct {
    const ItemType = enum {
        key,
        value,
    };

    key_values: std.ArrayList(KeyValueData) = .empty,
    cur_type: ItemType = .key,

    pub fn calculateLastLength(self: *DictData, buf_index: usize) void {
        if (self.key_values.items.len > 0) {
            var prev = &self.key_values.items[self.key_values.items.len - 1];
            prev.len = buf_index - prev.key_index;
        }
    }

    pub fn deinit(self: *DictData, gpa: std.Allocator) void {
        self.key_values.deinit(gpa);
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

    pub fn deinit(self: *NestedData) void {
        switch (self) {
            NestedType.dictionary, NestedType.set => |*value| value.deinit(),
            else => {},
        }
    }
};

/// The underlying `std.Io.Writer`.
io_writer: *std.Io.Writer,
/// Allocator to use for the temporary memory
gpa: std.mem.Allocator,
/// A buffer used for serializing dictionaries and sets, which need to be sorted after serializing the keys and values.
tmp_buf: std.ArrayList(u8) = .empty,
/// A stack that stores NestedDatas to keep track of what types of items we are inside, and data for some of these types.
nested_datas: std.ArrayList(NestedData) = .empty,
/// True if we are currently inside a set or dictionary
inside_dict_or_set: bool = false,

inline fn cur_writer(self: *Writer) *std.Io.Writer {
    if (self.inside_dict_or_set) {
        // noooo good
        var writer = std.Io.Writer.Allocating.fromArrayList(self.gpa, &self.tmp_buf);
        return writer.writer;
    } else {
        return self.io_writer;
    }
}

/// Deinitialize the `Writer`.
pub fn deinit(self: *Writer) void {
    self.tmp_buf.deinit(self.gpa);
    self.nested_datas.deinit(self.gpa);
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
    };
}

/// Write a boolean value to the writer.
pub fn writeBoolean(self: *Writer, val: bool) !void {
    try self.startWrite();
    if (val) {
        try self.cur_writer().writeByte(tags.True);
    } else {
        try self.cur_writer().writeByte(tags.False);
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
        try self.cur_writer().printInt(val, 10, .lower, .{});
        try self.cur_writer().writeByte(tags.PositiveInt);
    } else {
        try self.cur_writer().printInt(-val, 10, .lower, .{});
        try self.cur_writer().writeByte(tags.NegativeInt);
    }
}

/// Write a f32 float to the writer.
pub fn writeFloat(self: *Writer, val: f32) !void {
    try self.startWrite();
    try self.cur_writer().writeByte(tags.Float);
    try self.cur_writer().writeAll(&std.mem.toBytes(std.mem.nativeToBig(u32, @bitCast(val))));
}

/// Write a f64 float to the writer.
pub fn writeDouble(self: *Writer, val: f64) !void {
    try self.startWrite();
    try self.cur_writer().writeByte(tags.Double);
    try self.cur_writer().writeAll(&std.mem.toBytes(std.mem.nativeToBig(u64, @bitCast(val))));
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
    try self.cur_writer().printInt(val.len, 10, .lower, .{});
    try self.cur_writer().writeByte(sep);
    try self.cur_writer().writeAll(val);
}

/// Begin writing a Sequence of data. The Sequence will be populated with subsequent writes.
/// Call `writeEndSequence` to finish the Sequence.
pub fn writeStartSequence(self: *Writer) !void {
    try self.startWrite();
    try self.cur_writer().writeByte(tags.StartSequence);
    try self.nested_datas.append(self.gpa, .sequence);
}

/// Finish writing a Sequence. Throws `SequenceUnderflow` if we aren't in any sequences.
pub fn writeEndSequence(self: *Writer) !void {
    if (self.nested_datas.pop() != .sequence) {
        return error.SequenceUnderflow;
    }
    try self.cur_writer().writeByte(tags.EndSequence);
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
    try self.cur_writer().writeByte(tags.StartRecord);
    self.nested_datas.append(self.gpa, .record);
    try self.writeGeneric(label);
}

/// Finish writing a Record. Throws `RecordUnderflow` if we aren't in any records.
pub fn writeEndRecord(self: *Writer) !void {
    if (self.nested_datas.pop() != .record) {
        return error.RecordUnderflow;
    }
    try self.cur_writer().writeByte(tags.EndRecord);
}

/// Write a full Record.
pub fn writeRecord(self: *Writer, val: *const Record) WritingError!void {
    try self.writeStartRecord(val.label);
    for (val.fields) |field| {
        try self.writeGeneric(&field);
    }
    try self.writeEndRecord();
}

/// Begin writing a Dictionary of data. `tmp_buf` will be filled with subsequent writes of
/// (alternately) keys and values, until the dictionary is complete.
/// Call `writeEndDictionary` to finish the Dictionary.
fn writeStartDictionary(self: *Writer) !void {
    try self.startWrite();
    try self.cur_writer().writeByte(tags.StartDictionary);
    try self.nested_datas.append(self.gpa, .{ .dictionary = .{} });
}

/// Finish writing a Dictionary. Throws `DictionaryUnderflow` if we aren't in any dictionaries.
/// This sorts entries by key and then (unless we are still inside an outer Dictionary or Set) performs
/// the actual flush of keys and values to the underlying writer, as previous calls will have
/// only populated `tmp_buf` with items.
fn writeEndDictionary(self: *Writer) !void {
    const nested_data = if (self.nested_datas.pop()) |item| item else error.DictionaryUnderflow;
    var dict_data = if (nested_data == .dictionary) |item| item else error.DictionaryUnderflow;
    defer dict_data.deinit();

    dict_data.calculateLastLength(self.tmp_buf.items.len);

    // Sort the entries which dict_data is aware of

    try self.maybeFlushBuffer();
    try self.cur_writer().writeByte(tags.EndDictionary);
}

/// Begin writing a Set of data. `tmp_buf` will be filled with subsequent writes of
/// keys, until the set is complete.
/// Call `writeEndSet` to finish the Set.
fn writeStartSet(self: *Writer) !void {
    try self.startWrite();
    try self.cur_writer().writeByte(tags.StartSet);
    try self.nested_datas.append(self.gpa, .{ .set = .{} });
}

/// Finish writing a Set. Throws `SetUnderflow` if we aren't in any sets.
/// This sorts entries and then (unless we are still inside an outer Dictionary or Set) performs
/// the actual flush of keys to the underlying writer, as previous calls will have
/// only populated `tmp_buf` with items.
fn writeEndSet(self: *Writer) !void {
    const nested_data = if (self.nested_datas.pop()) |item| item else error.SetUnderflow;
    var dict_data = if (nested_data == .set) |*item| item else error.SetUnderflow;
    defer dict_data.deinit();

    dict_data.calculateLastLength(self.tmp_buf.items.len);

    try self.maybeFlushBuffer();
    try self.cur_writer().writeByte(tags.EndSet);
}

/// Start a write operation. We record index positions if we are in a Dictionary or Set.
fn startWrite(self: *Writer) !void {
    if (self.nested_datas.items.len <= 0) {
        return;
    }

    var last = &self.nested_datas.items[self.nested_datas.items.len - 1];
    switch (last.*) {
        .dictionary => |*dict_data| {
            if (dict_data.cur_type == .key) {
                dict_data.calculateLastLength(self.tmp_buf.items.len);
                try dict_data.key_values.append(self.gpa, .{ .key_index = self.tmp_buf.items.len });
                dict_data.cur_type = .value;
            } else {
                var item = &dict_data.key_values.items[dict_data.key_values.items.len - 1];
                item.value_index = self.tmp_buf.items.len;
                dict_data.cur_type = .key;
            }
        },
        .set => |*dict_data| {
            dict_data.calculateLastLength(self.tmp_buf.items.len);
            try dict_data.key_values.append(self.gpa, .{ .key_index = self.tmp_buf.items.len });
        },
        else => {},
    }
}

/// If we are no longer inside any dictionaries or sets, flush the temp buffer to the Io.Writer and clear the buffer.
fn maybeFlushBuffer(self: *Writer) !void {
    if (self.dictionary_depth <= 0 and self.set_depth <= 0) {
        self.io_writer.writeAll(self.tmp_buf.items);
        self.tmp_buf.clearRetainingCapacity();
    }
}

/// For testing: Double check we cleared all nested datas.
fn expectRootLevel(self: *Writer) !void {
    try std.testing.expectEqual(0, self.nested_datas.items.len);
}

test "basic datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer{ .io_writer = &output.writer, .gpa = std.testing.allocator };
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
    var writer = Writer{ .io_writer = &output.writer, .gpa = std.testing.allocator };
    defer output.deinit();
    defer writer.deinit();

    try writer.write(14.4);
    try writer.write(@as(f32, 58.365));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 68, 64, 44, 204, 204, 204, 204, 204, 205, 70, 66, 105, 117, 195 }, output.written());
    try writer.expectRootLevel();
}

test "string datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer{ .io_writer = &output.writer, .gpa = std.testing.allocator };
    defer output.deinit();
    defer writer.deinit();

    try writer.writeString("i love you, christine 😍");
    try writer.writeString("björn");

    try std.testing.expectEqualStrings("26\"i love you, christine 😍6\"björn", output.written());
    try writer.expectRootLevel();
}

test "data datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer{ .io_writer = &output.writer, .gpa = std.testing.allocator };
    defer output.deinit();
    defer writer.deinit();

    try writer.writeData(&[_]u8{ 69, 68, 67, 66, 65 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 53, 58, 69, 68, 67, 66, 65 }, output.written());
    try writer.expectRootLevel();
}

test "symbol datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer{ .io_writer = &output.writer, .gpa = std.testing.allocator };
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
    var writer = Writer{ .io_writer = &output.writer, .gpa = std.testing.allocator };
    defer output.deinit();
    defer writer.deinit();

    try writer.write(&sequence);
    try std.testing.expectEqualStrings("[6\"a test45+5'shark[170141183460469231731687303715884105690-15\"testing nesting]]", output.written());
    try writer.expectRootLevel();
}

test "record datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer{ .io_writer = &output.writer, .gpa = std.testing.allocator };
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
    var writer = Writer{ .io_writer = &output.writer, .gpa = std.testing.allocator };
    defer output.deinit();
    defer writer.deinit();

    try writer.expectRootLevel();
}

test "nested dictionary datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer{ .io_writer = &output.writer, .gpa = std.testing.allocator };
    defer output.deinit();
    defer writer.deinit();

    try writer.expectRootLevel();
}
