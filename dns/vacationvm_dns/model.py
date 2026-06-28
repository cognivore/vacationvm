"""Typed, immutable data the reconciler operates on.

Two record shapes:

* :class:`DesiredRecord` — what the flake says *should* exist. ``name`` is a
  bare subdomain relative to ``apex`` (``""`` denotes the apex itself).
* :class:`ObservedRecord` — what Porkbun reports *does* exist, already
  normalised to the same ``(apex, bare-name)`` shape and carrying the provider
  record ``id`` and free-form ``notes`` (our ownership marker lives there).

Plus the four :class:`Action` variants a plan is made of. Everything here is a
frozen dataclass with no I/O — trivially testable and trivially serialisable.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable

# Porkbun's documented minimum TTL. Sending anything lower makes Porkbun
# silently clamp to 600, which would otherwise make every reconcile think the
# record drifted (desired=300, observed=600) and issue a perpetual update. We
# clamp on the way in so desired and observed agree.
PORKBUN_MIN_TTL = 600

# Record types we manage. Intentionally small: these cover "point a name at
# this box" (A/AAAA), "alias to another name" (CNAME) and "verification/SPF
# style text" (TXT). Anything exotic (MX, SRV, CAA, …) is left to the operator
# to manage out of band and is never touched by the pruner.
SUPPORTED_TYPES = ("A", "AAAA", "CNAME", "TXT")


def normalise_type(kind: str) -> str:
    """Upper-case and validate a record type."""
    up = kind.strip().upper()
    if up not in SUPPORTED_TYPES:
        raise ValueError(
            f"unsupported record type {kind!r}; supported: {', '.join(SUPPORTED_TYPES)}"
        )
    return up


def clamp_ttl(ttl: int) -> int:
    """Clamp a TTL to Porkbun's minimum so reconciles stay idempotent."""
    return max(int(ttl), PORKBUN_MIN_TTL)


def normalise_content(kind: str, content: str) -> str:
    """Canonicalise content so that desired/observed compare equal.

    * CNAME: drop a trailing dot and lower-case (DNS names are case-insensitive
      and Porkbun stores them with an inconsistent trailing dot).
    * TXT: strip one layer of surrounding double quotes if present (Porkbun
      round-trips quotes inconsistently).
    * A/AAAA: just trim surrounding whitespace.
    """
    kind = normalise_type(kind)
    value = content.strip()
    if kind == "CNAME":
        return value.rstrip(".").lower()
    if kind == "TXT":
        if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
            return value[1:-1]
        return value
    return value


def subdomain_of(fqdn: str, apex: str) -> str:
    """Return the bare label(s) of ``fqdn`` relative to ``apex``.

    ``subdomain_of("blog.fere.me", "fere.me") == "blog"``;
    ``subdomain_of("fere.me", "fere.me") == ""`` (the apex);
    ``subdomain_of("a.b.fere.me", "fere.me") == "a.b"``.

    If ``fqdn`` does not sit under ``apex`` it is returned unchanged — the
    planner keys on ``(name, type)`` so a stray value simply never matches a
    desired record and (lacking our marker) is left alone.
    """
    fqdn = fqdn.strip().rstrip(".").lower()
    apex = apex.strip().rstrip(".").lower()
    if fqdn == apex:
        return ""
    suffix = "." + apex
    if fqdn.endswith(suffix):
        return fqdn[: -len(suffix)]
    return fqdn


@dataclass(frozen=True)
class DesiredRecord:
    """A record the flake declares should exist."""

    apex: str
    name: str  # bare subdomain, "" == apex
    type: str
    content: str
    ttl: int

    @staticmethod
    def from_json(obj: dict) -> "DesiredRecord":
        apex = str(obj["apex"]).strip().rstrip(".").lower()
        # Accept either a bare "name"/"subdomain" or a full "fqdn".
        if "name" in obj and obj["name"] is not None:
            raw_name = str(obj["name"]).strip()
            # Tolerate "@" and the apex itself being spelled out as the name.
            if raw_name in ("@", apex):
                name = ""
            elif raw_name.endswith("." + apex):
                name = subdomain_of(raw_name, apex)
            else:
                name = raw_name.rstrip(".")
        elif "fqdn" in obj and obj["fqdn"] is not None:
            name = subdomain_of(str(obj["fqdn"]), apex)
        else:
            name = ""
        kind = normalise_type(str(obj["type"]))
        return DesiredRecord(
            apex=apex,
            name=name.lower(),
            type=kind,
            content=normalise_content(kind, str(obj["content"])),
            ttl=clamp_ttl(int(obj.get("ttl", PORKBUN_MIN_TTL))),
        )

    @property
    def fqdn(self) -> str:
        return self.apex if self.name == "" else f"{self.name}.{self.apex}"

    @property
    def key(self) -> "RecordKey":
        return RecordKey(self.apex, self.name, self.type)


