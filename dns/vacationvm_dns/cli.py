"""Command-line entry point: ``vacationvm-dns {show,plan,reconcile}``.

Typical invocations
-------------------
Print the desired records (no credentials needed)::

    vacationvm-dns show --desired /nix/store/…-vacationvm-dns-desired.json

Dry-run against the live zone (read-only, needs credentials)::

    vacationvm-dns plan --desired desired.json --creds-dir "$CREDENTIALS_DIRECTORY"

Converge the live zone (this is what the systemd one-shot runs)::

    vacationvm-dns reconcile --desired desired.json --creds-dir "$CREDENTIALS_DIRECTORY"

Credential resolution order (first hit wins):
  1. ``--api-key-file`` / ``--secret-key-file``
  2. ``--creds-dir`` containing ``porkbun-api-key`` and ``porkbun-secret-key``
     (this is how systemd ``LoadCredential`` exposes them)
  3. ``$PORKBUN_API_KEY`` / ``$PORKBUN_SECRET_KEY``
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict
from typing import Sequence

from .model import Create, Delete, DesiredRecord, NoOp, Update
from .plan import plan_reconciliation
from .porkbun import DEFAULT_MARKER, PorkbunClient, PorkbunError


def _load_desired(path: str) -> tuple[list[DesiredRecord], str]:
    """Parse the desired-records JSON document.

    Accepts either a bare list of record objects, or an object
    ``{"records": [...], "ttl": 600, "marker": "vacationvm"}`` where ``ttl`` is
    a default applied to records that omit one and ``marker`` overrides the
    ownership marker.
    """
    with open(path, "r", encoding="utf-8") as fh:
        doc = json.load(fh)

    marker = DEFAULT_MARKER
    default_ttl = None
    if isinstance(doc, dict):
        raw_records = doc.get("records", [])
        marker = str(doc.get("marker", marker))
        if doc.get("ttl") is not None:
            default_ttl = int(doc["ttl"])
    elif isinstance(doc, list):
        raw_records = doc
    else:
        raise SystemExit(f"{path}: expected a JSON object or list, got {type(doc).__name__}")

    records: list[DesiredRecord] = []
    for raw in raw_records:
        if default_ttl is not None and "ttl" not in raw:
            raw = {**raw, "ttl": default_ttl}
        records.append(DesiredRecord.from_json(raw))
    return records, marker


def _read_first(*paths: str) -> str | None:
    for p in paths:
        if p and os.path.isfile(p):
            with open(p, "r", encoding="utf-8") as fh:
                return fh.read().strip()
    return None


def _load_creds(args: argparse.Namespace) -> tuple[str, str]:
    creds_dir = args.creds_dir or os.environ.get("CREDENTIALS_DIRECTORY")
    api = _read_first(
        args.api_key_file or "",
        os.path.join(creds_dir, "porkbun-api-key") if creds_dir else "",
    ) or os.environ.get("PORKBUN_API_KEY")
    secret = _read_first(
        args.secret_key_file or "",
        os.path.join(creds_dir, "porkbun-secret-key") if creds_dir else "",
    ) or os.environ.get("PORKBUN_SECRET_KEY")
    if not api or not secret:
        raise SystemExit(
            "error: Porkbun credentials not found. Provide --api-key-file/"
            "--secret-key-file, --creds-dir with porkbun-api-key+porkbun-secret-key, "
            "or PORKBUN_API_KEY/PORKBUN_SECRET_KEY env vars."
        )
    return api, secret


def _group_by_apex(records: list[DesiredRecord]) -> dict[str, list[DesiredRecord]]:
    grouped: dict[str, list[DesiredRecord]] = defaultdict(list)
    for rec in records:
        grouped[rec.apex].append(rec)
    return dict(grouped)


def _cmd_show(args: argparse.Namespace) -> int:
    records, marker = _load_desired(args.desired)
    by_apex = _group_by_apex(records)
    print(f"# desired DNS records (marker: {marker})")
    if not records:
        print("# (none — no services declare a public domain)")
        return 0
    for apex in sorted(by_apex):
        print(f"\n[{apex}]")
        for rec in by_apex[apex]:
            host = "@" if rec.name == "" else rec.name
            print(f"  {rec.type:5} {host:24} {rec.content}  (ttl {rec.ttl})")
    return 0


def _reconcile(args: argparse.Namespace, apply: bool) -> int:
    records, marker = _load_desired(args.desired)
    api, secret = _load_creds(args)
    client = PorkbunClient(api, secret, marker=marker)
    by_apex = _group_by_apex(records)

    if args.verbose:
        try:
            print(f"# porkbun ping ok, public ip: {client.ping()}", file=sys.stderr)
        except PorkbunError as exc:
            print(f"error: credential check failed: {exc}", file=sys.stderr)
            return 2

    total_changes = 0
    failures = 0
    # Apexes with no desired records are still visited when --prune is on, so we
    # can clean up records we used to own. Operators list those via --apex.
    apexes = sorted(set(by_apex) | set(args.apex or []))
    for apex in apexes:
        desired = by_apex.get(apex, [])
        try:
            observed = client.retrieve_all(apex)
        except PorkbunError as exc:
            print(f"error: {apex}: could not list records: {exc}", file=sys.stderr)
            failures += 1
            continue

        plan = plan_reconciliation(desired, observed, marker)
        print(f"[{apex}] {plan.summary()}")
        for action in plan.actions:
            if isinstance(action, NoOp) and not args.verbose:
                continue
            print(f"  {action.describe()}")

        if not apply:
            continue

        for action in plan.actions:
            try:
                if isinstance(action, Create):
                    client.create(
                        apex, action.record.name, action.record.type,
                        action.record.content, action.record.ttl,
                    )
                    total_changes += 1
                elif isinstance(action, Update):
                    client.edit(
                        apex, action.id, action.record.name, action.record.type,
                        action.record.content, action.record.ttl,
                    )
                    total_changes += 1
                elif isinstance(action, Delete):
                    if args.prune:
                        client.delete(apex, action.id)
                        total_changes += 1
            except PorkbunError as exc:
                print(f"  ! failed: {action.describe()}: {exc}", file=sys.stderr)
                failures += 1

    if apply:
        print(f"# applied {total_changes} change(s); {failures} failure(s)")
    if failures:
        return 1
    return 0


def _cmd_plan(args: argparse.Namespace) -> int:
    return _reconcile(args, apply=False)


def _cmd_reconcile(args: argparse.Namespace) -> int:
    return _reconcile(args, apply=not args.dry_run)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="vacationvm-dns",
        description="Stateless declarative Porkbun DNS reconciler.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    def add_common(p: argparse.ArgumentParser, creds: bool) -> None:
        p.add_argument(
            "--desired", required=True, metavar="FILE",
            help="path to the desired-records JSON document",
        )
        if creds:
            p.add_argument("--creds-dir", metavar="DIR",
                           help="directory holding porkbun-api-key + porkbun-secret-key")
            p.add_argument("--api-key-file", metavar="FILE", help="file holding the Porkbun API key")
            p.add_argument("--secret-key-file", metavar="FILE", help="file holding the Porkbun secret key")
            p.add_argument("--apex", action="append", metavar="DOMAIN",
                           help="extra apex domain to reconcile (for pruning emptied zones); repeatable")
            p.add_argument("-v", "--verbose", action="store_true", help="also print unchanged records and ping check")

    p_show = sub.add_parser("show", help="print the desired records (no credentials needed)")
    p_show.add_argument("--desired", required=True, metavar="FILE")
    p_show.set_defaults(func=_cmd_show)

    p_plan = sub.add_parser("plan", help="diff desired vs live zone, print plan, change nothing")
    add_common(p_plan, creds=True)
    p_plan.set_defaults(func=_cmd_plan)

    p_rec = sub.add_parser("reconcile", help="converge the live zone onto the desired records")
    add_common(p_rec, creds=True)
    p_rec.add_argument("--dry-run", action="store_true", help="plan only, do not mutate (same as `plan`)")
    prune = p_rec.add_mutually_exclusive_group()
    prune.add_argument("--prune", dest="prune", action="store_true", default=True,
                       help="delete owned records no longer desired (default)")
    prune.add_argument("--no-prune", dest="prune", action="store_false",
                       help="never delete, only create/update")
    p_rec.set_defaults(func=_cmd_reconcile)

    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    # `show` has no creds/prune attributes; give them harmless defaults.
    for attr, default in (("prune", True), ("verbose", False), ("dry_run", False), ("apex", None)):
        if not hasattr(args, attr):
            setattr(args, attr, default)
    try:
        return args.func(args)
    except PorkbunError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
