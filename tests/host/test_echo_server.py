"""echo_server.py --game: the game server of NETDEMO scenario F (the flow of
Headball): a state of GAME_STATE bytes every GAME_PERIOD once a client's
first input came, the inputs counted and their commit time echoed with the
time the server held it, the session ended after GAME_IDLE of silence;
--framed: both directions are records (GUDPESP's transparent mode)."""
from __future__ import annotations

import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "mame"))
import echo_server  # noqa: E402


def free_port() -> int:
    """A port free for both TCP and UDP (the server binds both)."""
    for _ in range(20):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as u, socket.socket() as t:
            u.bind(("127.0.0.1", 0))
            port = u.getsockname()[1]
            try:
                t.bind(("127.0.0.1", port))
            except OSError:
                continue
            return port
    raise RuntimeError("no free port")


class GameServerTests(unittest.TestCase):
    def flow(self, framed: bool, seconds: float = 1.0):
        port = free_port()
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "server.log"
            args = [sys.executable, str(ROOT / "tools/mame/echo_server.py"), "--port", str(port), "--game", "--log", str(log)]
            srv = subprocess.Popen(args + (["--framed"] if framed else []), stdout=subprocess.PIPE, text=True)
            try:
                self.assertEqual(srv.stdout.readline().strip(), "ready")
                c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                c.settimeout(0.005)
                dec = echo_server.XDecoder()
                t0, sent, states = time.time(), 0, []
                while time.time() - t0 < seconds + echo_server.GAME_IDLE + 0.3:
                    now = time.time() - t0
                    if now < seconds and now >= sent * 0.04:
                        inp = struct.pack(">HH", sent, round(now * 1000) & 0xFFFF) + bytes(16)
                        c.sendto(echo_server.xencode(inp) if framed else inp, ("127.0.0.1", port))
                        sent += 1
                    try:
                        d_, _ = c.recvfrom(1024)
                    except socket.timeout:
                        continue
                    for st in (dec.feed(d_, time.time()) if framed else [d_]):
                        states.append((round((time.time() - t0) * 1000), st))
                c.close()
                text = log.read_text()
            finally:
                srv.terminate()
                srv.wait()
                srv.stdout.close()
        return sent, states, text

    def check(self, framed: bool) -> None:
        sent, states, log = self.flow(framed)
        # 10 a second while the client sends, none after GAME_IDLE of silence
        self.assertGreaterEqual(len(states), 9)
        self.assertLessEqual(len(states), 1 + round((1.0 + echo_server.GAME_IDLE) / echo_server.GAME_PERIOD))
        last_n = 0
        for i, (t, st) in enumerate(states):
            self.assertEqual(len(st), echo_server.GAME_STATE)
            seq, n, t_in, held = struct.unpack(">HHHH", st[:8])
            self.assertEqual(seq, i)
            self.assertTrue(all(st[k] == (seq + k) & 255 for k in range(8, echo_server.GAME_STATE)))
            self.assertGreaterEqual(n, last_n)
            last_n = n
            # input up + state down, measured as NETDEMO F does: on localhost
            # a few ms, never negative beyond the 1-ms rounding
            self.assertLess(abs(t - t_in - held), 25)
        self.assertEqual(last_n, sent)
        self.assertIn("game start", log)
        self.assertIn(f"game end ('127.0.0.1', ", log)
        self.assertIn(f"inputs {sent} states {len(states)}", log)

    def test_plain(self) -> None:
        self.check(False)

    def test_framed(self) -> None:
        self.check(True)


class XDecoderTests(unittest.TestCase):
    """The record stream of one peer, cut by the module wherever it likes."""

    @staticmethod
    def stream(n_rec: int, size: int = 500) -> tuple[bytes, list[bytes]]:
        recs = [bytes((7 + 31 * (i * size + k)) & 255 for k in range(size)) for i in range(n_rec)]
        return b"".join(echo_server.xencode(r) for r in recs), recs

    def test_stall_inside_a_record(self) -> None:
        # the sixth Ж ESP series, NETDEMO S: 1460 bytes end 456 bytes into a
        # record, the module stalls 2.8 s, the next datagram completes it
        s, recs = self.stream(17)
        cuts = [(0, 3012, 0.0), (3012, 4016, 2.7), (4016, 5476, 2.7), (5476, 6024, 5.5),
                (6024, 7484, 5.5), (7484, len(s), 6.6)]
        dec, got = echo_server.XDecoder(), []
        for a, b, t in cuts:
            got += dec.feed(s[a:b], 100.0 + t)
        self.assertEqual(dec.bad, 0)
        self.assertEqual(got, recs)

    def test_new_session_after_a_cut_one(self) -> None:
        # a run cut in the middle of a record, the next run from the same
        # port starts its own stream after a pause
        s, recs = self.stream(3, 100)
        dec = echo_server.XDecoder()
        self.assertEqual(dec.feed(s[:150], 10.0), recs[:1])
        self.assertEqual(dec.feed(s, 15.0), recs)
        self.assertEqual(dec.bad, 0)

    def test_bad_header_resyncs_at_a_datagram(self) -> None:
        s, recs = self.stream(2, 100)
        dec = echo_server.XDecoder()
        self.assertEqual(dec.feed(b"\xff\xff" + s[:10], 1.0), [])
        self.assertEqual(dec.bad, 1)
        self.assertEqual(dec.feed(s, 1.1), recs)


if __name__ == "__main__":
    unittest.main()
