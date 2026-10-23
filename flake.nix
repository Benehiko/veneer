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

      depsHash = "sha256-srIsJT0GiTdHKbU0E/vwdAk3ETGj7L66mFI/PShebcw=";
      version = "0.0.0-${self.shortRev or self.dirtyShortRev or "unknown"}";
    in
    {
      packages = forAll (
        pkgs:
        let
          zig = pkgs.zig_0_17;
          src = pkgs.lib.cleanSource ./.;

          deps = pkgs.stdenvNoCC.mkDerivation {
            name = "veneer-zig-deps";
            inherit src;
            nativeBuildInputs = [ zig ];
            dontConfigure = true;
            dontInstall = true;
            dontFixup = true;
            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
              zig build --pkg-dir $out -Doptimize=safe --help > /dev/null
            '';
            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
            outputHash = depsHash;
          };

          runtimeLibs = map pkgs.lib.getLib [
            pkgs.vulkan-loader
            pkgs.libglvnd
            pkgs.libdrm
            pkgs.dbus
            pkgs.systemdLibs
            pkgs.pipewire
            pkgs.libpulseaudio
            pkgs.alsa-lib
            pkgs.libxtst
            pkgs.fribidi
            pkgs.libthai
            pkgs.libusb1
            pkgs.liburing
            pkgs.wayland
            pkgs.libxkbcommon
            pkgs.libdecor
            pkgs.libx11
            pkgs.libxcursor
            pkgs.libxext
            pkgs.libxfixes
            pkgs.libxi
            pkgs.libxrandr
            pkgs.libxscrnsaver
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
            autoPatchelfIgnoreMissingDeps = [
              "libsteam_api.so"
              "libsndio.so.7"
              "libjack.so.0"
              "libGLES_CM.so.1"
              "libGLESv1_CM.so.1"
            ];
            dontConfigure = true;
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
              cp -r ${deps} $TMPDIR/zig-pkg
              chmod -R u+w $TMPDIR/zig-pkg
              zig build --pkg-dir $TMPDIR/zig-pkg -Doptimize=safe -Dversion=${version} --prefix $out
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
