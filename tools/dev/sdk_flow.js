#!/usr/bin/env node
// sdk_flow.js -- NETDEMO F (the flow of Headball) on the Z application
// stand: the real SDK gateway with its CTC ticks, guaranteed polls and
// STEPs that the tick interrupts (tools/harness/appstand.js), in the real
// time of the board.  An input of 20 bytes every 40 ms, at most one in
// flight (an input offered while the previous one has no TX_DONE yet is
// skipped, as NETDEMO's fl_offer does), and the peer's state of 88 bytes
// every 100 ms; both have their own phase, swept over a period because a
// deterministic run (MAME) meets the STEPs at one phase only.
// Usage: node tools/dev/sdk_flow.js [dll ...] [--steps n] [--budget us]
//        [--polls ticks] [--isr us] [--s seconds] [--in ms,...] [--st ms,...]
//   --trace n    print the time line of the first n inputs whose TX_DONE
//                took longer than --trace-ms (default: the input period)
//   --in / --st  phases (ms after the start of the flow) of the first input
//                and the first state; default 0..38 step 6 / 0..90 step 30
'use strict';
const { AppStand } = require('../harness/appstand.js');
const { be16 } = require('../harness/net/peer.js');

const IN_MS = 40, ST_MS = 100, IN_B = 20, ST_B = 88;

// flow(dll, inAt, stAt, o): o = { steps, budget, polls, isr, secs, trace,
// traceMs } (defaults: NETDEMO F's profile on Ethernet); also used by
// tests/z/sdk/m5_sdk.test.js
function flow(dll, inAt, stAt, o = {}) {
  const { steps = 1, budget = 3000, polls = 10, isr = 0, secs = 10, traceMs = IN_MS } = o;
  let trace = o.trace || 0;
  const a = new AppStand({ dll, peer: { echo: false } });
  a.gwInit(); a.call('INIT');
  const env = a.initEnv({}, { steps, step_budget: budget, isr_budget: isr, poll_ticks: polls });
  if (env.a !== 0) return { err: `INIT_ENV ${env.a}` };
  a.start(); a.auto = 15;
  a.until(() => a.ctx('hw_state') === 2, 10000);
  a.call('OPEN');
  const ev = [];
  a.until(() => { ev.push(...a.events()); return ev.some((e) => e.name === 'CONNECTED'); }, 10000);
  // the DLL's side of the flow, learnt from one datagram it sends
  const peer = a.s.peer;
  let last = null;
  const orig = peer.udpInput.bind(peer);
  peer.udpInput = (f, len) => { last = f; orig(f, len); };
  a.send([1, 2, 3, 4], 1);
  a.until(() => last !== null, 2000);
  a.runMs(100); a.events(); a.drain();
  const push = (data) => {
    const u = new Array(8).fill(0);
    u[0] = peer.port >> 8; u[1] = peer.port & 255;
    const dp = be16(last, 34); u[2] = dp >> 8; u[3] = dp & 255;
    const body = peer.udpWrap(data); u[4] = (8 + body.length) >> 8; u[5] = (8 + body.length) & 255;
    peer.out.push(peer.ipFrame(last.slice(6, 12), last.slice(26, 30), 17, [...u, ...body]));
  };
  // --trace: every TAKE / BUDGET_BYTES with its caller and the units left
  const takes = [];
  if (trace) {
    const s = a.s, abs = (l) => s.base + 0x20 + s.syms[l];
    const syms = Object.entries(s.syms).filter(([k]) => !k.includes('.') && /^[A-Z]/.test(k)).map(([k, v]) => [s.base + 0x20 + v, k]).sort((x, y) => x[0] - y[0]);
    const owner = (pc) => { let b = '?'; for (const [ad, k] of syms) { if (ad <= pc) b = k; else break; } return b; };
    for (const l of ['TAKE', 'BUDGET_BYTES']) if (l in s.syms) a.onPc(abs(l), () => {
      const st = a.m.cpu.getState();
      takes.push([a.ms(), `${l === 'TAKE' ? '' : 'BB'}${(st.h << 8) | st.l}@${owner(a.m.peek16(st.sp) - 3)}/${a.ctx('units')}`]);
    });
  }
  const in0 = peer.udpIn.length;
  const wire = [];
  peer.udpInput = (f, len) => { wire.push(a.ms()); orig(f, len); };
  const t0 = a.ms();
  let nextIn = t0 + inAt, nextSt = t0 + stAt, offered = 0, sent = 0, skipped = 0, busy = false, tCommit = 0;
  let states = 0, pushed = 0;
  const txd = [], stLat = [], tPush = [];
  while (a.ms() - t0 < secs * 1000) {
    a.runMs(1);
    for (const e of a.events()) if (e.name === 'TX_DONE') {
      busy = false; txd.push(a.ms() - tCommit);
      if (trace && a.ms() - tCommit > traceMs) {
        trace--;
        const from = tCommit - 25, to = a.ms() + 1, w = (x) => x >= from && x <= to;
        const fmt = (x) => (x - tCommit).toFixed(1);
        const lines = [`commit 0`, `wire ${wire.filter(w).map(fmt).join(' ')}`, `TX_DONE seen ${fmt(a.ms())}`,
          'STEP ' + a.done.STEP.filter((x) => w(x.at / 1000)).map((x) => `${fmt(x.at / 1000 - x.us / 1000)}+${(x.us / 1000).toFixed(2)}${x.nested ? 'n' : ''}`).join(' '),
          'STEP_ISR ' + a.done.STEP_ISR.filter((x) => w(x.at / 1000)).map((x) => fmt(x.at / 1000)).join(' '),
          'states ' + tPush.filter(w).map(fmt).join(' ')];
        console.log(`  input ${sent - 1} at ${(tCommit - t0).toFixed(1)} ms of the flow: ${lines.join(' | ')}`);
        let lastT = -1e9, row = [];
        for (const [tt, x] of takes.filter(([tt]) => w(tt))) { if (tt - lastT > 1.5 && row.length) { console.log('    ' + row.join(' ')); row = []; } if (!row.length) row.push(`@${fmt(tt)}:`); row.push(x); lastT = tt; }
        if (row.length) console.log('    ' + row.join(' '));
      }
    }
    const d = a.drain();
    for (let o = 0; o + ST_B <= d.length; o += ST_B) { states++; stLat.push(a.ms() - tPush[(d[o] << 8) | d[o + 1]]); }
    if (a.ms() >= nextSt) {
      nextSt += ST_MS;
      tPush.push(a.ms());
      push(Array.from({ length: ST_B }, (_, i) => (i === 0 ? pushed >> 8 : i === 1 ? pushed & 255 : (i + pushed) & 255)));
      pushed++;
    }
    if (a.ms() >= nextIn) {
      nextIn += IN_MS;
      offered++;
      if (busy) { skipped++; continue; }
      const x = a.send(Array.from({ length: IN_B }, (_, i) => (i === 0 ? sent >> 8 : i === 1 ? sent & 255 : i)), (sent & 0x7f) + 2);
      if (x.res.a !== 0 || x.commit.a !== 0) { skipped++; continue; }
      busy = true; tCommit = a.ms(); sent++;
    }
  }
  const at = peer.udpIn.length - in0;
  const st = a.stats();
  return { offered, sent, skipped, at, txd, pushed, states, stLat, gw: st, problems: a.problems.slice(0, 3) };
}

