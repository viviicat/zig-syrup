const Generic = @import("generics.zig").Generic;

const Record = @This();

label: *const Generic,
fields: []const Generic,
