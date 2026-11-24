#!/usr/bin/env node
// real_ratio.js -- how much longer a STEP lasts on the board than its
// plain T-state count: the same deterministic scenario runs twice, without
// and with the memory waits of the board (tools/harness/dramwait.js), and
// every STEP is compared with its twin.  The largest ratio is the factor
// between the "model microseconds" the core counts in and real time.
//   node tools/dev/real_ratio.js [--budgets a,b] [dll ...]
'use strict';
const { boot, has, bytes } = require('../../tests/z/hw/eth_scenarios.js');
const { C } = require('../harness/ethnet.js');
const S = C.status;

function run(dll, budget) {
  const s = boot(dll, {}, { budget });
  const us = [], real = [];
  const tick = s.tick;
  s.tick = (...a) => { const r = tick(...a); us.push(r.plainUs); real.push(r.us); return r; };
  if (s.open().a !== S.OK) throw new Error('OPEN');
  s.until(has('CONNECTED'), 6000);
  const data = bytes(4096, 3);
  let off = 0, tag = 1, got = 0;
  for (let i = 0; i < 20000 && (off < data.length || got < data.length); i++) {
    if (off < data.length) {
      const n = Math.min(300, data.length - off);
      const x = s.send(data.slice(off, off + n), tag);
      if (x.res.a === S.OK) { off += n; tag++; }
    }
    s.run(1, 2); s.events(); got += s.drain().bytes.length;
  }
  if (got < data.length) throw new Error(`${dll} ${budget}: stream stalled at ${got}`);
  const isr = [];
  for (let i = 0; i < 8; i++) { const r = s.stepIsr(C.src.TIMER); isr.push(r.us / r.plainUs); }
  return { us, real, isr, maxDi: Math.max(...s.calls.map((c) => c.di ?? 0)) };
}

process.env.UG_WAITS = '1';
const argv = process.argv.slice(2);
const bi = argv.indexOf('--budgets');
const budgets = bi >= 0 ? argv.splice(bi, 2)[1].split(',').map(Number) : [1231, 2000];   // real us: 500 units, the largest
const dlls = argv.length ? argv : ['gudp509b', 'gtcp509b', 'gudprtl', 'gtcprtl', 'gudpesp', 'gtcpesp'];
console.log('dll        budget  STEPs   ratio real/model: max   mean   min (STEPs >= 100 us)   longest STEP model / real us   STEP_ISR ratio');
for (const dll of dlls) for (const b of budgets) {
  const a = run(dll, b);
  let max = 0, min = 9, sum = 0, n = 0, lm = 0, lr = 0;
  a.us.forEach((u, i) => { lm = Math.max(lm, u); lr = Math.max(lr, a.real[i]); if (u < 100) return; const r = a.real[i] / u; max = Math.max(max, r); min = Math.min(min, r); sum += r; n++; });
  console.log(`${dll.padEnd(10)} ${String(b).padStart(6)} ${String(n).padStart(6)}   ${max.toFixed(3)}  ${(sum / n).toFixed(3)}  ${min.toFixed(3)}        ${lm.toFixed(0)} / ${lr.toFixed(0)}      ${Math.max(...a.isr).toFixed(3)}`);
}
