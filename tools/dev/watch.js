#!/usr/bin/env node
// watch.js -- e2e flow with a write watch on chosen context fields.
'use strict';
const { ethStand } = require('../harness/ethnet.js');
const A = require('../harness/abi.json');
const fields = (process.argv[2] || 'ev_tmp,chan').split(',');
const s = ethStand({ dll: 'gtcp509b' });
s.call('INIT'); s.initConfig(s.defaultConfig({ step_budget_us: 500 }));
for (let i = 0; i < 200 && s.ctx('hw_state') !== 2; i++) s.tick();
s.open(); let ev = []; for (let n = 0; n < 400 && !ev.some((e) => e.name === 'CONNECTED'); n++) { s.tick(); ev.push(...s.events()); }
s.send(Array.from({ length: 300 }, (_, i) => (i * 7) & 255), 0x42);
ev = []; for (let n = 0; n < 400 && !(ev.some((e) => e.name === 'RX_READY') && ev.some((e) => e.name === 'TX_DONE')); n++) { s.tick(); ev.push(...s.events()); }
s.drain(); s.getStats(); s.call('CLOSE');
const ctx = s.layout().ctx;
const ranges = fields.map((f) => f === 'queue' ? [s.layout().ev, s.layout().ev + 128, 'queue'] : [ctx + A.ctx.fields[f].offset, ctx + A.ctx.fields[f].offset + A.ctx.fields[f].size, f]);
const syms = Object.entries(s.syms).filter(([k]) => /^[A-Z]/.test(k) && !k.includes('.')).map(([k, v]) => [s.base + 0x20 + v, k]).sort((a, b) => a[0] - b[0]);
const owner = (pc) => { let b = '?'; for (const [a, k] of syms) { if (a <= pc) b = k; else break; } return b; };
let n = 0;
s.m.watchWrite = (a, v) => { for (const [lo, hi, f] of ranges) if (a >= lo && a < hi && n++ < 40) { const st = s.m.regs(); console.log(`write ${f}+${a - lo}=${v.toString(16)} pc=${owner(st.pc)} sp=${st.sp.toString(16)}`); } };
for (let i = 0; i < 25; i++) { s.tick(); const e = s.events(); if (e.length) console.log('step', i, JSON.stringify(e)); }
