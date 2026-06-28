"""Porkbun JSON-API client.

All network I/O goes through a small :class:`Transport` so the client is unit
testable with a fake (no sockets, no Porkbun account). The default transport
uses ``urllib.request`` over TLS — no third-party HTTP library.

Porkbun's API is a flat set of ``POST`` endpoints under
``https://api.porkbun.com/api/json/v3``; every request body carries
``apikey`` + ``secretapikey``; every response has a ``status`` field that is
``"SUCCESS"`` on the happy path. See https://porkbun.com/api/json/v3/documentation
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Protocol

from .model import ObservedRecord

API_BASE = "https://api.porkbun.com/api/json/v3"
# Stamped into the Porkbun `notes` field of every record we create or edit, so
# the pruner can recognise records it owns and never delete a human's record.
DEFAULT_MARKER = "vacationvm"


class PorkbunError(RuntimeError):
    """Any failure talking to Porkbun (HTTP, transport, or API-level error)."""


@dataclass
class Response:
    status_code: int
    body: bytes

    def json(self) -> dict:
        try:
            return json.loads(self.body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:  # pragma: no cover - defensive
            raise PorkbunError(f"non-JSON response body: {exc}") from exc


class Transport(Protocol):
    """Minimal HTTP POST transport. Implementations must not raise on non-2xx;
    they return the status code and body and let the client interpret them."""

    def post(self, url: str, body: bytes, headers: dict) -> Response:  # pragma: no cover - protocol
        ...


class UrllibTransport:
    """Default transport: ``urllib`` over the system TLS trust store."""

    def __init__(self, timeout: float = 30.0) -> None:
        self.timeout = timeout

    def post(self, url: str, body: bytes, headers: dict) -> Response:
        req = urllib.request.Request(url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return Response(status_code=resp.status, body=resp.read())
        except urllib.error.HTTPError as exc:
            # Porkbun returns a JSON error body with a non-2xx status for some
            # failures; keep the body so the client can surface the message.
            return Response(status_code=exc.code, body=exc.read())
        except urllib.error.URLError as exc:
            raise PorkbunError(f"network error contacting Porkbun: {exc.reason}") from exc


class PorkbunClient:
    """Typed wrapper over the subset of Porkbun's DNS API we use."""

    def __init__(
        self,
        api_key: str,
        secret_key: str,
        transport: Transport | None = None,
        marker: str = DEFAULT_MARKER,
    ) -> None:
        if not api_key or not secret_key:
            raise PorkbunError("both api_key and secret_key are required")
        self._api_key = api_key
        self._secret_key = secret_key
        self._transport = transport or UrllibTransport()
        self.marker = marker

    # ── low-level ───────────────────────────────────────────────────────────

    def _post(self, path: str, extra: dict | None = None) -> dict:
        payload = {"apikey": self._api_key, "secretapikey": self._secret_key}
        if extra:
            payload.update(extra)
        body = json.dumps(payload).encode("utf-8")
        url = f"{API_BASE}{path}"
        resp = self._transport.post(
            url, body, {"Content-Type": "application/json"}
        )
        data = resp.json()
        status = str(data.get("status", "")).upper()
        if resp.status_code >= 400 or status != "SUCCESS":
            msg = data.get("message") or f"HTTP {resp.status_code}, status={status or '?'}"
            raise PorkbunError(f"Porkbun {path}: {msg}")
        return data

    # ── verbs ───────────────────────────────────────────────────────────────

    def ping(self) -> str:
        """Return the caller's public IP as Porkbun sees it (creds smoke-test)."""
        return str(self._post("/ping").get("yourIp", ""))

    def retrieve_all(self, domain: str) -> list[ObservedRecord]:
        """All records for ``domain``, normalised to :class:`ObservedRecord`."""
        data = self._post(f"/dns/retrieve/{domain}")
        records = data.get("records") or []
        out: list[ObservedRecord] = []
        for raw in records:
            kind = str(raw.get("type", "")).upper()
            # Skip types we don't manage so they never enter the planner (and
            # thus can never be pruned).
            if kind not in ("A", "AAAA", "CNAME", "TXT"):
                continue
            out.append(ObservedRecord.from_porkbun(domain, raw))
        return out

    def create(self, domain: str, name: str, type: str, content: str, ttl: int) -> str:
        body = {
            "name": name,  # bare subdomain; "" == apex
            "type": type,
            "content": content,
            "ttl": str(ttl),
            "notes": self.marker,
        }
        data = self._post(f"/dns/create/{domain}", body)
        return str(data.get("id", ""))

    def edit(self, domain: str, record_id: str, name: str, type: str, content: str, ttl: int) -> None:
        body = {
            "name": name,
            "type": type,
            "content": content,
            "ttl": str(ttl),
            "notes": self.marker,
        }
        self._post(f"/dns/edit/{domain}/{record_id}", body)

    def delete(self, domain: str, record_id: str) -> None:
        self._post(f"/dns/delete/{domain}/{record_id}")
