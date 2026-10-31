#!/usr/bin/env node
// overrun.js -- run the audit scenario (connect, 300-byte echo, close) and,
// for every STEP above the budget, print the budget calls with the units
// left and the time between them (PROFILE=1: per-label time of that STEP;
// ITEMS=1: worst real time of every successful budget item, caller:units).
// AT=n: budget calls and profile of STEP n.  SCEN=stream: 8 KiB echo at a 2 ms STEP period instead of the short run.
// Usage: node tools/dev/overrun.js gtcprtl [budget]
'use strict';
const { ethStand } = require('../harness/ethnet.js');
const A = require('../harness/abi.json');
const dll = process.argv[2] || 'gtcprtl';
const budget = +(process.argv[3] || 500);
const s = ethStand({ dll });
s.call('INIT');
s.initConfig(s.defaultConfig({ step_budget_us: budget }));
const ua = s.layout().ctx + A.ctx.fields.units.offset;
const syms = Object.entries(s.syms).filter(([k]) => !k.includes('.') && /^[A-Z]/.test(k)).map(([k, v]) => [s.base + 0x20 + v, k]).sort((a, b) => a[0] - b[0]);
const owner = (pc) => { let b = '?'; for (const [a, k] of syms) { if (a <= pc) b = k; else break; } return b; };
const pts = { [s.sym('TAKE')]: 'T', [s.sym('BUDGET_BYTES')]: 'B' };
let n = 0, over = 0, baseMax = 0, baseAt = -1, needMax = 0, needAt = -1;
const itemMax = {};                     // caller/cost -> [max real us, reserved]
const run = (k) => { for (let i = 0; i < k; i++) {
  const log = []; let c0 = null; const calls = [];
  s.pump(); s.t += 10;
  const prof = (process.env.PROFILE || (process.env.AT && +process.env.AT === n)) ? s.profileHook() : null;
  const r = s.step(s.t, budget, 0, { onStep: (m, st) => {
    if (prof) prof.hook(m, st);
    if (c0 === null) c0 = m.cycles;
    const l = pts[st.pc];
    if (l) calls.push({ t: (m.cycles - (c0 ?? m.cycles)) / m.mhz, u: m.peek16(ua), cost: (st.h << 8) | st.l, who: owner(m.peek16(st.sp) - 3) + (l === 'B' ? '/bytes' : '') });
    if (l) log.push(`${((m.cycles - c0) / m.mhz).toFixed(0)}us ${l}${(st.h << 8) | st.l}@${owner(m.peek16(st.sp) - 3)} left ${m.peek16(ua)}`);
  } });
  s.pump();
  // base path = the whole call minus the work bought by successful budget
  // calls (a call succeeded when the units dropped before the next one)
  let items = 0, reserved = 0;
  for (let k = 0; k < calls.length; k++) {
    const next = calls[k + 1];
    const uAfter = next ? next.u : null;
    const tNext = next ? next.t : r.us;
    const used = (uAfter ?? s.m.peek16(ua));
    if (k > 0 && used < calls[k].u) {
      const real = tNext - calls[k].t;
      items += real;
      reserved += calls[k].u - used;
      const key = `${calls[k].who}:${calls[k].u - used}`;
      if (!itemMax[key] || itemMax[key] < real) itemMax[key] = real;
    }
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
  const dt = 2, piece = dll.startsWith('gudp') ? 512 : 536;
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
