#!/usr/bin/env node
// pkt_profile.js -- where the time of one packet goes: per-label time
// (exclusive, by enclosing global label) of every STEP from TX_COMMIT to
// the whole echo, on the Z stand, one packet at a time.
//   node tools/dev/pkt_profile.js <dll> [budget] [bytes] [--top n]
'use strict';
const { boot, has, bytes } = require('../../tests/z/hw/eth_scenarios.js');
const { C } = require('../harness/ethnet.js');
const S = C.status;
const argv = process.argv.slice(2);
const ti = argv.indexOf('--top');
const top = ti >= 0 ? +argv.splice(ti, 2)[1] : 14;
const dll = argv[0] || 'gudp509b', budget = +(argv[1] || 2000), size = +(argv[2] || 64);
const s = boot(dll, {}, { budget });
if (s.open().a !== S.OK) throw new Error('OPEN');
s.until(has('CONNECTED'), 6000);
s.run(50); s.events(); s.drain();
const total = {};
const pts = { [s.sym('TAKE')]: 'T', [s.sym('BUDGET_BYTES')]: 'B', [s.sym('RUN_PORTION')]: 'P' };
const syms = Object.entries(s.syms).map(([k, v]) => [s.base + 0x20 + v, k]).sort((a, b) => a[0] - b[0]);
const owner = (pc) => { let b = '?'; for (const [a, k] of syms) { if (a <= pc) b = k; else break; } return b; };
for (let k = 0; k < 2; k++) {
  const x = s.send(bytes(size, 7 + k), k + 1);
  if (x.res.a !== S.OK || x.commit.a !== S.OK) throw new Error('send');
  let got = 0, tx = 0, echo = 0;
  for (let i = 1; i <= 400 && (!tx || !echo); i++) {
    const log = [];
    const r = s.tick(2, budget, { profile: true, onStep: (m, st) => { const l = pts[st.pc]; if (!l) return;
      log.push(l === 'P' ? `[portion ${owner(m.peek16(st.sp) - 3)}]` : `${l === 'B' ? 'bytes ' : ''}${(st.h << 8) | st.l}@${owner(m.peek16(st.sp) - 3)}`); } });
    const ev = s.events().map((e) => e.name);
    if (ev.includes('TX_DONE')) tx = i;
    got += s.drain().bytes.length;
    if (got >= size) echo = i;
    if (k === 1) {
      console.log(`STEP ${i}: ${r.us.toFixed(0)} us  events [${ev.join(',')}] rx ${got}`);
      console.log('    budget: ' + log.join(' '));
      console.log('    ' + s.lastProfile.slice(0, top).map(([l, v]) => `${l} ${v}`).join(', '));
      for (const [l, v] of s.lastProfile) total[l] = (total[l] || 0) + v;
    }
  }
  s.run(20); s.events(); s.drain();
}
const sum = Object.values(total).reduce((a, b) => a + b, 0);
console.log(`\npacket total ${sum.toFixed(0)} us:`);
for (const [l, v] of Object.entries(total).sort((a, b) => b[1] - a[1]).slice(0, 40)) console.log(`  ${l.padEnd(18)} ${v.toFixed(1).padStart(7)}  ${(100 * v / sum).toFixed(1)} %`);
