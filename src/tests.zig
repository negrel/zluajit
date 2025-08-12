const std = @import("std");
const builtin = @import("builtin");
const recover = @import("./recover.zig");

const z = @import("zluajit");

const recoverCall = recover.call;

/// Execute provided test case with a memory limited allocator, increasing it's
/// limit each time test case returns an [OutOfMemory] error or panics.
fn withProgressiveAllocator(tcase: fn (*std.mem.Allocator) anyerror!void) !void {
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
fn recoverableLuaPanic(lua: ?*z.c.lua_State) callconv(.c) c_int {
    std.debug.assert(builtin.is_test);

    var len: usize = 0;
    const str = z.c.lua_tolstring(lua, -1, &len);
    if (str != null) {
        recover.panic.call(str[0..len], @returnAddress());
    } else recover.panic.call("lua panic", @returnAddress());
    return 0;
}

fn recoverGetGlobalValue(state: z.State, name: [*c]const u8) !?z.Value {
    std.debug.assert(builtin.is_test);

    return recover.call(struct {
        fn getGlobalAnyType(st: z.State, n: [*c]const u8) ?z.Value {
            return st.getGlobalAnyType(n, z.Value);
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

test "State.init" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = null,
            });
            state.deinit();
        }
    }.testCase);
}

test "Thread.newThread" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const thread = try recoverCall(z.State.newThread, .{state});
            try std.testing.expect(!thread.isMain());
            try std.testing.expectEqual(0, thread.top());
            try std.testing.expectEqual(.ok, thread.status());
        }
    }.testCase);
}

test "Thread.pushAnyType/Thread.popAnyType/Thread.valueType" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            // Bool.
            {
                try recoverCall(z.State.pushAnyType, .{ state, true });
                try std.testing.expectEqual(state.valueType(-1), .boolean);
                try std.testing.expectEqual(true, state.popAnyType(bool));

                try recoverCall(z.State.pushAnyType, .{ state, false });
                try std.testing.expectEqual(state.valueType(-1), .boolean);
                try std.testing.expectEqual(false, state.popAnyType(bool));
            }

            // Function.
            {
                const ns = struct {
                    fn func(_: ?*z.c.lua_State) callconv(.c) c_int {
                        return 0;
                    }
                };

                try recoverCall(z.State.pushAnyType, .{ state, &ns.func });
                try std.testing.expectEqual(state.valueType(-1), .function);
                try std.testing.expectEqual(
                    z.FunctionRef.init(z.ValueRef.init(state, state.top())),
                    state.popAnyType(z.FunctionRef),
                );
            }

            // State / c.lua_State
            {
                try recoverCall(z.State.pushAnyType, .{ state, state });
                try std.testing.expectEqual(state.valueType(-1), .thread);
                try std.testing.expectEqual(
                    state,
                    state.popAnyType(z.State),
                );

                try recoverCall(z.State.pushAnyType, .{ state, state.lua });
                try std.testing.expectEqual(state.valueType(-1), .thread);
                try std.testing.expectEqual(
                    state.lua,
                    state.popAnyType(*z.c.lua_State),
                );

                try recoverCall(z.State.pushAnyType, .{ state, state.lua });
                try std.testing.expectEqual(state.valueType(-1), .thread);
                try std.testing.expectEqual(
                    state,
                    state.popAnyType(z.State),
                );
            }

            // Strings.
            {
                try recoverCall(z.State.pushAnyType, .{
                    state, @as([]const u8, "foo bar baz"),
                });
                try std.testing.expectEqual(state.valueType(-1), .string);
                try std.testing.expectEqualStrings(
                    "foo bar baz",
                    state.popAnyType([]const u8).?,
                );

                try recoverCall(z.State.pushAnyType, .{ state, @as(f64, 1) });
                try std.testing.expectEqualStrings(
                    "1",
                    (try recoverCall(struct {
                        fn popString(th: z.State) ?[]const u8 {
                            return th.popAnyType([]const u8);
                        }
                    }.popString, .{state})).?,
                );
            }

            // Floats.
            {
                try recoverCall(
                    z.State.pushAnyType,
                    .{ state, @as(f32, 1) },
                );
                try std.testing.expectEqual(state.valueType(-1), .number);
                try std.testing.expectEqual(1, state.popAnyType(f32));

                try recoverCall(
                    z.State.pushAnyType,
                    .{ state, @as(f64, 1) },
                );
                try std.testing.expectEqual(state.valueType(-1), .number);
                try std.testing.expectEqual(1, state.popAnyType(f64));

                try recoverCall(z.State.pushAnyType, .{ state, @as(f32, 1) });
                try std.testing.expectEqual(state.valueType(-1), .number);
                try std.testing.expectEqual(1, state.popAnyType(f64));

                try recoverCall(z.State.pushAnyType, .{ state, @as(f64, 1) });
                try std.testing.expectEqual(state.valueType(-1), .number);
                try std.testing.expectEqual(1, state.popAnyType(f32));
            }

            // Light userdata.
            {
                const pi: *anyopaque = @ptrCast(@constCast(&std.math.pi));
                try recoverCall(z.State.pushAnyType, .{ state, pi });
                try std.testing.expectEqual(
                    state.valueType(-1),
                    .lightuserdata,
                );
                try std.testing.expectEqual(pi, state.popAnyType(*anyopaque).?);
            }

            // Pointers.
            {
                const pi: f64 = std.math.pi;
                try recoverCall(z.State.pushAnyType, .{ state, pi });
                try std.testing.expectEqual(state.valueType(-1), .number);
                try std.testing.expectEqual(pi, state.popAnyType(f64));
            }

            // Value.
            {
                const value: z.Value = .{ .number = std.math.pi };
                try recoverCall(z.State.pushAnyType, .{ state, value });
                try std.testing.expectEqual(state.valueType(-1), .number);
                try std.testing.expectEqual(
                    value,
                    state.popAnyType(z.Value),
                );

                try recoverCall(z.State.pushAnyType, .{ state, value });
                try std.testing.expectEqual(state.valueType(-1), .number);
                try std.testing.expectEqual(
                    value.number,
                    state.popAnyType(f64),
                );
            }
        }
    }.testCase);
}

