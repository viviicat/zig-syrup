const Record = @import("Record.zig");

// TODO: any way to make it generic for any size?
pub const Integral = union(enum) {
    i32: i32,
    i64: i64,
    i128: i128,
};

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
