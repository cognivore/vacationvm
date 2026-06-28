"""Unit tests for record normalisation and JSON parsing."""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from vacationvm_dns.model import (  # noqa: E402
    DesiredRecord,
    ObservedRecord,
    clamp_ttl,
    normalise_content,
    normalise_type,
    subdomain_of,
)


class NormalisationTests(unittest.TestCase):
    def test_subdomain_of(self):
        self.assertEqual(subdomain_of("blog.fere.me", "fere.me"), "blog")
        self.assertEqual(subdomain_of("fere.me", "fere.me"), "")
        self.assertEqual(subdomain_of("a.b.fere.me", "fere.me"), "a.b")
        self.assertEqual(subdomain_of("FERE.ME", "fere.me"), "")
        self.assertEqual(subdomain_of("blog.fere.me.", "fere.me"), "blog")

    def test_clamp_ttl(self):
        self.assertEqual(clamp_ttl(60), 600)
        self.assertEqual(clamp_ttl(600), 600)
        self.assertEqual(clamp_ttl(3600), 3600)

    def test_normalise_type(self):
        self.assertEqual(normalise_type("a"), "A")
        self.assertEqual(normalise_type("cname"), "CNAME")
        with self.assertRaises(ValueError):
            normalise_type("MX")

    def test_normalise_content_cname(self):
        self.assertEqual(normalise_content("CNAME", "Edge.Fere.Me."), "edge.fere.me")

    def test_normalise_content_txt_strips_quotes(self):
        self.assertEqual(normalise_content("TXT", '"hello world"'), "hello world")
        self.assertEqual(normalise_content("TXT", "v=spf1 -all"), "v=spf1 -all")


class DesiredFromJsonTests(unittest.TestCase):
    def test_name_and_apex(self):
        rec = DesiredRecord.from_json(
            {"apex": "fere.me", "name": "wyrm", "type": "A", "content": "1.2.3.4", "ttl": 600}
        )
        self.assertEqual(rec.name, "wyrm")
        self.assertEqual(rec.fqdn, "wyrm.fere.me")

    def test_at_sign_is_apex(self):
        rec = DesiredRecord.from_json(
            {"apex": "fere.me", "name": "@", "type": "A", "content": "1.2.3.4"}
        )
        self.assertEqual(rec.name, "")
        self.assertEqual(rec.fqdn, "fere.me")

    def test_fqdn_form(self):
        rec = DesiredRecord.from_json(
            {"apex": "fere.me", "fqdn": "wyrm.fere.me", "type": "A", "content": "1.2.3.4"}
        )
        self.assertEqual(rec.name, "wyrm")

    def test_name_given_as_full_fqdn(self):
        rec = DesiredRecord.from_json(
            {"apex": "fere.me", "name": "wyrm.fere.me", "type": "A", "content": "1.2.3.4"}
        )
        self.assertEqual(rec.name, "wyrm")

    def test_default_ttl_clamped(self):
        rec = DesiredRecord.from_json(
            {"apex": "fere.me", "name": "x", "type": "A", "content": "1.2.3.4", "ttl": 5}
        )
        self.assertEqual(rec.ttl, 600)


class ObservedFromPorkbunTests(unittest.TestCase):
    def test_fqdn_name_becomes_subdomain(self):
        rec = ObservedRecord.from_porkbun(
            "fere.me",
            {"id": "12", "name": "wyrm.fere.me", "type": "A", "content": "1.2.3.4", "ttl": "600", "notes": "vacationvm"},
        )
        self.assertEqual(rec.name, "wyrm")
        self.assertEqual(rec.id, "12")
        self.assertTrue(rec.owned_by("vacationvm"))

    def test_numeric_id_coerced_to_str(self):
        rec = ObservedRecord.from_porkbun(
            "fere.me",
            {"id": 99, "name": "x.fere.me", "type": "A", "content": "1.2.3.4", "ttl": 600},
        )
        self.assertEqual(rec.id, "99")
        self.assertFalse(rec.owned_by("vacationvm"))


if __name__ == "__main__":
    unittest.main()
