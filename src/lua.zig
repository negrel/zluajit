//! Zig bindings for lua.h.

const std = @import("std");
const builtin = @import("builtin");

const c = @import("./c.zig").c;
const recover = @import("./recover.zig");
const testutils = @import("./testutils.zig");

/// State is a wrapper around [c.lua_State] and more precisely around main
/// thread.
pub const State = struct {
    const Self = @This();
    const Options = struct {
        /// Allocator used by Lua runtime.
        allocator: ?*std.mem.Allocator,
        /// Panic handler used by Lua runtime.
        panicHandler: ?CFunction,
    };

    lua: *c.lua_State,

    /// Creates a new main lua state. Allocator is used by Lua runtime so
    /// pointer must outlive lua state.
    pub fn init(options: Options) std.mem.Allocator.Error!Self {
        const lua = c.lua_newstate(
            if (options.allocator != null) luaAlloc else null,
            if (options.allocator != null) @ptrCast(@constCast(options.allocator)) else null,
        ) orelse {
            return std.mem.Allocator.Error.OutOfMemory;
        };
        if (options.panicHandler != null) {
            _ = c.lua_atpanic(lua, options.panicHandler);
        } else _ = c.lua_atpanic(lua, luaPanic);

        return .{ .lua = lua };
    }

    fn fromThread(thread: Thread) Self {
        std.debug.assert(thread.isMain());
        return .{ .lua = thread.lua };
    }

    /// Destroys lua state. You must not use [State] nor data owned by it after
    /// calling this method.
    pub fn deinit(self: Self) void {
        c.lua_close(self.lua);
    }

    /// Returns a [Thread] handle to main Lua thread.
    pub fn asThread(self: Self) Thread {
        return Thread.init(self.lua);
    }
};

