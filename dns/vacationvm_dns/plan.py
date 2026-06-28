"""The pure reconciliation planner.

Given the desired records (from the flake) and the observed records (from
Porkbun), produce a deterministic, total plan: every desired record yields
exactly one of Create / Update / NoOp, and every *owned* observed record with
no desired counterpart yields a Delete.

Safety property — the planner only ever proposes deleting a record that
carries our ownership ``marker`` in its Porkbun ``notes`` field. Records a
human created by hand (no marker) are never deleted, even if they sit on a
name we don't manage. Taking over an existing un-owned record on a name we
*do* declare is allowed (it becomes an Update that also stamps the marker),
which is the one case where we touch foreign data — and only because the
operator explicitly declared that exact name.
"""

from __future__ import annotations

from typing import Iterable

from .model import (
    Create,
    Delete,
    DesiredRecord,
    NoOp,
    ObservedRecord,
    Plan,
    Update,
)


def plan_reconciliation(
    desired: Iterable[DesiredRecord],
    observed: Iterable[ObservedRecord],
    marker: str,
) -> Plan:
    """Compute the actions required to converge ``observed`` onto ``desired``.

    Ordering is stable for readable diffs: Create/Update/NoOp appear in the
    input order of ``desired``; Delete actions are appended in the input order
    of ``observed``.
    """
    desired = list(desired)
    observed = list(observed)

    # Index observed by (apex, name, type). If Porkbun somehow returns two rows
    # with the same key (it shouldn't for our managed types), the later one
    # wins the index but both remain in `observed`, so the duplicate is still
    # considered for pruning below.
    observed_by_key = {rec.key: rec for rec in observed}

    actions: list = []
    consumed = set()

    for want in desired:
        match = observed_by_key.get(want.key)
        if match is None:
            actions.append(Create(want))
        elif match.matches(want):
            actions.append(NoOp(want, id=match.id))
        else:
            actions.append(
                Update(
                    record=want,
                    id=match.id,
                    old_content=match.content,
                    old_ttl=match.ttl,
                )
            )
        consumed.add(want.key)

    for have in observed:
        if have.key in consumed:
            continue
        if not have.owned_by(marker):
            # Foreign record we never created — leave it untouched.
            continue
        actions.append(
            Delete(
                id=have.id,
                apex=have.apex,
                name=have.name,
                type=have.type,
                content=have.content,
            )
        )

    return Plan(actions=actions)
