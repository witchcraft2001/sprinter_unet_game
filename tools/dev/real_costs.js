#!/usr/bin/env node
// real_costs.js -- the fixed core paths in plain T-states ("model") and in
// the real time of the board (memory waits, tools/harness/dramwait.js):
// STEP_ISR empty poll, the BUS_BUSY path and an idle STEP after bring-up
// (what UGTEST's ISRTIME16 / BUSYTIME16 / EMPTYSTEP16 measure through
// libman, minus the libman call).
//   node tools/dev/real_costs.js [dll ...]
'use strict';
const { ethStand, C, US } = require('../harness/ethnet.js');
const UHW_RUN = 2;
function measure(dll, waits) {
  const s = ethStand({ dll, waits });
  s.call('INIT');
  s.initConfig(s.defaultConfig({ step_budget_us: US(500) }));
  for (let i = 0; i < 3000 && s.ctx('hw_state') !== UHW_RUN; i++) s.tick(2, US(500));
  for (let i = 0; i < 50; i++) s.tick(2, US(500));
  const L = s.layout();
  const avg = (f) => { let t = 0; for (let i = 0; i < 16; i++) t += f().us; return t / 16; };
  const isr = avg(() => s.stepIsr(C.src.TIMER));
  s.m.poke(L.lock, 3);
  const busy = avg(() => s.stepIsr(C.src.TIMER));
  s.m.poke(L.lock, 0);
  const empty = avg(() => s.step(s.nowMs ? s.nowMs() : s.t, US(500)));
  return { isr, busy, empty };
}
const dlls = process.argv.slice(2);
console.log('dll        path         model us   real us   ratio');
for (const dll of dlls.length ? dlls : ['gudp509b', 'gtcp509b', 'gudprtl', 'gtcprtl', 'gudpesp', 'gtcpesp']) {
  const a = measure(dll, false), b = measure(dll, true);
  for (const k of ['isr', 'busy', 'empty']) console.log(`${dll.padEnd(10)} ${k.padEnd(10)} ${a[k].toFixed(1).padStart(9)} ${b[k].toFixed(1).padStart(9)}   ${(b[k] / a[k]).toFixed(2)}`);
}