/// Thread defines a Lua thread.
pub const Thread = struct {
    const Self = @This();

    /// Thread status.
    const Status = enum(c_int) {
        ok = 0,
        yield = c.LUA_YIELD,
    };

    fn statusFromInt(code: c_int) Status {
        return switch (code) {
            0 => Status.ok,
            c.LUA_YIELD => Status.yield,
            else => unreachable,
        };
    }

    lua: *c.lua_State,

    /// Initializes a new Thread wrapping provided [c.lua_State].
    pub fn init(lua: *c.lua_State) Self {
        return .{ .lua = lua };
    }

    /// Creates a new thread, pushes it on the stack, and returns a [Thread]
    /// that represents this new thread. The new thread returned by this
    /// function shares with the original thread its global environment, but has
    /// an independent execution stack.
    ///
    /// There is no explicit function to close or to destroy a thread. Threads
    /// are subject to garbage collection, like any Lua object.
    ///
    /// This function doesn't return an [error.OutOfMemory] as lua_newthread
    /// calls panic handler instead of returning null.
    ///
    /// This is the same as lua_newthread.
    pub fn newThread(self: Self) Self {
        // lua_newthread never returns a null pointer.
        return Self.init(c.lua_newthread(self.lua).?);
    }

    /// Returns the index of the top element in the stack. Because indices start
    /// at 1, this result is equal to the number of elements in the stack (and
    /// so 0 means an empty stack).
    ///
    /// This is the same as lua_gettop.
    pub fn top(self: Self) c_int {
        return c.lua_gettop(self.lua);
    }

    /// Accepts any index, or 0, and sets the stack top to this index. If the
    /// new top is larger than the old one, then the new elements are filled
    /// with nil. If index is 0, then all stack elements are removed.
    ///
    /// This is the same as lua_settop.
    pub fn setTop(self: Self, idx: c_int) void {
        c.lua_settop(self.lua, idx);
    }

    /// Removes the element at the given valid index, shifting down the elements
    /// above this index to fill the gap. This function cannot be called with a
    /// pseudo-index, because a pseudo-index is not an actual stack position.
    ///
    /// This is the same as lua_remove.
    pub fn remove(self: Self, idx: c_int) void {
        c.lua_remove(self.lua, idx);
    }

    /// Moves the top element into the given valid index, shifting up the
    /// elements above this index to open space. This function cannot be called
    /// with a pseudo-index, because a pseudo-index is not an actual stack
    /// position.
    ///
    /// This is the same as lua_insert.
    pub fn insert(self: Self, idx: c_int) void {
        c.lua_insert(self.lua, idx);
    }

    /// Moves the top element into the given valid index without shifting any
    /// element (therefore replacing the value at the given index), and then
    /// pops the top element.
    ///
    /// This is the same as lua_replace.
    pub fn replace(self: Self, idx: c_int) void {
        c.lua_replace(self.lua, idx);
    }

    /// Ensures that there are at least extra free stack slots in the stack. It
    /// returns false if it cannot fulfill the request, because it would cause
    /// the stack to be larger than a fixed maximum size (typically at least a
    /// few thousand elements) or because it cannot allocate memory for the new
    /// stack size. This function never shrinks the stack; if the stack is
    /// already larger than the new size, it is left unchanged.
    ///
    /// This is the same as lua_checkstack.
    pub fn checkStack(self: Self, sz: c_int) bool {
        return c.lua_checkstack(self.lua, sz) != 0;
    }

    /// Exchange values between different threads of the same state.
    /// This function pops n values from the stack from, and pushes them onto
    /// the stack to.
    ///
    /// This is the same as lua_xmove.
    pub fn xMove(self: Self, to: Thread, n: c_int) void {
        c.lua_xmove(self.lua, to.lua, n);
    }

    /// Returns the type of the value in the given valid index, or null for
    /// a non-valid (but acceptable) index.
    ///
    /// This is the same as lua_type.
    pub fn valueType(self: Self, idx: c_int) ?ValueType {
        const t = c.lua_type(self.lua, idx);
        if (t == c.LUA_TNONE) return null;

        return @enumFromInt(t);
    }

    /// Returns the name of the type encoded by the value `tp`.
    ///
    /// This is the same as lua_typename.
    pub fn typeName(self: Self, tp: ValueType) [*c]const u8 {
        return c.lua_typename(self.lua, @intFromEnum(tp));
    }

    /// Pushes onto the stack the value of the global `name`.
    ///
    /// This is the same as lua_getglobal.
    pub fn getGlobal(self: Self, name: [*c]const u8) void {
        c.lua_getglobal(self.lua, name);
    }

    /// Gets value of the global `name` and returns it.
    pub fn getGlobalAny(self: Self, name: [*c]const u8, comptime T: type) ?T {
        const currentTop = self.top();
        c.lua_getglobal(self.lua, name);
        if (currentTop == self.top()) return null;

        return self.popAny(T);
    }

    /// Pops a value from the stack and sets it as the new value of global `name`.
    ///
    /// This is the same as lua_setglobal.
    pub fn setGlobal(self: Self, name: [*c]const u8) void {
        c.lua_setglobal(self.lua, name);
    }

    /// Sets provided value as the new value of global `name`.
    pub fn setGlobalAny(self: Self, name: [*c]const u8, value: anytype) void {
        self.pushAny(value);
        self.setGlobal(name);
    }

    /// Returns true if the value at the given acceptable index has type
    /// boolean, and false otherwise.
    ///
    /// This is the same as lua_isboolean.
    pub fn isBoolean(self: Self, idx: c_int) bool {
        return c.lua_isboolean(self.lua, idx) != 0;
    }

    /// Returns true if the value at the given acceptable index is a [CFunction],
    /// and false otherwise.
    ///
    /// This is the same as lua_iscfunction.
    pub fn isCFunction(self: Self, idx: c_int) bool {
        return c.lua_iscfunction(self.lua, idx) != 0;
    }

    /// Returns true if the value at the given acceptable index is a function (
    /// either C or Lua), and false otherwise.
    ///
    /// This is the same as lua_isfunction.
    pub fn isFunction(self: Self, idx: c_int) bool {
        return c.lua_isfunction(self.lua, idx) != 0;
    }

    /// Returns true if the value at the given acceptable index is nil, and
    /// false otherwise.
    ///
    /// This is the same as lua_isnil.
    pub fn isNil(self: Self, idx: c_int) bool {
        return c.lua_isnil(self.lua, idx) != 0;
    }

    /// Returns true if the given acceptable index is not valid (that is, it
    /// refers to an element outside the current stack), and false otherwise.
    ///
    /// This is the same as lua_isnone.
    pub fn isNone(self: Self, idx: c_int) bool {
        return c.lua_isnone(self.lua, idx) != 0;
    }

    /// Returns true if the given acceptable index is not valid (that is, it
    /// refers to an element outside the current stack) or if the value at this
    /// index is nil, and false otherwise.
    ///
    /// This is the same as lua_isnoneornil.
    pub fn isNoneOrNil(self: Self, idx: c_int) bool {
        return c.lua_isnoneornil(self.lua, idx) != 0;
    }

    /// Returns true if the value at the given acceptable index is a number or a
    /// string convertible to a number, and false otherwise.
    ///
    /// This is the same as lua_isnumber.
    pub fn isNumber(self: Self, idx: c_int) bool {
        return c.lua_isnumber(self.lua, idx) != 0;
    }

    /// Returns true if the value at the given acceptable index is a string or a
    /// number (which is always convertible to a string), and false otherwise.
    ///
    /// This is the same as lua_isstring.
    pub fn isString(self: Self, idx: c_int) bool {
        return c.lua_isstring(self.lua, idx) != 0;
    }

    /// Returns true if the value at the given acceptable index is a table, and
    /// false otherwise.
    ///
    /// This is the same as lua_istable.
    pub fn isTable(self: Self, idx: c_int) bool {
        return c.lua_istable(self.lua, idx) != 0;
    }

    /// Returns true if the value at the given acceptable index is a thread, and
    /// false otherwise.
    ///
    /// This is the same as lua_isthread.
    pub fn isThread(self: Self, idx: c_int) bool {
        return c.lua_isthread(self.lua, idx) != 0;
    }

    /// Returns true if the value at the given acceptable index is a userdata
    /// (either full or light), and false otherwise.
    ///
    /// This is the same as lua_isuserdata.
    pub fn isUserData(self: Self, idx: c_int) bool {
        return c.lua_isuserdata(self.lua, idx) != 0;
    }

    /// Returns true if the value at the given acceptable index is a light
    /// userdata, and false otherwise.
    ///
    /// This is the same as lua_islightuserdata.
    pub fn isLightUserData(self: Self, idx: c_int) bool {
        return c.lua_islightuserdata(self.lua, idx) != 0;
    }

    /// Returns true if the two values in acceptable indices `index1` and
    /// `index2` are equal, following the semantics of the Lua == operator
    /// (that is, may call metamethods). Otherwise returns false. Also returns
    /// false if any of the indices is non valid.
    ///
    /// This is the same as lua_equal.
    pub fn equal(self: Self, index1: c_int, index2: c_int) bool {
        return c.lua_equal(self.lua, index1, index2) != 0;
    }

    /// Returns true if the two values in acceptable indices `index1` and
    /// `index2` are primitively equal (that is, without calling metamethods).
    /// Otherwise returns false. Also returns false if any of the indices are
    /// non valid.
    ///
    /// This is the same as lua_rawequal.
    pub fn rawEqual(self: Self, index1: c_int, index2: c_int) bool {
        return c.lua_rawequal(self.lua, index1, index2) != 0;
    }

    /// Returns true if the value at acceptable index `index1` is smaller than
    /// the value at acceptable index `index2`, following the semantics of the
    /// Lua < operator (that is, may call metamethods). Otherwise returns false.
    /// Also returns false if any of the indices is non valid.
    ///
    /// This is the same as lua_lessthan.
    pub fn lessThan(self: Self, index1: c_int, index2: c_int) bool {
        return c.lua_lessthan(self.lua, index1, index2) != 0;
    }

    /// Converts the Lua value at the given acceptable index to the C type
    /// lua_Number (see lua_Number). The Lua value must be a number or a string
    /// convertible to a number; otherwise, lua_tonumber returns 0.
    ///
    /// This is the same as lua_tonumber.
    pub fn toNumber(self: Self, idx: c_int) c.lua_Number {
        return c.lua_tonumber(self.lua, idx);
    }

    /// Converts the Lua value at the given acceptable index to the signed
    /// integral type lua_Integer. The Lua value must be a number or a string
    /// convertible to a number; otherwise, lua_tointeger returns 0.
    /// If the number is not an integer, it is truncated in some non-specified way.
    ///
    /// This is the same as lua_tointeger.
    pub fn toInteger(self: Self, idx: c_int) c.lua_Integer {
        return c.lua_tointeger(self.lua, idx);
    }

    /// Converts the Lua value at the given acceptable index to a boolean
    /// value. Like all tests in Lua, toBoolean returns true for any Lua value
    /// different from false and nil; otherwise it returns 0. It also returns
    /// false when called with a non-valid index. (If you want to accept only
    /// actual boolean values, use isBoolean to test the value's type.)
    ///
    /// This is the same as lua_toboolean.
    pub fn toBoolean(self: Self, idx: c_int) bool {
        return c.lua_toboolean(self.lua, idx) != 0;
    }

    /// Converts the Lua value at the given acceptable index to a []const u8.
    /// The Lua value must be a string or a number; otherwise, the function
    /// returns null. If the value is a number, then toString also changes the
    /// actual value in the stack to a string. (This change confuses lua_next
    /// when toString is applied to keys during a table traversal.)
    ///
    /// toString returns a fully aligned pointer to a string inside the Lua
    /// state. This string always has a zero ('\0') after its last character
    /// (as in C), but can contain other zeros in its body. Because Lua has
    /// garbage collection, there is no guarantee that the pointer returned by
    /// toString will be valid after the corresponding value is removed from the stack.
    ///
    /// This is the same as lua_tolstring.
    pub fn toString(self: Self, idx: c_int) ?[]const u8 {
        var len: usize = 0;
        const str = c.lua_tolstring(self.lua, idx, &len) orelse return null;
        return str[0..len];
    }

    /// Converts a value at the given acceptable index to a C function. That
    /// value must be a C function; otherwise, returns null.
    ///
    /// This is the same as lua_tocfunction.
    pub fn toCFunction(self: Self, idx: c_int) ?CFunction {
        return c.lua_tocfunction(self.lua, idx);
    }

    /// Converts the value at the given acceptable index to a generic opaque
    /// pointer. The value can be a userdata, a table, a thread, or a function;
    /// otherwise, lua_topointer returns NULL. Different objects will give
    /// different pointers. There is no way to convert the pointer back to its
    /// original value.
    ///
    /// Typically this function is used only for debug information.
    ///
    /// This is the same as lua_topointer.
    pub fn toPointer(self: Self, idx: c_int) ?*const anyopaque {
        return c.lua_topointer(self.lua, idx);
    }

    /// Converts the value at the given acceptable index to a Lua [Thread].
    /// This value must be a thread; otherwise, the function returns null.
    ///
    /// This is the same as lua_tothread.
    pub fn toThread(self: Self, idx: c_int) ?Thread {
        const lua = c.lua_tothread(self.lua, idx) orelse return null;
        return Thread.init(lua);
    }

    /// If the value at the given acceptable index is a full userdata, returns
    /// its block address. If the value is a light userdata, returns its
    /// pointer. Otherwise, returns null.
    pub fn toUserData(self: Self, idx: c_int) ?*anyopaque {
        return c.lua_touserdata(self.lua, idx);
    }

    /// Returns the "length" of the value at the given acceptable index: for
    /// strings, this is the string length; for tables, this is the result of
    /// the length operator ('#'); for userdata, this is the size of the block
    /// of memory allocated for the userdata; for other values, it is false.
    ///
    /// This is the same as lua_objlen.
    pub fn objLen(self: Self, idx: c_int) usize {
        return c.lua_objlen(self.lua, idx);
    }

    /// This is the same as [Thread.objLen].
    pub fn strLen(self: Self, idx: c_int) usize {
        return c.lua_strlen(self.lua, idx);
    }

    /// Gets a value of type T at position `idx` from Lua stack without popping
    /// it. Values on the stack may be converted to type T (e.g. )
    pub fn toAny(self: Self, comptime T: type, idx: c_int) ?T {
        return switch (T) {
            bool => self.toBoolean(idx),
            FunctionRef => FunctionRef.init(ValueRef.init(self, idx)),
            *anyopaque => self.toUserData(idx),
            f32, f64 => @floatCast(self.toNumber(idx)),
            c.lua_Integer => self.toInteger(idx),
            []const u8 => self.toString(idx),
            TableRef => TableRef.init(ValueRef.init(self, idx)),
            *c.lua_State => c.lua_tothread(self.lua, idx),
            Thread => self.toThread(idx),
            State => (self.toAny(Thread, idx) orelse return null).asState(),
            Value => {
                return switch (self.valueType(idx) orelse return null) {
                    .thread => .{
                        .thread = self.toAny(Thread, idx) orelse return null,
                    },
                    .bool => .{
                        .bool = self.toAny(bool, idx) orelse return null,
                    },
                    .nil => null,
                    .string => .{
                        .string = self.toAny([]const u8, idx) orelse return null,
                    },
                    .number => .{
                        .number = self.toAny(f64, idx) orelse return null,
                    },
                    .function => .{
                        .function = self.toAny(FunctionRef, idx) orelse return null,
                    },
                    .table => .{
                        .table = self.toAny(TableRef, idx) orelse return null,
                    },
                    .userdata => .{
                        .userdata = self.toAny(*anyopaque, idx) orelse return null,
                    },
                    .lightuserdata => .{
                        .lightuserdata = self.toAny(*anyopaque, idx) orelse return null,
                    },
                };
            },
            else => @compileError("can't get value of type " ++ @typeName(T) ++ " from Lua stack"),
        };
    }

    /// Pops `n` elements from the stack.
    ///
    /// This is the same as lua_pop.
    pub fn pop(self: Self, n: c_int) void {
        c.lua_pop(self.lua, n);
    }

    /// Pops a value of type T from top of Lua stack. If returned value is null
    /// nothing was popped from the stack.
    pub fn popAny(self: Self, comptime T: type) ?T {
        const v = self.toAny(T, -1);
        if (v != null)
            self.pop(1);
        return v;
    }

    /// Pushes a boolean value with value b onto the stack.
    ///
    /// This is the same as lua_pushbool.
    pub fn pushBool(self: Self, b: bool) void {
        c.lua_pushboolean(self.lua, @intFromBool(b));
    }

    /// Pushes a copy of the element at the given index onto the stack.
    ///
    /// This is the same as lua_pushvalue.
    pub fn pushValue(self: Self, idx: c_int) void {
        c.lua_pushvalue(self.lua, idx);
    }

    /// Pushes a nil value onto the stack.
    ///
    /// This is the same as lua_pushnil.
    pub fn pushNil(self: Self) void {
        c.lua_pushnil(self.lua);
    }

    /// Pushes a number with value `n` onto the stack.
    ///
    /// This is the same as lua_pushnumber.
    pub fn pushNumber(self: Self, n: c.lua_Number) void {
        c.lua_pushnumber(self.lua, n);
    }

    /// Pushes a number with value `n` onto the stack.
    ///
    /// This is the same as lua_pushinteger.
    pub fn pushInteger(self: Self, n: c.lua_Integer) void {
        c.lua_pushinteger(self.lua, n);
    }

    /// Pushes the string pointed to by `s` with size len onto the stack. Lua
    /// makes (or reuses) an internal copy of the given string, so the memory at
    /// `s` can be freed or reused immediately after the function returns. The
    /// string can contain embedded zeros.
    ///
    /// This is the same as lua_pushlstring.
    pub fn pushString(self: Self, s: []const u8) void {
        c.lua_pushlstring(self.lua, s.ptr, s.len);
    }

    /// Pushes a new C closure onto the stack.
    ///
    /// When a [CFunction] is created, it is possible to associate some values
    /// with it, thus creating a C closure; these values are then accessible to
    /// the function whenever it is called. To associate values with a
    /// [CFunction], first these values should be pushed onto the stack
    /// (when there are multiple values, the first value is pushed first). Then
    /// [Thread.pushCClosure] is called to create and push the [CFunction] onto
    /// the stack, with the argument `n` telling how many values should be
    /// associated with the function. [Thread.pushCClosure] also pops these values
    /// from the stack.
    ///
    /// This is the same as lua_pushcclosure.
    pub fn pushCClosure(self: Self, cfn: CFunction, n: c_int) void {
        c.lua_pushcclosure(self.lua, cfn, n);
    }

    /// Pushes a [CFunction] onto the stack.
    ///
    /// This function receives a pointer to a [CFunction] and pushes onto the
    /// stack a Lua value of type function that, when called, invokes the
    /// corresponding [CFunction].
    ///
    /// Any function to be registered in Lua must follow the correct protocol to
    /// receive its parameters and return its results (see lua_CFunction).
    ///
    /// This is the same as lua_pushcfunction.
    pub fn pushCFunction(self: Self, cfn: CFunction) void {
        c.lua_pushcfunction(self.lua, cfn);
    }

    /// Pushes a light userdata onto the stack.
    ///
    /// Userdata represent C values in Lua. A light userdata represents a
    /// pointer. It is a value (like a number): you do not create it, it has no
    /// individual metatable, and it is not collected (as it was never created).
    /// A light userdata is equal to "any" light userdata with the same C address.
    ///
    /// This is the same as lua_pushlightuserdata
    pub fn pushLightUserData(self: Self, p: *anyopaque) void {
        c.lua_pushlightuserdata(self.lua, p);
    }

    /// Pushes the thread represented by self onto the stack. Returns true if this
    /// thread is the main thread of its state.
    ///
    /// This is the same as lua_pushthread.
    pub fn pushThread(self: Self) bool {
        return c.lua_pushthread(self.lua) != 0;
    }

    /// Pushes value `v` onto Lua stack.
    pub fn pushAny(self: Self, v: anytype) void {
        self.pushT(@TypeOf(v), v);
    }

    /// Pushes a value of type T on Lua stack using comptime reflection.
    fn pushT(self: Self, comptime T: type, v: T) void {
        switch (T) {
            @TypeOf(null) => self.pushNil(),
            bool => return c.lua_pushboolean(self.lua, @intFromBool(v)),
            CFunction => return self.pushCFunction(v),
            *anyopaque => return self.pushLightUserData(v),
            f32, f64 => return self.pushNumber(v),
            c.lua_Integer => return self.pushInteger(v),
            []const u8 => return self.pushString(v),
            TableRef, FunctionRef => return self.pushAny(v.ref),
            ValueRef => return self.pushValue(v.idx),
            *c.lua_State => return self.pushAny(Thread.init(v)),
            Thread => {
                _ = v.pushThread();
                if (v.lua != self.lua) v.xMove(self, 1);
                return;
            },
            State => return v.asThread().pushAny(v.asThread()),
            // TODO: userdata => {},
            Value => return switch (v) {
                .bool => self.pushAny(v.bool),
                .function => self.pushAny(v.function),
                .lightuserdata => self.pushAny(v.lightuserdata),
                .nil => return,
                .number => self.pushAny(v.number),
                .string => self.pushAny(v.string),
                .table => self.pushAny(v.table),
                .thread => self.pushAny(v.thread),
                .userdata => self.pushAny(v.userdata),
            },
            else => {
                switch (@typeInfo(T)) {
                    .pointer => |info| {
                        return switch (info.size) {
                            .one => return self.pushT(info.child, v.*),
                            else => @compileError("pointer type of size " ++ @tagName(info.size) ++ " is not supported (" ++ @typeName(T) ++ ")"),
                        };
                    },
                    .optional => |info| {
                        if (v == null) {
                            c.lua_pushnil(self.lua);
                            return;
                        } else {
                            self.pushT(info.child, v.?);
                            return;
                        }
                    },
                    else => {},
                }
            },
        }

        @compileError("can't push value of type " ++ @typeName(T) ++ " on Lua stack");
    }

    /// Dump [Thread] Lua stack using [std.debug.print].
    pub fn dumpStack(self: Self) void {
        std.debug.print("lua stack size {}\n", .{self.top()});
        for (1..@as(usize, @intCast(self.top())) + 1) |i| {
            const val = self.toAny(Value, @intCast(i));
            if (val != null) {
                if (val.? == .string) {
                    std.debug.print("  stack[{}] '{s}'\n", .{ i, val.?.string });
                } else {
                    std.debug.print("  stack[{}] {}\n", .{ i, val.? });
                }
            } else {
                std.debug.print("  stack[{}] null\n", .{i});
            }
        }
    }

    /// Returns true if is is the main [Thread] and false otherwise.
    pub fn isMain(self: Self) bool {
        const main = c.lua_pushthread(self.lua) == 1;
        c.lua_pop(self.lua, 1);
        return main;
    }

    /// Returns [Thread] as [State] if it is the main thread.
    pub fn asState(self: Self) ?State {
        if (self.isMain()) return State.fromThread(self);
        return null;
    }

    /// Pushes onto the stack the value t[k], where t is the value at the given
    /// valid index and k is the value at the top of the stack.
    /// This function pops the key from the stack (putting the resulting value
    /// in its place). As in Lua, this function may trigger a metamethod for
    /// the "index" event.
    ///
    /// This is the same as lua_gettable.
    pub fn getTable(self: Self, index: c_int) void {
        c.lua_gettable(self.lua, index);
    }

    /// Pushes onto the stack the value t[k], where t is the value at the given
    /// valid index. As in Lua, this function may trigger a metamethod for the
    /// "index" event.
    ///
    /// This is the same as lua_getfield.
    pub fn getField(self: Self, index: c_int, k: [*c]const u8) void {
        c.lua_getfield(self.lua, index, k);
    }

    /// Similar to lua_gettable, but does a raw access (i.e., without
    /// metamethods).
    ///
    /// This is the same as lua_rawget.
    pub fn rawGet(self: Self, index: c_int) void {
        c.lua_rawget(self.lua, index);
    }

    /// Pushes onto the stack the value t[n], where t is the value at the given
    /// valid index. The access is raw; that is, it does not invoke metamethods.
    ///
    /// This is the same as lua_rawgeti.
    pub fn rawGeti(self: Self, index: c_int, n: c_int) void {
        c.lua_rawgeti(self.lua, index, n);
    }

    /// Creates a new empty table and pushes it onto the stack. The new table
    /// has space pre-allocated for narr array elements and nrec non-array
    /// elements. This pre-allocation is useful when you know exactly how many
    /// elements the table will have. Otherwise you can use the function
    /// lua_newtable.
    ///
    /// This is the same as lua_createtable.
    pub fn createTable(self: Self, narr: c_int, nrec: c_int) void {
        c.lua_createtable(self.lua, narr, nrec);
    }

    /// Creates a new empty table and pushes it onto the stack. It is equivalent
    /// to [Thread.createTable](0, 0).
    ///
    /// This is the same as lua_newtable.
    pub fn newTable(self: Self) void {
        c.lua_newtable(self.lua);
    }

    /// This function allocates a new block of memory with the given size,
    /// pushes onto the stack a new full userdata with the block address, and
    /// returns this address.
    ///
    /// Userdata represent C values in Lua. A full userdata represents a block
    /// of memory. It is an object (like a table): you must create it, it can
    /// have its own metatable, and you can detect when it is being collected.
    /// A full userdata is only equal to itself (under raw equality).
    ///
    /// When Lua collects a full userdata with a gc metamethod, Lua calls the
    /// metamethod and marks the userdata as finalized. When this userdata is
    /// collected again then Lua frees its corresponding memory.
    ///
    /// This is the same as lua_newuserdata.
    pub fn newUserData(self: Self, size: usize) ?*anyopaque {
        return c.lua_newuserdata(self.lua, size);
    }

    /// Pushes onto the stack the metatable of the value at the given acceptable
    /// index. If the index is not valid, or if the value does not have a
    /// metatable, the function returns false and pushes nothing on the stack.
    ///
    /// This is the same as lua_getmetatable.
    pub fn getMetaTable(self: Self, objindex: c_int) bool {
        return c.lua_getmetatable(self.lua, objindex) != 0;
    }

    /// Pushes onto the stack the environment table of the value at the given
    /// index.
    ///
    /// This is the same as lua_getfenv.
    pub fn getFEnv(self: Self, idx: c_int) void {
        c.lua_getfenv(self.lua, idx);
    }

    /// Does the equivalent to t[k] = v, where t is the value at the given valid
    /// index, v is the value at the top of the stack, and k is the value just
    /// below the top.
    ///
    /// This function pops both the key and the value from the stack. As in Lua,
    /// this function may trigger a metamethod for the "newindex" event.
    ///
    /// This is the same as lua_settable.
    pub fn setTable(self: Self, idx: c_int) void {
        c.lua_settable(self.lua, idx);
    }

    /// Does the equivalent to t[k] = v, where t is the value at the given valid
    /// index and v is the value at the top of the stack.
    /// This function pops the value from the stack. As in Lua, this function
    /// may trigger a metamethod for the "newindex" event.
    ///
    /// This is the same as lua_setfield.
    pub fn setField(self: Self, idx: c_int, k: []const u8) void {
        c.lua_setfield(self.lua, idx, k);
    }

    /// Similar to lua_settable, but does a raw assignment (i.e., without
    /// metamethods).
    ///
    /// This is the same as lua_rawset.
    pub fn rawSet(self: Self, idx: c_int) void {
        c.lua_rawset(self.lua, idx);
    }

    /// Does the equivalent of t[n] = v, where t is the value at the given valid
    /// index and v is the value at the top of the stack.
    /// This function pops the value from the stack. The assignment is raw; that
    /// is, it does not invoke metamethods.
    ///
    /// This is the same as lua_rawseti.
    pub fn rawSeti(self: Self, idx: c_int) void {
        c.lua_rawseti(self.lua, idx);
    }

    /// Pops a table from the stack and sets it as the new metatable for the
    /// value at the given acceptable index.
    ///
    /// This is the same as lua_setmetatable.
    pub fn setMetaTable(self: Self, objindex: c_int) void {
        c.lua_setmetatable(self.lua, objindex);
    }

    /// Pops a table from the stack and sets it as the new environment for the
    /// value at the given index. If the value at the given index is neither a
    /// function nor a thread nor a userdata, lua_setfenv returns false.
    /// Otherwise it returns true.
    ///
    /// This is the same as lua_setfenv.
    pub fn setFEnv(self: Self, idx: c_int) bool {
        return c.lua_setfenv(self.lua, idx) != 0;
    }

    /// Calls a function.
    ///
    /// To call a function you must use the following protocol: first, the
    /// function to be called is pushed onto the stack; then, the arguments to
    /// the function are pushed in direct order; that is, the first argument is
    /// pushed first. Finally you call lua_call; nargs is the number of
    /// arguments that you pushed onto the stack. All arguments and the function
    /// value are popped from the stack when the function is called. The
    /// function results are pushed onto the stack when the function returns.
    /// The number of results is adjusted to nresults, unless nresults is
    /// MULTRET. In this case, all results from the function are pushed. Lua
    /// takes care that the returned values fit into the stack space. The
    /// function results are pushed onto the stack in direct order (the first
    /// result is pushed first), so that after the call the last result is on
    /// the top of the stack.
    ///
    /// Any error inside the called function is propagated upwards (with a
    /// longjmp).
    ///
    /// The following example shows how the host program can do the equivalent
    /// to this Lua code:
    ///      a = f("how", t.x, 14)
    ///
    /// Here it is in Zig:
    ///      thread.getGlobal("f");                     // function to be called
    ///      thread.pushString("how");                           // 1st argument
    ///      thread.getGlobal("t");                       // table to be indexed
    ///      thread.getField(-1, "x");           // push result of t.x (2nd arg)
    ///      thread.remove(-2);                     // remove 't' from the stack
    ///      thread.pushInteger(14);                             // 3rd argument
    ///      thread.call(3, 1);        // call 'f' with 3 arguments and 1 result
    ///      thread.setGlobal("a");                            // set global 'a'
    ///
    /// Note that the code above is "balanced": at its end, the stack is back
    /// to its original configuration. This is considered good programming
    /// practice.
    ///
    /// This is the same as lua_call.
    pub fn call(self: Self, nargs: c_int, nresults: c_int) void {
        c.lua_call(self.lua, nargs, nresults);
    }

    /// Calls a function in protected mode.
    ///
    /// Both nargs and nresults have the same meaning as in lua_call. If there
    /// are no errors during the call, lua_pcall behaves exactly like lua_call.
    /// However, if there is any error, lua_pcall catches it, pushes a single
    /// value on the stack (the error message), and returns an error code. Like
    /// lua_call, lua_pcall always removes the function and its arguments from
    /// the stack.
    ///
    /// If errfunc is 0, then the error message returned on the stack is exactly
    /// the original error message. Otherwise, errfunc is the stack index of an
    /// error handler function. (In the current implementation, this index
    /// cannot be a pseudo-index.) In case of runtime errors, this function will
    /// be called with the error message and its return value will be the
    /// message returned on the stack by lua_pcall.
    ///
    /// Typically, the error handler function is used to add more debug
    /// information to the error message, such as a stack traceback. Such
    /// information cannot be gathered after the return of lua_pcall, since by
    /// then the stack has unwound.
    pub fn pCall(self: Self, nargs: c_int, nresults: c_int, errfunc: c_int) CallError!void {
        return callErrorFromInt(c.lua_pcall(self.lua, nargs, nresults, errfunc));
    }

    /// Calls the C function func in protected mode. func starts with only one
    /// element in its stack, a light userdata containing ud. In case of errors,
    /// lua_cpcall returns the same error codes as lua_pcall, plus the error
    /// object on the top of the stack; otherwise, it returns zero, and does not
    /// change the stack. All values returned by func are discarded.
    ///
    /// This is the same as lua_cpcall.
    pub fn cPCall(self: Self, func: CFunction, udata: ?*anyopaque) CallError!void {
        return callErrorFromInt(c.lua_cpcall(self.lua, func, udata));
    }

    /// Loads a Lua chunk. If there are no errors, [Thread.load] pushes the
    /// compiled chunk as a Lua function on top of the stack. Otherwise, it
    /// pushes an error message.
    ///
    /// This function only loads a chunk; it does not run it.
    /// [Thread.load] automatically detects whether the chunk is text or binary,
    /// and loads it accordingly.
    ///
    /// The [Thread.load] function uses a user-supplied reader function to read
    /// the chunk (see Reader). The data argument is an opaque value passed to
    /// the reader function.
    ///
    /// The chunkname argument gives a name to the chunk, which is used for
    /// error messages and in debug information.
    ///
    /// This is the same as lua_load.
    pub fn load(
        self: Self,
        reader: Reader,
        dt: ?*anyopaque,
        chunkname: []const u8,
    ) LoadError!void {
        return loadErrorFromInt(c.lua_load(self.lua, reader, dt, chunkname));
    }

    /// Dumps a function as a binary chunk. Receives a Lua function on the top
    /// of the stack and produces a binary chunk that, if loaded again, results
    /// in a function equivalent to the one dumped. As it produces parts of the
    /// chunk, lua_dump calls function writer (see lua_Writer) with the given
    /// data to write them.
    ///
    /// The value returned is the error code returned by the last call to the
    /// writer.
    ///
    /// This function does not pop the Lua function from the stack.
    ///
    /// This is the same as lua_dump.
    pub fn dump(self: Self, writer: Writer, data: ?*anyopaque) !void {
        const err = c.lua_dump(self.lua, writer, data);
        if (err != 0) return @errorFromInt(err);
    }

    /// Yields a coroutine.
    ///
    /// This function should only be called as the return expression of a
    /// [CFunction], as follows:
    ///     return thread.yield(nresults);
    ///
    /// When a [CFunction] calls [Thread.yield] in that way, the running coroutine
    /// suspends its execution, and the call to [Thread.@"resume"] that started
    /// this coroutine returns.
    ///
    /// The parameter nresults is the number of values from the stack that are
    /// passed as results to [Thread.@"resume"].
    ///
    /// This is the same as lua_yield.
    pub fn yield(self: Self, nresults: c_int) c_int {
        return c.lua_yield(self.lua, nresults);
    }

    /// Starts and resumes a coroutine in a given thread.
    ///
    /// To start a coroutine, you first create a new thread (see
    /// [Thread.newThread]); then you push onto its stack the main function plus
    /// any arguments; then you call [Thread.@"resume"], with narg being the
    /// number of arguments. This call returns when the coroutine suspends or
    /// finishes its execution. When it returns, the stack contains all values
    /// passed to [Thread.yield], or all values returned by the body function.
    /// [Thread.@"resume"] returns [Thread.Status.yield] if the coroutine yields,
    /// [Thread.Status.ok] if the coroutine finishes its execution without errors,
    /// or an error code in case of errors (see [Thread.pCall]). In case of
    /// errors, the stack is not unwound, so you can use the debug API over it.
    /// The error message is on the top of the stack. To restart a coroutine,
    /// you put on its stack only the values to be passed as results from yield,
    /// and then call [Thread.@"resume"].
    ///
    /// This is the same as lua_resume.
    pub fn @"resume"(self: Self, narg: c_int) (CallError)!Status {
        const code = c.lua_resume(self.lua, narg);
        try callErrorFromInt(code);
        return statusFromInt(code);
    }

    /// Returns the status of the thread.
    ///
    /// The status can be ok for a normal thread, an error code if the thread
    /// finished its execution with an error, or yield if the thread is
    /// suspended.
    ///
    /// This is the same as lua_status.
    pub fn status(self: Self) CallError!Status {
        const code = c.lua_status(self.lua);
        try callErrorFromInt(code);
        return statusFromInt(code);
    }

    /// Controls the garbage collector.
    ///
    /// This function performs several tasks, according to the value of the parameter what:
    ///
    /// * GcOp.stop: stops the garbage collector.
    /// * GcOp.restart: restarts the garbage collector.
    /// * GcOp.collect: performs a full garbage-collection cycle.
    /// * GcOp.count: returns the current amount of memory (in Kbytes) in use by
    /// Lua.
    /// * GcOp.countb: returns the remainder of dividing the current amount of
    /// bytes of memory in use by Lua by 1024.
    /// * GcOp.step: performs an incremental step of garbage collection. The
    /// step "size" is controlled by data (larger values mean more steps) in a
    /// non-specified way. If you want to control the step size you must
    /// experimentally tune the value of data. The function returns 1 if the
    /// step finished a garbage-collection cycle.
    /// * GcOp.setPause: sets data as the new value for the pause of the
    /// collector. The function returns the previous value of the pause.
    /// * GcOp.setStepMul: sets data as the new value for the step multiplier of
    /// the collector. The function returns the previous value of the step
    /// multiplier.
    ///
    /// This is the same as lua_gc.
    pub fn gc(self: Self, what: GcOp, data: c_int) c_int {
        return c.lua_gc(self.lua, @intFromEnum(what), data);
    }

    /// Generates a Lua error. The error message (which can actually be a Lua
    /// value of any type) must be on the stack top. This function does a long
    /// jump, and therefore never returns.
    ///
    /// This is the same as lua_error.
    pub fn @"error"(self: Self) noreturn {
        _ = c.lua_error(self.lua);
    }

    /// Pops a key from the stack, and pushes a key-value pair from the table at
    /// the given index (the "next" pair after the given key). If there are no
    /// more elements in the table, then lua_next returns 0 (and pushes
    /// nothing).
    ///
    /// A typical traversal looks like this:
    ///
    ///      /* table is in the stack at index 't' */
    ///      thread.pushNil();  /* first key */
    ///      while (thread.next(t)) {
    ///        /* uses 'key' (at index -2) and 'value' (at index -1) */
    ///        printf("%s - %s\n",
    ///               lua_typename(L, lua_type(L, -2)),
    ///               lua_typename(L, lua_type(L, -1)));
    ///        /* removes 'value'; keeps 'key' for next iteration */
    ///        lua_pop(L, 1);
    ///      }
    /// While traversing a table, do not call [Thread.toString] directly on a key,
    /// unless you know that the key is actually a string. Recall that
    /// [Thread.toString] changes the value at the given index; this confuses the
    /// next call to [Thread.next].
    ///
    /// This is the same as lua_next.
    pub fn next(self: Self, idx: c_int) bool {
        return c.lua_next(self.lua, idx) != 0;
    }

    /// Concatenates the n values at the top of the stack, pops them, and leaves
    /// the result at the top. If n is 1, the result is the single value on the
    /// stack (that is, the function does nothing); if n is 0, the result is the
    /// empty string. Concatenation is performed following the usual semantics
    /// of Lua.
    ///
    /// This is the same as lua_concat.
    pub fn concat(self: Self, n: c_int) void {
        return c.lua_concat(self.lua, n);
    }

    /// Returns the memory-allocation function of a given state. If ud is not
    /// null, Lua stores in *ud the opaque pointer passed to [State.init].
    ///
    /// This is the same as lua_getallocf.
    pub fn allocator(self: Self) ?*std.mem.Allocator {
        var ud: ?*std.mem.Allocator = null;
        _ = c.lua_getallocf(self.lua, @ptrCast(@alignCast(&ud)));
        return ud;
    }

    /// Changes the allocator of a given [Thread] to f with user data ud.
    ///
    /// This is the same as lua_setallocf.
    pub fn setAllocator(self: Self, alloc: ?*std.mem.Allocator) void {
        if (alloc == null) {
            c.lua_setallocf(self.lua, null, null);
        } else {
            c.lua_setallocf(self.lua, luaAlloc, alloc);
        }
    }

    /// Sets the [CFunction] f as the new value of global name.
    ///
    /// This is the same as c.lua_register.
    pub fn register(self: Self, name: [*c]const u8, cfunc: CFunction) void {
        c.lua_register(self.lua, name, cfunc);
    }
};

