# `zluajit` - Zig bindings to LuaJIT C API

`zluajit` provides high quality, ergonomic, well documented and type-safe 
bindings to LuaJIT 5.1/5.2 C API.

## Getting started

Start a new Zig project:

```shell
$ zig init
```

Fetch `zlua` and adds it to your build.zig.zon:

```shell
$ zig fetch --save=zluajit git+https://github.com/negrel/zluajit
info: resolved to commit e5967404a3314b68cf0d49bd0e01930e72eb67f9
```

Add this to your build.zig:

```zig
const zluajit = b.dependency("zluajit", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("zluajit", zluajit.module("zluajit"));
```

Copy this simple hello world to your `main.zig`:

```zig
const zluajit = @import("zluajit");

pub fn main() !void {
    const state = try zluajit.State.init(.{});
    defer state.deinit();

    state.openLibs();
    try state.doString("print 'hello world'", null);
}
```

Compile and run:

```shell
$ zig build run
hello world
```

## Contributing

If you want to contribute to `zlua` to add a feature or improve the code contact
me at [alexandre@negrel.dev](mailto:alexandre@negrel.dev), open an
[issue](https://github.com/negrel/zluajit/issues) or make a
[pull request](https://github.com/negrel/zluajit/pulls).

## :stars: Show your support

Please give a :star: if this project helped you!

[![buy me a coffee](https://github.com/negrel/.github/blob/master/.github/images/bmc-button.png?raw=true)](https://www.buymeacoffee.com/negrel)

## :scroll: License

MIT © [Alexandre Negrel](https://www.negrel.dev/)
