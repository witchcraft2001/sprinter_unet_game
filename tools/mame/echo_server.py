#!/usr/bin/env python3
"""echo_server.py -- the peer of the M stand: TCP and UDP echo on 127.0.0.1.

The MAME ESP-AT device opens real host sockets, so the library under test
talks to this process through the emulated SprinterESP card.

  echo_server.py [--port 7000] [--close-after N] [--log FILE]

--close-after N: a TCP connection is closed by the server once it has
echoed N bytes (the "peer closes" scenario).
--idle-close S: a TCP connection silent for S seconds is reset (RST).  A
client that vanishes without FIN/RST (scenario D on real hardware: v1
sends no RST) otherwise stays ESTABLISHED here for ever, and a later SYN
from the same address and port gets no SYN-ACK.  Every connection, datagram
and byte count is logged (one line each) for the evidence directory.
--framed: UDP carries records (GUDPESP's transparent mode, esp_fw = 2;
docs/unet-game-abi.md, tools/harness/net/xrec.js): the datagrams of a
client are read as one stream of records (the module may cut a record or
merge two), every whole record is echoed as one datagram of its own; a
header that fails its check drops what was gathered up to the client's
next datagram, a pause of a second drops a record left unfinished.
--game: UDP is the server of a real-time game (NETDEMO scenario F, the
flow of Headball, games/headball/specs.md §15.4) instead of an echo: a
client's first datagram (an input) opens its session, and from then on
the server sends it a state of GAME_STATE bytes every GAME_PERIOD s,
whatever the client sends, until the client has been silent for
GAME_IDLE s.  An input is >= 4 bytes: its seq (BE16) and the client's
now_ms of its commit (BE16).  A state is
  seq (BE16), inputs received so far (BE16), the commit time of the
  latest input (BE16), the ms the server has held that input (BE16),
  then byte i = (seq + i) & 255 for i = 8..GAME_STATE-1,
so the client measures "input up + state down" without a common clock:
now - commit time - held.  With --framed both directions are records.
"""
import argparse
import selectors
import socket
import struct
import sys
import time


XREC_MAX = 512
GAME_STATE = 88         # Headball: a state of 88 bytes 10 times a second
GAME_PERIOD = 0.1
GAME_IDLE = 1.0


def xcheck(n):
    return (0x2B + (n & 0xFF) + (n >> 8)) & 0x3F


def xencode(payload):
    n = len(payload)
    return bytes([(xcheck(n) << 2) | (n >> 8), n & 0xFF]) + payload


class XDecoder:
    """The record stream of one client (tools/harness/net/xrec.js)."""

    def __init__(self):
        self.buf, self.skip, self.bad, self.last = b'', False, 0, 0.0

    def feed(self, d, now):
        if now - self.last > 1.0:
            self.buf = b''
        self.last = now
        if self.skip:                       # a datagram start: look again
            self.skip, self.buf = False, b''
        self.buf += d
        out = []
        while len(self.buf) >= 2:
            n = ((self.buf[0] & 3) << 8) | self.buf[1]
            if n > XREC_MAX or (self.buf[0] >> 2) != xcheck(n):
                self.bad += 1
                self.buf, self.skip = b'', True
                break
            if len(self.buf) < 2 + n:
                break
            out.append(self.buf[2:2 + n])
            self.buf = self.buf[2 + n:]
        return out


