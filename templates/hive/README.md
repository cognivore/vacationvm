# My vacationvm hive

A ready-to-edit operator repo: many small services colocated on one NixOS box,
deployed with `colmena apply`, fronted by Caddy (automatic TLS), with DNS
reconciled to Porkbun — all declarative, no imperative state.

Scaffold it with:

```bash
nix flake init -t github:cognivore/vacationvm#hive
```

## Layout

```
flake.nix                 inputs (vacationvm, agenix, colmena, your services) + the colmena hive
hosts/wyrm.nix            the box: hardware/network/ssh + the `vacationvm` block
services/annexwyrm.nix    adapter: run annexwyrm (a package-only service) as an app
secrets/secrets.nix       agenix recipients (the box host key + your key)
secrets/*.age             encrypted secrets (you create these)
```

## First deploy (the whole story)

1. **Provision a NixOS box** anywhere (Hetzner, EC2, a VPS via
   [nixos-anywhere]). Note its public IP. Put your real disk/boot/network
   config in `hosts/wyrm.nix`.

2. **Register the box's host key** so agenix can encrypt to it:
   ```bash
   ssh-keyscan -t ed25519 <box-ip>     # copy the key into secrets/secrets.nix
   ```
   (or run `nix run github:cognivore/vacationvm#register-host -- <box-ip>`)

3. **Create the secrets** (encrypted to the box; never committed in plaintext):
   ```bash
   nix develop                          # brings in agenix + colmena
   agenix -e secrets/porkbun-api-key.age
   agenix -e secrets/porkbun-secret-key.age
   agenix -e secrets/annexwyrm-password.age
   ```

4. **Point the apex's nameservers at Porkbun** (one-time, in the Porkbun panel)
   and set `acmeEmail`, `publicIp4`, and each service's `domain` in the repo.

5. **Deploy:**
   ```bash
   colmena apply --on wyrm
   ```
   On activation the box: builds + starts each app as a sandboxed systemd unit,
   Caddy obtains certificates, and the DNS reconciler creates/updates the A/AAAA
   records at Porkbun. Re-run any time; it converges.

## Add another service

- **A service that ships a vacationvm module** (the easy path):
  ```nix
  # flake.nix
  inputs.hello-vvm.url = "github:you/hello-vvm";
  # hostModules
  inputs.hello-vvm.nixosModules.default
  # hosts/wyrm.nix (or its own file)
  vacationvm.services.hello-vvm = { enable = true; domain = "hi.fere.me"; };
  ```

- **A package-only service**: copy `services/annexwyrm.nix` and adapt.

## Preview / debug

```bash
ssh root@<box> systemctl start vacationvm-dns-plan   # dry-run DNS diff
ssh root@<box> journalctl -u vacationvm-dns-plan      #   ...read it
ssh root@<box> systemctl status vacationvm-annexwyrm  # an app's unit
```

[nixos-anywhere]: https://github.com/nix-community/nixos-anywhere
