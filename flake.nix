{
  description = "Zig bindings to Lua C API";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      outputsWithoutSystem = { };
      outputsWithSystem = flake-utils.lib.eachDefaultSystem (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
          };
          lib = pkgs.lib;
        in
        {
          packages = {
            luajit = pkgs.pkgsStatic.luajit.overrideAttrs (oldAttrs: {
              env = (oldAttrs.env or { }) // {
                NIX_CFLAGS_COMPILE = toString [
                  (oldAttrs.env.NIX_CFLAGS_COMPILE or "")
                  "-DLUAJIT_ENABLE_LUA52COMPAT"
                  "-DLUAJIT_NO_UNWIND=1"
                ];

                dontStrip = true;
              };
            });
          };
          devShells = {
            default = pkgs.mkShell rec {
              buildInputs =
                with pkgs;
                [
                  zig
                  zls
                  lua51Packages.lua
                  lua52Packages.lua
                ]
                ++ [ self.packages.${system}.luajit ];

              LD_LIBRARY_PATH = "${lib.makeLibraryPath buildInputs}";
            };
          };
        }
      );
    in
    outputsWithSystem // outputsWithoutSystem;
}
