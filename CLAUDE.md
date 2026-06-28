# CLAUDE.md — vacationvm conventions & invariants

Guidance for humans and LLM agents working on or with this repo. Read it before
changing the module or adding a service.

## What this is

A NixOS framework to colocate many small services on one box, deployed with
`colmena apply`. Each service: its own repo → flake input → `vacationvm.services.<name>`.
Caddy fronts everything (auto-TLS); a stateless reconciler keeps Porkbun DNS in
sync; agenix holds secrets.

## Hard invariants (do not break)

1. **No imperative or implicit state.** Everything is in the flake. No state
   files, no hand-edited server config, no manual DNS/console clicks, no
   `certbot`. If you're tempted to add a step that mutates the server outside
   Nix, find the declarative form instead.
2. **Secrets via agenix only.** Never write a secret into the Nix store or a
   `systemd Environment=`. App secrets are `cat`'d from their agenix path inside
   the per-app start wrapper at runtime (see `mkStartScript` in
   `modules/fleet.nix`). Porkbun creds reach the reconciler via
   `LoadCredential`.
3. **DNS pruning is marker-gated.** The reconciler only deletes records whose
   Porkbun `notes` carry the ownership marker (default `vacationvm`). Never
   delete by name alone. This is what makes stateless pruning safe.
4. **The DNS tool stays dependency-free.** `dns/` is Python standard-library
   only — no `requirements.txt`, no lockfile. Keep it auditable.
5. **Services speak a Unix socket (preferred) or loopback TCP.** Nothing but
   Caddy binds a public port. Apps run with `UMask=0007`; Caddy is added to each
   app's group so it can reach the socket.

## Layout

```
modules/fleet.nix        the module: options + systemd units + Caddy + DNS + agenix wiring
modules/app-options.nix  the per-app submodule schema
lib/default.nix          pure helpers (splitDomain, deriveRecords, mkApp) — also the flake `lib`
dns/vacationvm_dns/       reconciler: model.py (data) / plan.py (pure planner) / porkbun.py / cli.py
dns/tests/               unittest suite (run: python3 -m unittest discover -s dns/tests)
templates/hive/          operator repo template
templates/service/       self-describing service template (std-only Rust)
```

## Adding a service (two paths)

- **Service ships its own module** (preferred): it exposes
  `nixosModules.default` that sets run-time defaults under
  `vacationvm.services.<name>` as `mkDefault`s and leaves it disabled. The hive
  imports it and sets `enable = true; domain = …`. See `templates/service/`.
- **Package-only service**: write a ~25-line adapter in the hive mapping the
  package onto the schema. See `templates/hive/services/annexwyrm.nix`.

The app schema (`vacationvm.services.<name>`) — common fields: `enable`,
`package`, `domain`, `aliases`, `listen.{type,socket,port}`, `exec`,
`preStart`, `environment`, `environmentSecrets` (ENV→agenix value),
`secretFiles` (ENV→agenix path), `staticFiles`, `packages` (PATH deps),
`maxBodySize`, `extraDnsRecords`, `caddyExtra`. Full docs in
`modules/app-options.nix`.

## Module-writing gotchas (learned the hard way)

- **Never gate an *undeclared* option's presence on `config`.** Writing
  `optionalAttrs (cfg.x) { age.secrets = …; }` or `mkIf cfg.x { age.secrets = …; }`
  for an option agenix declares causes an infinite recursion via
  `_module.freeformType` when agenix isn't imported. `age.secrets` is therefore
  declared **unconditionally** (empty when unused), and agenix is a hard
  requirement of any host using the module.
- **No self-referential option defaults.** An option default must not derive
  from the same `config` namespace it lives in (it caused a fixpoint loop; the
  DNS desired-records JSON is a `let` binding, not an option default).

## Commands

```bash
# Framework dev
nix flake check                               # builds python tests + module smoke + lib eval
python3 -m unittest discover -s dns/tests -v  # just the reconciler tests
nix run .#register-host -- <box-ip>           # print the agenix recipient line for a box

# On a deployed box
systemctl start  vacationvm-dns-plan           # dry-run DNS diff (read-only)
journalctl -u    vacationvm-dns-plan
systemctl start  vacationvm-dns-reconcile      # force a reconcile now
systemctl status vacationvm-<app>              # an app's unit
```

## Verifying changes to the module

Evaluate a representative host (no real infra needed) — this is what
`checks.module-smoke` does:

```bash
nix build .#checks.<system>.module-smoke   # asserts units/vhosts/DNS + no failed assertions
```
