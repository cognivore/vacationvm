{
  description = "vacationvm — declaratively colocate many small services on one NixOS box via `colmena apply`, with automatic Caddy TLS and stateless Porkbun DNS.";

  # Small input set: the framework needs nixpkgs and agenix (its declarative
  # secret layer — the fleet module always declares `age.secrets`). A *hive*
  # (operator repo) additionally pulls in `colmena` and the service flakes —
  # see templates/hive/flake.nix.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, flake-utils, agenix }:
    let
      # System-independent pure helpers (also consumed by the NixOS module).
      vacationvmLib = import ./lib { lib = nixpkgs.lib; };
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = nixpkgs.lib;
        dnsPkg = pkgs.callPackage ./dns/package.nix { };

        registerHost = pkgs.writeShellApplication {
          name = "vacationvm-register-host";
          runtimeInputs = [ pkgs.openssh pkgs.gawk ];
          text = builtins.readFile ./scripts/register-host.sh;
        };

        # A minimal evaluated host that exercises the module without needing
        # agenix or any service flake — a fast structural smoke test. Pinned to
        # x86_64-linux (NixOS is Linux-only) and using literal exec paths so it
        # is pure-eval: nothing here forces a derivation build, so it evaluates
        # fine even on a darwin builder.
        smokeHost = lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            agenix.nixosModules.default
            ./modules/fleet.nix
            (
              { ... }:
              {
                system.stateVersion = "24.11";
                networking.hostName = "vacationvm-smoke";
                # Minimal bootable shape so NixOS' own assertions pass and only
                # real (vacationvm) problems show up in failedAssertions.
                fileSystems."/" = { device = "tmpfs"; fsType = "tmpfs"; };
                boot.loader.grub.enable = false;
                vacationvm = {
                  enable = true;
                  acmeEmail = "ops@example.com";
                  publicIp4 = "203.0.113.10";
                  publicIp6 = "2001:db8::10";
                  # Tenant scheme: a public app named `wyrm` becomes
                  # wyrm.sweater.vac.example.com unless it sets `domain`.
                  tenant = "sweater";
                  baseDomain = "vac.example.com";
                  # Plain dummy paths so the smoke host needs no agenix.
                  dns.porkbun.apiKeyFile = "/run/dummy/porkbun-api";
                  dns.porkbun.secretKeyFile = "/run/dummy/porkbun-secret";
                  dns.extraRecords = [
                    { fqdn = "example.com"; type = "TXT"; content = "v=spf1 -all"; }
                  ];
                  # Tenant-derived domain (wyrm.sweater.vac.example.com):
                  services.wyrm = {
                    enable = true;
                    description = "wyrm (tenant-derived)";
                    exec = [ "/run/current-system/sw/bin/true" ];
                    listen.type = "unix";
                    staticFiles."/static/*" = "/var/empty";
                  };
                  # Explicit domain override + alias:
                  services.hello = {
                    enable = true;
                    description = "hello (tcp, explicit domain)";
                    domain = "hello.example.com";
                    aliases = [ "example.com" ];
                    exec = [ "/run/current-system/sw/bin/true" ];
                    listen = { type = "tcp"; port = 9000; };
                  };
                  # Internal-only (no vhost, no DNS):
                  services.worker = {
                    enable = true;
                    public = false;
                    exec = [ "/run/current-system/sw/bin/true" ];
                    listen = { type = "tcp"; port = 9001; };
                  };
                };
              }
            )
          ];
        };

        # All pure-eval: attrNames doesn't force unit values, and deriveRecords
        # is pure Nix (no derivation), so no Linux build is triggered.
        smokeFacts = {
          units = builtins.attrNames smokeHost.config.systemd.services;
          vhosts = builtins.attrNames smokeHost.config.services.caddy.virtualHosts;
          desired = vacationvmLib.deriveRecords smokeHost.config.vacationvm;
          failedAssertions =
            map (a: a.message) (builtins.filter (a: !a.assertion) smokeHost.config.assertions);
        };

        # Pure-eval checks of the lib helpers; failure aborts evaluation.
        libChecks = [
          (vacationvmLib.splitDomain { domain = "blog.fere.me"; } == { apex = "fere.me"; sub = "blog"; })
          (vacationvmLib.splitDomain { domain = "fere.me"; } == { apex = "fere.me"; sub = ""; })
          (vacationvmLib.splitDomain { domain = "a.b.fere.me"; } == { apex = "fere.me"; sub = "a.b"; })
          (
            vacationvmLib.recordsForApp { publicIp4 = "1.2.3.4"; ttl = 600; } {
              domain = "x.fere.me";
              aliases = [ ];
              extraDnsRecords = [ ];
            }
            == [ { apex = "fere.me"; name = "x"; type = "A"; content = "1.2.3.4"; ttl = 600; } ]
          )
        ];
      in
      {
        packages = {
          vacationvm-dns = dnsPkg;
          register-host = registerHost;
          default = dnsPkg;
        };

        apps.register-host = {
          type = "app";
          program = "${registerHost}/bin/vacationvm-register-host";
        };

        devShells.default = pkgs.mkShell {
          packages = [
            dnsPkg
            pkgs.colmena
            pkgs.python3
            pkgs.age
            pkgs.jq
            pkgs.openssh
            pkgs.nixpkgs-fmt
          ];
          shellHook = ''
            echo "[vacationvm] dev shell"
            echo "  python3 -m unittest discover -s dns/tests   # reconciler tests"
            echo "  nix flake check                             # full checks"
          '';
        };

        checks = {
          # Builds the reconciler AND runs its unittest suite in checkPhase.
          vacationvm-dns = dnsPkg;

          # Force module evaluation of a representative host; dump the shape and
          # fail on any unmet vacationvm assertion.
          module-smoke = pkgs.runCommand "vacationvm-module-smoke"
            {
              facts = builtins.toJSON smokeFacts;
              passthru = { };
            }
            ''
              printf '%s\n' "$facts" > "$out"
              ${lib.optionalString (smokeFacts.failedAssertions != [ ]) ''
                echo "module assertions failed: ${builtins.concatStringsSep "; " smokeFacts.failedAssertions}" >&2
                exit 1
              ''}
              # Sanity: the reconcile unit and the app units must exist, and the
              # tenant-derived vhost must be present.
              for u in vacationvm-wyrm vacationvm-hello vacationvm-worker vacationvm-dns-reconcile; do
                grep -q "\"$u\"" "$out" || { echo "missing unit $u" >&2; exit 1; }
              done
              grep -q "wyrm.sweater.vac.example.com" "$out" || { echo "missing tenant-derived vhost" >&2; exit 1; }
            '';

          lib-eval =
            if builtins.all (x: x) libChecks then
              pkgs.runCommand "vacationvm-lib-eval" { } "echo ok > $out"
            else
              throw "vacationvm lib-eval: a helper produced an unexpected value";
        };

        formatter = pkgs.nixpkgs-fmt;
      }
    )
    // {
      # ── System-independent outputs ──────────────────────────────────────
      nixosModules.vacationvm = import ./modules/fleet.nix;
      nixosModules.default = import ./modules/fleet.nix;

      lib = vacationvmLib;

      templates = {
        hive = {
          path = ./templates/hive;
          description = "An operator hive: colocate services on one NixOS box and `colmena apply`.";
        };
        service = {
          path = ./templates/service;
          description = "A new vacationvm-style service shipping nixosModules + vacationvm app metadata.";
        };
        default = {
          path = ./templates/hive;
          description = "Alias for the hive template.";
        };
      };
    };
}
