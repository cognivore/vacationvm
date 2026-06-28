# The per-app submodule schema: `vacationvm.services.<name>`.
#
# One entry describes how to RUN one colocated service and how to EXPOSE it
# (Caddy vhost + DNS). It is deliberately declarative and uniform so an LLM or
# operator can add a service by filling in a handful of obvious fields, and so
# the fleet module can turn every app into a sandboxed systemd unit the same
# way.
#
# A service flake usually ships a module that sets the run-time fields
# (`package`, `exec`, `listen`, `preStart`, `staticFiles`, `environment`) with
# `vacationvm.lib.mkApp`, leaving the operator to set only `enable`, `domain`
# and secrets in the hive.

{ lib }:

{ name, config, ... }:

let
  inherit (lib) mkOption mkEnableOption types literalExpression;
  defaultUser = "vacationvm-${name}";
in
{
  options = {
    enable = mkEnableOption "the ${name} app on this vacationvm host";

    package = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = ''
        The service's package. Optional — `exec`/`preStart` are argv lists and
        may reference any store path — but conventionally set so static assets
        can be served from `''${package}/share`.
      '';
    };

    description = mkOption {
      type = types.str;
      default = name;
      description = "Human description, used as the systemd unit Description.";
    };

    # ── Exposure ──────────────────────────────────────────────────────────
    domain = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "wyrm.fere.me";
      description = ''
        Explicit public FQDN this app answers on. Overrides the tenant-derived
        default. When null, the effective domain is
        `<subdomain>.<tenant>.<baseDomain>` if `public` and the fleet sets
        `tenant`+`baseDomain`, otherwise the app is not exposed (no vhost, no
        DNS). Caddy serves the effective domain with automatic TLS and the DNS
        reconciler points it (A/AAAA) at the host's public IP.
      '';
    };

    subdomain = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "wyrm";
      description = ''
        Label used to build the tenant-derived domain
        `<subdomain>.<tenant>.<baseDomain>`. Defaults to the app's attribute
        name. Ignored when `domain` is set explicitly.
      '';
    };

    public = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to expose this app publicly via the tenant-derived domain when
        no explicit `domain` is set. Set false for internal-only apps.
      '';
    };

    aliases = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = literalExpression ''[ "fere.me" ]'';
      description = "Extra FQDNs that should also serve this app (each gets a vhost + A/AAAA record).";
    };

    listen = {
      type = mkOption {
        type = types.enum [ "unix" "tcp" ];
        default = "unix";
        description = ''
          How the daemon listens. "unix" (the annexwyrm style) is preferred:
          Caddy proxies to a Unix socket and nothing binds a public port.
          "tcp" proxies to a loopback `host:port`.
        '';
      };
      socket = mkOption {
        type = types.str;
        default = "/run/vacationvm-${name}/sock";
        description = "Unix socket path (when listen.type = \"unix\").";
      };
      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Loopback host Caddy proxies to (when listen.type = \"tcp\").";
      };
      port = mkOption {
        type = types.nullOr types.port;
        default = null;
        description = "Loopback port the daemon binds (when listen.type = \"tcp\").";
      };
    };

    # ── Run ───────────────────────────────────────────────────────────────
    exec = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = literalExpression ''[ "''${cfg.package}/bin/annexwyrm" "serve" ]'';
      description = "ExecStart argv (the long-running command). Required when enabled.";
    };

    preStart = mkOption {
      type = types.listOf (types.listOf types.str);
      default = [ ];
      example = literalExpression ''[ [ "''${cfg.package}/bin/annexwyrm" "init" "/var/lib/vacationvm-annexwyrm" ] ]'';
      description = ''
        Commands run (in order) before `exec`, inside the same start wrapper so
        they see the same environment AND the resolved secrets. Use for
        idempotent init / migrations.
      '';
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Static (non-secret) environment variables for the unit.";
    };

    environmentSecrets = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = literalExpression ''{ ANNEXWYRM_PASSWORD = "annexwyrm-password"; }'';
      description = ''
        Map of ENV_VAR -> agenix secret name (a `<name>.age` under
        `vacationvm.secretsDir`). The decrypted *value* is read at service start
        and exported, never landing in the Nix store or in `systemctl show`.
      '';
    };

    environmentFiles = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        agenix secret names whose decrypted content is already in `KEY=value`
        form; loaded via systemd `EnvironmentFile` (visible to preStart + exec).
      '';
    };

    secretFiles = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = literalExpression ''{ TOKEN_FILE = "api-token"; }'';
      description = ''
        Map of ENV_VAR -> agenix secret name. The env var is set to the
        decrypted file's *path* (for daemons that read a secret from a file).
      '';
    };

    provisionFiles = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          secret = mkOption {
            type = types.str;
            description = "agenix secret name (a `<name>.age` under `vacationvm.secretsDir`).";
          };
          mode = mkOption {
            type = types.str;
            default = "0600";
            description = "Mode of the installed file.";
          };
        };
      });
      default = { };
      example = literalExpression ''
        { "/var/lib/vacationvm-wyrm/admin-rclone.conf" = { secret = "wyrm-rclone-conf"; mode = "0400"; }; }
      '';
      description = ''
        "Secrets to be provisioned": decrypted agenix secrets *installed to a
        path* (under the app's writable state) at every service start, before
        `preStart`. Use for config files a daemon (or a `preStart` step)
        consumes — e.g. an admin `rclone.conf` that `preStart` loads into the
        app's own secret store. Keyed by destination path. (Distinct from
        `environmentSecrets`/`secretFiles`, which inject *values/paths* as env.)
      '';
    };

    # ── Filesystem / identity ─────────────────────────────────────────────
    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/vacationvm-${name}";
      description = "Persistent state dir (systemd StateDirectory). Also the unit's HOME.";
    };

    user = mkOption {
      type = types.str;
      default = defaultUser;
      description = "System user the daemon runs as.";
    };

    group = mkOption {
      type = types.str;
      default = defaultUser;
      description = "Primary group; Caddy is added to it so it can reach the Unix socket.";
    };

    extraGroups = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Supplementary groups for the daemon user.";
    };

    packages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      example = literalExpression "[ pkgs.rclone pkgs.git-annex ]";
      description = "Extra runtime dependencies placed on the unit's PATH (e.g. tools the daemon shells out to).";
    };

    # ── Caddy front ───────────────────────────────────────────────────────
    staticFiles = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = literalExpression ''{ "/static/*" = "''${cfg.package}/share/annexwyrm/static"; }'';
      description = "Caddy `handle_path` static mounts: URL-path-pattern -> filesystem dir.";
    };

    maxBodySize = mkOption {
      type = types.str;
      default = "1GB";
      description = "Caddy `request_body max_size` — the outer upload cap.";
    };

    forwardHeaders = mkOption {
      type = types.bool;
      default = true;
      description = "Send X-Forwarded-Host/-Proto upstream (apps behind TLS termination usually want this).";
    };

    caddyExtra = mkOption {
      type = types.lines;
      default = "";
      description = "Extra Caddyfile directives injected inside this app's site block.";
    };

    # ── systemd knobs ─────────────────────────────────────────────────────
    hardening = mkOption {
      type = types.bool;
      default = true;
      description = "Apply the standard systemd sandbox (ProtectSystem=strict, NoNewPrivileges, …).";
    };

    after = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra `After=` unit dependencies.";
    };

    wants = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra `Wants=` unit dependencies.";
    };

    extraServiceConfig = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      description = "Escape hatch merged into the unit's `serviceConfig`.";
    };

    extraDnsRecords = mkOption {
      type = types.listOf (types.attrsOf types.anything);
      default = [ ];
      example = literalExpression ''[ { name = "_atproto"; type = "TXT"; content = "did=…"; } ]'';
      description = ''
        Extra DNS records emitted for this app, beyond the A/AAAA for `domain`
        and `aliases`. Each is `{ name | fqdn, type, content, ttl?, apex? }`.
      '';
    };

    # Read-only handle so the fleet module / other modules can refer to the
    # generated unit name without recomputing it.
    unitName = mkOption {
      type = types.str;
      default = "vacationvm-${name}";
      readOnly = true;
      description = "Generated systemd unit name (vacationvm-<name>).";
    };
  };
}
