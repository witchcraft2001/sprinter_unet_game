"""Host checks: ABI sources vs generated files, block layouts, delivery list."""
from __future__ import annotations

import json
import re
import subprocess
import sys
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import gen_abi  # noqa: E402


class AbiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.abi = tomllib.loads((ROOT / "abi" / "unetgame_abi.toml").read_text(encoding="utf-8"))
        self.d = gen_abi.load()
        self.json = json.loads((ROOT / "tools" / "harness" / "abi.json").read_text())

    def test_generated_files_are_fresh(self) -> None:
        for path, text in gen_abi.outputs().items():
            self.assertEqual(path.read_text(encoding="utf-8"), text, f"{path} is stale: run make gen")

    def test_status_source_event_values(self) -> None:
        st = self.abi["status"]
        self.assertEqual(sorted(st.values()), list(range(0x0C)), "statuses 0x00..0x0B, dense")
        self.assertEqual(st["BUS_BUSY"], 0x04)
        self.assertEqual(st["DEVICE_FAULT"], 0x0B)
        self.assertEqual(sorted(self.abi["src"].values()), list(range(1, 7)))
        self.assertEqual(sorted(self.abi["ev"].values()), list(range(1, 13)))
        self.assertEqual(self.abi["flag"]["MASK_ROUTE"], 0x01)
        self.assertEqual(self.abi["timeout"], {"OPEN": 1, "TX": 2, "CLOSE": 3})
        self.assertEqual(self.abi["txdone"], {"OK": 0, "CANCEL": 1, "FAILED": 2})
        self.assertEqual(self.abi["lock"]["NET_MAIN"], 1)
        self.assertEqual(self.abi["lock"]["NET_ISR"], 2)

    def test_exports(self) -> None:
        names = [e["name"] for e in self.d["exports"]]
        self.assertEqual(names[:2], ["INIT", "FINI"])
        for required in ("INIT_CONFIG", "SHUTDOWN", "STEP", "STEP_ISR", "OPEN", "CLOSE", "ABORT",
                         "TX_RESERVE", "TX_COMMIT", "TX_UNRESERVE", "RX_PEEK", "RX_RELEASE",
                         "NEXT_EVENT", "GET_INFO", "GET_STATS"):
            self.assertIn(required, names)
        jt = (ROOT / "include" / "unetg_jt.inc").read_text()
        order = re.findall(r"JP\s+EXP_(\w+)", jt)
        self.assertEqual(order[:len(names)], names)
        self.assertEqual(len(order), self.abi["exports"]["reserved_to"] + 1)

    def test_blocks(self) -> None:
        b = self.json["blocks"]
        self.assertEqual(b["EVT"]["size"], 8)
        self.assertEqual(list(b["EVT"]["fields"]), ["type", "channel", "tag", "status", "slot", "detail"])
        for name in ("CFG", "INFO", "STATS"):
            f = b[name]["fields"]
            self.assertEqual((f["abi_version"]["offset"], f["size"]["offset"]), (0, 2))
        # every field naturally inside a signed-8 window from IX = cfg + 64
        self.assertLessEqual(b["CFG"]["size"], 64 + 128)
        # GET_INFO patch target and STATS DI chunk boundary (src/core/info.asm)
        self.assertLess(b["INFO"]["fields"]["image_base"]["offset"], 128)
        offsets = {v["offset"] for v in b["STATS"]["fields"].values()}
        self.assertIn(4 + 38, offsets, "GET_STATS chunk must end on a field boundary")
        self.assertEqual(self.json["ctx"]["fields"]["stats"]["size"], b["STATS"]["size"] - 4)

    def test_copy_runs(self) -> None:
        self.assertEqual(len(self.d["copies"]), 4)
        for c in self.d["copies"]:
            self.assertLess(c["ctx"] + c["len"], 257)

    def test_delivery_names(self) -> None:
        out = subprocess.run([sys.executable, str(ROOT / "tools" / "check_names.py")], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        listed = [d["src"] for d in self.abi["dll"]]
        build = (ROOT / "tools" / "build.sh").read_text()
        m = re.search(r"ALL_DLLS=\(([^)]*)\)", build)
        self.assertEqual(m.group(1).split(), listed)


if __name__ == "__main__":
    unittest.main()
