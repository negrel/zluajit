const std = @import("std");
const builtin = @import("builtin");
const recover = @import("./recover.zig");
const c = @import("./c.zig").c;
const zlua = @import("./root.zig");

const State = zlua.State;
const Value = zlua.Value;
pub const recoverCall = recover.call;

/// Execute provided test case with a memory limited allocator, increasing it's
/// limit each time test case returns an [OutOfMemory] error or panics.
pub fn withProgressiveAllocator(tcase: fn (*std.mem.Allocator) anyerror!void) !void {
    std.debug.assert(builtin.is_test);

    var palloc = ProgressiveAllocator.init();
    var alloc = palloc.allocator();
    defer palloc.deinit();

    while (true) {
        tcase(&alloc) catch |err| {
            if (err == std.mem.Allocator.Error.OutOfMemory or err == error.Panic) {
                palloc.progress();
                continue;
            }

            return err;
        };

        break;
    }
}

/// Recoverable panic function called by lua. This should be used in tests only.
pub fn recoverableLuaPanic(lua: ?*c.lua_State) callconv(.c) c_int {
    std.debug.assert(builtin.is_test);

    var len: usize = 0;
    const str = c.lua_tolstring(lua, -1, &len);
    if (str != null) {
        recover.panic.call(str[0..len], @returnAddress());
    } else recover.panic.call("lua panic", @returnAddress());
    return 0;
}

pub fn recoverGetGlobalValue(state: State, name: [*c]const u8) !?Value {
    std.debug.assert(builtin.is_test);

    return recover.call(struct {
        fn getGlobalAnyType(st: State, n: [*c]const u8) ?Value {
            return st.getGlobalAnyType(n, Value);
        }
    }.getGlobalAnyType, .{ state, name });
}

/// ProgressiveAllocator is a wrapper around [std.heap.DebugAllocator] that
/// tracks requested memory. This enables progressively incrementing memory
/// limit until a test succeed.
const ProgressiveAllocator = struct {
    const Self = @This();

    dbg: std.heap.DebugAllocator(.{ .enable_memory_limit = true }),
    requested: usize = 0,

    pub fn init() Self {
        var dbg =
            std.heap.DebugAllocator(.{ .enable_memory_limit = true }).init;
        dbg.requested_memory_limit = 0;
        return .{ .dbg = dbg };
    }

    pub fn deinit(self: *Self) void {
        _ = self.dbg.detectLeaks();
        _ = self.dbg.deinit();
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn progress(self: *Self) void {
        _ = self.dbg.deinit();
        self.dbg =
            std.heap.DebugAllocator(.{ .enable_memory_limit = true }).init;
        self.dbg.requested_memory_limit = self.requested;
        self.requested = 0;
    }

    pub fn alloc(
        ptr: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.requested += len;

        const dalloc = self.dbg.allocator();
        return dalloc.rawAlloc(len, alignment, ret_addr);
    }

    pub fn resize(
        ptr: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.requested += new_len - memory.len;

        const dalloc = self.dbg.allocator();
        return dalloc.rawResize(
            memory,
            alignment,
            new_len,
            ret_addr,
        );
    }

    pub fn remap(
        ptr: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.requested += new_len - memory.len;

        const dalloc = self.dbg.allocator();
        return dalloc.rawRemap(
            memory,
            alignment,
            new_len,
            ret_addr,
        );
    }

    pub fn free(
        ptr: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const dalloc = self.dbg.allocator();
        return dalloc.rawFree(
            memory,
            alignment,
            ret_addr,
        );
    }
};
