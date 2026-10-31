#!/usr/bin/env node
// profile_step.js -- per-build STEP profile under the 8 KiB stream scenario
// (connect, 8 KiB echoed in 536/512-byte pieces) at several STEP periods,
// plus the direct STEP_ISR paths and the STEPs one segment needs.
//
// For every DLL and period it prints:
//   - every successful budget item (caller:reserved units) with its worst
//     and p99 real time and ratio = reserved / worst real (< 1: the reserve
//     is too small, the STEP can overrun its budget);
//   - the needed base reserve (STEP time minus what the items reserved:
//     PROF_STEP_BASE_US must cover it), overruns, worst STEP, worst DI;
//   - the echo rate in virtual time and the STEPs the stream took;
// then STEP_ISR: empty poll (with and without pre-acquire), BUS_BUSY (lock
// held by the sound owner), budget refusal; and the STEPs from TX_COMMIT of
// a 100/536-byte segment to its TX_DONE and to the echo.
//
// Usage: node tools/dev/profile_step.js [dll...] [--dt 2,10,20] [--budget 500]
//        [--json out.json] [--base base.json] [--check] [--items] [--incl]
//   --json  store the results; --base  print deltas against a stored run;
//   --check exit 1 when a STEP overran its budget, the stand found a
//           problem or a stream did not finish intact (make profile-check);
//           item ratios < 1 are reported, not fatal: an item's real time
//           runs to the next budget call or phase boundary;
//   --items print the item table; --incl inclusive time of the main labels.
'use strict';
const fs = require('fs');
const { ethStand, C } = require('../harness/ethnet.js');
const A = require('../harness/abi.json');

const S = C.status;
const UHW_RUN = 2;
const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args.splice(i, 2)[1] : def; };
const flag = (name) => { const i = args.indexOf(name); if (i >= 0) args.splice(i, 1); return i >= 0; };
const dts = opt('--dt', '2,10,20').split(',').map(Number);
const budget = +opt('--budget', 500);
const jsonOut = opt('--json', null), baseIn = opt('--base', null);
const check = flag('--check'), showItems = flag('--items'), showIncl = flag('--incl');
const dlls = args.length ? args : ['gtcpesp', 'gudpesp', 'gtcprtl', 'gudprtl', 'gtcp509b', 'gudp509b', 'gloop'];
const INCL = ['TXP_DATA', 'TXP_BEGIN', 'RXP_COPY', 'RXP_HEADER', 'NIC_TX_WRITE', 'NIC_RX_READ', 'ETH_CLASSIFY', 'ETH_ACCEPT', 'ETH_SUM0', 'TP_RX_STORE', 'TP_RX_ACCEPT', 'EXP_STEP', 'CLOCK_STEP', 'DEADLINES', 'EV_FLUSH', 'HW_STEP', 'HW_RUN', 'ETH_RX_STEP', 'ETH_TX_STEP', 'TP_STEP',
  'TCP_CHOOSE', 'TP_TX_PULL', 'TP_RX_COMMIT', 'TCP_ACKED', 'TCP_RELEASE', 'IP_TEMPLATE', 'RUN_PORTION', 'PORTION',
  'ISA_ACQUIRE', 'ISA_RELEASE', 'ISA_MAP', 'ISA_UNMAP', 'UART_PUMP', 'ESP_PARSE', 'ESP_PEND', 'CSUM_RAM'];
const bytes = (n, seed = 1) => Array.from({ length: n }, (_, i) => (i * 31 + seed) & 255);
const p99 = (a) => { const b = [...a].sort((x, y) => x - y); return b[Math.min(b.length - 1, Math.floor(b.length * 0.99))]; };

function boot(dll, b = budget) {
  const s = ethStand({ dll });
  s.call('INIT');
  const r = s.initConfig(s.defaultConfig({ step_budget_us: b }));
  if (r.a !== S.OK) throw new Error(`${dll}: INIT_CONFIG ${r.a}`);
  return s;
}