test "Thread.pushZigFunction" {
    var state = try z.State.init(.{});
    defer state.deinit();

    const zfunc = struct {
        pub fn zfunc(a: f64, b: f64) f64 {
            return a + b;
        }
    }.zfunc;

    state.pushZigFunction(zfunc);
    state.pushInteger(1);
    state.pushInteger(2);
    state.call(2, 1);
    try std.testing.expectEqual(3, state.toInteger(-1));

    // Missing argument.
    state.pushZigFunction(zfunc);
    state.pushInteger(1);
    state.pCall(1, 1, 0) catch {
        try std.testing.expectEqualStrings(
            "bad argument #2 to '?' (number expected, got no value)",
            state.popAnyType([]const u8).?,
        );
        return;
    };

    unreachable;
}

test "Thread.error" {
    var state = try z.State.init(.{});
    defer state.deinit();

    const zfunc = struct {
        pub fn zfunc(th: z.State) f64 {
            th.pushString("a runtime error");
            th.@"error"();
        }
    }.zfunc;

    // Missing argument.
    state.pushZigFunction(zfunc);
    _ = state.pushThread();
    state.pCall(1, 0, 0) catch {
        try std.testing.expectEqualStrings(
            "a runtime error",
            state.popAnyType([]const u8).?,
        );
        return;
    };

    unreachable;
}

test "Thread.concat" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.pushNumber, .{ state, 100 });
            try recoverCall(z.State.pushString, .{ state, " foo" });
            try recoverCall(z.State.concat, .{ state, 2 });
            try std.testing.expectEqualStrings(
                "100 foo",
                state.popAnyType([]const u8).?,
            );
        }
    }.testCase);
}

