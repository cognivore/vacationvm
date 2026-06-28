"""End-to-end reconcile tests against an in-memory fake Porkbun zone.

The fake :class:`FakeZone` implements just enough of the Porkbun JSON API
(ping / retrieve / create / edit / delete) to let us drive the real
:class:`PorkbunClient` and the real CLI ``reconcile`` loop with no network,
asserting convergence, idempotency, prune-safety and marker stamping.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from vacationvm_dns.cli import main  # noqa: E402
from vacationvm_dns.porkbun import PorkbunClient, Response  # noqa: E402


class FakeZone:
    """A tiny stateful fake of Porkbun's DNS API, as a Transport."""

    def __init__(self):
        self.records = {}  # id -> dict(name(fqdn), type, content, ttl, notes)
        self._next = 1
        self.calls = []  # list of (path,) for assertions

    # Transport protocol -------------------------------------------------
    def post(self, url: str, body: bytes, headers: dict) -> Response:
        path = url.split("/api/json/v3", 1)[1]
        payload = json.loads(body.decode()) if body else {}
        self.calls.append(path)

        if path == "/ping":
            return self._ok({"yourIp": "203.0.113.7"})

        parts = path.strip("/").split("/")
        # /dns/retrieve/{domain}
        if parts[:2] == ["dns", "retrieve"]:
            domain = parts[2]
            recs = [
                {"id": rid, **r}
                for rid, r in self.records.items()
                if r["name"].endswith(domain)
            ]
            return self._ok({"records": recs})
        # /dns/create/{domain}
        if parts[:2] == ["dns", "create"]:
            domain = parts[2]
            name = payload.get("name", "")
            fqdn = domain if name == "" else f"{name}.{domain}"
            rid = str(self._next)
            self._next += 1
            self.records[rid] = {
                "name": fqdn,
                "type": payload["type"],
                "content": payload["content"],
                "ttl": str(payload["ttl"]),
                "notes": payload.get("notes", ""),
            }
            return self._ok({"id": int(rid)})
        # /dns/edit/{domain}/{id}
        if parts[:2] == ["dns", "edit"]:
            rid = parts[3]
            if rid not in self.records:
                return self._err("record not found")
            self.records[rid].update(
                {
                    "type": payload["type"],
                    "content": payload["content"],
                    "ttl": str(payload["ttl"]),
                    "notes": payload.get("notes", ""),
                }
            )
            return self._ok({})
        # /dns/delete/{domain}/{id}
        if parts[:2] == ["dns", "delete"]:
            rid = parts[3]
            self.records.pop(rid, None)
            return self._ok({})

        return self._err(f"unhandled path {path}")

    @staticmethod
    def _ok(extra):
        return Response(200, json.dumps({"status": "SUCCESS", **extra}).encode())

    @staticmethod
    def _err(msg):
        return Response(400, json.dumps({"status": "ERROR", "message": msg}).encode())

    # Convenience for assertions ----------------------------------------
    def seed(self, name, type, content, ttl="600", notes="vacationvm"):
        rid = str(self._next)
        self._next += 1
        self.records[rid] = {"name": name, "type": type, "content": content, "ttl": ttl, "notes": notes}
        return rid

    def fqdns(self):
        return {(r["name"], r["type"]): r["content"] for r in self.records.values()}


class ClientReconcileTests(unittest.TestCase):
    def setUp(self):
        self.zone = FakeZone()
        self.client = PorkbunClient("api", "secret", transport=self.zone)

    def test_create_then_idempotent(self):
        from vacationvm_dns.model import DesiredRecord
        from vacationvm_dns.plan import plan_reconciliation

        desired = [DesiredRecord("fere.me", "wyrm", "A", "1.2.3.4", 600)]

        # First pass: creates.
        observed = self.client.retrieve_all("fere.me")
        plan = plan_reconciliation(desired, observed, "vacationvm")
        self.assertEqual(plan.summary(), "1 create, 0 update, 0 delete, 0 unchanged")
        for a in plan.creates():
            self.client.create("fere.me", a.record.name, a.record.type, a.record.content, a.record.ttl)
        self.assertEqual(self.zone.fqdns(), {("wyrm.fere.me", "A"): "1.2.3.4"})

        # Second pass: no changes.
        observed = self.client.retrieve_all("fere.me")
        plan = plan_reconciliation(desired, observed, "vacationvm")
        self.assertFalse(plan.has_changes())

    def test_create_stamps_marker(self):
        self.client.create("fere.me", "wyrm", "A", "1.2.3.4", 600)
        rec = next(iter(self.zone.records.values()))
        self.assertEqual(rec["notes"], "vacationvm")


