const std = @import("std");

pub const dynamic = @import("dynamic.zig");
pub const Writer = @import("Writer.zig");
pub const Reader = @import("Reader.zig");

pub const Error = Writer.Error || Reader.Error;

comptime {
    std.testing.refAllDecls(@This());
}
