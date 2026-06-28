# Architecture

vacationvm turns one declaration —

```nix
vacationvm.services.<name> = { enable = true; domain = "x.fere.me"; … };
```

— into four coordinated pieces of running infrastructure. This document
explains each piece and the decisions behind them.

## The control loop

```
flake (source of truth)
   │  colmena apply  (build closure on laptop, push, activate on box)
   ▼
NixOS activation on the box
   ├─▶ systemd: one hardened unit per enabled app
   ├─▶ Caddy:   one vhost per domain, automatic TLS, reverse-proxy to the app
   ├─▶ agenix:  decrypt secrets/*.age using the box's SSH host key → /run/agenix/*
   └─▶ vacationvm-dns-reconcile (oneshot): converge Porkbun to the declared records
```

Everything downstream of the flake is derived; nothing is hand-maintained.

## 1. The app unit (systemd)

For each enabled `vacationvm.services.<name>` the module generates
`vacationvm-<name>.service`:

- Runs as a dedicated system user `vacationvm-<name>` in group `vacationvm-<name>`.
- `StateDirectory=/var/lib/vacationvm-<name>`, `RuntimeDirectory=/run/vacationvm-<name>`.
- `UMask=0007` so a Unix socket the daemon creates is group-accessible — that's
  how Caddy (added to the app's group) reaches it without the socket being
  world-accessible.
- The `ExecStart` is a generated **start wrapper** that (a) exports
  `environmentSecrets` by `cat`-ing their agenix paths, (b) exposes
  `secretFiles` paths, (c) runs `preStart` (e.g. `init`), then (d) `exec`s the
  daemon — all in one process, so init and serve share the secret environment.
  This mirrors annexwyrm's own `serveScript`.
- The standard systemd sandbox (`ProtectSystem=strict`, `NoNewPrivileges`,
  `PrivateTmp`, `RestrictNamespaces`, …), toggleable per app via `hardening`.

Why a per-app named user (not `DynamicUser`)? So agenix can own a secret file
to a stable uid, and so the app's group is a stable handle for the Caddy↔socket
permission.

## 2. The front (Caddy)

`services.caddy` is configured with one virtual host per `domain` (and per
`alias`). Each vhost: `encode`, an upload cap (`request_body max_size`), static
mounts (`handle_path`), and a catch-all `handle { reverse_proxy … }` to the
app's Unix socket (`unix//run/vacationvm-<name>/sock`) or loopback `host:port`.

Caddy does automatic HTTPS (ACME HTTP-01) per domain — no wildcard cert, no DNS
plugin needed. The DNS reconciler ensures the domain resolves to the box before
Caddy needs the cert; Caddy retries until it does.

Why Caddy and a Unix socket? The same reason annexwyrm uses it: Caddy already
does TLS/HTTP-3/ACME/compression well, so the daemon speaks minimal HTTP/1.1
over a socket and stays tiny. See annexwyrm's README, "Why no HTTP server".

## 3. Secrets (agenix)

The box's ed25519 **SSH host key** is the decryption identity. Secrets are
`secrets/<name>.age` files (age-encrypted to that key, committed to the repo).
At activation agenix decrypts them to `/run/agenix/<name>` (tmpfs) with the
ownership the module computed (the app user for app secrets, root for Porkbun
creds). Nothing secret is ever in the world-readable Nix store.

The module auto-declares `age.secrets.<stem>` for every secret an app
references and for the Porkbun credentials, reading the `<stem>.age` files from
`vacationvm.secretsDir`. agenix is a hard dependency of the fleet — see
[secrets.md](secrets.md).

## 4. DNS (stateless Porkbun reconciler)

From the enabled apps' `domain`/`aliases`/`extraDnsRecords` plus
`dns.extraRecords`, the module derives a desired record set (pure Nix,
`lib/default.nix`) and writes it to a JSON file in the store. A oneshot unit,
`vacationvm-dns-reconcile`, runs the Python reconciler at every activation (and
on a timer), which fetches the live Porkbun zone, diffs, and converges.

It keeps **no state**: the diff is recomputed live each run, and pruning is made
safe by an ownership marker written into Porkbun's `notes` field — see
[dns.md](dns.md).

## Why colmena

colmena gives declarative multi-target deploys (`apply`, `--on`, tags,
`buildOnTarget`) on top of plain `nixosSystem`. A vacationvm host is an ordinary
NixOS config plus a `deployment` block; nothing here is colmena-specific except
that block, so you can also `nixos-rebuild --flake .#wyrm` or grow to many
hosts later.

## Data-flow summary

| Input (declared) | Derived artifact | Runtime effect |
|---|---|---|
| `services.<n>.exec/preStart/env/secrets` | start wrapper + unit | the daemon runs, sandboxed |
| `services.<n>.domain/aliases/staticFiles` | Caddy vhost | TLS + reverse proxy |
| `services.<n>.domain` + `publicIp4/6` | desired DNS JSON | A/AAAA at Porkbun |
| `secrets/*.age` + `secretsDir` | `age.secrets.*` | `/run/agenix/*` on the box |
