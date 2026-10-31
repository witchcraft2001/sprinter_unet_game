#!/usr/bin/env node
// step_profile.js -- per-label time of an idle STEP on a quiet connected
// channel (the fixed STEP path: prologue, clock, card poll, transport idle
// step, deadlines, flush).  Usage: node tools/dev/step_profile.js gtcprtl [n]
'use strict';
const { ethStand } = require('../harness/ethnet.js');
const dll = process.argv[2] || 'gtcprtl', n = +(process.argv[3] || 4);
const s = ethStand({ dll });
s.call('INIT');
s.initConfig(s.defaultConfig({ step_budget_us: 500 }));
for (let i = 0; i < 2000 && s.ctx('hw_state') !== 2; i++) s.tick(2, 500);
s.open();
for (let i = 0; i < 3000; i++) { s.tick(2, 500); if (s.events().some((e) => e.name === 'CONNECTED')) break; }
for (let i = 0; i < 300; i++) s.tick(2, 500);
s.events();
for (let i = 0; i < n; i++) {
  const r = s.tick(2, 500, { profile: true });
  console.log(`STEP ${i}: ${r.us.toFixed(1)} us`);
  console.log('   ', s.lastProfile.map(([k, v]) => `${k} ${v}`).join(', '));
}