/// [Thread.gc] operations.
pub const GcOp = enum(c_int) {
    stop = c.LUA_GCSTOP,
    restart = c.LUA_GCRESTART,
    collect = c.LUA_GCCOLLECT,
    count = c.LUA_GCCOUNT,
    countb = c.LUA_GCCOUNTB,
    step = c.LUA_GCSTEP,
    setPause = c.LUA_GCSETPAUSE,
    setStepMul = c.LUA_GCSETSTEPMUL,
};

/// LoadError defines possible error returned by loading a chunk of Lua code /
/// bytecode.
pub const LoadError = error{
    /// LUA_ERRSYNTAX
    InvalidSyntax,
    /// LUA_ERRMEM
    OutOfMemory,
};

fn loadErrorFromInt(code: c_int) LoadError!void {
    return switch (code) {
        c.LUA_ERRSYNTAX => LoadError.InvalidSyntax,
        c.LUA_ERRMEM => LoadError.OutOfMemory,
        else => {},
    };
}

pub const MULTRET = c.LUA_MULTRET;

/// CallError defines possible error returned by a protected call to a Lua
/// function.
pub const CallError = error{
    /// LUA_ERRRUN
    Runtime,
    /// LUA_ERRMEM
    OutOfMemory,
    /// LUA_ERRERR
    Handler,
};

