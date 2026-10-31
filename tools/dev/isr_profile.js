#!/usr/bin/env node
// isr_profile.js -- per-label time of the STEP_ISR paths on a quiet,
// connected channel: empty poll, pre-acquired poll, BUS_BUSY, refusal.
// Usage: node tools/dev/isr_profile.js gtcprtl
'use strict';
const { ethStand, C } = require('../harness/ethnet.js');
const dll = process.argv[2] || 'gtcprtl';
const s = ethStand({ dll });
s.call('INIT');
s.initConfig(s.defaultConfig({ step_budget_us: 500 }));
for (let i = 0; i < 2000 && s.ctx('hw_state') !== 2; i++) s.tick(2, 500);
s.open();
for (let i = 0; i < 3000; i++) { s.tick(2, 500); if (s.events().some((e) => e.name === 'CONNECTED')) break; }
for (let i = 0; i < 300; i++) s.tick(2, 500);
s.events();
const L = s.layout();
const run = (what, budget, pre, lock) => {
  s.m.poke(L.lock, lock);
  const r = s.call('STEP_ISR', { a: C.src.TIMER | (pre ? 0x80 : 0), de: budget }, { iff: 0, isr: true, profile: true });
  s.m.poke(L.lock, 0);
  console.log(`${what}: status ${r.a} ${r.us.toFixed(1)} us ${r.tstates ?? ''} stack ${r.stack} ${r.problems.join('; ')}`);
  console.log('   ', s.lastProfile.map(([k, v]) => `${k} ${v}`).join(', '));
};
run('empty poll', 150, false, 0);
run('pre-acquired', 150, true, 2);
run('BUS_BUSY', 150, false, 3);
run('refused', 20, false, 0);
