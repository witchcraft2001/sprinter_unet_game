"""Vendored files must match the SHA-256 pinned in THIRD_PARTY.md."""
import hashlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ThirdPartyTests(unittest.TestCase):
    def test_z80core_pinned(self) -> None:
        text = (ROOT / "THIRD_PARTY.md").read_text()
        pinned = re.search(r"^([0-9a-f]{64})$", text, re.M).group(1)
        actual = hashlib.sha256((ROOT / "tools" / "harness" / "z80core.js").read_bytes()).hexdigest()
        self.assertEqual(actual, pinned)


if __name__ == "__main__":
    unittest.main()