test "Thread.next" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.newTable, .{state});
            const idx = state.top();

            try recoverCall(z.State.pushInteger, .{ state, 1 });
            try recoverCall(z.State.rawSeti, .{ state, idx, 1 });

            try recoverCall(z.State.pushInteger, .{ state, 2 });
            try recoverCall(z.State.rawSeti, .{ state, idx, 2 });

            try recoverCall(z.State.pushInteger, .{ state, 3 });
            try recoverCall(z.State.rawSeti, .{ state, idx, 3 });

            var i: z.Integer = 0;
            state.pushNil(); // first key
            while (state.next(idx)) {
                i += 1;
                try std.testing.expectEqual(
                    i,
                    // removes 'value'; keeps 'key' for next iteration
                    state.popAnyType(z.Integer),
                );
                try std.testing.expectEqual(
                    i,
                    state.toAnyType(z.Integer, -1),
                );
            }

            try std.testing.expectEqual(3, i);
        }
    }.testCase);
}

test "Thread.top/Thread.setTop" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = null,
            });
            defer state.deinit();

            try std.testing.expectEqual(0, state.top());
            state.setTop(10);
            try std.testing.expectEqual(10, state.top());
        }
    }.testCase);
}

test "Thread.pushValue" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as(f64, std.math.pi),
            });
            try std.testing.expectEqual(1, state.top());

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as([]const u8, "foo bar baz"),
            });
            try std.testing.expectEqual(2, state.top());

            try recoverCall(z.State.pushValue, .{ state, -2 });
            try std.testing.expectEqual(3, state.top());

            try std.testing.expectEqual(
                @as(f64, std.math.pi),
                state.popAnyType(f64),
            );
            try std.testing.expectEqualStrings(
                @as([]const u8, "foo bar baz"),
                state.popAnyType([]const u8).?,
            );
            try std.testing.expectEqual(
                @as(f64, std.math.pi),
                state.popAnyType(f64),
            );
            try std.testing.expectEqual(0, state.top());
        }
    }.testCase);
}

test "Thread.remove" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as(f64, std.math.pi),
            });
            try std.testing.expectEqual(1, state.top());

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as([]const u8, "foo bar baz"),
            });
            try std.testing.expectEqual(2, state.top());

            state.remove(1);

            try std.testing.expectEqualStrings(
                @as([]const u8, "foo bar baz"),
                state.popAnyType([]const u8).?,
            );
            try std.testing.expectEqual(0, state.top());
        }
    }.testCase);
}

test "Thread.insert" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as(f64, std.math.pi),
            });
            try std.testing.expectEqual(1, state.top());

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as([]const u8, "foo bar baz"),
            });
            try std.testing.expectEqual(2, state.top());

            state.insert(1);

            try std.testing.expectEqual(
                @as(f64, std.math.pi),
                state.popAnyType(f64),
            );
            try std.testing.expectEqual(1, state.top());
        }
    }.testCase);
}

test "Thread.replace" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as(f64, std.math.pi),
            });
            try std.testing.expectEqual(1, state.top());

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as([]const u8, "foo bar baz"),
            });
            try std.testing.expectEqual(2, state.top());

            state.replace(1);

            try std.testing.expectEqualStrings(
                @as([]const u8, "foo bar baz"),
                state.popAnyType([]const u8).?,
            );
            try std.testing.expectEqual(0, state.top());
        }
    }.testCase);
}

test "Thread.checkStack" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try std.testing.expect(state.checkStack(1));
            try std.testing.expect(!state.checkStack(400000000));
        }
    }.testCase);
}

test "Thread.xMove" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const thread2 = try recoverCall(z.State.newThread, .{state});

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as([]const u8, "foo bar baz"),
            });
            state.xMove(thread2, 1);

            try std.testing.expectEqualStrings(
                @as([]const u8, "foo bar baz"),
                thread2.popAnyType([]const u8).?,
            );
            try std.testing.expectEqual(0, thread2.top());
            try std.testing.expectEqual(1, state.top());
        }
    }.testCase);
}