fn callErrorFromInt(code: c_int) CallError!void {
    return switch (code) {
        c.LUA_ERRRUN => CallError.Runtime,
        c.LUA_ERRMEM => CallError.OutOfMemory,
        c.LUA_ERRERR => CallError.Handler,
        else => {},
    };
}

/// ValueType enumerates all Lua type.
pub const ValueType = enum(c_int) {
    bool = c.LUA_TBOOLEAN,
    function = c.LUA_TFUNCTION,
    lightuserdata = c.LUA_TLIGHTUSERDATA,
    nil = c.LUA_TNIL,
    number = c.LUA_TNUMBER,
    string = c.LUA_TSTRING,
    table = c.LUA_TTABLE,
    thread = c.LUA_TTHREAD,
    userdata = c.LUA_TUSERDATA,
};

/// Value is a union over all Lua value types.
pub const Value = union(ValueType) {
    bool: bool,
    function: FunctionRef,
    lightuserdata: *anyopaque,
    nil: void,
    number: f64,
    string: []const u8,
    table: TableRef,
    thread: Thread,
    userdata: *anyopaque,
};

/// ValueRef is a reference to a Lua value on the stack of a [Thread]. [Thread]
/// must outlive ValueRef and stack position must remain stable.
pub const ValueRef = struct {
    const Self = @This();

    thread: Thread,
    idx: c_int,

    /// Initializes a new reference of value at index `idx` on stack of
    /// `thread`. If `idx` is a relative index, it is converted to an absolute
    /// index.
    pub fn init(thread: Thread, idx: c_int) Self {
        return .{
            .thread = thread,
            .idx = if (idx < 0) thread.top() + idx + 1 else idx,
        };
    }

    /// Returns the type of the value referenced or null for
    /// a non-valid (but acceptable) reference.
    pub fn valueType(self: Self) ?ValueType {
        return self.thread.valueType(self.idx);
    }

    /// Returns a [TableRef], a specialized reference for table values. If
    /// referenced value isn't a table, this function panics.
    pub fn toTable(self: Self) TableRef {
        std.debug.assert(self.valueType() == .table);
        return TableRef.init(self);
    }

    /// Returns a [FunctionRef], a specialized reference for function values. If
    /// referenced value isn't a function, this function panics.
    pub fn toFunction(self: Self) FunctionRef {
        std.debug.assert(self.valueType() == .function);
        return FunctionRef.init(self);
    }
};

