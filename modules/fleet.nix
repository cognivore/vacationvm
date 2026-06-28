# The vacationvm fleet NixOS module — `vacationvm.*`.
#
# Import it on a host and you get: a sandboxed systemd unit per declared app,
# a Caddy front with automatic TLS and a vhost per public domain, and a
# stateless Porkbun DNS reconciler that points every domain at this box. The
# whole public surface of one medium NixOS machine, declared in one attrset.
#
# Secrets are agenix (`age.secrets.*`) — the host imports
# `agenix.nixosModules.default` and its SSH host key is the decryption
# identity. App secrets are resolved at service start and never touch the Nix
# store; Porkbun credentials reach the reconciler via systemd LoadCredential.
#
# This module is `pkgs`-aware but provider-agnostic about *how* a service is
# built: apps reference store paths (their `package`), wired in by the
# service's own flake module or by a thin adapter in the hive.

{ config, lib, pkgs, ... }:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    mkMerge
    mkDefault
    types
    literalExpression
    optional
    optionals
    optionalString
    optionalAttrs
    filterAttrs
    mapAttrs'
    mapAttrsToList
    nameValuePair
    concatMapStrings
    concatStringsSep
    listToAttrs
    unique
    escapeShellArgs
    ;

  vlib = import ../lib { inherit lib; };
  cfg = config.vacationvm;

  # Only enabled apps matter for unit/vhost/DNS generation.
  enabledApps = filterAttrs (_: a: a.enable) cfg.services;
  # Each app carries its attr name (`_name`) and its *resolved* effective domain
  # (explicit `domain`, else the tenant-derived `<sub>.<tenant>.<baseDomain>`).
  appDomain = vlib.effectiveDomain { inherit (cfg) tenant baseDomain; };
  enabledList = mapAttrsToList (n: a: a // { _name = n; domain = appDomain (a // { _name = n; }); }) enabledApps;
  appsWithDomain = builtins.filter (a: a.domain != null) enabledList;
  unixApps = builtins.filter (a: a.listen.type == "unix") enabledList;

  # ── Desired DNS document (Nix -> JSON in the store) ───────────────────────
  desiredDoc = vlib.desiredDocument cfg;
  desiredJson = pkgs.writeText "vacationvm-dns-desired.json" (builtins.toJSON desiredDoc);

  dnsPkg = cfg.dns.package;

  # ── Secret collection ─────────────────────────────────────────────────────
  # Every (stem, owner, group) an enabled app needs at runtime. `environment-
  # Secrets`/`secretFiles` are read by the app user (in the start wrapper), so
  # they must be owned by it; `environmentFiles` likewise. Deduped by stem,
  # first app (sorted) wins ownership.
  appSecretRefs = lib.concatMap (a:
    let
      stems =
        (lib.attrValues a.environmentSecrets)
        ++ a.environmentFiles
        ++ (lib.attrValues a.secretFiles)
        ++ (map (pf: pf.secret) (lib.attrValues a.provisionFiles));
    in
    map (stem: { inherit stem; owner = a.user; group = a.group; }) stems
  ) enabledList;

  dedupSecretRefs =
    let
      step = acc: ref: if acc ? ${ref.stem} then acc else acc // { ${ref.stem} = ref; };
    in
    builtins.attrValues (builtins.foldl' step { } appSecretRefs);

  secretAgePath = stem: cfg.secretsDir + "/${stem}.age";
  secretDeclared = stem: cfg.secretsDir != null && builtins.pathExists (secretAgePath stem);

  appSecrets = listToAttrs (map (ref: nameValuePair ref.stem {
    file = secretAgePath ref.stem;
    owner = ref.owner;
    group = ref.group;
    mode = "0400";
  }) (builtins.filter (ref: secretDeclared ref.stem) dedupSecretRefs));

  # Porkbun credentials: explicit file paths win; otherwise fall back to
  # agenix secrets named porkbun-api-key / porkbun-secret-key under secretsDir.
  porkbunApiPath =
    if cfg.dns.porkbun.apiKeyFile != null then cfg.dns.porkbun.apiKeyFile
    else if secretDeclared "porkbun-api-key" then config.age.secrets."porkbun-api-key".path
    else null;
  porkbunSecretPath =
    if cfg.dns.porkbun.secretKeyFile != null then cfg.dns.porkbun.secretKeyFile
    else if secretDeclared "porkbun-secret-key" then config.age.secrets."porkbun-secret-key".path
    else null;

  porkbunAgenixSecrets = optionalAttrs (cfg.dns.enable) (
    (optionalAttrs (cfg.dns.porkbun.apiKeyFile == null && secretDeclared "porkbun-api-key") {
      "porkbun-api-key" = { file = secretAgePath "porkbun-api-key"; mode = "0400"; };
    })
    // (optionalAttrs (cfg.dns.porkbun.secretKeyFile == null && secretDeclared "porkbun-secret-key") {
      "porkbun-secret-key" = { file = secretAgePath "porkbun-secret-key"; mode = "0400"; };
    })
  );

  # The complete set of agenix secrets the module declares (empty when no app
  # or Porkbun secrets are in use). Assigned unconditionally to `age.secrets`
  # below — see the note there on why it must not be config-gated.
  allAgeSecrets = appSecrets // porkbunAgenixSecrets;

  # ── Per-app start wrapper ─────────────────────────────────────────────────
  # Exports resolved secrets, runs preStart commands, then exec's the daemon —
  # all in one process so init and serve share the secret environment, exactly
  # like annexwyrm's serveScript. Secrets are `cat`'d from their agenix paths
  # so they never enter the unit's Environment (invisible to `systemctl show`).
  mkStartScript = a:
    let
      envSecretExports = mapAttrsToList (var: stem:
        ''export ${var}="$(${pkgs.coreutils}/bin/cat ${lib.escapeShellArg config.age.secrets.${stem}.path})"''
      ) a.environmentSecrets;
      fileSecretExports = mapAttrsToList (var: stem:
        ''export ${var}=${lib.escapeShellArg config.age.secrets.${stem}.path}''
      ) a.secretFiles;
      # "Secrets to be provisioned": install each decrypted secret to its
      # destination path (creating parents) before preStart runs.
      provisionLines = mapAttrsToList (dest: pf:
        ''${pkgs.coreutils}/bin/install -D -m ${pf.mode} ${lib.escapeShellArg config.age.secrets.${pf.secret}.path} ${lib.escapeShellArg dest}''
      ) a.provisionFiles;
      preStartLines = map escapeShellArgs a.preStart;
    in
    pkgs.writeShellScript "${a.unitName}-start" ''
      set -euo pipefail
      ${concatStringsSep "\n" envSecretExports}
      ${concatStringsSep "\n" fileSecretExports}
      ${concatStringsSep "\n" provisionLines}
      ${concatStringsSep "\n" preStartLines}
      exec ${escapeShellArgs a.exec}
    '';

  hardeningConfig = {
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    RestrictNamespaces = true;
    LockPersonality = true;
    SystemCallArchitectures = "native";
  };

  mkAppService = a: nameValuePair a.unitName {
    description = "vacationvm app: ${a.description}";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ] ++ a.after;
    wants = [ "network-online.target" ] ++ a.wants;
    path = optional (a.package != null) a.package ++ a.packages;
    environment = { HOME = a.stateDir; } // a.environment;
    serviceConfig = mkMerge [
      {
        Type = "simple";
        ExecStart = "${mkStartScript a}";
        User = a.user;
        Group = a.group;
        SupplementaryGroups = a.extraGroups;
        StateDirectory = a.unitName;
        StateDirectoryMode = "0750";
        RuntimeDirectory = a.unitName;
        RuntimeDirectoryMode = "0750";
        # 0007 so a daemon honouring umask creates its Unix socket group-rw,
        # which is how Caddy (added to the app's group) reaches it.
        UMask = "0007";
        Restart = "on-failure";
        RestartSec = "2s";
      }
      (mkIf a.hardening hardeningConfig)
      a.extraServiceConfig
    ];
  };

  # ── Per-app Caddy vhost(s) ────────────────────────────────────────────────
  upstreamOf = a:
    if a.listen.type == "unix"
    then "unix/${a.listen.socket}"
    else "${a.listen.host}:${toString a.listen.port}";

  # Static mounts as `handle_path` blocks (each terminal for its path prefix).
  staticHandlers = a: concatMapStrings (pattern: ''
    handle_path ${pattern} {
        root * ${a.staticFiles.${pattern}}
        file_server
    }
  '') (builtins.attrNames a.staticFiles);

  forwardHeaderLines = a: optionalString a.forwardHeaders ''
            header_up X-Forwarded-Host {host}
            header_up X-Forwarded-Proto {scheme}
  '';

  # The catch-all proxy lives inside `handle {}` so it is mutually exclusive
  # with the static `handle_path` routes above and evaluation order is
  # unambiguous (Caddy is whitespace-insensitive; readability aside, this is
  # the canonical static-assets-plus-proxy shape).
  siteBody = a: ''
    encode zstd gzip
    request_body {
        max_size ${a.maxBodySize}
    }
    ${staticHandlers a}handle {
        reverse_proxy ${upstreamOf a} {
    ${forwardHeaderLines a}        transport http {
                versions 1.1
            }
        }
    }
    ${optionalString (a.caddyExtra != "") a.caddyExtra}'';

  mkVhosts = a:
    listToAttrs (map (host: nameValuePair host { extraConfig = siteBody a; })
      ([ a.domain ] ++ a.aliases));

  caddyVirtualHosts = mkMerge (map mkVhosts appsWithDomain);

  # Caddy must be in each unix app's group to reach its socket.
  caddyExtraGroups = unique (map (a: a.group) unixApps);

  # ── DNS reconcile units ───────────────────────────────────────────────────
  pruneFlag = if cfg.dns.prune then "--prune" else "--no-prune";
  reconcileScript = pkgs.writeShellScript "vacationvm-dns-reconcile" ''
    set -euo pipefail
    exec ${dnsPkg}/bin/vacationvm-dns reconcile \
      --desired ${desiredJson} \
      --creds-dir "$CREDENTIALS_DIRECTORY" \
      ${pruneFlag}
  '';
  planScript = pkgs.writeShellScript "vacationvm-dns-plan" ''
    set -euo pipefail
    exec ${dnsPkg}/bin/vacationvm-dns plan \
      --desired ${desiredJson} \
      --creds-dir "$CREDENTIALS_DIRECTORY" \
      --verbose
  '';
  dnsCredentials = [
    "porkbun-api-key:${toString porkbunApiPath}"
    "porkbun-secret-key:${toString porkbunSecretPath}"
  ];
  dnsHardening = {
    DynamicUser = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    NoNewPrivileges = true;
    # AF_UNIX is needed for name resolution via systemd-resolved / nss before
    # the HTTPS call to Porkbun goes out over AF_INET{,6}.
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
  };

  appOptions = import ./app-options.nix { inherit lib; };
