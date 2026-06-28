# Adding a service

There are two ways a service joins a fleet. Prefer the first; use the second for
services that only ship a package.

## Path A — the service ships a vacationvm module (preferred)

The service's flake exposes `nixosModules.default` that sets run-time defaults
under `vacationvm.services.<name>` and leaves it **disabled**. Adopting it is
then two lines in the hive.

In the service repo (`nix flake init -t github:cognivore/vacationvm#service`):

```nix
# nix/vacationvm-module.nix
self:
{ pkgs, lib, ... }:
let pkg = self.packages.${pkgs.stdenv.hostPlatform.system}.default; in
{
  config.vacationvm.services.hello-vvm = {
    package = lib.mkDefault pkg;
    exec = lib.mkDefault [ "${pkg}/bin/hello-vvm" ];
    environment.VVM_HELLO_SOCKET = lib.mkDefault "/run/vacationvm-hello-vvm/sock";
  };
}
```

```nix
# flake.nix
nixosModules.default = import ./nix/vacationvm-module.nix self;
```

In the hive:

```nix
# flake.nix inputs
inputs.hello-vvm.url = "github:you/hello-vvm";
# hostModules
inputs.hello-vvm.nixosModules.default
# host config
vacationvm.services.hello-vvm = { enable = true; domain = "hi.fere.me"; };
```

The service module **does not depend on the vacationvm flake** — it only *sets*
options the fleet module declares — so services stay decoupled from the
framework version.

## Path B — a package-only service (adapter in the hive)

For a service that only exposes `packages.default` (like annexwyrm), write a
short adapter in your hive mapping the package onto the schema. This is the full
worked example from `templates/hive/services/annexwyrm.nix`:

```nix
{ pkgs, inputs, ... }:
let
  pkg = inputs.annexwyrm.packages.${pkgs.stdenv.hostPlatform.system}.default;
  socket = "/run/vacationvm-annexwyrm/sock";
  dataDir = "/var/lib/vacationvm-annexwyrm";
in {
  vacationvm.services.annexwyrm = {
    enable = true;
    package = pkg;
    domain = "wyrm.fere.me";
    listen = { type = "unix"; socket = socket; };
    exec = [ "${pkg}/bin/annexwyrm" "serve" ];
    preStart = [ [ "${pkg}/bin/annexwyrm" "init" dataDir ] ];
    environment = {
      ANNEXWYRM_DOMAIN = "wyrm.fere.me";
      ANNEXWYRM_BASE_URL = "https://wyrm.fere.me";
      ANNEXWYRM_SOCKET = socket;
      ANNEXWYRM_DATA = dataDir;
      # …identity vars…
    };
    environmentSecrets.ANNEXWYRM_PASSWORD = "annexwyrm-password";
    packages = [ pkgs.rclone pkgs.git-annex pkgs.git-annex-remote-rclone ];
    staticFiles."/static/*" = "${pkg}/share/annexwyrm/static";
    maxBodySize = "4GB";
  };
}
```

## The app schema (cheat-sheet)

| Field | Meaning |
|---|---|
| `enable` | run this app |
| `package` | the service derivation (assets served from `${package}/share`) |
| `domain` / `aliases` | explicit public FQDN(s) → Caddy vhost + TLS + DNS A/AAAA |
| `subdomain` / `public` | tenant scheme: `<subdomain>.<tenant>.<baseDomain>` when `public` and no explicit `domain` (subdomain defaults to the app name; `public=false` = internal) |
| `listen.{type,socket,port,host}` | `unix` (socket) or `tcp` (loopback host:port) |
| `exec` | ExecStart argv (the long-running command) |
| `preStart` | argv list run before exec, sharing the secret env (init/migrate) |
| `environment` | static env vars |
| `environmentSecrets` | `ENV → agenix stem`; decrypted **value** exported at start |
| `secretFiles` | `ENV → agenix stem`; env set to the decrypted file **path** |
| `environmentFiles` | agenix stems whose content is `KEY=value`, via EnvironmentFile |
| `provisionFiles` | `destPath → { secret, mode }`; install a decrypted secret to a path at start ("secret to be provisioned", e.g. an admin `rclone.conf`) |
| `packages` | extra runtime deps on the unit PATH (tools the daemon shells to) |
| `staticFiles` | `"/path/*" → dir` Caddy static mounts |
| `maxBodySize` | Caddy upload cap (default `1GB`) |
| `extraDnsRecords` | extra DNS records for this app (`{name|fqdn,type,content,ttl?}`) |
| `caddyExtra` | extra Caddyfile directives inside the site block |
| `hardening` | toggle the systemd sandbox (default true) |
| `extraServiceConfig` | escape hatch merged into the unit's `serviceConfig` |

Full descriptions live in `modules/app-options.nix`.

## Checklist for "in the style of annexwyrm"

- Single binary; listens on a **Unix socket** (path from an env var) or a
  loopback TCP port. Nothing binds a public port itself.
- Configurable entirely by **environment variables** — no config file baked into
  the image, no interactive setup.
- Idempotent `init` (safe to run on every start) if it needs schema/keys.
- Honours `umask` when creating its socket (so Caddy in the app group can reach
  it). Most runtimes do this by default.
- Ships either a vacationvm `nixosModules.default` (Path A) or just a clean
  `packages.default` (Path B).
