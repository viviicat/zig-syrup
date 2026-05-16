const Writer = @import("Writer.zig");

/// A record type for Syrup which contains a label and a list of fields.
/// Use this with `Writer.write` and `Writer.writeRecord`.
pub const Record = struct {
    label: *const Value,
    fields: []const Value,
};

const Integral = union(enum) {
    i32: i32,
    i64: i64,
    i128: i128,
};

/// A union which allows for encoding the nested Syrup structure. Contains all the possible Syrup types.
/// Once created, it can be written via `Writer.write` or `Writer.writeValue`. For example:
/// ```zig
/// const set = Value{
///     .set = &[_]Value{
///         .{ .symbol = "one" },
///         .{ .int = .{ .i64 = 2342356 } },
///         .{ .dictionary = &[_]Value{
///             .{ .f64 = 67.98 },
///             .{ .f64 = 67.89 },
///             .{ .data = "boop" },
///             .{ .f64 = 99.999 },
///             .{ .set = &[_]Value{
///                 .{ .string = "hey" },
///                 .{ .string = "there" },
///                 } },
///             .{ .string = "stranger" },
///             } },
///     },
/// };
/// ```
pub const Value = union(enum) {
    true,
    false,
    f32: f32,
    f64: f64,
    int: Integral,
    data: []const u8,
    string: []const u8,
    symbol: []const u8,
    sequence: []const Value,
    record: Record,
    dictionary: []const Value,
    set: []const Value,
};