class CliReconcileTests(unittest.TestCase):
    def _write_desired(self, records, ttl=600, marker="vacationvm"):
        fd, path = tempfile.mkstemp(suffix=".json")
        os.close(fd)
        with open(path, "w") as fh:
            json.dump({"ttl": ttl, "marker": marker, "records": records}, fh)
        self.addCleanup(os.unlink, path)
        return path

    def _run(self, zone, argv):
        # Patch the client's transport by monkeypatching UrllibTransport use:
        # the CLI builds its own PorkbunClient, so inject via env-free path by
        # temporarily swapping the default transport factory.
        import vacationvm_dns.porkbun as pb

        original = pb.UrllibTransport
        pb.UrllibTransport = lambda *a, **k: zone  # type: ignore
        try:
            return main(argv)
        finally:
            pb.UrllibTransport = original

    def test_full_reconcile_via_cli(self):
        zone = FakeZone()
        # A stale record we own (should be pruned), and a foreign one (kept).
        zone.seed("old.fere.me", "A", "9.9.9.9", notes="vacationvm")
        zone.seed("mail.fere.me", "MX", "mx.fere.me", notes="")  # unmanaged type, ignored
        zone.seed("hand.fere.me", "A", "8.8.8.8", notes="")  # foreign A, kept

        desired = self._write_desired(
            [{"apex": "fere.me", "name": "wyrm", "type": "A", "content": "1.2.3.4"}]
        )
        rc = self._run(
            zone,
            ["reconcile", "--desired", desired, "--api-key-file", _tmpfile("k"),
             "--secret-key-file", _tmpfile("s")],
        )
        self.assertEqual(rc, 0)
        live = zone.fqdns()
        self.assertEqual(live.get(("wyrm.fere.me", "A")), "1.2.3.4")  # created
        self.assertNotIn(("old.fere.me", "A"), live)  # owned stale -> pruned
        self.assertEqual(live.get(("hand.fere.me", "A")), "8.8.8.8")  # foreign -> kept

    def test_no_prune_keeps_owned_stale(self):
        zone = FakeZone()
        zone.seed("old.fere.me", "A", "9.9.9.9", notes="vacationvm")
        desired = self._write_desired(
            [{"apex": "fere.me", "name": "wyrm", "type": "A", "content": "1.2.3.4"}]
        )
        rc = self._run(
            zone,
            ["reconcile", "--no-prune", "--desired", desired,
             "--api-key-file", _tmpfile("k"), "--secret-key-file", _tmpfile("s")],
        )
        self.assertEqual(rc, 0)
        self.assertIn(("old.fere.me", "A"), zone.fqdns())  # kept because --no-prune

    def test_dry_run_changes_nothing(self):
        zone = FakeZone()
        desired = self._write_desired(
            [{"apex": "fere.me", "name": "wyrm", "type": "A", "content": "1.2.3.4"}]
        )
        rc = self._run(
            zone,
            ["reconcile", "--dry-run", "--desired", desired,
             "--api-key-file", _tmpfile("k"), "--secret-key-file", _tmpfile("s")],
        )
        self.assertEqual(rc, 0)
        self.assertEqual(zone.records, {})  # nothing created


def _tmpfile(content):
    fd, path = tempfile.mkstemp()
    with os.fdopen(fd, "w") as fh:
        fh.write(content)
    return path


if __name__ == "__main__":
    unittest.main()
