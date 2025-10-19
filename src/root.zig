//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const Writer = @import("Writer.zig");

const generics = @import("generics.zig");
pub const Generic = generics.Generic;
pub const Integral = generics.Integral;

comptime {
    std.testing.refAllDecls(@This());
}
