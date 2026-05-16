//! Simple Base32 encoding library based on Goblins' Base32 module.
//! See https://codeberg.org/spritely/goblins/src/branch/main/goblins/utils/base32.scm

const std = @import("std");

const alphabet = "abcdefghijklmnopqrstuvwxyz234567";

fn getCharIndex(char: u8) !u5 {
    switch (char) {
        'a'...'z' => return @intCast(char - 'a'),
        '2'...'7' => return @intCast(char - '2' + 26),
        5 => return 2,
        else => return error.InvalidBase32,
    }
}

fn getShiftedChunk(int: u64, shift: u6) u5 {
    return @truncate((int >> shift));
}

fn writeShiftedChunk(writer: *std.Io.Writer, int: u64, shift: u6) !void {
    try writer.writeByte(alphabet[getShiftedChunk(int, shift)]);
}

const EncodeOptions = struct {
    include_pad: bool = false,
};

/// Read from `reader`, encode in base32, and write to `writer`.
pub fn encode(reader: *std.Io.Reader, writer: *std.Io.Writer, options: EncodeOptions) !void {
    while (true) {
        const input = reader.take(5) catch |err| blk: switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => {
                break :blk reader.buffered();
            },
        };

        // Read in the value, but put the bytes as far to the left as possible
        const int: u64 = std.mem.readVarInt(u64, input, .big) << @truncate(64 - input.len * 8);

        const offset_len: usize = switch (input.len) {
            5 => 8,
            4 => 7,
            3 => 5,
            2 => 4,
            1 => 2,
            else => 0,
        };

        const offsets: [8]u6 = .{ 59, 54, 49, 44, 39, 34, 29, 24 };
        for (offsets[0..offset_len]) |shift| {
            try writeShiftedChunk(writer, int, shift);
        }

        if (input.len < 5) {
            if (input.len > 0 and options.include_pad)
                try writer.splatByteAll('=', 8 - offset_len);

            return;
        }
    }
}

/// Encode the provided `slice` in base32, and write to `writer`.
pub fn encodeSlice(slice: []const u8, writer: *std.Io.Writer, options: EncodeOptions) !void {
    var reader = std.io.Reader.fixed(slice);
    try encode(&reader, writer, options);
}

var read_buf: [256]u8 = undefined;
test encode {
    var reader = std.testing.Reader.init(&read_buf, &.{
        .{ .buffer = "this is a test! " },
        .{ .buffer = "of some base32 :)" },
    });

    var buf: [500]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&reader.interface, &writer, .{});
    try std.testing.expectEqualStrings("orugs4zanfzsayjaorsxg5bbebxwmidtn5wwkidcmfzwkmzsea5cs", writer.buffered());
}

test "encode empty" {
    var buf: [10]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encodeSlice("", &writer, .{ .include_pad = true });
    try std.testing.expectEqualStrings("", writer.buffered());
}

test encodeSlice {
    var buf: [500]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encodeSlice("Purchased for $300.\nAnd then I went home.\n", &writer, .{ .include_pad = true });
    try std.testing.expectEqualStrings("kb2xey3imfzwkzbamzxxeibegmydalqkifxgiidunbsw4icjeb3wk3tuebug63lffyfa====", writer.buffered());
}