/// TableRef is a reference to a table value on the stack of a [Thread].
/// [Thread] must outlive TableRef and stack position must remain stable.
pub const TableRef = struct {
    const Self = @This();

    ref: ValueRef,

    pub fn init(ref: ValueRef) Self {
        return .{ .ref = ref };
    }
};

/// FunctionRef is a reference to a function on the stack of a [Thread].
/// [Thread] must outlive TableRef and stack position must remain stable.
pub const FunctionRef = struct {
    const Self = @This();

    ref: ValueRef,

    pub fn init(ref: ValueRef) Self {
        return .{ .ref = ref };
    }
};

/// Type for C functions.
/// In order to communicate properly with Lua, a C function must use the
/// following protocol, which defines the way parameters and results are passed:
/// a C function receives its arguments from Lua in its stack in direct order
/// (the first argument is pushed first). So, when the function starts,
/// Thread.top() returns the number of arguments received by the function. The
/// first argument (if any) is at index 1 and its last argument is at index
/// Thread.top(). To return values to Lua, a C function just pushes them onto
/// the stack, in direct order (the first result is pushed first), and returns
/// the number of results. Any other value in the stack below the results will
/// be properly discarded by Lua. Like a Lua function, a C function called by
/// Lua can also return many results.
pub const CFunction = *const fn (?*c.lua_State) callconv(.c) c_int;

