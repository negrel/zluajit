const std = @import("std");
const recover = @import("./recover.zig");

/// Execute provided test case with a memory limited allocator, increasing it's
/// limit each time test case returns an [OutOfMemory] error or panics.
pub fn withProgressiveAllocator(tcase: fn (*std.mem.Allocator) anyerror!void) !void {
    const tries = 4096;

    var memory_limit: usize = 0;
    for (0..tries) |_| {
        var dbgAlloc = std.heap.DebugAllocator(.{
            .enable_memory_limit = true,
        }).init;
        dbgAlloc.requested_memory_limit = memory_limit;

        var alloc = dbgAlloc.allocator();
        tcase(&alloc) catch |err| {
            if (err == std.mem.Allocator.Error.OutOfMemory or err == error.Panic) {
                memory_limit += 8;
                continue;
            }

            return err;
        };

        return;
    }

    std.debug.print("progressive memory allocator failed after {} tries\n", .{tries});
    return error.ProgressiveAllocatorError;
}
