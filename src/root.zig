const std = @import("std");

const generics = @import("generics.zig");
pub const Generic = generics.Generic;
pub const Record = @import("Record.zig");
pub const Writer = @import("Writer.zig");
pub const Reader = @import("Reader.zig");

comptime {
    std.testing.refAllDecls(@This());
}
