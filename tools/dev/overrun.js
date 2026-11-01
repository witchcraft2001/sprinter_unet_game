#!/usr/bin/env node
// overrun.js -- run the audit scenario (connect, 300-byte echo, close) and,
// for every STEP above the budget, print the budget calls with the units
// left and the time between them (PROFILE=1: per-label time of that STEP;
// ITEMS=1: worst real time of every successful budget item, caller:units).
// AT=n: budget calls and profile of STEP n.  SCEN=stream: 8 KiB echo at a 2 ms STEP period (DT=ms) instead of the short run.
// Usage: node tools/dev/overrun.js gtcprtl [budget]
'use strict';
const { ethStand } = require('../harness/ethnet.js');
const { budgetTracker } = require('./budget_calls.js');
const dll = process.argv[2] || 'gtcprtl';
const budget = +(process.argv[3] || 500);
const s = ethStand({ dll });
s.call('INIT');
s.initConfig(s.defaultConfig({ step_budget_us: budget }));
const tr = budgetTracker(s);
let n = 0, over = 0, baseMax = 0, baseAt = -1, needMax = 0, needAt = -1;
const itemMax = {};                     // caller:reserved -> max real us
const run = (k) => { for (let i = 0; i < k; i++) {
  s.pump(); s.t += 10;
  const prof = (process.env.PROFILE || (process.env.AT && +process.env.AT === n)) ? s.profileHook() : null;
  tr.reset();
  const r = s.step(s.t, budget, 0, { onStep: (m, st) => { if (prof) prof.hook(m, st); tr.onStep(m, st); } });
  s.pump();
  // base path = the whole call minus the work bought by successful budget
  // calls, after refunds (budget_calls.js)
  const { items: its, reserved, calls } = tr.finish(r.us);
  const log = calls.map((c) => `${c.t.toFixed(0)}us ${c.kind === '/round' ? 'P' + (0x10000 - c.bc) + ' de' + c.de : c.kind === '/bytes' ? 'B' + c.cost : 'T' + c.cost}@${c.who}` +
    ` left ${c.u} took ${c.taken}${c.refund ? ' refunded ' + c.refund : ''}`);
  let items = 0;
  for (const x of its) {
    items += x.real;
    const key = `${x.who}:${x.reserved}`;
    if (!itemMax[key] || itemMax[key] < x.real) itemMax[key] = x.real;
  }
  const base = r.us - items;
  // what the fixed STEP reserve must cover for this call to stay in budget
  const need = r.us - reserved;
  if (calls.length && need > needMax) { needMax = need; needAt = n; }
  if (process.env.AT && +process.env.AT === n) {
    console.log(`step ${n}: ${r.us.toFixed(0)} us, base ${base.toFixed(0)}, need ${need.toFixed(0)}`);
    for (const x of log) console.log('   ', x);
    console.log('    profile', JSON.stringify(prof.result()));
  }
  if (calls.length && base > baseMax) { baseMax = base; baseAt = n; }
  if (r.us > budget) {
    over++;
    console.log(`step ${n}: ${r.us.toFixed(0)} us`);
    for (const x of log) console.log('   ', x);
    if (prof) console.log('    profile', JSON.stringify(prof.result().slice(0, 24)));
  }
  n++;
} };
if (process.env.SCEN === 'stream') {
  // 8 KiB echoed in 536/512-byte pieces at a 2 ms STEP period
  const dt = +(process.env.DT || 2), piece = dll.startsWith('gudp') ? 512 : 536;
  const runDt = (k) => { for (let i = 0; i < k; i++) { s.t -= 10 - dt; run(1); } };
  runDt(400); s.open(); runDt(400); s.events();
  const d = Array.from({ length: 8192 }, (_, i) => (i * 31 + 3) & 255);
  let off = 0, tag = 1, got = 0;
  for (let i = 0; i < 20000 && got < d.length; i++) {
    if (off < d.length) {
      const res = s.call('TX_RESERVE', { de: Math.min(piece, d.length - off) });
      if (res.a === 0) { const n = Math.min(piece, d.length - off); s.m.pokeBytes(res.hl, d.slice(off, off + n)); s.call('TX_COMMIT', { a: res.de & 0xff, de: n, ix: tag++ }); off += n; }
    }
    runDt(1); s.events(); got += s.drain().bytes.length;
  }
  console.log('stream: echoed', got, 'of', d.length);
} else {
  run(60); s.open(); run(60); s.events();
  s.send(Array.from({ length: 300 }, (_, i) => i & 255), 0x42); run(200); s.events(); s.drain(); run(10);
  s.call('CLOSE'); run(80);
}
if (process.env.ITEMS) for (const [k, v] of Object.entries(itemMax).sort()) console.log('  item', k.padEnd(30), 'max real', v.toFixed(0));
console.log('overruns', over, 'base path max', baseMax.toFixed(0), 'us at step', baseAt,
  '| needed base reserve', needMax.toFixed(0), 'us at step', needAt, '(PROF_STEP_BASE_US must cover it)');