/// The reader function used by Thread.load. Every time it needs another piece
/// of the chunk, Thread.load calls the reader, passing along its data parameter.
/// The reader must return a pointer to a block of memory with a new piece of
/// the chunk and set size to the block size. The block must exist until the
/// reader function is called again. To signal the end of the chunk, the reader
/// must return null or set size to zero. The reader function may return pieces
/// of any size greater than zero.
pub const Reader = *const fn (
    ?*c.lua_State,
    ?*anyopaque,
    [*c]usize,
) callconv(.c) [*c]const u8;

/// The type of the writer function used by lua_dump. Every time it produces
/// another piece of chunk, lua_dump calls the writer, passing along the buffer
/// to be written (p), its size (sz), and the data parameter supplied to
/// Thread.dump.
//
/// The writer returns an error code: 0 means no errors; any other value means
/// an error and stops Thread.dump from calling the writer again.
pub const Writer = *const fn (
    ?*c.lua_State,
    ?*const anyopaque,
    usize,
    ?*anyopaque,
) callconv(.c) c_int;

/// c.lua_Alloc function to enable Lua VM to allocate memory using zig
/// allocator.
fn luaAlloc(
    ud: ?*anyopaque,
    ptr: ?*anyopaque,
    osize: usize,
    nsize: usize,
) callconv(.c) ?*anyopaque {
    const alloc: *std.mem.Allocator = @ptrCast(@alignCast(ud.?));

    var result: ?*anyopaque = ptr;
    if (ptr == null) {
        const bslice = alloc.alloc(u8, nsize) catch return null;
        result = bslice.ptr;
    } else {
        var bslice: []u8 = @as([*]u8, @ptrCast(ptr))[0..osize];
        bslice = alloc.realloc(bslice, nsize) catch return null;
        result = bslice.ptr;
    }

    return result;
}

