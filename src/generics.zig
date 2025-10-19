// TODO: any way to make it generic for any size?
pub const Integral = union(enum) {
    i32: i32,
    i64: i64,
    i128: i128,
};

pub const Generic = union(enum) {
    bool: bool,
    float: f32,
    double: f64,
    int: Integral,
    data: []const u8,
    string: []const u8,
    symbol: []const u8,
    sequence: []const Generic,
};
