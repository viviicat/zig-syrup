const std = @import("std");

const Writer = @This();

io_writer: *std.Io.Writer,

pub fn write(self: Writer, val: anytype) !void {
    const ValType = @TypeOf(val);
    const ValInfo = @typeInfo(ValType);

    try switch (ValType) {
        bool => self.writeBoolean(val),
        f32 => self.writeFloat(val),
        f64 => self.writeDouble(val),
        comptime_float => self.writeDouble(@as(f64, val)),
        else => switch (ValInfo) {
            .int => self.writeInt(val),
            .comptime_int => self.writeInt(val),
            .pointer => @compileError("use either writeString or writeData with a byte slice."),
            else => @compileError("unsupported type!" ++ @typeName(ValType)),
        },
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
    try self.io_writer.printInt(val.len, 10, .lower, .{});
    try self.io_writer.writeByte(':');
    try self.io_writer.writeAll(val);
}

pub fn writeString(self: Writer, val: []const u8) !void {
    try self.io_writer.printInt(val.len, 10, .lower, .{});
    try self.io_writer.writeByte('"');
    try self.io_writer.writeAll(val);
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
