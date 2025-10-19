const std = @import("std");
const Generic = @import("generics.zig").Generic;

const Writer = @This();

io_writer: *std.Io.Writer,

pub fn write(self: Writer, val: anytype) !void {
    const ValType = @TypeOf(val);
    const ValInfo = @typeInfo(ValType);

    try switch (ValType) {
        Generic => self.writeGeneric(val),
        bool => self.writeBoolean(val),
        f32 => self.writeFloat(val),
        f64 => self.writeDouble(val),
        comptime_float => self.writeDouble(@as(f64, val)),
        else => switch (ValInfo) {
            .int => self.writeInt(val),
            .comptime_int => self.writeInt(val),
            // TODO: support sequence slices
            .pointer => @compileError("use one of writeString, writeData, writeSymbol with a byte slice."),
            else => @compileError("unsupported type!" ++ @typeName(ValType)),
        },
    };
}

pub fn writeGeneric(self: Writer, gen: Generic) !void {
    return switch (gen) {
        .bool => |val| try self.writeBoolean(val),
        .float => |val| try self.writeFloat(val),
        .double => |val| try self.writeDouble(val),
        .data => |val| try self.writeData(val),
        .string => |val| try self.writeString(val),
        .symbol => |val| try self.writeSymbol(val),
        .int => |int| switch (int) {
            .i32 => |val| try self.writeInt(val),
            .i64 => |val| try self.writeInt(val),
            .i128 => |val| try self.writeInt(val),
        },
        .sequence => |val| try self.writeSequence(val),
    };
}

pub fn writeBoolean(self: Writer, val: bool) !void {
    if (val) {
        try self.io_writer.writeByte('t');
    } else {
        try self.io_writer.writeByte('f');
    }
}

pub fn writeInt(self: Writer, val: anytype) !void {
    const ValType = @TypeOf(val);
    const ValInfo = @typeInfo(ValType);
    switch (ValInfo) {
        .int => {},
        .comptime_int => {},
        else => @compileError("writeInt must be called with integer type."),
    }

    if (val >= 0) {
        try self.io_writer.printInt(val, 10, .lower, .{});
        try self.io_writer.writeByte('+');
    } else {
        try self.io_writer.printInt(-val, 10, .lower, .{});
        try self.io_writer.writeByte('-');
    }
}

pub fn writeFloat(self: Writer, val: f32) !void {
    try self.io_writer.writeByte('F');
    try self.io_writer.writeAll(&std.mem.toBytes(std.mem.nativeToBig(u32, @bitCast(val))));
}

pub fn writeDouble(self: Writer, val: f64) !void {
    try self.io_writer.writeByte('D');
    try self.io_writer.writeAll(&std.mem.toBytes(std.mem.nativeToBig(u64, @bitCast(val))));
}

pub fn writeData(self: Writer, val: []const u8) !void {
    try self.writeDataInternal(val, ':');
}

pub fn writeString(self: Writer, val: []const u8) !void {
    try self.writeDataInternal(val, '"');
}

pub fn writeSymbol(self: Writer, val: []const u8) !void {
    try self.writeDataInternal(val, '\'');
}

fn writeDataInternal(self: Writer, val: []const u8, sep: u8) !void {
    try self.io_writer.printInt(val.len, 10, .lower, .{});
    try self.io_writer.writeByte(sep);
    try self.io_writer.writeAll(val);
}

pub fn writeSequence(self: Writer, val: []const Generic) std.Io.Writer.Error!void {
    try self.io_writer.writeByte('[');
    for (val) |gen| {
        try self.writeGeneric(gen);
    }
    try self.io_writer.writeByte(']');
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
        .{ .string = "a test" }, .{ .int = .{ .i32 = 45 } }, .{ .symbol = "shark" }, .{
            .sequence = &[_]Generic{
                .{ .int = .{ .i128 = -170_141_183_460_469_231_731_687_303_715_884_105_690 } },
                .{ .string = "testing nesting" },
            },
        },
    };

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var writer = Writer{ .io_writer = &output.writer };
    defer output.deinit();

    try writer.writeSequence(&sequence);
    try std.testing.expectEqualStrings("[6\"a test45+5'shark[170141183460469231731687303715884105690-15\"testing nesting]]", output.written());
}
