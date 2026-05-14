//! A record type for Syrup which contains a label and a list of fields.
//! Use this with `Writer.write` and `Writer.writeRecord`.
const Value = @import("dynamic.zig").Value;
const Writer = @import("Writer.zig");

const Record = @This();

label: *const Value,
fields: []const Value,
