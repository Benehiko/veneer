{
  description = "veneer: a Linux-native game launcher for Proton, Wine, gamescope and OptiScaler";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      depsHash = nixpkgs.lib.fakeHash;
      version = "0.0.0-${self.shortRev or self.dirtyShortRev or "unknown"}";
    in
    {
      packages = forAll (
        pkgs:
        let
          zig = pkgs.zig_0_17;
          src = pkgs.lib.cleanSource ./.;

          deps = pkgs.stdenvNoCC.mkDerivation {
            pname = "veneer-zig-deps";
            inherit version src;
            nativeBuildInputs = [ zig ];
            dontConfigure = true;
            dontInstall = true;
            dontFixup = true;
            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
              zig build --fetch=all --pkg-dir $out
            '';
            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
            outputHash = depsHash;
          };

          runtimeLibs = [
            pkgs.vulkan-loader
            pkgs.wayland
            pkgs.libxkbcommon
            pkgs.libdecor
            pkgs.xorg.libX11
            pkgs.xorg.libXcursor
            pkgs.xorg.libXext
            pkgs.xorg.libXfixes
            pkgs.xorg.libXi
            pkgs.xorg.libXrandr
            pkgs.xorg.libXScrnSaver
          ];
        in
        {
          inherit deps;
          default = pkgs.stdenv.mkDerivation {
            pname = "veneer";
            inherit version src;
            nativeBuildInputs = [
              zig
              pkgs.autoPatchelfHook
            ];
            buildInputs = runtimeLibs;
            runtimeDependencies = runtimeLibs;
            dontConfigure = true;
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
              zig build --system ${deps} -Doptimize=safe -Dversion=${version} --prefix $out
              runHook postInstall
            '';
            meta = {
              description = "Linux-native game launcher for Proton, Wine, gamescope and OptiScaler";
              license = pkgs.lib.licenses.gpl3Plus;
              platforms = systems;
              mainProgram = "veneer";
            };
          };
        }
      );

      devShells = forAll (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = [
            pkgs.zig_0_17
            pkgs.gnumake
            pkgs.git
            pkgs.libarchive
            pkgs.gnupg
          ];
        };
      });

      formatter = forAll (pkgs: pkgs.nixfmt);
    };
}
