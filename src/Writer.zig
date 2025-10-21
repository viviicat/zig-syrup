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
};

const WritingError = WriterError || std.Io.Writer.Error;

io_writer: *std.Io.Writer,
sequence_depth: usize = 0,
record_depth: usize = 0,

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
    if (val) {
        try self.io_writer.writeByte(tags.True);
    } else {
        try self.io_writer.writeByte(tags.False);
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

    if (val >= 0) {
        try self.io_writer.printInt(val, 10, .lower, .{});
        try self.io_writer.writeByte(tags.PositiveInt);
    } else {
        try self.io_writer.printInt(-val, 10, .lower, .{});
        try self.io_writer.writeByte(tags.NegativeInt);
    }
}

/// Write a f32 float to the writer.
pub fn writeFloat(self: *Writer, val: f32) !void {
    try self.io_writer.writeByte(tags.Float);
    try self.io_writer.writeAll(&std.mem.toBytes(std.mem.nativeToBig(u32, @bitCast(val))));
}

/// Write a f64 float to the writer.
pub fn writeDouble(self: *Writer, val: f64) !void {
    try self.io_writer.writeByte(tags.Double);
    try self.io_writer.writeAll(&std.mem.toBytes(std.mem.nativeToBig(u64, @bitCast(val))));
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
    try self.io_writer.printInt(val.len, 10, .lower, .{});
    try self.io_writer.writeByte(sep);
    try self.io_writer.writeAll(val);
}

/// Begin writing a Sequence of data. The Sequence will be populated with subsequent writes.
/// Call `writeEndSequence` to finish the Sequence.
pub fn writeStartSequence(self: *Writer) !void {
    self.sequence_depth += 1;
    try self.io_writer.writeByte(tags.StartSequence);
}

/// Finish writing a Sequence. Throws `SequenceUnderflow` if we aren't in any sequences.
/// Does not verify that the current depth is writing a sequence, vs a record, so it's possible to
/// confuse it into writing invalid data.
pub fn writeEndSequence(self: *Writer) !void {
    if (self.sequence_depth == 0) {
        return error.SequenceUnderflow;
    }
    self.sequence_depth -= 0;
    try self.io_writer.writeByte(tags.EndSequence);
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
    self.record_depth += 1;
    try self.io_writer.writeByte(tags.StartRecord);
    try self.writeGeneric(label);
}

/// Finish writing a Record. Throws `RecordUnderflow` if we aren't in any records.
/// Does not verify that the current depth is writing a record, vs a sequence, so it's possible to
/// confuse it into writing invalid data.
pub fn writeEndRecord(self: *Writer) !void {
    if (self.record_depth == 0) {
        return error.RecordUnderflow;
    }
    self.record_depth -= 0;
    try self.io_writer.writeByte(tags.EndRecord);
}

/// Write a full Record.
pub fn writeRecord(self: *Writer, val: *const Record) WritingError!void {
    try self.writeStartRecord(val.label);
    for (val.fields) |field| {
        try self.writeGeneric(&field);
    }
    try self.writeEndRecord();
}

test "basic datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer{ .io_writer = &output.writer };
    defer output.deinit();

    try writer.write(false);
    try writer.write(true);
    try writer.write(502345);
    try writer.write(-42069);

    try std.testing.expectEqualStrings("ft502345+42069-", output.written());
}

test "float datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer{ .io_writer = &output.writer };
    defer output.deinit();

    try writer.write(14.4);
    try writer.write(@as(f32, 58.365));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 68, 64, 44, 204, 204, 204, 204, 204, 205, 70, 66, 105, 117, 195 }, output.written());
}

test "string datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer{ .io_writer = &output.writer };
    defer output.deinit();

    try writer.writeString("i love you, christine 😍");
    try writer.writeString("björn");

    try std.testing.expectEqualStrings("26\"i love you, christine 😍6\"björn", output.written());
}

test "data datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer{ .io_writer = &output.writer };
    defer output.deinit();

    try writer.writeData(&[_]u8{ 69, 68, 67, 66, 65 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 53, 58, 69, 68, 67, 66, 65 }, output.written());
}

test "symbol datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer{ .io_writer = &output.writer };
    defer output.deinit();

    try writer.writeSymbol("hämta");
    try std.testing.expectEqualStrings("6'hämta", output.written());
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
    var writer = Writer{ .io_writer = &output.writer };
    defer output.deinit();

    try writer.write(&sequence);
    try std.testing.expectEqualStrings("[6\"a test45+5'shark[170141183460469231731687303715884105690-15\"testing nesting]]", output.written());
}

test "record datatype" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer{ .io_writer = &output.writer };
    defer output.deinit();

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
}