@dataclass(frozen=True)
class ObservedRecord:
    """A record Porkbun reports, normalised to the desired shape."""

    id: str
    apex: str
    name: str  # bare subdomain, "" == apex
    type: str
    content: str
    ttl: int
    notes: str = ""

    @staticmethod
    def from_porkbun(apex: str, raw: dict) -> "ObservedRecord":
        kind = normalise_type(str(raw["type"]))
        return ObservedRecord(
            id=str(raw["id"]),
            apex=apex.strip().rstrip(".").lower(),
            name=subdomain_of(str(raw["name"]), apex),
            type=kind,
            content=normalise_content(kind, str(raw.get("content", ""))),
            ttl=int(str(raw.get("ttl", PORKBUN_MIN_TTL))),
            notes=str(raw.get("notes") or ""),
        )

    @property
    def fqdn(self) -> str:
        return self.apex if self.name == "" else f"{self.name}.{self.apex}"

    @property
    def key(self) -> "RecordKey":
        return RecordKey(self.apex, self.name, self.type)

    def owned_by(self, marker: str) -> bool:
        """True if this record carries our ownership marker in its notes."""
        return marker != "" and marker in self.notes

    def matches(self, desired: DesiredRecord) -> bool:
        """True if content+ttl already equal the desired record (same key assumed)."""
        return self.content == desired.content and self.ttl == desired.ttl


@dataclass(frozen=True)
class RecordKey:
    """Identity used for matching: a record is unique per (apex, name, type)."""

    apex: str
    name: str
    type: str


# ── Plan actions ────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Create:
    record: DesiredRecord

    def describe(self) -> str:
        return f"CREATE {self.record.type:5} {self.record.fqdn} -> {self.record.content} (ttl {self.record.ttl})"


@dataclass(frozen=True)
class Update:
    record: DesiredRecord
    id: str
    old_content: str
    old_ttl: int

    def describe(self) -> str:
        return (
            f"UPDATE {self.record.type:5} {self.record.fqdn} "
            f"{self.old_content}@{self.old_ttl} -> {self.record.content}@{self.record.ttl} (id {self.id})"
        )


@dataclass(frozen=True)
class Delete:
    id: str
    apex: str
    name: str
    type: str
    content: str

    @property
    def fqdn(self) -> str:
        return self.apex if self.name == "" else f"{self.name}.{self.apex}"

    def describe(self) -> str:
        return f"DELETE {self.type:5} {self.fqdn} -> {self.content} (id {self.id})"


@dataclass(frozen=True)
class NoOp:
    record: DesiredRecord
    id: str

    def describe(self) -> str:
        return f"OK     {self.record.type:5} {self.record.fqdn} -> {self.record.content} (id {self.id})"


# A plan is just an ordered list of these. Using a union alias keeps signatures
# readable without pulling in typing.Union noise everywhere.
Action = object


@dataclass
class Plan:
    """An ordered, executable reconciliation plan plus convenience views."""

    actions: list = field(default_factory=list)

    def creates(self) -> Iterable[Create]:
        return (a for a in self.actions if isinstance(a, Create))

    def updates(self) -> Iterable[Update]:
        return (a for a in self.actions if isinstance(a, Update))

    def deletes(self) -> Iterable[Delete]:
        return (a for a in self.actions if isinstance(a, Delete))

    def noops(self) -> Iterable[NoOp]:
        return (a for a in self.actions if isinstance(a, NoOp))

    def has_changes(self) -> bool:
        return any(not isinstance(a, NoOp) for a in self.actions)

    def summary(self) -> str:
        c = sum(1 for _ in self.creates())
        u = sum(1 for _ in self.updates())
        d = sum(1 for _ in self.deletes())
        n = sum(1 for _ in self.noops())
        return f"{c} create, {u} update, {d} delete, {n} unchanged"
