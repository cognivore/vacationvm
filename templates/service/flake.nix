{
  description = "hello-vvm — a tiny standard-library-only vacationvm-style service";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages.default = pkgs.callPackage ./nix/package.nix { };

        devShells.default = pkgs.mkShell {
          packages = [ pkgs.cargo pkgs.rustc pkgs.rustfmt pkgs.clippy ];
        };

        formatter = pkgs.nixpkgs-fmt;
      }
    )
    // {
      # The headline output: a NixOS module a vacationvm hive imports to get
      # this service as a colocatable app. Exposed top-level (not per-system),
      # mirroring annexwyrm's `homeManagerModules.default`.
      nixosModules.default = import ./nix/vacationvm-module.nix self;
    };
}