/// Panic function called by lua before aborting. This functions dumps lua stack
/// before panicking.
fn luaPanic(lua: ?*c.lua_State) callconv(.c) c_int {
    const th = Thread.init(lua.?);
    th.dumpStack();
    @panic("lua panic");
}

/// Recoverable panic function called by lua. This should be used in tests only.
fn recoverableLuaPanic(lua: ?*c.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const str = c.lua_tolstring(lua, -1, &len);
    if (str != null) {
        recover.panic.call(str[0..len], @returnAddress());
    } else recover.panic.call("lua panic", @returnAddress());
    return 0;
}

/// Calls Thread.newThread using recover.call. This should be used in tests only.
fn recoverNewThread(thread: Thread) !Thread {
    return recover.call(struct {
        fn newThread(th: Thread) Thread {
            return th.newThread();
        }
    }.newThread, .{thread});
}

/// Calls Thread.pushAny using recover.call. This should be used in tests only.
fn recoverPushAny(thread: Thread, value: anytype) !void {
    return recover.call(struct {
        fn pushAny(th: Thread, v: anytype) void {
            return th.pushAny(v);
        }
    }.pushAny, .{ thread, value });
}

/// Calls Thread.pushValue using recover.call. This should be used in tests only.
fn recoverPushValue(thread: Thread, idx: c_int) !void {
    return recover.call(struct {
        fn pushValue(th: Thread, i: c_int) void {
            return th.pushValue(i);
        }
    }.pushValue, .{ thread, idx });
}

/// Calls Thread.popAny using recover.call. This should be used in tests only.
fn recoverPopValue(thread: Thread) !?Value {
    return recover.call(struct {
        fn popValue(th: Thread) ?Value {
            return th.popAny(Value);
        }
    }.popValue, .{thread});
}

test "State.init" {
    try testutils.withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try State.init(.{ .allocator = alloc, .panicHandler = null });
            state.deinit();
        }
    }.testCase);
}

test "Thread.newThread" {
    try testutils.withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const thread = try recoverNewThread(state.asThread());
            try std.testing.expect(!thread.isMain());
            try std.testing.expectEqual(null, thread.asState());
            try std.testing.expectEqual(0, thread.top());
            try std.testing.expectEqual(.ok, thread.status());
        }
    }.testCase);
}

test "State.asThread" {
    try testutils.withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try State.init(.{
                .allocator = alloc,
                .panicHandler = null,
            });
            defer state.deinit();

            const thread = state.asThread();
            try std.testing.expect(thread.isMain());
        }
    }.testCase);
}

