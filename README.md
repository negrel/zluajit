# `zlua` - Zig bindings to Lua C API

## Getting started

Start a new Zig project:

```shell
$ zig init
```

Fetch `zlua` and adds it to your build.zig.zon:

```shell
$ zig fetch --save=zlua git+https://github.com/negrel/zlua
info: resolved to commit e5967404a3314b68cf0d49bd0e01930e72eb67f9
```

Add this to your build.zig:

```zig
const zlua = b.dependency("zlua", .{ .target = target, .optimize = optimize });
exe_mod.addImport("zlua", zlua.module("zlua"));
```

Copy this simple hello world to your `main.zig`:

```zig
const zlua = @import("zlua");

pub fn main() !void {
    const state = try zlua.State.init(.{});
    defer state.deinit();

    const thread = state.asThread();

    thread.openLibs();
    try thread.doString("print 'hello world'", null);
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
[issue](https://github.com/negrel/zlua/issues) or make a
[pull request](https://github.com/negrel/zlua/pulls).

## :stars: Show your support

Please give a :star: if this project helped you!

[![buy me a coffee](https://github.com/negrel/.github/blob/master/.github/images/bmc-button.png?raw=true)](https://www.buymeacoffee.com/negrel)

## :scroll: License

MIT © [Alexandre Negrel](https://www.negrel.dev/)
