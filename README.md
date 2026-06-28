# vacationvm

> Set up your services, then go on vacation. One medium NixOS box, many small
> services, deployed with `colmena apply` — fully declarative, no imperative
> state, automatic TLS, automatic DNS.

When you write small services in the style of [annexwyrm] — memory-efficient,
single-binary, speaking HTTP over a Unix socket — you can fit **a lot** of them
on one medium machine. vacationvm is the declarative substrate for doing exactly
that: each service is developed in its own repo, pulled in as a flake input,
and *just gets launched and assigned a DNS record*.

```
            ┌─────────────────────────  one NixOS box  ──────────────────────────┐
            │                                                                     │
   :443 ───▶│  Caddy  ──unix socket──▶  vacationvm-annexwyrm.service  (sandboxed)  │
   (TLS,    │    │    ──unix socket──▶  vacationvm-hello-vvm.service   (sandboxed)  │
    ACME)   │    │    ──127.0.0.1:n──▶  vacationvm-someapi.service     (sandboxed)  │
            │    └─ automatic certs per domain                                    │
            │                                                                     │
            │  vacationvm-dns-reconcile.oneshot ──▶ Porkbun  (stateless, on every  │
            │                                                 deploy + on a timer) │
            └─────────────────────────────────────────────────────────────────────┘
                       ▲                                   ▲
              colmena apply (from your laptop)     agenix secrets (decrypted by
                                                    the box's SSH host key)
```

## The whole thing in one screen

A *hive* (your operator repo) declares a box and the services on it:

```nix
# flake.nix — inputs: nixpkgs, vacationvm, agenix, colmena, + your service flakes
vacationvm.services.annexwyrm = {
  enable = true;
  domain = "wyrm.fere.me";              # ← Caddy vhost + TLS + DNS A record
  environmentSecrets.ANNEXWYRM_PASSWORD = "annexwyrm-password";  # ← agenix
  # ...exec / socket / static come from the service or a 25-line adapter
};
```

```bash
colmena apply --on wyrm
```

On activation the box builds and starts each app as a hardened systemd unit,
Caddy fetches certificates, and the DNS reconciler converges Porkbun to match
your declarations. Re-run any time — it's idempotent.

## Principles

- **No imperative state, anywhere.** No `terraform apply` with a state file, no
  hand-edited nginx, no `certbot` cron, no clicking in the Porkbun panel. The
  flake is the single source of truth. DNS is reconciled from your declarations
  by a [stateless reconciler](dns/README.md); the only "state" is the box's SSH
  host key (its intrinsic identity) and a marker the reconciler stamps into
  Porkbun's own `notes` field.
- **Declarative secrets ([agenix]).** Secrets are age-encrypted in the repo,
  decrypted on the box by its SSH host key, and injected into a service at
  start — never landing in the Nix store or `systemctl show`.
- **Services are decoupled and portable.** A service ships a tiny NixOS module
  and is adopted with `enable = true; domain = …`. It doesn't know about your
  fleet; your fleet barely knows about it.
- **Optimised for humans and LLMs.** One uniform schema
  (`vacationvm.services.<name>`); obvious field names; everything greppable; the
  DNS tool is dependency-free Python you can read in five minutes.

## Quickstart

```bash
# 1. Scaffold an operator hive
nix flake init -t github:cognivore/vacationvm#hive

# 2. (Or) scaffold a new service that plugs straight in
nix flake init -t github:cognivore/vacationvm#service
```

Then follow [docs/bootstrap.md](docs/bootstrap.md) for the first deploy.

## What's in this repo

| Path | What |
|------|------|
| `modules/fleet.nix` | the `vacationvm` NixOS module (units + Caddy + DNS + firewall + agenix) |
| `modules/app-options.nix` | the per-app schema (`vacationvm.services.<name>`) |
| `lib/` | pure helpers: domain math + DNS-record derivation |
| `dns/` | the stateless Porkbun reconciler (dependency-free Python, tested) |
| `templates/hive/` | `nix flake init -t .#hive` — an operator repo |
| `templates/service/` | `nix flake init -t .#service` — a self-describing service |
| `docs/` | architecture, bootstrap, DNS, secrets, adding a service |

## Documentation

- [docs/architecture.md](docs/architecture.md) — how the pieces fit, and why
- [docs/bootstrap.md](docs/bootstrap.md) — first-time provisioning, step by step
- [docs/adding-a-service.md](docs/adding-a-service.md) — the two integration paths
- [docs/dns.md](docs/dns.md) — how DNS reconciliation stays declarative and safe
- [docs/secrets.md](docs/secrets.md) — the agenix flow
- [CLAUDE.md](CLAUDE.md) — conventions & invariants (for humans and agents)

## Status / scope

Single host, many services (multi-host is a natural extension — colmena already
supports it). DNS provider: Porkbun. TLS: Caddy automatic HTTPS (HTTP-01).
Secrets: agenix. License: AGPL-3.0-or-later.

[annexwyrm]: https://github.com/cognivore/annexwyrm
[agenix]: https://github.com/ryantm/agenix
