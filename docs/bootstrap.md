# Bootstrap — first deploy, step by step

The goal: go from "a fresh NixOS box + a Porkbun account" to "services live on
HTTPS with DNS pointing at them", with **no imperative state** created along the
way. The only thing that isn't in your repo is the box's SSH host key, which the
box generates itself.

## 0. Prerequisites

- A domain at **Porkbun**, with its nameservers set to Porkbun (the default for
  domains registered there). vacationvm manages *records*, not the registration.
- A **Porkbun API key + secret** (Porkbun panel → Account → API Access), with
  API access enabled **for that domain**.
- A box running **NixOS** with SSH reachable as root (any provider). If you're
  starting from a non-NixOS VPS, [nixos-anywhere] installs NixOS over SSH.
- `nix` with flakes on your laptop.

## 1. Scaffold the hive

```bash
mkdir my-fleet && cd my-fleet
nix flake init -t github:cognivore/vacationvm#hive
git init && git add -A          # agenix needs files tracked by git
```

Edit:
- `hosts/wyrm.nix` — real disk/boot/network (paste your
  `hardware-configuration.nix` or a cloud-image import), your laptop's SSH key,
  `acmeEmail`, and `publicIp4` (and `publicIp6` if you have one).
- `flake.nix` — the colmena node's `deployment.targetHost`.
- `services/annexwyrm.nix` (or your own) — set `domain`, identity, etc.

## 2. Register the box's host key

agenix encrypts secrets to the box's ed25519 **host** key. Read it back:

```bash
nix run github:cognivore/vacationvm#register-host -- <box-ip>
#  → prints:  wyrm = "ssh-ed25519 AAAA…";
```

Paste that line into `secrets/secrets.nix`, and add your own user key as a
second recipient so you can edit secrets.

> If the box was just created and sshd isn't up yet, wait a minute and retry.
> TOFU caveat: verify the key out of band if you don't trust the network path.

## 3. Create the secrets

```bash
nix develop                     # brings in agenix + colmena + the reconciler
agenix -e secrets/porkbun-api-key.age       # paste the Porkbun API key
agenix -e secrets/porkbun-secret-key.age    # paste the Porkbun secret key
agenix -e secrets/annexwyrm-password.age    # any per-app secrets you declared
git add -A                                   # commit the *.age files (safe — encrypted)
```

The `.age` files are encrypted to the recipients in `secrets/secrets.nix`; only
the box (and you) can read them.

## 4. Deploy

```bash
colmena apply --on wyrm
```

What happens on the box during activation:
1. agenix decrypts the secrets to `/run/agenix/*`.
2. Each app starts as `vacationvm-<name>.service`.
3. `vacationvm-dns-reconcile` pushes the A/AAAA records to Porkbun.
4. Caddy requests certificates (retries until DNS has propagated).

Give DNS + ACME a minute on the very first deploy, then visit your domain.

## 5. Verify

```bash
ssh root@<box> systemctl start vacationvm-dns-plan   # dry-run DNS diff
ssh root@<box> journalctl -u vacationvm-dns-plan -n 50
ssh root@<box> systemctl status vacationvm-annexwyrm
ssh root@<box> journalctl -u vacationvm-dns-reconcile -n 50
curl -I https://wyrm.fere.me
```

## Day 2

- **Add/remove a service** → edit the flake, `colmena apply`. Removing a service
  removes its unit + vhost, and the reconciler prunes its (marker-owned) DNS
  records on the next run.
- **Rotate a secret** → `agenix -e secrets/<name>.age`, `colmena apply`.
- **Rotate the box** (rebuild it) → its host key changes; re-run step 2,
  `agenix --rekey`, redeploy.

[nixos-anywhere]: https://github.com/nix-community/nixos-anywhere
