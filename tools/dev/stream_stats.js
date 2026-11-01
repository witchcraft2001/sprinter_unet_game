#!/usr/bin/env node
// stream_stats.js -- the 8 KiB stream (536/512-byte pieces) at one STEP
// period and budget: STEPs, virtual time, our and the peer's
// retransmissions, budget yields.  Usage:
//   node tools/dev/stream_stats.js gtcprtl [dt_ms=20] [budget=500|min]
'use strict';
const { ethStand } = require('../harness/ethnet.js');

const dll = process.argv[2] || 'gtcprtl', dt = +(process.argv[3] || 20);
const s = ethStand({ dll });
s.call('INIT');
const budget = process.argv[4] === 'min' ? s.getInfo().info.min_useful_budget_us : +(process.argv[4] || 500);
s.initConfig(s.defaultConfig({ step_budget_us: budget }));
for (let i = 0; i < 2000 && s.ctx('hw_state') !== 2; i++) s.tick(2, budget);
s.open();
for (let i = 0; i < 3000; i++) { s.tick(2, budget); if (s.events().some((e) => e.name === 'CONNECTED')) break; }
const piece = dll.startsWith('gudp') ? 512 : 536;
const d = Array.from({ length: 8192 }, (_, i) => (i * 31 + 11) & 255);
let off = 0, tag = 1, got = 0, steps = 0;
const t0 = s.t;
for (let i = 0; i < 20000 && got < d.length; i++) {
  if (off < d.length) {
    const n = Math.min(piece, d.length - off);
    if (s.send(d.slice(off, off + n), tag).res.a === 0) { off += n; tag++; }
  }
  s.tick(dt, budget);
  steps++;
  s.events();
  got += s.drain().bytes.length;
}
const st = s.getStats().stats;
console.log(`${dll} DT ${dt} budget ${budget}: ${got}/${d.length} bytes, ${steps} STEPs, ${s.t - t0} ms, ` +
  `our retransmits ${st.tcp_retransmits}, peer retransmits ${s.peer.retransmits}, budget yields ${st.budget_yields}`);
