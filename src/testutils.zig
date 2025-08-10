const std = @import("std");
const builtin = @import("builtin");
const recover = @import("./recover.zig");
const c = @import("./c.zig").c;
const zlua = @import("./lua.zig");

const Thread = zlua.Thread;
const Value = zlua.Value;
pub const recoverCall = recover.call;

/// Execute provided test case with a memory limited allocator, increasing it's
/// limit each time test case returns an [OutOfMemory] error or panics.
pub fn withProgressiveAllocator(tcase: fn (*std.mem.Allocator) anyerror!void) !void {
    std.debug.assert(builtin.is_test);

    const tries = 8192;

    var memory_limit: usize = 10000000000000000;
    for (0..tries) |_| {
        var dbgAlloc = std.heap.DebugAllocator(.{
            .enable_memory_limit = true,
        }).init;
        dbgAlloc.requested_memory_limit = memory_limit;

        var alloc = dbgAlloc.allocator();
        tcase(&alloc) catch |err| {
            if (err == std.mem.Allocator.Error.OutOfMemory or err == error.Panic) {
                memory_limit += @sizeOf(usize);
                continue;
            }

            return err;
        };

        return;
    }

    std.debug.print("progressive memory allocator failed after {} tries\n", .{tries});
    return error.ProgressiveAllocatorError;
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

/// Calls Thread.newThread using recover.call. This should be used in tests only.
pub fn recoverNewThread(thread: Thread) !Thread {
    std.debug.assert(builtin.is_test);

    return recover.call(struct {
        fn newThread(th: Thread) Thread {
            return th.newThread();
        }
    }.newThread, .{thread});
}

/// Calls Thread.pushAnyType using recover.call. This should be used in tests only.
pub fn recoverPushAnyType(thread: Thread, value: anytype) !void {
    std.debug.assert(builtin.is_test);

    return recover.call(struct {
        fn pushAnyType(th: Thread, v: anytype) void {
            return th.pushAnyType(v);
        }
    }.pushAnyType, .{ thread, value });
}

/// Calls Thread.pushValue using recover.call. This should be used in tests only.
pub fn recoverPushValue(thread: Thread, idx: c_int) !void {
    std.debug.assert(builtin.is_test);

    return recover.call(struct {
        fn pushValue(th: Thread, i: c_int) void {
            return th.pushValue(i);
        }
    }.pushValue, .{ thread, idx });
}

/// Calls Thread.popAny using recover.call. This should be used in tests only.
pub fn recoverPopValue(thread: Thread) !?Value {
    std.debug.assert(builtin.is_test);

    return recover.call(struct {
        fn popValue(th: Thread) ?Value {
            return th.popAny(Value);
        }
    }.popValue, .{thread});
}

/// Calls Thread.openBase using recover.call. This should be used in tests only.
pub fn recoverOpenBase(thread: Thread) !void {
    std.debug.assert(builtin.is_test);

    return recover.call(struct {
        fn openBase(th: Thread) void {
            return th.openBase();
        }
    }.openBase, .{thread});
}

pub fn recoverGetGlobalAny(thread: Thread, name: [*c]const u8) !?Value {
    std.debug.assert(builtin.is_test);

    return recover.call(struct {
        fn getGlobalAny(th: Thread, n: [*c]const u8) ?Value {
            return th.getGlobalAny(n, Value);
        }
    }.getGlobalAny, .{ thread, name });
}
