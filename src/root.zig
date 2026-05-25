const std = @import("std");

pub const dynamic = @import("dynamic.zig");
pub const Writer = @import("Writer.zig");
pub const Reader = @import("Reader.zig");

pub const Error = Writer.Error || Reader.Error;

comptime {
    std.testing.refAllDecls(@This());
}

const static = @import("static.zig");

pub const ParseOptions = static.ParseOptions;
pub const Parsed = static.Parsed;
pub const parseFromSlice = static.parseFromSlice;
pub const parse = static.parse;