class Game:
    """One client of --game: inputs in, a state every GAME_PERIOD."""

    def __init__(self, now):
        self.seq = self.inputs = self.t_in = 0
        self.at, self.last, self.next, self.prev = now, now, now, None

    def input(self, d, now):
        self.inputs += 1
        self.last = now
        if len(d) >= 4:
            self.t_in, self.at = (d[2] << 8) | d[3], now
        gap = None if self.prev is None else round((now - self.prev) * 1000)
        self.prev = now
        return ((d[0] << 8) | d[1]) if len(d) >= 2 else None, gap

    def state(self, now):
        held = min(0xFFFF, round((now - self.at) * 1000))
        head = struct.pack('>HHHH', self.seq & 0xFFFF, self.inputs & 0xFFFF, self.t_in, held)
        body = bytes((self.seq + i) & 255 for i in range(8, GAME_STATE))
        self.seq += 1
        self.next += GAME_PERIOD
        if self.next < now:             # a late wake-up: no burst of states
            self.next = now + GAME_PERIOD
        return head + body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default='127.0.0.1')
    ap.add_argument('--port', type=int, default=7000)
    ap.add_argument('--close-after', type=int, default=0)
    ap.add_argument('--idle-close', type=float, default=0)
    ap.add_argument('--log', default=None)
    ap.add_argument('--framed', action='store_true')
    ap.add_argument('--game', action='store_true')
    a = ap.parse_args()
    xdec = {}
    games = {}
    log = open(a.log, 'a', buffering=1) if a.log else sys.stdout

    def note(*parts):
        log.write('%.3f %s\n' % (time.time(), ' '.join(str(p) for p in parts)))

    sel = selectors.DefaultSelector()
    lst = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    lst.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    lst.bind((a.host, a.port))
    lst.listen(4)
    lst.setblocking(False)
    sel.register(lst, selectors.EVENT_READ, 'accept')
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    udp.bind((a.host, a.port))
    udp.setblocking(False)
    sel.register(udp, selectors.EVENT_READ, 'udp')
    echoed = {}
    seen = {}
    note('listening', a.host, a.port, 'close-after', a.close_after, 'framed' if a.framed else '', 'game' if a.game else '')
    print('ready', flush=True)
    while True:
        now = time.time()
        for peer, g in list(games.items()):
            if now - g.last > GAME_IDLE:
                note('game end', peer, 'inputs', g.inputs, 'states', g.seq)
                games.pop(peer)
                xdec.pop(peer, None)
                continue
            if now >= g.next:
                st = g.state(now)
                udp.sendto(xencode(st) if a.framed else st, peer)
        wait = min([1.0] + [max(0.0, g.next - time.time()) for g in games.values()])
        if a.idle_close:
            for c in [c for c, t in seen.items() if time.time() - t > a.idle_close]:
                note('tcp reset: idle', echoed.pop(c, 0))
                seen.pop(c)
                sel.unregister(c)
                c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
                c.close()
        for key, _ in sel.select(wait):
            if key.data == 'accept':
                c, peer = lst.accept()
                c.setblocking(False)
                c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                sel.register(c, selectors.EVENT_READ, 'tcp')
                echoed[c] = 0
                seen[c] = time.time()
                note('tcp connect', peer)
            elif key.data == 'udp':
                d, peer = udp.recvfrom(4096)
                if a.game:
                    now = time.time()
                    if peer not in games:
                        games[peer] = Game(now)
                        note('game start', peer)
                    recs = xdec.setdefault(peer, XDecoder()).feed(d, now) if a.framed else [d]
                    for r in recs:
                        seq, gap = games[peer].input(r, now)
                        note('game input', peer, len(r), 'seq', seq, 'gap_ms', gap)
                    continue
                if not a.framed:
                    udp.sendto(d, peer)
                    note('udp', peer, len(d))
                    continue
                dec = xdec.setdefault(peer, XDecoder())
                bad = dec.bad
                recs = dec.feed(d, time.time())
                for r in recs:
                    udp.sendto(xencode(r), peer)
                note('udp framed', peer, len(d), 'records', [len(r) for r in recs],
                     'bad header' if dec.bad > bad else '')
            else:
                c = key.fileobj
                try:
                    d = c.recv(4096)
                except ConnectionError:
                    d = b''
                if not d:
                    seen.pop(c, None)
                    note('tcp closed by the client', echoed.pop(c, 0))
                    sel.unregister(c)
                    c.close()
                    continue
                if a.close_after:
                    d = d[:max(0, a.close_after - echoed[c])]
                seen[c] = time.time()
                c.sendall(d)
                echoed[c] += len(d)
                note('tcp echo', len(d), 'total', echoed[c])
                if a.close_after and echoed[c] >= a.close_after:
                    note('tcp close by the server after', echoed[c])
                    sel.unregister(c)
                    echoed.pop(c, None)
                    seen.pop(c, None)
                    c.close()


if __name__ == '__main__':
    main()