test "Thread.equal" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            state.pushAnyType(@as(f64, 1));
            state.pushAnyType(@as(f64, 2));

            try std.testing.expect(!state.equal(1, 2));
            try std.testing.expect(state.equal(1, 1));
            try std.testing.expect(state.equal(2, 2));
        }
    }.testCase);
}

test "Thread.rawEqual" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            state.pushAnyType(@as(f64, 1));
            state.pushAnyType(@as(f64, 2));

            try std.testing.expect(!state.rawEqual(1, 2));
            try std.testing.expect(state.rawEqual(1, 1));
            try std.testing.expect(state.rawEqual(2, 2));
        }
    }.testCase);
}

test "Thread.lessThan" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            state.pushAnyType(@as(f64, 1));
            state.pushAnyType(@as(f64, 2));

            try std.testing.expect(state.lessThan(1, 2));
            try std.testing.expect(!state.lessThan(2, 1));
            try std.testing.expect(!state.lessThan(1, 1));
            try std.testing.expect(!state.lessThan(2, 2));
        }
    }.testCase);
}

test "Thread.valueType" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            state.pushAnyType(@as(f64, 3.14));
            try std.testing.expectEqual(
                .number,
                state.valueType(1),
            );
            try recoverCall(z.State.pushAnyType, .{
                state,
                @as([]const u8, "foo bar baz"),
            });
            try std.testing.expectEqual(
                .string,
                state.valueType(2),
            );
        }
    }.testCase);
}

test "Thread.typeName" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try std.testing.expectEqualStrings(
                "boolean",
                std.mem.span(state.typeName(.boolean)),
            );
            try std.testing.expectEqualStrings(
                "number",
                std.mem.span(state.typeName(.number)),
            );
            try std.testing.expectEqualStrings(
                "function",
                std.mem.span(state.typeName(.function)),
            );
            try std.testing.expectEqualStrings(
                "string",
                std.mem.span(state.typeName(.string)),
            );
        }
    }.testCase);
}

test "Thread.getGlobal" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.openBase, .{state});
            try recoverCall(z.State.getGlobal, .{ state, "_G" });
            try recoverCall(z.State.getGlobal, .{ state, "_G" });
            try std.testing.expect(state.equal(-1, -2));
        }
    }.testCase);
}

test "Thread.getGlobalAnyType" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.openBase, .{state});

            const value = try recoverGetGlobalValue(state, "_G");
            _ = value.?.table;
        }
    }.testCase);
}

test "Thread.setGlobalAnyType" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.openBase, .{state});

            var value = try recoverGetGlobalValue(state, "_G");
            _ = value.?.table;

            state.setGlobalAnyType("_G", @as(f32, 1));

            value = try recoverGetGlobalValue(state, "_G");
            _ = value.?.number;
        }
    }.testCase);
}

test "Thread.isXXX" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.openBase, .{state});

            try std.testing.expect(!state.isBoolean(z.Global));
            try std.testing.expect(!state.isCFunction(z.Global));
            try std.testing.expect(!state.isFunction(z.Global));
            try std.testing.expect(!state.isNil(z.Global));
            try std.testing.expect(!state.isNone(z.Global));
            try std.testing.expect(!state.isNoneOrNil(z.Global));
            try std.testing.expect(!state.isNumber(z.Global));
            try std.testing.expect(state.isTable(z.Global));
            try std.testing.expect(!state.isThread(z.Global));
            try std.testing.expect(!state.isUserData(z.Global));
            try std.testing.expect(!state.isLightUserData(z.Global));
        }
    }.testCase);
}

