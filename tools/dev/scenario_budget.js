#!/usr/bin/env node
// scenario_budget.js -- budget accounting (budget_calls.js) over the
// scenarios of tests/z/hw/eth_scenarios.js that profile_step.js does not
// run: every STEP over its budget with its budget calls and per-label
// profile, and the largest "needed base reserve" (STEP time minus the
// units its items reserved; PROF_STEP_BASE_US must cover it), and the
// items whose worst time exceeds reserve / 1.1 (ITEMS=1: all items).
//   shutdown  SHUTDOWN at any point of a send (minimum budget)
//   broadcast steady foreign broadcast traffic while sending (500)
//   lone      a lone send on a quiet channel, STEP every 10 ms (minimum)
// AT='<scenario tag> STEP n' also prints that STEP (the tag of the max line).
// Usage: node tools/dev/scenario_budget.js <dll> <scenario> [budget|min] [--check]
//   --check: exit 1 on an overrun, a needed base reserve above
//   PROF_STEP_BASE_US or an item over its reserve (make profile-check).
'use strict';
const { ethStand } = require('../harness/ethnet.js');
const { budgetTracker } = require('./budget_calls.js');

const check = process.argv.includes('--check');
process.argv = process.argv.filter((a) => a !== '--check');
const dll = process.argv[2] || 'gtcp509b', scen = process.argv[3] || 'broadcast';
let base = 0, itemsOver = 0;
const bytes = (n, seed = 1) => Array.from({ length: n }, (_, i) => (i * 31 + seed) & 255);
const piece = dll.startsWith('gudp') ? 512 : 536;
let need = 0, needAt = '', overs = 0;
const items = {};                       // caller:reserved -> worst real us

function stand(b) {
  const s = ethStand({ dll });
  s.call('INIT');
  const min = s.getInfo().info.min_useful_budget_us;
  const budget = b === 'min' || b === undefined && scen !== 'broadcast' ? min : +(b || 500);
  s.initConfig(s.defaultConfig({ step_budget_us: budget }));
  const tr = budgetTracker(s);
  base = s.syms.PROF_STEP_BASE_US;
  let n = 0;
  s.stepT = (dt = 2, tag = '') => {
    tr.reset();
    const prof = s.profileHook();
    const r = s.tick(dt, budget, { onStep: (m, st) => { tr.onStep(m, st); prof.hook(m, st); } });
    n++;
    const { calls, reserved, items: its } = tr.finish(r.us);
    for (const x of its) if (x.kind === '') { const k = `${x.who}:${x.reserved}`; items[k] = Math.max(items[k] || 0, x.real); }
    if (calls.length && r.us - reserved > need) { need = r.us - reserved; needAt = `${tag} STEP ${n}`; }
    if (r.us > budget || process.env.AT && `${tag} STEP ${n}` === process.env.AT) {
      overs++;
      console.log(`${tag} STEP ${n}: ${r.us.toFixed(0)} us > ${budget}`);
      for (const c of calls) console.log(`    ${c.t.toFixed(0)}us ${c.who}${c.kind} cost ${c.cost} left ${c.u} took ${c.taken}${c.refund ? ' refunded ' + c.refund : ''}`);
      console.log('    profile', JSON.stringify(prof.result().slice(0, 18)));
    }
    return r;
  };
  for (let i = 0; i < 2000 && s.ctx('hw_state') !== 2; i++) s.stepT();
  s.open();
  for (let i = 0; i < 3000; i++) { s.stepT(); if (s.events().some((e) => e.name === 'CONNECTED')) break; }
  return s;
}

if (scen === 'shutdown') {
  for (const k of [0, 4, 8, 10, 12, 16, 20, 26, 32, 40]) {
    const s = stand(process.argv[4]);
    s.send(bytes(piece, k), 0x77);
    for (let i = 0; i < k; i++) s.stepT(2, `k ${k}`);
    for (let i = 0; i < 1000; i++) { if (s.call('SHUTDOWN').a === 0) break; s.stepT(2, `k ${k}`); s.events(); }
  }
} else if (scen === 'broadcast') {
  const s = stand(process.argv[4]);
  const noise = [...[255, 255, 255, 255, 255, 255], 0x02, 9, 9, 9, 9, 9, 0x08, 0x00,
    0x45, 0, 0, 200, 0, 0, 0x40, 0, 64, 17, 0, 0, 192, 168, 0, 77, 192, 168, 0, 99, ...new Array(180).fill(0x55)];
  const d = bytes(1500, 11);
  let off = 0, got = 0;
  for (let i = 0; i < 10000 && (got < d.length || i < 3000); i++) {
    if (i % 10 === 0) s.card.deliver(noise);
    if (off < d.length && s.send(d.slice(off, off + 300), 1 + off / 300).res.a === 0) off += 300;
    s.stepT(2, 'broadcast');
    s.events();
    got += s.drain().bytes.length;
  }
} else if (scen === 'lone') {
  const s = stand(process.argv[4]);
  for (let i = 0; i < 50; i++) s.stepT(10);
  s.events(); s.drain();
  s.send(bytes(100, 4), 0x31);
  let done = -1;
  for (let i = 0; i < 1000 && done < 0; i++) { s.stepT(10, 'lone'); if (s.events().some((e) => e.name === 'TX_DONE')) done = i; }
  console.log(`TX_DONE after ${done < 0 ? 'never (1000)' : done + 1} STEPs`);
} else throw new Error(`unknown scenario ${scen}`);
for (const [k, v] of Object.entries(items).sort()) {
  const res = +k.split(':').pop();
  if (v > res) itemsOver++;
  if (v > res / 1.1 || process.env.ITEMS) console.log(`  item ${k.padEnd(34)} max ${v.toFixed(1)}${v > res ? '  OVER' : v > res / 1.1 ? '  (< 1.1)' : ''}`);
}
console.log(`${dll} ${scen}: overruns ${overs}, needed base reserve ${need.toFixed(0)} us at ${needAt} (base ${base})`);
if (check && (overs || need > base || itemsOver)) { console.log(`${dll} ${scen}: FAIL`); process.exit(1); }
