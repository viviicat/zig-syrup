const Record = @import("Record.zig");
const Writer = @import("Writer.zig");

// TODO: any way to make it generic for any size?
pub const Integral = union(enum) {
    i32: i32,
    i64: i64,
    i128: i128,
};

/// A union which allows for encoding the nested Syrup structure. Contains all the possible Syrup types.
/// Once created, it can be written via `Writer.write` or `Writer.writeGeneric`. For example:
/// ```zig
/// const set = Generic{
///     .set = &[_]Generic{
///         .{ .symbol = "one" },
///         .{ .int = .{ .i64 = 2342356 } },
///         .{ .dictionary = &[_]Generic{
///             .{ .f64 = 67.98 },
///             .{ .f64 = 67.89 },
///             .{ .data = "boop" },
///             .{ .f64 = 99.999 },
///             .{ .set = &[_]Generic{
///                 .{ .string = "hey" },
///                 .{ .string = "there" },
///                 } },
///             .{ .string = "stranger" },
///             } },
///     },
/// };
/// ```
pub const Generic = union(enum) {
    true,
    false,
    f32: f32,
    f64: f64,
    int: Integral,
    data: []const u8,
    string: []const u8,
    symbol: []const u8,
    sequence: []const Generic,
    record: Record,
    dictionary: []const Generic,
    set: []const Generic,
};