test "Thread.toXXX" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.openBase, .{state});

            try std.testing.expect(state.toBoolean(z.Global));
            try std.testing.expect(state.toCFunction(z.Global) == null);
            try std.testing.expect(state.toNumber(z.Global) == 0);
            try std.testing.expect(state.toThread(z.Global) == null);
            try std.testing.expect(state.toUserData(z.Global) == null);
            try std.testing.expect(state.toPointer(z.Global) != null);
            try std.testing.expect(state.toString(z.Global) == null);
        }
    }.testCase);
}

test "Thread.objLen" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as([]const u8, "foo bar baz"),
            });
            try std.testing.expectEqual(
                11,
                state.objLen(-1),
            );
        }
    }.testCase);
}

test "Thread.openXXX" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try std.testing.expect(
                try recoverGetGlobalValue(state, "_G") == null,
            );
            try std.testing.expect(
                try recoverGetGlobalValue(state, "coroutine") == null,
            );
            try recoverCall(z.State.openBase, .{state});
            try std.testing.expect(
                try recoverGetGlobalValue(state, "_G") != null,
            );
            try std.testing.expect(
                try recoverGetGlobalValue(state, "coroutine") != null,
            );

            try std.testing.expect(
                try recoverGetGlobalValue(state, "package") == null,
            );
            try recoverCall(z.State.openPackage, .{state});
            try std.testing.expect(
                try recoverGetGlobalValue(state, "package") != null,
            );

            try std.testing.expect(
                try recoverGetGlobalValue(state, "table") == null,
            );
            try recoverCall(z.State.openTable, .{state});
            try std.testing.expect(
                try recoverGetGlobalValue(state, "table") != null,
            );

            try std.testing.expect(
                try recoverGetGlobalValue(state, "string") == null,
            );
            try recoverCall(z.State.openString, .{state});
            try std.testing.expect(
                try recoverGetGlobalValue(state, "string") != null,
            );

            try std.testing.expect(
                try recoverGetGlobalValue(state, "io") == null,
            );
            try recoverCall(z.State.openIO, .{state});
            try std.testing.expect(
                try recoverGetGlobalValue(state, "io") != null,
            );

            try std.testing.expect(
                try recoverGetGlobalValue(state, "os") == null,
            );
            try recoverCall(z.State.openOS, .{state});
            try std.testing.expect(
                try recoverGetGlobalValue(state, "os") != null,
            );

            try std.testing.expect(
                try recoverGetGlobalValue(state, "math") == null,
            );
            try recoverCall(z.State.openMath, .{state});
            try std.testing.expect(
                try recoverGetGlobalValue(state, "math") != null,
            );

            try std.testing.expect(
                try recoverGetGlobalValue(state, "debug") == null,
            );
            try recoverCall(z.State.openDebug, .{state});
            try std.testing.expect(
                try recoverGetGlobalValue(state, "debug") != null,
            );
        }
    }.testCase);
}

test "Thread.loadFile" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.loadFile, .{
                state,
                "src/testdata/add.lua",
            });
            try recoverCall(z.State.call, .{ state, 0, 0 });

            try recoverCall(z.State.getGlobal, .{ state, "add" });
            state.pushInteger(1);
            state.pushInteger(2);

            try recoverCall(z.State.call, .{ state, 2, 1 });
            try std.testing.expectEqual(3, state.toInteger(-1));
        }
    }.testCase);
}

test "Thread.doFile" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.doFile, .{ state, "src/testdata/add.lua" });

            try recoverCall(z.State.getGlobal, .{ state, "add" });
            state.pushInteger(1);
            state.pushInteger(2);
            try recoverCall(z.State.call, .{ state, 2, 1 });
            try std.testing.expectEqual(3, state.toInteger(-1));
        }
    }.testCase);
}

test "Thread.loadString" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try state.loadString("return 1 + 2", null);
            state.call(0, 1);
            try std.testing.expectEqual(3, state.toInteger(-1));
        }
    }.testCase);
}

test "Thread.doString" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try state.doString("return 1 + 2", null);
            try std.testing.expectEqual(3, state.toInteger(-1));
        }
    }.testCase);
}
