{
  description = "A flake for Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # For upgrade use `nix flake update zig zigscient-src`
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
  };

  outputs =
    inputs@{ nixpkgs
    , flake-utils
    , ...
    }:
    let
      overlays = [
        (
          _final: prev: with prev; {
            zig = inputs.zig.packages.${system}."0.15.1";
          }
        )
      ];
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit overlays system; };
        inherit (pkgs) zig;

        buildInputs =
          with pkgs;
          [
            zig
            pkg-config
            coreutils
          ];

        baseShellHook = ''
          export FLAKE_ROOT="$(nix flake metadata | grep 'Resolved URL' | awk '{print $3}' | sed 's/^path://' | sed 's/^git+file:\/\///')"
        '';
      in
      {
        # run: `nix develop`
        devShells = rec {
          default = pkgs.mkShell {
            buildInputs = buildInputs ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.udev ];

            shellHook =
              baseShellHook
              + ''
                export HISTFILE="$FLAKE_ROOT/.nix_bash_history"
                sed -i 's/^: [0-9]\{10\}:[0-9];//' $HISTFILE > /dev/null 2>&1
                sed -i '/^#/d' $HISTFILE > /dev/null 2>&1

                export PROJECT_ROOT="$FLAKE_ROOT"
              ''
              + pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
                export NIX_CFLAGS_COMPILE=$(echo $NIX_CFLAGS_COMPILE | sed 's/-fmacro-prefix-map=[^ ]*//g')
                export NIX_CFLAGS_COMPILE="-iframework $SDKROOT/System/Library/Frameworks -isystem $SDKROOT/usr/include $NIX_CFLAGS_COMPILE"
                export NIX_LDFLAGS="-L$SDKROOT/usr/lib $NIX_LDFLAGS"
              '';
          };
          # nix develop .#cross-aarch64 -c zig build -Dcpu=baseline -Doptimize=ReleaseFast -Dtarget=aarch64-linux-gnu
          cross-aarch64 = pkgs.mkShell {
            buildInputs = buildInputs ++ [ pkgs.pkgsCross.aarch64-multiplatform.udev ];

            shellHook = default.shellHook;
          };
          # nix develop .#cross-amd64 -c zig build -Dcpu=baseline -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu
          cross-amd64 = pkgs.mkShell {
            buildInputs = buildInputs ++ [ pkgs.pkgsCross.gnu64.udev ];

            shellHook = default.shellHook;
          };
        };
        packages = with pkgs; {
          default = pkgs.stdenv.mkDerivation {
            name = "minichlink-ocd";
            src = ./.;
            nativeBuildInputs =
              [
                zig
              ]
              ++ lib.optionals stdenv.hostPlatform.isLinux [
                udev
              ]
              ++ lib.optionals stdenv.hostPlatform.isDarwin [
                apple-sdk_14
              ];

            phases = [
              "unpackPhase"
              "buildPhase"
            ];
            buildPhase =
              pkgs.lib.optionalString stdenv.isDarwin ''
                export NIX_CFLAGS_COMPILE="-iframework $SDKROOT/System/Library/Frameworks -isystem $SDKROOT/usr/include $NIX_CFLAGS_COMPILE"
                export NIX_LDFLAGS="-L$SDKROOT/usr/lib $NIX_LDFLAGS"
              ''
              + ''
                mkdir -p .cache
                zig build --cache-dir $(pwd)/.zig-cache --global-cache-dir $(pwd)/.cache -Dcpu=baseline --prefix $out
              '';
          };
        };
      }
    );
}
