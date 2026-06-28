# vacationvm-dns

A **stateless, dependency-free** declarative DNS reconciler for [Porkbun].

It is the control-plane half of [vacationvm](../README.md): Nix derives a
desired set of DNS records from your `vacationvm.services` declarations, writes
them to a JSON file in the Nix store, and a systemd one-shot runs this tool on
the target host at every `colmena apply` to converge the live Porkbun zone.

## Why standard-library-only

There is no `requirements.txt`, no lockfile, no virtualenv. The entire tool is
`urllib` + `json` + `dataclasses`. That makes it trivially auditable (it can
mutate your DNS, so you should be able to read all of it in five minutes) and
trivially packageable with Nix (`buildPythonApplication` with no deps).

## Model

* **Desired** records come from the flake (`{apex, name, type, content, ttl}`;
  `name` is a bare subdomain, `""`/`"@"` is the apex).
* **Observed** records come from `GET /dns/retrieve/{domain}`.
* The **planner** (`plan.py`) is pure: each desired record becomes exactly one
  of Create / Update / NoOp; each *owned* observed record with no desired
  counterpart becomes a Delete.

### Ownership marker = safe, stateless pruning

Every record this tool writes is stamped with `notes = "vacationvm"`. The pruner
**only ever deletes records carrying that marker**. A record a human created by
hand in the Porkbun panel (no marker) is never deleted — even on a name we
don't manage. This is how we get garbage collection of removed services
*without keeping any state file*: the marker in the provider's own `notes`
field is the state.

## CLI

```
vacationvm-dns show      --desired desired.json                  # print desired, no creds
vacationvm-dns plan      --desired desired.json --creds-dir DIR  # read-only diff
vacationvm-dns reconcile --desired desired.json --creds-dir DIR  # converge (default: prune)
vacationvm-dns reconcile --desired desired.json --creds-dir DIR --no-prune
vacationvm-dns reconcile --desired desired.json --creds-dir DIR --dry-run
```

Credentials are resolved in order: explicit `--api-key-file`/`--secret-key-file`,
then `--creds-dir` holding `porkbun-api-key` + `porkbun-secret-key` (how systemd
`LoadCredential` exposes them), then `$PORKBUN_API_KEY`/`$PORKBUN_SECRET_KEY`.

## Tests

```
python3 -m unittest discover -s tests -v
```

No test dependencies either — `unittest` with an in-memory fake of the Porkbun
API (`tests/test_reconcile.py`) drives the real client and CLI with no network.

[Porkbun]: https://porkbun.com/api/json/v3/documentation
