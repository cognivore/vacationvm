{
  description = "My vacationvm fleet — many small services colocated on one NixOS box.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    vacationvm.url = "github:cognivore/vacationvm";
    vacationvm.inputs.nixpkgs.follows = "nixpkgs";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";

    colmena.url = "github:zhaofengli/colmena";
    colmena.inputs.nixpkgs.follows = "nixpkgs";

    # ── Services, each developed in its own repo ─────────────────────────
    # A service either ships its own `nixosModules.default` (then enabling it
    # is two lines — see hello-vvm), or it only exposes a package and you wrap
    # it with a thin adapter (see services/annexwyrm.nix).
    annexwyrm.url = "github:cognivore/annexwyrm";
    # hello-vvm.url = "github:you/hello-vvm";
  };

  outputs =
    { self, nixpkgs, vacationvm, agenix, colmena, ... }@inputs:
    let
      system = "x86_64-linux";

      # The modules every view of this host shares. The colmena node adds
      # `deployment` on top; the plain nixosConfiguration does not (so
      # `nix flake check` / `nixos-rebuild` work too).
      hostModules = [
        agenix.nixosModules.default
        vacationvm.nixosModules.vacationvm
        ./hosts/wyrm.nix
        ./services/annexwyrm.nix
        # inputs.hello-vvm.nixosModules.default   # a self-describing service
      ];
    in
    {
      # ── colmena: `colmena apply` ─────────────────────────────────────────
      colmena = {
        meta = {
          nixpkgs = import nixpkgs { inherit system; };
          specialArgs = { inherit inputs; };
        };

        wyrm = { ... }: {
          imports = hostModules;
          deployment = {
            targetHost = "46.62.199.15"; # <-- your box's public IP / hostname
            targetUser = "root";
            # Build on your laptop and push the closure. Set true to build on
            # the box instead (handy for native/Koka builds like annexwyrm).
            buildOnTarget = false;
          };
        };
      };

      # ── nixos-rebuild / nix flake check fallback ─────────────────────────
      nixosConfigurations.wyrm = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = hostModules;
      };

      # ── operator dev shell ───────────────────────────────────────────────
      devShells.${system}.default =
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.mkShell {
          packages = [
            colmena.packages.${system}.colmena
            agenix.packages.${system}.default
            vacationvm.packages.${system}.vacationvm-dns
            pkgs.openssh
            pkgs.jq
          ];
          shellHook = ''
            echo "vacationvm hive. Common commands:"
            echo "  agenix -e secrets/porkbun-api-key.age      # edit a secret"
            echo "  colmena apply --on wyrm                    # deploy"
            echo "  ssh root@<box> systemctl start vacationvm-dns-plan  # preview DNS"
          '';
        };
    };
}
