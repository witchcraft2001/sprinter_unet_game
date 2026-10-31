#!/usr/bin/env node
// tcpcheck.js -- TCP stream on an Ethernet build: for every data segment the
// DLL transmits, compare its payload with the application data at that
// sequence offset and report checksum failures and retransmissions.
// Usage: node tools/dev/tcpcheck.js gtcp509b [bytes] [budget]
'use strict';
const { boot, bytes, has } = require('../../tests/z/hw/eth_scenarios.js');
const { be16, be32 } = require('../harness/net/peer.js');
const dll = process.argv[2] || 'gtcp509b';
const total = +(process.argv[3] || 8192);
const budget = +(process.argv[4] || 500);
const s = boot(dll, {}, { budget });
s.open(); s.until(has('CONNECTED'));
const d = bytes(total, 3);
const orig = s.peer.input.bind(s.peer);
let base = null, step = 0;
const seen = new Map();
s.card.onTransmit = (f) => {
  const e0 = s.peer.errors.length; orig(f);
  if (be16(f, 12) !== 0x0800 || f[23] !== 6) return;
  const len = be16(f, 16) - 20, hl = (f[46] >> 4) * 4, pl = f.slice(34 + hl, 34 + len), seq = be32(f, 38);
  if (!pl.length) return;
  if (base === null) base = seq;
  const off = (seq - base) >>> 0, exp = d.slice(off, off + pl.length), diff = pl.findIndex((v, i) => v !== exp[i]);
  const again = seen.has(off); seen.set(off, (seen.get(off) || 0) + 1);
  if (s.peer.errors.length > e0 || diff >= 0 || again) {
    console.log(`step ${step} ${s.peer.errors.length > e0 ? 'BAD-CSUM' : 'csum-ok '} ${again ? 'RETX' : 'new '} off ${off} len ${pl.length} payload ${diff < 0 ? 'intact' : 'differs at ' + diff}`);
  }
};
let off = 0, tag = 1;
const rx = [];
for (; step < 4000 && rx.length < d.length; step++) {
  if (off < d.length) { const x = s.send(d.slice(off, off + 536), tag); if (x.res.a === 0) { off += Math.min(536, d.length - off); tag++; } }
  s.run(1); s.events(); rx.push(...s.drain().bytes);
}
console.log('steps', step, 'rx', rx.length, 'intact', JSON.stringify(rx) === JSON.stringify(d), 'retransmits', s.getStats().stats.tcp_retransmits, 'peer errors', s.peer.errors.length, 'problems', s.probs.slice(0, 2));
