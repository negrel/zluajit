const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

pub const lua = @import("./lua.zig");

test {
    _ = lua;
}
