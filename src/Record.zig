//! A record type for Syrup which contains a label and a list of fields.
//! Use this with `Writer.write` and `Writer.writeRecord`.
const Generic = @import("generics.zig").Generic;
const Writer = @import("Writer.zig");

const Record = @This();

label: *const Generic,
fields: []const Generic,
