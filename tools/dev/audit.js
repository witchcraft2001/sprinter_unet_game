#!/usr/bin/env node
// audit.js -- budget audit of a whole connect/send/echo/close run.
'use strict';
const { ethStand } = require('../harness/ethnet.js');
const { budgetAudit } = require('../harness/audit.js');
const dll = process.argv[2] || 'gtcp509b';
const s = ethStand({ dll });
s.call('INIT');
const cfg = s.defaultConfig({ step_budget_us: 500 });
if (dll.startsWith('gudp')) { cfg.tx_slot_size = 512; cfg.rx_slot_size = 512; }
s.initConfig(cfg);
const a = budgetAudit(s);
let over = 0, worst = 0;
const run = (n) => { for (let i = 0; i < n; i++) { s.pump(); s.t += 10; const r = s.step(s.t, 500, 0, { onStep: (m, st) => a.hook(m, st) }); a.end(s.m); s.pump(); if (r.us > 500) over++; worst = Math.max(worst, r.us); } };
run(60); s.open(); run(60); s.events();
s.send(Array.from({ length: 300 }, (_, i) => i & 255), 0x42); run(200); s.events(); s.drain(); run(10);
s.call('CLOSE'); run(80);
console.log('overruns', over, 'worst', worst.toFixed(0));
for (const [k, v] of a.report(14)) console.log(k.padEnd(28), JSON.stringify(v));
