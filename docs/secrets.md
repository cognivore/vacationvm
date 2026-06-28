# Secrets — agenix

vacationvm's secret layer is [agenix]. Secrets are age-encrypted files committed
to your hive repo, decrypted on the box by its SSH **host** key, and injected
into a service at start. No plaintext secret is ever in the Nix store, in
`systemctl show`, or in your git history.

agenix is a **hard requirement** of the fleet module (it always declares
`age.secrets`). Every host that imports `vacationvm.nixosModules.vacationvm` must
also import `agenix.nixosModules.default`. The hive template does this for you.

## The model

```
secrets/secrets.nix          recipients map: which keys can decrypt which *.age
secrets/<name>.age           an age-encrypted secret (committed; safe)
vacationvm.secretsDir         points the module at the directory of *.age files
```

The recipient that matters in production is the **box's ed25519 host key** — see
[bootstrap.md](bootstrap.md) step 2. You typically add your own user key too so
you can edit secrets from your laptop.

## Declaring and consuming a secret

You **don't** write `age.secrets.* = …` yourself — the module does it, reading
`<stem>.age` from `secretsDir` and owning it to the right app user. You just
reference a secret by its stem on the app:

```nix
vacationvm.services.annexwyrm = {
  # value → exported as an env var at start (cat'd from /run/agenix/...):
  environmentSecrets.ANNEXWYRM_PASSWORD = "annexwyrm-password";  # secrets/annexwyrm-password.age

  # path → env var set to the decrypted file's path (for daemons that read a file):
  secretFiles.SOME_TOKEN_FILE = "some-token";                    # secrets/some-token.age

  # already-`KEY=value` content → loaded via systemd EnvironmentFile:
  environmentFiles = [ "extra-env" ];                            # secrets/extra-env.age
};
```

At service start the generated wrapper does the equivalent of:

```sh
export ANNEXWYRM_PASSWORD="$(cat /run/agenix/annexwyrm-password)"
export SOME_TOKEN_FILE=/run/agenix/some-token
# preStart (init) and the daemon both see these
```

`environmentSecrets`/`secretFiles` are read by the **app user**, so the module
owns those secrets to that user (mode `0400`).

## Porkbun credentials

The DNS reconciler needs the Porkbun API key + secret. Drop them at
`secrets/porkbun-api-key.age` and `secrets/porkbun-secret-key.age` and the
module wires them automatically (via systemd `LoadCredential`, owned root). Or
point at explicit paths:

```nix
vacationvm.dns.porkbun.apiKeyFile    = config.age.secrets.porkbun-api-key.path;
vacationvm.dns.porkbun.secretKeyFile = config.age.secrets.porkbun-secret-key.path;
```

## Editing & rotating

```bash
agenix -e secrets/annexwyrm-password.age    # edit (decrypt → $EDITOR → re-encrypt)
agenix --rekey                              # re-encrypt all to current recipients
colmena apply --on wyrm                     # roll it out
```

Rotating a secret is just editing the `.age` and redeploying — the new value is
resolved at the next service start.

## A note on ownership uniqueness

A given `<stem>.age` is owned to the first app (by name) that references it. If
two apps need the same value, give them separate secrets rather than sharing one
file — it keeps ownership unambiguous and isolation intact.

[agenix]: https://github.com/ryantm/agenix
