"""Unit tests for the pure reconciliation planner."""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from vacationvm_dns.model import (  # noqa: E402
    Create,
    Delete,
    DesiredRecord,
    NoOp,
    ObservedRecord,
    Update,
)
from vacationvm_dns.plan import plan_reconciliation  # noqa: E402

MARKER = "vacationvm"


def want(name, content, ttl=600, apex="fere.me", type="A"):
    return DesiredRecord(apex=apex, name=name, type=type, content=content, ttl=ttl)


def have(rec_id, name, content, ttl=600, apex="fere.me", type="A", notes=MARKER):
    return ObservedRecord(
        id=rec_id, apex=apex, name=name, type=type, content=content, ttl=ttl, notes=notes
    )


class PlannerTests(unittest.TestCase):
    def test_empty_inputs_empty_plan(self):
        plan = plan_reconciliation([], [], MARKER)
        self.assertEqual(plan.actions, [])
        self.assertFalse(plan.has_changes())

    def test_missing_record_is_created(self):
        plan = plan_reconciliation([want("wyrm", "1.2.3.4")], [], MARKER)
        self.assertEqual(len(plan.actions), 1)
        self.assertIsInstance(plan.actions[0], Create)

    def test_matching_record_is_noop(self):
        d = want("wyrm", "1.2.3.4")
        o = have("rec-1", "wyrm", "1.2.3.4")
        plan = plan_reconciliation([d], [o], MARKER)
        self.assertIsInstance(plan.actions[0], NoOp)
        self.assertFalse(plan.has_changes())

    def test_content_mismatch_is_update(self):
        plan = plan_reconciliation(
            [want("wyrm", "9.9.9.9")], [have("rec-1", "wyrm", "1.2.3.4")], MARKER
        )
        action = plan.actions[0]
        self.assertIsInstance(action, Update)
        self.assertEqual(action.id, "rec-1")
        self.assertEqual(action.old_content, "1.2.3.4")

    def test_ttl_mismatch_is_update(self):
        plan = plan_reconciliation(
            [want("wyrm", "1.2.3.4", ttl=1200)],
            [have("rec-1", "wyrm", "1.2.3.4", ttl=600)],
            MARKER,
        )
        self.assertIsInstance(plan.actions[0], Update)

    def test_owned_unwanted_record_is_deleted(self):
        plan = plan_reconciliation([], [have("rec-1", "stale", "1.2.3.4")], MARKER)
        self.assertEqual(len(plan.actions), 1)
        action = plan.actions[0]
        self.assertIsInstance(action, Delete)
        self.assertEqual(action.id, "rec-1")
        self.assertEqual(action.name, "stale")

    def test_foreign_record_is_left_alone(self):
        # No marker -> we never created it -> never delete it.
        plan = plan_reconciliation(
            [], [have("rec-1", "mail", "1.2.3.4", notes="hand-made")], MARKER
        )
        self.assertEqual(plan.actions, [])

    def test_declared_name_takes_over_foreign_record(self):
        # An un-owned record on a name we DO declare becomes an Update (and the
        # client will stamp our marker on it).
        plan = plan_reconciliation(
            [want("wyrm", "9.9.9.9")],
            [have("rec-1", "wyrm", "1.2.3.4", notes="")],
            MARKER,
        )
        self.assertIsInstance(plan.actions[0], Update)

    def test_different_types_same_name_are_independent(self):
        d_a = want("api", "1.2.3.4", type="A")
        d_cname = DesiredRecord("fere.me", "www", "CNAME", "fere.me", 600)
        plan = plan_reconciliation([d_a, d_cname], [], MARKER)
        self.assertEqual(len(plan.actions), 2)
        self.assertTrue(all(isinstance(a, Create) for a in plan.actions))

    def test_mixed_plan_ordering(self):
        desired = [
            want("blog", "1.2.3.4"),  # NoOp
            want("api", "9.9.9.9"),  # Update
            want("status", "5.5.5.5"),  # Create
        ]
        observed = [
            have("rec-blog", "blog", "1.2.3.4"),
            have("rec-api", "api", "1.2.3.4"),
            have("rec-stale", "stale", "7.7.7.7"),  # owned, undesired -> Delete
        ]
        plan = plan_reconciliation(desired, observed, MARKER)
        kinds = [type(a).__name__ for a in plan.actions]
        self.assertEqual(kinds, ["NoOp", "Update", "Create", "Delete"])
        self.assertEqual(plan.summary(), "1 create, 1 update, 1 delete, 1 unchanged")

    def test_apex_record_keyed_by_empty_name(self):
        d = DesiredRecord("fere.me", "", "A", "1.2.3.4", 600)
        o = ObservedRecord("r", "fere.me", "", "A", "1.2.3.4", 600, MARKER)
        plan = plan_reconciliation([d], [o], MARKER)
        self.assertIsInstance(plan.actions[0], NoOp)


if __name__ == "__main__":
    unittest.main()