// Instrumented STEP: budget calls (TAKE / BUDGET_BYTES / PARSE_BUDGET) with
// the units left, so that the time between a successful call and the next
// one (or the next scheduler phase boundary: the dispatch and the STEP tail
// belong to the base path) is the real cost of the item it bought.
const BOUNDS = ['EV_FLUSH', 'DEADLINES', 'TP_IF_RUNNING', 'ETH_AFFORD', 'ETH_RX_CONT', 'ETH_TX_CONT', 'ETH_STEP_ODD', 'UNITS_REFUND'];
function instrument(s, b, acc) {
  const ua = s.layout().ctx + A.ctx.fields.units.offset;
  const syms = Object.entries(s.syms).filter(([k]) => !k.includes('.') && /^[A-Z]/.test(k))
    .map(([k, v]) => [s.base + 0x20 + v, k]).sort((x, y) => x[0] - y[0]);
  const owner = (pc) => { let lo = 0, hi = syms.length - 1, best = '?'; while (lo <= hi) { const mid = (lo + hi) >> 1; if (syms[mid][0] <= pc) { best = syms[mid][1]; lo = mid + 1; } else hi = mid - 1; } return best; };
  const pts = { [s.sym('TAKE')]: '', [s.sym('BUDGET_BYTES')]: '/bytes' };
  if ('PARSE_BUDGET' in s.syms) pts[s.sym('PARSE_BUDGET')] = '/round';
  const incl = INCL.filter((l) => l in s.syms);
  const bounds = new Set(BOUNDS.filter((l) => l in s.syms).map((l) => s.sym(l)));
  return (dt) => {
    const calls = [], marks = []; let c0 = null;
    const r = s.tick(dt, b, {
      inclusive: showIncl ? incl : null,
      onStep: (m, st) => {
        if (c0 === null) c0 = m.cycles;
        const l = pts[st.pc];
        if (l !== undefined) calls.push({ t: (m.cycles - c0) / m.mhz, u: m.peek16(ua), who: owner(m.peek16(st.sp) - 3) + l });
        else if (bounds.has(st.pc)) marks.push((m.cycles - c0) / m.mhz);
      },
    });
    let reserved = 0;
    for (let k = 0; k < calls.length; k++) {   // the base reserve is inline (no TAKE)
      const next = calls[k + 1];
      const used = next ? next.u : s.m.peek16(ua);
      if (used < calls[k].u) {
        let end = next ? next.t : r.us;
        for (const t of marks) if (t > calls[k].t && t < end) { end = t; break; }
        const real = end - calls[k].t;
        reserved += calls[k].u - used;
        const key = calls[k].who.endsWith('/bytes') || calls[k].who.endsWith('/round') ? calls[k].who : `${calls[k].who}:${calls[k].u - used}`;
        const it = (acc.items[key] ||= { reserved: calls[k].u - used, real: [] });
        it.reserved = Math.min(it.reserved, calls[k].u - used);
        // variable-size items: compare the real time with this call's reserve
        it.real.push(key.includes('/') ? real / (calls[k].u - used) : real);
      }
    }
    if (calls.length) acc.need = Math.max(acc.need, r.us - reserved);
    acc.steps++;
    acc.maxUs = Math.max(acc.maxUs, r.us);
    acc.maxDi = Math.max(acc.maxDi, r.maxDiUs || 0);
    if (r.us > b) acc.over++;
    if (r.problems.length) acc.problems.push(...r.problems.slice(0, 2));
    if (showIncl && s.lastInclusive) for (const [k, v] of Object.entries(s.lastInclusive)) {
      const x = (acc.incl[k] ||= { max: 0, sum: 0, n: 0 });
      for (const u of v) { x.max = Math.max(x.max, u); x.sum += u; x.n++; }
    }
    return r;
  };
}