module.exports = { flow };
if (require.main !== module) return;

const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args.splice(i, 2)[1] : d; };
const steps = +opt('--steps', '1'), budget = +opt('--budget', '3000'), polls = +opt('--polls', '10'), isr = +opt('--isr', '0');
const secs = +opt('--s', '10');
const trace = +opt('--trace', '0'), traceMs = +opt('--trace-ms', String(IN_MS));
const list = (s) => s.split(',').map(Number);
const ins = list(opt('--in', '0,6,12,18,24,30,36')), sts = list(opt('--st', '0,30,60,90'));
const dlls = args.length ? args : ['gudprtl', 'gudp509b'];
const mm = (v) => (v.length ? `${(v.reduce((p, q) => p + q, 0) / v.length).toFixed(1)} / ${Math.max(...v).toFixed(1)}` : '—');
console.log(`profile: ${steps} STEP(s) of ${budget} us per period, a poll every ${polls} tick(s)${isr ? `, STEP_ISR ${isr} us` : ''}; ` +
  `${secs} s, input ${IN_B} B every ${IN_MS} ms (one in flight), state ${ST_B} B every ${ST_MS} ms`);
console.log('dll        in ms  st ms   offered sent skipped at-peer   TX_DONE ms mean/max   states/pushed   state ms mean/max   gw refuse/step');
for (const dll of dlls) {
  for (const i of ins) {
    for (const s of sts) {
      let x;
      try { x = flow(dll, i, s, { steps, budget, polls, isr, secs, trace, traceMs }); } catch (e) { x = { err: e.message }; }
      if (x.err) { console.log(`${dll.padEnd(10)} ${String(i).padStart(5)}  ${String(s).padStart(5)}   ERROR ${x.err}`); continue; }
      console.log(`${dll.padEnd(10)} ${String(i).padStart(5)}  ${String(s).padStart(5)}   ${String(x.offered).padStart(7)} ${String(x.sent).padStart(4)} ${String(x.skipped).padStart(7)} ${String(x.at).padStart(7)}   ` +
        `${mm(x.txd).padStart(19)}   ${String(x.states).padStart(6)}/${String(x.pushed).padEnd(6)}   ${mm(x.stLat).padStart(17)}   ${x.gw.refuse}/${x.gw.step}`);
    }
  }
}