test "Thread.pushAny/Thread.popAny/Thread.valueType" {
    try testutils.withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const thread = state.asThread();

            // Bool.
            {
                try recoverPushAny(thread, true);
                try std.testing.expectEqual(thread.valueType(-1), .bool);
                try std.testing.expectEqual(true, thread.popAny(bool));

                try recoverPushAny(thread, false);
                try std.testing.expectEqual(thread.valueType(-1), .bool);
                try std.testing.expectEqual(false, thread.popAny(bool));
            }

            // Function.
            {
                const ns = struct {
                    fn func(_: ?*c.lua_State) callconv(.c) c_int {
                        return 0;
                    }
                };

                try recoverPushAny(thread, &ns.func);
                try std.testing.expectEqual(thread.valueType(-1), .function);
                try std.testing.expectEqual(
                    FunctionRef.init(ValueRef.init(thread, thread.top())),
                    thread.popAny(FunctionRef),
                );
            }

            // State / Thread / c.lua_State
            {
                try recoverPushAny(thread, state);
                try std.testing.expectEqual(thread.valueType(-1), .thread);
                try std.testing.expectEqual(
                    state,
                    thread.popAny(State),
                );

                try recoverPushAny(thread, thread);
                try std.testing.expectEqual(thread.valueType(-1), .thread);
                try std.testing.expectEqual(
                    thread,
                    thread.popAny(Thread),
                );

                try recoverPushAny(thread, state.lua);
                try std.testing.expectEqual(thread.valueType(-1), .thread);
                try std.testing.expectEqual(
                    state.lua,
                    thread.popAny(*c.lua_State),
                );

                try recoverPushAny(thread, thread.lua);
                try std.testing.expectEqual(thread.valueType(-1), .thread);
                try std.testing.expectEqual(
                    thread,
                    thread.popAny(Thread),
                );
            }

            // Strings.
            {
                try recoverPushAny(thread, @as([]const u8, "foo bar baz"));
                try std.testing.expectEqual(thread.valueType(-1), .string);
                try std.testing.expectEqualStrings(
                    "foo bar baz",
                    thread.popAny([]const u8).?,
                );

                try recoverPushAny(thread, @as(f64, 1));
                try std.testing.expectEqualStrings(
                    "1",
                    (try recover.call(struct {
                        fn popString(th: Thread) ?[]const u8 {
                            return th.popAny([]const u8);
                        }
                    }.popString, .{thread})).?,
                );
            }

            // Floats.
            {
                try recoverPushAny(thread, @as(f32, 1));
                try std.testing.expectEqual(thread.valueType(-1), .number);
                try std.testing.expectEqual(1, thread.popAny(f32));

                try recoverPushAny(thread, @as(f64, 1));
                try std.testing.expectEqual(thread.valueType(-1), .number);
                try std.testing.expectEqual(1, thread.popAny(f64));

                try recoverPushAny(thread, @as(f32, 1));
                try std.testing.expectEqual(thread.valueType(-1), .number);
                try std.testing.expectEqual(1, thread.popAny(f64));

                try recoverPushAny(thread, @as(f64, 1));
                try std.testing.expectEqual(thread.valueType(-1), .number);
                try std.testing.expectEqual(1, thread.popAny(f32));
            }

            // Light userdata.
            {
                const pi: *anyopaque = @ptrCast(@constCast(&std.math.pi));
                try recoverPushAny(thread, pi);
                try std.testing.expectEqual(thread.valueType(-1), .lightuserdata);
                try std.testing.expectEqual(pi, thread.popAny(*anyopaque).?);
            }

            // Pointers.
            {
                const pi: f64 = std.math.pi;
                try recoverPushAny(thread, pi);
                try std.testing.expectEqual(thread.valueType(-1), .number);
                try std.testing.expectEqual(pi, thread.popAny(f64));
            }

            // Value.
            {
                const value: Value = .{ .number = std.math.pi };
                try recoverPushAny(thread, value);
                try std.testing.expectEqual(thread.valueType(-1), .number);
                try std.testing.expectEqual(value, thread.popAny(Value));

                try recoverPushAny(thread, value);
                try std.testing.expectEqual(thread.valueType(-1), .number);
                try std.testing.expectEqual(value.number, thread.popAny(f64));
            }
        }
    }.testCase);
}

test "Thread.top/Thread.setTop" {
    try testutils.withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try State.init(.{
                .allocator = alloc,
                .panicHandler = null,
            });
            defer state.deinit();

            const thread = state.asThread();

            try std.testing.expectEqual(0, thread.top());
            thread.setTop(10);
            try std.testing.expectEqual(10, thread.top());
        }
    }.testCase);
}

test "Thread.pushValue" {
    try testutils.withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const thread = state.asThread();

            try recoverPushAny(thread, @as(f64, std.math.pi));
            try std.testing.expectEqual(1, thread.top());

            try recoverPushAny(thread, @as([]const u8, "foo bar baz"));
            try std.testing.expectEqual(2, thread.top());

            try recoverPushValue(thread, -2);
            try std.testing.expectEqual(3, thread.top());

            try std.testing.expectEqual(
                @as(f64, std.math.pi),
                thread.popAny(f64),
            );
            try std.testing.expectEqualStrings(
                @as([]const u8, "foo bar baz"),
                thread.popAny([]const u8).?,
            );
            try std.testing.expectEqual(
                @as(f64, std.math.pi),
                thread.popAny(f64),
            );
            try std.testing.expectEqual(0, thread.top());
        }
    }.testCase);
}

test "Thread.remove" {
    try testutils.withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const thread = state.asThread();

            try recoverPushAny(thread, @as(f64, std.math.pi));
            try std.testing.expectEqual(1, thread.top());

            try recoverPushAny(thread, @as([]const u8, "foo bar baz"));
            try std.testing.expectEqual(2, thread.top());

            thread.remove(1);

            try std.testing.expectEqualStrings(
                @as([]const u8, "foo bar baz"),
                thread.popAny([]const u8).?,
            );
            try std.testing.expectEqual(0, thread.top());
        }
    }.testCase);
}

test "Thread.insert" {
    try testutils.withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const thread = state.asThread();

            try recoverPushAny(thread, @as(f64, std.math.pi));
            try std.testing.expectEqual(1, thread.top());

            try recoverPushAny(thread, @as([]const u8, "foo bar baz"));
            try std.testing.expectEqual(2, thread.top());

            thread.insert(1);

            try std.testing.expectEqual(
                @as(f64, std.math.pi),
                thread.popAny(f64),
            );
            try std.testing.expectEqual(1, thread.top());
        }
    }.testCase);
}

test "Thread.replace" {
    try testutils.withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const thread = state.asThread();

            try recoverPushAny(thread, @as(f64, std.math.pi));
            try std.testing.expectEqual(1, thread.top());

            try recoverPushAny(thread, @as([]const u8, "foo bar baz"));
            try std.testing.expectEqual(2, thread.top());

            thread.replace(1);

            try std.testing.expectEqualStrings(
                @as([]const u8, "foo bar baz"),
                thread.popAny([]const u8).?,
            );
            try std.testing.expectEqual(0, thread.top());
        }
    }.testCase);
}

test "Thread.checkStack" {
    try testutils.withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const thread = state.asThread();

            try std.testing.expect(thread.checkStack(1));
            try std.testing.expect(!thread.checkStack(400000000));
        }
    }.testCase);
}

test "Thread.xMove" {
    try testutils.withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const thread = state.asThread();
            const thread2 = try recoverNewThread(thread);

            try recoverPushAny(thread, @as([]const u8, "foo bar baz"));
            thread.xMove(thread2, 1);

            try std.testing.expectEqualStrings(
                @as([]const u8, "foo bar baz"),
                thread2.popAny([]const u8).?,
            );
            try std.testing.expectEqual(0, thread2.top());
            try std.testing.expectEqual(1, thread.top());
        }
    }.testCase);
}

test "Thread.equal" {
    try testutils.withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const thread = state.asThread();

            thread.pushAny(@as(f64, 1));
            thread.pushAny(@as(f64, 2));

            try std.testing.expect(!thread.equal(1, 2));
            try std.testing.expect(thread.equal(1, 1));
            try std.testing.expect(thread.equal(2, 2));
        }
    }.testCase);
}

test "Thread.rawEqual" {
    try testutils.withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const thread = state.asThread();

            thread.pushAny(@as(f64, 1));
            thread.pushAny(@as(f64, 2));

            try std.testing.expect(!thread.rawEqual(1, 2));
            try std.testing.expect(thread.rawEqual(1, 1));
            try std.testing.expect(thread.rawEqual(2, 2));
        }
    }.testCase);
}

test "Thread.lessThan" {
    try testutils.withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const thread = state.asThread();

            thread.pushAny(@as(f64, 1));
            thread.pushAny(@as(f64, 2));

            try std.testing.expect(thread.lessThan(1, 2));
            try std.testing.expect(!thread.lessThan(2, 1));
            try std.testing.expect(!thread.lessThan(1, 1));
            try std.testing.expect(!thread.lessThan(2, 2));
        }
    }.testCase);
}