function streamRun(dll, dt) {
  const s = boot(dll);
  const acc = { items: {}, need: 0, steps: 0, maxUs: 0, maxDi: 0, over: 0, problems: [], incl: {} };
  const step = instrument(s, budget, acc);
  for (let i = 0; i < 2000 && s.ctx('hw_state') !== UHW_RUN; i++) step(2);
  s.open();
  let ok = false;
  for (let i = 0; i < 3000 && !ok; i++) { step(2); ok = s.events().some((e) => e.name === 'CONNECTED'); }
  if (!ok) return { error: 'no CONNECTED' };
  acc.steps = 0;
  const piece = dll.startsWith('gudp') ? 512 : 536, d = bytes(8192, 11);
  const t0 = s.t;
  let off = 0, tag = 1, got = 0, errors = [];
  for (let i = 0; i < 20000 && got < d.length; i++) {
    if (off < d.length) {
      const n = Math.min(piece, d.length - off);
      const x = s.send(d.slice(off, off + n), tag);
      if (x.res.a === S.OK) { off += n; tag++; }
    }
    step(dt);
    for (const e of s.events()) if (e.name === 'STREAM_ERROR' || e.name === 'CLOSED' || e.name === 'TIMEOUT') errors.push(e.name);
    got += s.drain().bytes.length;
  }
  const ms = s.t - t0;
  const items = {};
  for (const [k, v] of Object.entries(acc.items)) {
    const max = Math.max(...v.real);
    items[k] = { reserved: v.reserved, max: +max.toFixed(1), p99: +p99(v.real).toFixed(1), n: v.real.length,
      ratio: +(k.includes('/') ? 1 / max : v.reserved / max).toFixed(2) };
  }
  return { echoed: got, of: d.length, ms, rate: +(got / ms * 1000 / 1024).toFixed(2), steps: acc.steps,
    need: +acc.need.toFixed(0), maxUs: +acc.maxUs.toFixed(0), maxDi: +acc.maxDi.toFixed(0), over: acc.over,
    errors: [...new Set(errors)], problems: acc.problems.slice(0, 3), items,
    incl: Object.fromEntries(Object.entries(acc.incl).map(([k, x]) => [k, { max: +x.max.toFixed(1), avg: +(x.sum / x.n).toFixed(1), n: x.n }])) };
}

// STEP_ISR paths on a quiet connected channel, and STEPs per segment.
function isrAndSegments(dll) {
  const s = boot(dll);
  const tick = (n = 1) => { for (let i = 0; i < n; i++) s.tick(2, budget); };
  for (let i = 0; i < 2000 && s.ctx('hw_state') !== UHW_RUN; i++) tick();
  s.open();
  for (let i = 0; i < 3000; i++) { tick(); if (s.events().some((e) => e.name === 'CONNECTED')) break; }
  tick(300); s.events();
  const out = {};
  const isr = (pre) => { let w = 0; for (let i = 0; i < 4; i++) { const r = s.stepIsr(C.src.TIMER, 150, pre); if (r.a === S.IDLE) w = Math.max(w, r.us); } return +w.toFixed(1); };
  out.empty = isr(false);
  const L = s.layout();
  s.m.poke(L.lock, 1); out.emptyPre = isr(true); s.m.poke(L.lock, 0);
  s.m.poke(L.lock, 3);
  const bb = s.stepIsr(C.src.TIMER, 150, false);
  out.busBusy = bb.a === S.BUS_BUSY || dll === 'gloop' ? +bb.us.toFixed(1) : `status ${bb.a}`;
  s.m.poke(L.lock, 0);
  const rf = s.stepIsr(C.src.TIMER, 20, false);
  out.refused = rf.a === S.YIELD ? +rf.us.toFixed(1) : `status ${rf.a}`;
  // idle STEP
  let idle = 0; for (let i = 0; i < 20; i++) idle = Math.max(idle, s.tick(2, budget).us);
  out.idleStep = +idle.toFixed(0);
  for (const n of [100, dll.startsWith('gudp') ? 512 : 536]) {
    const x = s.send(bytes(n, n & 255), 0x55);
    if (x.res.a !== S.OK) { out[`seg${n}`] = 'no slot'; continue; }
    let done = -1, echo = -1, rx = 0;
    for (let i = 1; i <= 2000 && (done < 0 || echo < 0); i++) {
      tick();
      for (const e of s.events()) { if (e.name === 'TX_DONE' && done < 0) done = i; }
      rx += s.drain().bytes.length;
      if (rx >= n && echo < 0) echo = i;
    }
    out[`seg${n}`] = { txDone: done, echo };
    tick(50); s.events(); s.drain();
  }
  return out;
}

