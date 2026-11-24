"""Host checks of the Ж report decoding (tools/measure/parse_hw.py and
tools/mame/ugreport.py) on synthetic reports with known numbers."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "measure"))
sys.path.insert(0, str(ROOT / "tools" / "mame"))
import parse_hw  # noqa: E402

FRAME_MS = 20.0          # with CAL 6400 (25600 counts): 0.78125 us per count


def block_hex(name: str, **fields: int) -> str:
    abi = json.loads((ROOT / "tools" / "harness" / "abi.json").read_text())
    blk = abi["blocks"][name]
    size = max(f["offset"] + f["size"] * f.get("count", 1) for f in blk["fields"].values())
    b = bytearray(size)
    for k, v in fields.items():
        f = blk["fields"][k]
        b[f["offset"]:f["offset"] + f["size"]] = v.to_bytes(f["size"], "little")
    return b.hex().upper()


def ugtest_report(lat="0004 3200 0000C800 0004 6400 00019000 0000 00", overrun=0) -> str:
    return "\r\n".join([
        "UGTEST GTCPRTL.DLL", "SCEN K", "CAL 6400 1000",
        "INFO " + block_hex("INFO", bus_busy_us=25, empty_poll_us=55, min_useful_budget_us=425),
        "INIT_CONFIG 00", "HW RUN",
        "ISRTIME16 0C00", "BUSYTIME16 0200", "EMPTYSTEP16 0800",
        "OPEN", "EV 01/00",
        "SOAK 00007530 0A00 01000000 00100000 00",
        "CALLTIME16 0100",
        "STATS " + block_hex("STATS", uart_overrun=overrun, tx_bytes=1000),
        "STEPTIME 0200 0100 00010000 0000", "NOW_MS 00001000",
        "LAT " + lat, "SHUTDOWN ", "RESULT: PASS", ""])


PROBE = "\r\n".join([
    "UGPROBE E", "SCEN E", "CAL 6400 1000",
    "PROBE CPU 6400 1000 1000 1000",
    "PROBE ISA_RD 0100 0100 0100 0100 00C0 00C0 00C0 00C0",
    "PROBE ISA_WR 0100 0100 0100 0100 00C0 00C0 00C0 00C0",
    "PROBE BRACKET 2000 0A00",
    "PROBE CTC 0190 0640 00004600 0000",
    "PROBE UART08 00AC 0014 0009 0000 0001 0000 0000 0000 0000 0000 0000 0000 0013 0000 0000 0000 0000 0000 0000 0000",
    "PROBE RTS08 0028 B",
    "RESULT: PASS", ""])


class ParseHwTests(unittest.TestCase):
    def parse(self, name: str, text: str):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / name
            p.write_text(text)
            return parse_hw.parse_file(p, FRAME_MS, 8)[1]

    def test_ugtest_numbers_and_pass(self) -> None:
        s = self.parse("URTLTK.TXT", ugtest_report())
        self.assertEqual((s["prog"], s["dll"], s["scenario"]), ("ugtest", "gtcprtl", "K"))
        self.assertEqual(s["step"]["max_us"], 400)            # 0x200 x 0.78125
        self.assertEqual(s["trivial_call_us"], 12)            # 0x100 x 0.78125 / 16
        hw = s["hw"]
        self.assertEqual(hw["costs16"]["isr"]["per_call_us"], 150.0)
        self.assertEqual(hw["lat"]["txdone"]["max_us"], 10000.0)
        self.assertEqual(hw["lat"]["echo"]["mean_us"], 20000.0)
        self.assertEqual(hw["soak"]["frames"], 30000)
        self.assertEqual(hw["soak"]["net_max_us"], 2000.0)
        self.assertEqual(s["criteria"], {"result": True, "overflow": True, "step": True, "latency": True,
                                         "soak": True, "isr": True, "bus_busy": True})

    def test_ugtest_failures(self) -> None:
        s = self.parse("URTLTK.TXT", ugtest_report(lat="0004 FFFF 0003FFFC 0000 0000 00000000 0004 03",
                                                   overrun=1))
        self.assertEqual(s["hw"]["lat"]["saturated"], 4)
        self.assertNotIn("max_us", s["hw"]["lat"]["txdone"])
        self.assertIs(s["criteria"]["latency"], False)
        self.assertIs(s["criteria"]["overflow"], False)

    def test_probe(self) -> None:
        s = self.parse("PROBEE.TXT", PROBE)
        pr = s["probe"]
        self.assertEqual(pr["CPU"]["ctc_clock_mhz"], 20.48)    # 25600 x 16 / 20000 us
        self.assertEqual(pr["ISA_RD"]["extra_us_per_access_mean"], 0.781)   # 64 counts / 64
        self.assertEqual(pr["CTC"]["sample_us"], 37.5)         # 20000 x (1/400 - 1/1600)
        self.assertEqual(pr["RTS08"]["resume"], "below_trigger")
        self.assertEqual(pr["UART08"]["hist_1_16plus"][8], 19)
        self.assertEqual(s["criteria"], {"result": True, "probe_ctc": True, "probe_uart": True})

    def test_slot(self) -> None:
        # hw.env said slot 0, the card answered only in slot 1 and ran there
        s = self.parse("URTLTK.TXT", ugtest_report().replace("SCEN K", "SCEN K\r\nSLOT 0 02 1"))
        self.assertEqual(s["hw"]["slot"], {"configured": 0, "found": [1], "used": 1})
        self.assertIs(s["criteria"]["card_found"], True)
        # the first 3C509B runs on Zh: isa_slot 2 -> INIT_CONFIG BAD_CONFIG
        s = self.parse("U509TE.TXT", "\r\n".join([
            "UGTEST GTCP509B.DLL", "SCEN E", "CAL 6900 1569", "INIT_CONFIG 08", "RESULT: FAIL C", ""]))
        self.assertIs(s["criteria"]["result"], False)
        # no slot answers: the probe fails
        s = self.parse("PROBE3.TXT", "\r\n".join([
            "UGPROBE 3", "SCEN 3", "SLOT 1 00 1", "CAL 6400 1000", "RESULT: FAIL S", ""]))
        self.assertEqual(s["hw"]["slot"]["found"], [])
        self.assertIs(s["criteria"]["card_found"], False)
        self.assertIs(s["criteria"]["result"], False)

    def test_bring(self) -> None:
        # hw_bring: ms of the bring-up and the card scratch byte at RUN
        s = self.parse("URTLTK.TXT", ugtest_report().replace("HW RUN", "HW RUN\r\nBRING 00A0 01"))
        self.assertEqual(s["hw"]["bring"], {"ms": 160, "scratch": 1})
        self.assertNotIn("bring", self.parse("URTLTK.TXT", ugtest_report())["hw"])

    def test_state(self) -> None:
        # UGPROBE 3 1 after a series: what is left to the system stack;
        # addresses stay out of the evidence but a change is still seen
        head = ["UGPROBE 3", "SCEN 3", "CARD 00 00 50 6D 00 00 10 00", "DSSENV BOOTDSK=C:",
                "DSSENV NET=509B", "DSSENV NET_IP=192.168.1.148", "DSSENV NET_GW -",
                "DSSENV NET_LEASE_SEC=92.168.1.1", "DSSENV NET_DNS=10.0.0.1"]
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "STATA3.TXT"
            p.write_text("\r\n".join(head + ["RESULT: PASS", ""]))
            text, s = parse_hw.parse_file(p, FRAME_MS, 8)
        self.assertEqual((s["prog"], s["card"]), ("ugstate", "EL3"))
        self.assertEqual(s["state"]["card_regs"], ["00", "00", "50", "6D", "00", "00", "10", "00"])
        self.assertEqual(s["state"]["env"]["NET"], "509B")
        self.assertIsNone(s["state"]["env"]["NET_GW"])
        self.assertNotIn("192.168", text + json.dumps(s))
        # an address under any other name too (RTL series: NET_LEASE_SEC)
        self.assertNotIn("92.168", text + json.dumps(s))
        self.assertNotIn("10.0.0", text + json.dumps(s))
        self.assertEqual(parse_hw.state_of("DSSENV NET_LEASE_SEC=25200\r\n")[1]["env"]["NET_LEASE_SEC"], "25200")
        other = parse_hw.state_of("DSSENV NET_IP=192.168.1.149\r\n")[1]["env"]["NET_IP"]
        self.assertNotEqual(s["state"]["env"]["NET_IP"], other)
        # the probe carries the same head: the "before" side
        s = self.parse("PROBE3.TXT", "\r\n".join(head + ["SLOT 0 01 0", "CAL 6400 1000", "RESULT: PASS", ""]))
        self.assertEqual(s["prog"], "ugprobe")
        self.assertEqual(s["state"]["env"]["BOOTDSK"], "C:")

    def test_transparent_name(self) -> None:
        # X: GUDPESP in its transparent mode (tools/hw/build_hw.sh UGTESPX)
        rep = ugtest_report().replace("UGTEST GTCPRTL.DLL", "UGTEST GUDPESP.DLL").replace("SCEN K", "SCEN E")
        s = self.parse("UESPXE.TXT", rep)
        self.assertEqual((s["prog"], s["dll"], s["scenario"]), ("ugtest", "gudpespx", "E"))
        self.assertIsNone(parse_hw.identify("URTLXE.TXT", []))

    def test_flow(self) -> None:
        # NETDEMO F: offered, sent, at the server, states, first / last state
        # seq, TX_DONE max, loop max, loop sum, max gap (sdk/example/netdemo.asm)
        def rep(flow):
            return "\r\n".join(["NETDEMO GUDPRTL.DLL", "SCEN F", "SLOT 0 01 0", "OPEN", "EV 01/00",
                                  "FLOW " + flow, "EV 09/00", "SHUTDOWN 00", "RESULT: PASS", ""])
        s = self.parse("NRTLUF.TXT", rep("00FB 00FB 00F8 0064 0000 0063 0028 0075 239B 0078"))
        f = s["hw"]["flow"]
        self.assertEqual((f["offered"], f["skipped"], f["at_server"], f["states"], f["states_lost"]), (251, 0, 248, 100, 0))
        self.assertEqual((f["txdone_max_ms"], f["loop_max_ms"], f["loop_mean_ms"], f["state_gap_max_ms"]), (40, 117, 91.2, 120))
        self.assertEqual(f["inputs_per_s"], 24.8)
        self.assertTrue(s["criteria"]["flow"])
        # a lost state (seq 0..100 seen as 100 states) or too few inputs fail it
        self.assertEqual(self.parse("NRTLUF.TXT", rep("00FB 00FB 00F8 0064 0000 0064 0028 0075 239B 00C8"))["hw"]["flow"]["states_lost"], 1)
        self.assertFalse(self.parse("NRTLUF.TXT", rep("00FB 00FB 00F8 0064 0000 0064 0028 0075 239B 00C8"))["criteria"]["flow"])
        self.assertFalse(self.parse("NESPUF.TXT", rep("00FB 0033 0032 0064 0000 0063 00DC 00EB 4D62 0078")
                                    .replace("GUDPRTL", "GUDPESP"))["criteria"]["flow"])
        # seq wraps at 16 bits
        self.assertEqual(self.parse("NRTLUF.TXT", rep("00FB 00FB 00F8 0064 FFF0 0053 0028 0075 239B 0078"))["hw"]["flow"]["states_lost"], 0)

    def test_name_mismatch(self) -> None:
        with self.assertRaises(ValueError):
            self.parse("UESPTS.TXT", ugtest_report())          # the report says GTCPRTL


if __name__ == "__main__":
    unittest.main()
