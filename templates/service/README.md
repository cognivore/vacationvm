# hello-vvm — a vacationvm-style service template

A complete, minimal example of a service written "in the style of annexwyrm"
and wired for [vacationvm](https://github.com/cognivore/vacationvm): it speaks
HTTP/1.1 over a **Unix domain socket**, is configured entirely by environment
variables, and ships a NixOS module so a fleet can adopt it in two lines.

Scaffold it with:

```bash
nix flake init -t github:cognivore/vacationvm#service
```

## What's here

```
src/main.rs               the daemon — standard-library only, no crates
Cargo.toml / Cargo.lock   a zero-dependency crate (lock has no deps → offline build)
nix/package.nix           buildRustPackage derivation
nix/vacationvm-module.nix  the vacationvm integration (the important part)
flake.nix                 packages.default + nixosModules.default
```

## The integration contract

A vacationvm-style service exposes:

1. **`packages.default`** — a binary in `/bin`, optional assets in `/share`.
2. **`nixosModules.default`** — sets run-time defaults under
   `vacationvm.services.<name>` (package, `exec`, socket env) as `mkDefault`s,
   leaving the app **disabled** until an operator opts in.

Then a hive adds the service with:

```nix
# flake.nix inputs
hello-vvm.url = "github:you/hello-vvm";

# in the host config
imports = [ hello-vvm.nixosModules.default ];
vacationvm.services.hello-vvm = {
  enable = true;
  domain = "hi.fere.me";
  # everything else (package, exec, socket) comes from the service module.
  environment.VVM_HELLO_GREETING = "hi!";          # optional
  environmentSecrets.VVM_HELLO_SECRET = "hello-secret";  # optional agenix secret
};
```

That's it — the app gets a sandboxed systemd unit, a Caddy vhost with automatic
TLS, and an A/AAAA record at `hi.fere.me` pointing at the box.

## Develop

```bash
nix develop
cargo run                  # listens on ./hello.sock by default? no — set VVM_HELLO_SOCKET
VVM_HELLO_SOCKET=$PWD/hello.sock cargo run
# in another shell:
curl --unix-socket hello.sock http://localhost/
```

## Why a Unix socket

The same reasoning as annexwyrm: Caddy already does TLS/HTTP-3/ACME well, so
the daemon speaks plain HTTP/1.1 over a socket and lets Caddy front it. vacationvm
runs the daemon with `UMask=0007` and adds Caddy to the app's group, so the
socket is reachable by the proxy and nothing else.
