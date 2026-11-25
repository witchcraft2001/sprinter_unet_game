#!/usr/bin/env python3
"""xstream.py -- where every byte of a transparent-mode stream came from.

  tools/dev/xstream.py <server_x.log> [--piece 500] [--total 8192] [--seed 7]

The record echo server (tools/mame/echo_server.py --framed) logs every
datagram whole.  A stream scenario (UGTEST / NETDEMO S) sends `total` bytes
of the stand pattern (byte i = seed + 31 i mod 256, sdk/example/ugtest.asm
send_one) in TX slots of `piece` bytes, each slot one record (2-byte header,
docs/unet-game-abi.md).  With piece 500 no two records are alike
(build_hw.sh -DUG_PIECE=500), so every 16 bytes of a datagram occur at one
place of the stream the client sent.

For every session (datagrams closer than 5 s) whose byte count is near the
stream's, it prints each datagram as segments "stream offset +length", and
the verdict: in order, a gap (bytes lost), a repeat (bytes sent twice) or
bytes from elsewhere -- with the offset they came from, its record and the
start of the datagram before (a module that re-reads its packet buffer puts
out the head of the previous packet; the core can only put out the record
it is sending).
"""
import argparse
import re
import sys


def xhdr(n):
    return bytes([(((0x2B + (n & 0xFF) + (n >> 8)) & 0x3F) << 2) | (n >> 8), n & 0xFF])


def stream(total, piece, seed):
    out, rec_at, i = bytearray(), [], 0
    while i < total:
        n = min(piece, total - i)
        rec_at.append(len(out))
        out += xhdr(n) + bytes((seed + 31 * (i + k)) & 255 for k in range(n))
        i += n
    return bytes(out), rec_at


def segments(d, e, index, w=16):
    """[(d_off, length, e_off or None)] by 16-byte windows, greedy."""
    segs, j = [], 0
    while j < len(d):
        key = d[j:j + w]
        cands = index.get(key, []) if len(key) == w else [k for k in range(len(e)) if e.startswith(key, k)]
        if not cands:
            if segs and segs[-1][2] is None:
                segs[-1] = (segs[-1][0], segs[-1][1] + 1, None)
            else:
                segs.append((j, 1, None))
            j += 1
            continue
        best = None
        for c in cands:                     # the longest run from this window
            n = 0
            while j + n < len(d) and c + n < len(e) and d[j + n] == e[c + n]:
                n += 1
            if best is None or n > best[1]:
                best = (c, n)
        segs.append((j, best[1], best[0]))
        j += best[1]
    return segs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('log')
    ap.add_argument('--piece', type=int, default=500)
    ap.add_argument('--total', type=int, default=8192)
    ap.add_argument('--seed', type=int, default=7)
    a = ap.parse_args()
    e, rec_at = stream(a.total, a.piece, a.seed)
    index = {}
    for k in range(len(e) - 15):
        index.setdefault(e[k:k + 16], []).append(k)
    rx = re.compile(r'^(\d+\.\d+) udp framed .* (\d+) crc ([0-9a-f]{8}) .*datagram ([0-9a-f]+)\s*$')
    sessions, cur, last = [], [], 0.0
    for line in open(a.log, encoding='latin1'):
        m = rx.match(line)
        if not m:
            continue
        t, d = float(m.group(1)), bytes.fromhex(m.group(4))
        if cur and t - last > 5.0:
            sessions.append(cur)
            cur = []
        cur.append((t, d))
        last = t
    if cur:
        sessions.append(cur)
    rec_of = lambda off: max(r for r, s in enumerate(rec_at) if s <= off)
    shown = 0
    for s in sessions:
        n = sum(len(d) for _, d in s)
        if abs(n - len(e)) > len(e) // 4:
            continue
        shown += 1
        print(f'session at {s[0][0]:.3f}: {len(s)} datagrams, {n} bytes (stream {len(e)}, {len(rec_at)} records)')
        expect, prev_start, faults = 0, None, 0
        for t, d in s:
            segs = segments(d, e, index)
            txt = []
            for j, ln, off in segs:
                if off is None:
                    txt.append(f'?{ln}')
                    faults += 1
                    continue
                note = ''
                if off != expect:
                    faults += 1
                    if off > expect:
                        note = f' GAP {off - expect}'
                    elif off + ln <= expect:
                        note = f' REPEAT of {off} (record {rec_of(off)} +{off - rec_at[rec_of(off)]})'
                    else:
                        note = f' OVERLAP {expect - off}'
                    if prev_start is not None and off == prev_start:
                        note += ' = start of the datagram before'
                txt.append(f'{off}+{ln}{note}')
                expect = max(expect, off + ln)
            prev_start = segs[0][2] if segs and segs[0][2] is not None else prev_start
            print(f'  {t:.3f} {len(d):5d}: ' + ', '.join(txt))
        tail = len(e) - expect
        print(f'  verdict: {"in order, complete" if not faults and not tail else f"{faults} faults, {tail} bytes never seen at the end"}')
    if not shown:
        print('no session of about the stream size (check --piece / --total)')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
