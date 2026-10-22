{
  description = "veneer: a Linux-native game launcher for Proton, Wine, gamescope and OptiScaler";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAll (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = [
            pkgs.zig_0_17
            pkgs.gnumake
            pkgs.git
          ];
        };
      });

      formatter = forAll (pkgs: pkgs.nixfmt);
    };
}