const res = {};
for (const dll of dlls) {
  res[dll] = { dt: {} };
  for (const dt of dts) res[dll].dt[dt] = streamRun(dll, dt);
  res[dll].isr = isrAndSegments(dll);
}

const base = baseIn ? JSON.parse(fs.readFileSync(baseIn, 'utf8')) : null;
const delta = (v, b) => (b === undefined || typeof v !== 'number' || typeof b !== 'number' ? '' : ` (${v - b >= 0 ? '+' : ''}${+(v - b).toFixed(2)})`);
let bad = 0;
for (const dll of dlls) {
  const R = res[dll], B = base?.[dll];
  console.log(`== ${dll}`);
  for (const dt of dts) {
    const r = R.dt[dt], b = B?.dt?.[dt] || {};
    if (r.error) { console.log(`  DT ${dt}: ${r.error}`); bad++; continue; }
    const low = Object.entries(r.items).filter(([, v]) => v.ratio < 1);
    console.log(`  DT ${String(dt).padStart(2)} ms: echoed ${r.echoed}/${r.of} in ${r.ms} ms = ${r.rate} KiB/s${delta(r.rate, b.rate)}, ` +
      `${r.steps} STEPs${delta(r.steps, b.steps)}, need base ${r.need}${delta(r.need, b.need)}, max STEP ${r.maxUs}${delta(r.maxUs, b.maxUs)}, ` +
      `DI ${r.maxDi}, over ${r.over}${r.errors.length ? ', events ' + r.errors : ''}${low.length ? ', ratio<1: ' + low.map(([k]) => k) : ''}`);
    if (r.problems.length) console.log('     problems:', r.problems.join('; '));
    if (showItems) for (const [k, v] of Object.entries(r.items).sort()) {
      const bv = b.items?.[k];
      console.log(`     ${k.padEnd(34)} res ${String(v.reserved).padStart(4)} max ${String(v.max).padStart(6)}${delta(v.max, bv?.max)} p99 ${String(v.p99).padStart(6)} n ${String(v.n).padStart(5)} ratio ${v.ratio}`);
    }
    if (showIncl) for (const [k, v] of Object.entries(r.incl).sort((x, y) => y[1].max - x[1].max)) console.log(`     incl ${k.padEnd(18)} max ${v.max} avg ${v.avg} n ${v.n}`);
    if (check && (r.over || r.echoed < r.of || r.problems.length || r.errors.length)) bad++;
  }
  const i = R.isr, bi = B?.isr || {};
  console.log(`  STEP_ISR: empty poll ${i.empty}${delta(i.empty, bi.empty)} (pre-acquired ${i.emptyPre}), BUS_BUSY ${i.busBusy}${delta(i.busBusy, bi.busBusy)}, ` +
    `refused ${i.refused}; idle STEP ${i.idleStep}${delta(i.idleStep, bi.idleStep)}`);
  for (const k of Object.keys(i).filter((x) => x.startsWith('seg'))) {
    const v = i[k], bv = bi[k] || {};
    console.log(`  ${k.slice(3)} bytes: TX_DONE after ${v.txDone}${delta(v.txDone, bv.txDone)} STEPs, echo after ${v.echo}${delta(v.echo, bv.echo)}`);
  }
}
if (jsonOut) fs.writeFileSync(jsonOut, JSON.stringify(res, null, 1));
if (check && bad) { console.log(`profile-check: ${bad} failing run(s)`); process.exit(1); }