in
{
  options.vacationvm = {
    enable = mkEnableOption "the vacationvm fleet (colocated services + Caddy + Porkbun DNS)";

    acmeEmail = mkOption {
      type = types.str;
      example = "ops@fere.me";
      description = "Email registered with Let's Encrypt for automatic TLS issuance.";
    };

    publicIp4 = mkOption {
      type = types.str;
      example = "46.62.199.15";
      description = "This host's public IPv4. Every app domain gets an A record pointing here.";
    };

    publicIp6 = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "2a01:4f9:c012:abcd::1";
      description = "This host's public IPv6 (optional). When set, every app domain also gets an AAAA record.";
    };

    tenant = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "sweater";
      description = ''
        The tenant label in the default domain scheme
        `<app>.<tenant>.<baseDomain>` (e.g. tenant `sweater` + baseDomain
        `vac.fere.me` → `wyrm.sweater.vac.fere.me`). Apps may override with an
        explicit `domain`.
      '';
    };

    baseDomain = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "vac.fere.me";
      description = ''
        The base zone under the tenant in the default domain scheme. With
        `tenant`, a public app named `wyrm` gets `wyrm.<tenant>.<baseDomain>`.
        DNS records are created under the registrable apex inferred from the
        FQDN (e.g. `fere.me`).
      '';
    };

    secretsDir = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = literalExpression "./secrets";
      description = ''
        Directory holding agenix `<name>.age` files. App `environmentSecrets`/
        `secretFiles`/`environmentFiles`/`provisionFiles` and (optionally) the
        Porkbun credentials are resolved from here and auto-wired into
        `age.secrets`.
      '';
    };

    services = mkOption {
      type = types.attrsOf (types.submodule appOptions);
      default = { };
      description = "The colocated apps, keyed by name. See `vacationvm.services.<name>`.";
    };

    caddy = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Run Caddy as the TLS-terminating reverse proxy for all app domains.";
      };
      globalConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Extra Caddy global options (the top-of-file block).";
      };
      package = mkOption {
        type = types.package;
        default = pkgs.caddy;
        defaultText = literalExpression "pkgs.caddy";
        description = "Caddy package to use.";
      };
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open 80/443 in the NixOS firewall for Caddy.";
    };

    dns = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Reconcile Porkbun DNS from the app declarations at activation and on a timer.";
      };
      provider = mkOption {
        type = types.enum [ "porkbun" ];
        default = "porkbun";
        description = "DNS provider. Only Porkbun is implemented today.";
      };
      package = mkOption {
        type = types.package;
        default = pkgs.callPackage ../dns/package.nix { };
        defaultText = literalExpression "pkgs.callPackage ./dns/package.nix { }";
        description = "The vacationvm-dns reconciler package.";
      };
      ttl = mkOption {
        type = types.int;
        default = 600;
        description = "Default record TTL (seconds). Porkbun's minimum is 600.";
      };
      marker = mkOption {
        type = types.str;
        default = "vacationvm";
        description = ''
          Ownership marker stamped into each managed record's Porkbun `notes`.
          The reconciler only ever deletes records bearing this marker, so
          hand-made records are safe. Change it to isolate two fleets sharing
          one Porkbun account.
        '';
      };
      prune = mkOption {
        type = types.bool;
        default = true;
        description = "Delete owned (marker-bearing) records that no app declares any more.";
      };
      reconcileOnActivation = mkOption {
        type = types.bool;
        default = true;
        description = "Run the reconciler as part of `colmena apply` / `nixos-rebuild switch`.";
      };
      extraRecords = mkOption {
        type = types.listOf (types.attrsOf types.anything);
        default = [ ];
        example = literalExpression ''[ { fqdn = "fere.me"; type = "TXT"; content = "v=spf1 -all"; } ]'';
        description = "Fleet-wide DNS records not tied to a single app (e.g. apex, SPF, verification).";
      };
      timer = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Also re-reconcile on a timer, healing any out-of-band drift.";
        };
        onCalendar = mkOption {
          type = types.str;
          default = "hourly";
          description = "systemd OnCalendar expression for the periodic reconcile.";
        };
      };
      porkbun = {
        apiKeyFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = literalExpression "config.age.secrets.porkbun-api-key.path";
          description = "Path to the Porkbun API key on the host. Defaults to the agenix `porkbun-api-key` secret if present in secretsDir.";
        };
        secretKeyFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = literalExpression "config.age.secrets.porkbun-secret-key.path";
          description = "Path to the Porkbun secret key on the host. Defaults to the agenix `porkbun-secret-key` secret if present in secretsDir.";
        };
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      # ── Assertions ────────────────────────────────────────────────────────
      assertions =
        [
          {
            assertion = cfg.acmeEmail != "";
            message = "vacationvm: set vacationvm.acmeEmail for ACME/Let's Encrypt.";
          }
          {
            assertion = !cfg.dns.enable || (porkbunApiPath != null && porkbunSecretPath != null);
            message = ''
              vacationvm.dns is enabled but Porkbun credentials are unresolved.
              Set vacationvm.dns.porkbun.{apiKeyFile,secretKeyFile} (e.g. to
              config.age.secrets.porkbun-api-key.path), or drop
              porkbun-api-key.age + porkbun-secret-key.age into
              vacationvm.secretsDir.
            '';
          }
        ]
        ++ mapAttrsToList (n: a: {
          assertion = a.exec != [ ];
          message = "vacationvm.services.${n}: `exec` is empty — set the ExecStart argv.";
        }) enabledApps
        ++ mapAttrsToList (n: a: {
          assertion = a.listen.type != "tcp" || a.listen.port != null;
          message = "vacationvm.services.${n}: listen.type = \"tcp\" requires listen.port.";
        }) enabledApps;

      # ── App users / groups ────────────────────────────────────────────────
      # Caddy is folded in here (not in a second `users.users` block, which
      # would be a duplicate attribute) so it joins each unix app's group.
      users.users = mkMerge [
        (mapAttrs' (n: a: nameValuePair a.user {
          isSystemUser = true;
          group = a.group;
          description = "vacationvm app ${n}";
        }) enabledApps)
        (mkIf cfg.caddy.enable { caddy.extraGroups = caddyExtraGroups; })
      ];

      users.groups = listToAttrs (map (a: nameValuePair a.group { }) enabledList);

      # ── App units ─────────────────────────────────────────────────────────
      systemd.services = listToAttrs (map mkAppService enabledList);

      # ── Caddy ─────────────────────────────────────────────────────────────
      services.caddy = mkIf cfg.caddy.enable {
        enable = true;
        package = cfg.caddy.package;
        email = cfg.acmeEmail;
        globalConfig = cfg.caddy.globalConfig;
        virtualHosts = caddyVirtualHosts;
      };

      networking.firewall = mkIf (cfg.openFirewall && cfg.caddy.enable) {
        allowedTCPPorts = [ 80 443 ];
      };
    }

    # ── agenix secrets ────────────────────────────────────────────────────
    # Declared UNCONDITIONALLY (an empty attrset when no app/Porkbun secrets
    # are in use). It must not be gated on a config-derived value: gating the
    # presence of an *undeclared* option (which `age` is, until the host
    # imports `agenix.nixosModules.default`) on `config` forces
    # `_module.freeformType`, which needs `config` — an infinite recursion. By
    # always defining it, the key is static and the value stays lazy; agenix is
    # a hard requirement of the fleet (its whole secret story), so the host
    # imports it and the `age` option exists.
    {
      age.secrets = allAgeSecrets;
    }

    # ── DNS reconciler ──────────────────────────────────────────────────────
    (mkIf cfg.dns.enable {
      systemd.services.vacationvm-dns-reconcile = {
        description = "Reconcile Porkbun DNS from vacationvm declarations";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = optional cfg.dns.reconcileOnActivation "multi-user.target";
        # Re-run whenever the desired set or the reconciler itself changes.
        restartTriggers = [ desiredJson dnsPkg ];
        serviceConfig = mkMerge [
          {
            Type = "oneshot";
            ExecStart = "${reconcileScript}";
            LoadCredential = dnsCredentials;
          }
          dnsHardening
        ];
      };

      # Manual, read-only preview: `systemctl start vacationvm-dns-plan` then
      # `journalctl -u vacationvm-dns-plan`.
      systemd.services.vacationvm-dns-plan = {
        description = "Preview (dry-run) the Porkbun DNS plan";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = mkMerge [
          {
            Type = "oneshot";
            ExecStart = "${planScript}";
            LoadCredential = dnsCredentials;
          }
          dnsHardening
        ];
      };

      systemd.timers.vacationvm-dns-reconcile = mkIf cfg.dns.timer.enable {
        description = "Periodic Porkbun DNS reconcile";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.dns.timer.onCalendar;
          Persistent = true;
          RandomizedDelaySec = "120";
        };
      };

      environment.systemPackages = [ dnsPkg ];
    })
  ]);
}
