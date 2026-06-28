# DNS — declarative, stateless, and safe

vacationvm provisions DNS at **Porkbun** without Terraform, without a state file,
and without you ever opening the Porkbun panel. This document explains how that
stays correct and safe.

## Where the records come from

The desired record set is **derived** from your declarations (pure Nix,
`lib/default.nix`):

- every enabled app with a `domain` → an `A` record (and `AAAA` if
  `vacationvm.publicIp6` is set) pointing the domain at the box;
- each `alias` → the same;
- each app's `extraDnsRecords` and the fleet-wide `dns.extraRecords` → verbatim
  (e.g. apex `A`, `TXT` for SPF / verification, a `CNAME`).

The module serialises this to a JSON document in the Nix store. You can preview
it with no credentials:

```bash
vacationvm-dns show --desired <that-json>
# or on the box:  systemctl start vacationvm-dns-plan   (a read-only live diff)
```

## How it's applied

`vacationvm-dns-reconcile.service` (a oneshot, run at every activation and on a
timer) executes the reconciler:

1. For each apex, `GET /dns/retrieve/{domain}` — the live records.
2. Diff against the desired set, keyed by `(name, type)`:
   - missing → **create**
   - present but content/ttl differ → **update**
   - present and equal → **noop**
   - present, owned, and no longer desired → **delete**
3. Execute the plan via Porkbun's create/edit/delete endpoints.

It holds **no state of its own** — every run recomputes the diff from the live
zone. There is nothing to drift, nothing to import, nothing to `terraform
refresh`.

## Why pruning is safe

Stateless deletion is the scary part. vacationvm makes it safe with an
**ownership marker**: every record the reconciler writes is stamped with
`notes = "vacationvm"` (configurable via `dns.marker`). The pruner deletes a
record **only if** it carries that marker. Therefore:

- A record you created by hand in the Porkbun panel (no marker) is **never**
  deleted — even if it's on a name vacationvm doesn't manage, even with
  `--prune`.
- Records vacationvm created for a service you've since removed **are** cleaned
  up automatically.

The one case where vacationvm touches a pre-existing record: if you *declare* a
name that already exists un-owned, vacationvm takes it over (an `update` that
also stamps the marker). That only happens for a name you explicitly put in your
config.

Two fleets can share one Porkbun account safely by giving each a distinct
`dns.marker`.

## TTL and provider quirks

- Porkbun's minimum TTL is **600s**; the reconciler clamps lower values so a
  declared `ttl = 300` doesn't cause a perpetual "update" loop against the
  clamped-to-600 live record.
- CNAME targets are compared with trailing dots and case normalised; TXT values
  with surrounding quotes stripped — so equal records compare equal and stay
  `noop`.

## Controls

| Option | Effect |
|---|---|
| `vacationvm.dns.enable` | turn the whole reconciler on/off |
| `vacationvm.dns.prune` | allow deletes (default true); `false` = create/update only |
| `vacationvm.dns.marker` | the ownership marker; isolate fleets sharing an account |
| `vacationvm.dns.ttl` | default TTL (≥ 600) |
| `vacationvm.dns.timer.{enable,onCalendar}` | periodic re-reconcile cadence |
| `vacationvm.dns.reconcileOnActivation` | run as part of `colmena apply` |
| `vacationvm.dns.extraRecords` | fleet-wide records (apex, SPF, verification) |

## Supported record types

`A`, `AAAA`, `CNAME`, `TXT`. Anything else in your zone (MX, SRV, CAA, NS) is
**ignored** by the reconciler — it is never read into the plan, so it can never
be pruned. Manage those by hand or via `extraRecords` once support is added.

## The reconciler itself

It's dependency-free Python (`dns/`), unit-tested against an in-memory fake of
the Porkbun API. Read [dns/README.md](../dns/README.md) — the whole tool is
small on purpose, because it can change your DNS.
