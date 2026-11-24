#!/usr/bin/env node
// game_load.js -- a real-time game's traffic on a UDP build, in the real
// time of the board: the application offers one small datagram (its input)
// every few frames while the peer sends a larger one (the state) at its own
// rate, both at once, and reads once per frame.  Reports what arrives, how
// late, and what is skipped or lost.
//   input:  offered every --tx frames; a refused TX_RESERVE is "skipped"
//           (a game merges that input into its next packet); latency from
//           the offer to the datagram at the peer;
//   state:  the peer sends one every --rx frames; latency from the peer's
//           send to the application's RX_PEEK; "lost" never arrived.
// Usage: node tools/dev/game_load.js [dll...] [--tx bytes,frames]
//        [--rx bytes,frames] [--budget us] [--steps n] [--isr us]
//        [--polls n] [--frames n] [--dt ms] [--phase in,st]
//   --steps   STEPs per frame, evenly spread (default 1)
//   --queue   inputs in flight at most (default 1: a game sends its
//             latest input, it does not queue stale ones)
//   --isr     STEP_ISR(TIMER, us) between STEPs, --polls of them per STEP
//   --esp-fw  1: the AT command profile, 2: transparent UDP (GUDPESP)
//   --trigger, --divisor: the UART RX FIFO trigger (1/4/8/14) and divisor
//   --phase in,st[,poll]  the input is offered / the state reaches the card
//             in ms after the frame's STEP (default 0,0: both right before
//             the next STEP; one STEP per frame only); poll: the
//             ms of a single STEP_ISR (--isr, --polls 1; default dt / 2).  NETDEMO F meets
//             the STEPs at any phase: sweep it (tools/mame/run_m.py too)
//   --trace f print the budget calls (units / caller / units left) of
//             the STEPs of frames f..f+19 of the first build
'use strict';
process.env.UG_WAITS = '1';
const { ethStand, C } = require('../harness/ethnet.js');
const { be16 } = require('../harness/net/peer.js');

const S = C.status;
const put16 = (a, o, v) => { a[o] = v >> 8; a[o + 1] = v & 255; };
const packet = (n, seq) => Array.from({ length: n }, (_, i) => (i === 0 ? seq >> 8 : i === 1 ? seq & 255 : (i * 31 + seq) & 255));
const stat = (v) => {
  if (!v.length) return 'none';
  const a = [...v].sort((x, y) => x - y);
  const mean = a.reduce((p, q) => p + q, 0) / a.length;
  return `${mean.toFixed(0)} / ${a[Math.floor(a.length * 0.95)]} / ${a[a.length - 1]}`;
};

// the DLL's side of the flow, learnt from one datagram it sends (Ethernet)
function udpSender(s) {
  let last = null;
  const orig = s.peer.udpInput.bind(s.peer);
  s.peer.udpInput = (f, len) => { last = f; orig(f, len); };
  return (data) => {
    const u = new Array(8).fill(0);
    put16(u, 0, s.peer.port); put16(u, 2, be16(last, 34)); put16(u, 4, 8 + (data = s.peer.udpWrap(data)).length);
    s.peer.out.push(s.peer.ipFrame(last.slice(6, 12), last.slice(26, 30), 17, [...u, ...data]));
  };
}

// run(dll, o): o = { txSize, txEvery, rxSize, rxEvery, budget, steps, isr,
// polls, frames, dt, queue, traceAt } (defaults: the Headball flow at one
// STEP of 2000 us per 20 ms frame); also used by tests/z/hw/eth_scenarios.js
const DEFAULTS = { txSize: 20, txEvery: 2, rxSize: 88, rxEvery: 5, budget: 2000, steps: 1, isr: 0, polls: 1,
  frames: 1500, dt: 20, queue: 1, traceAt: -1, espFw: 1, trigger: 0, divisor: 0, inAt: 0, stAt: 0, pollAt: -1 };
function run(dll, o = {}) {
  const { txSize, txEvery, rxSize, rxEvery, budget, steps, isr, polls, frames, dt, queue, traceAt, espFw, trigger, divisor, inAt, stAt, pollAt } = { ...DEFAULTS, ...o };
  if (!dll.startsWith('gudp')) return { err: 'a UDP build is needed (datagrams)' };
  const phased = inAt > 0 || stAt > 0 || pollAt >= 0;
  if (phased && (steps !== 1 || inAt >= dt || stAt >= dt || inAt < 0 || stAt < 0)) return { err: '--phase: one STEP per frame, 0 <= in, st < dt' };
  const s = ethStand({ dll, peer: { echo: false } });
  if (o.espModel && s.esp) Object.assign(s.esp, o.espModel);   // e.g. { xFirst: true }
  s.call('INIT');
  const esp = s.isEsp ? { esp_fw: espFw, ...(trigger ? { uart_rx_trigger: trigger } : {}), ...(divisor ? { uart_divisor: divisor } : {}) } : {};
  const r = s.initConfig(s.defaultConfig({ step_budget_us: budget, ...esp }));
  if (r.a !== S.OK) return { err: `INIT_CONFIG ${r.a}` };
  s.peer.echo = false;
  for (let i = 0; i < 2000 && s.ctx('hw_state') !== 2; i++) s.tick(2, budget);
  s.open();
  let ok = false;
  for (let i = 0; i < 3000 && !ok; i++) { s.tick(2, budget); ok = s.events().some((e) => e.name === 'CONNECTED'); }
  if (!ok) return { err: 'no CONNECTED' };
  let push = (d) => s.peer.sendData(d);
  if (!s.isEsp) {
    const mk = udpSender(s);
    s.send([1, 2, 3, 4], 1);
    for (let i = 0; i < 50 && !s.peer.udpIn.length; i++) s.tick(dt, budget);
    push = mk;
  }
  for (let i = 0; i < 20; i++) s.tick(dt, budget);
  s.events(); s.drain();
  const seen0 = s.peer.udpIn.length;

  const tOffer = new Map(), tPush = new Map();
  const inLat = [], stLat = [], stepUs = [];
  let offered = 0, sent = 0, skipped = 0, pushed = 0, got = 0, bad = 0, over = 0, maxStep = 0, seen = seen0, txFail = 0, done = 0;
  const prob = new Set();
  const sub = dt / steps;
  // --trace: every TAKE / BUDGET_BYTES with its caller and the units left
  let tracer = null;
  if (traceAt >= 0) {
    const syms = Object.entries(s.syms).filter(([k]) => !k.includes('.') && /^[A-Z]/.test(k)).map(([k, v]) => [s.base + 0x20 + v, k]).sort((a, b) => a[0] - b[0]);
    const owner = (pc) => { let b = '?'; for (const [a, k] of syms) { if (a <= pc) b = k; else break; } return b; };
    const pts = {}; for (const l of ['TAKE', 'BUDGET_BYTES', 'SHORT_TAKE', 'PARSE_BUDGET']) if (l in s.syms) pts[s.sym(l)] = l;
    const ua = s.layout().ctx + require('../harness/abi.json').ctx.fields.units.offset;
    tracer = (log) => ({ onStep: (m, st) => { const l = pts[st.pc]; if (l) log.push(`${l === 'BUDGET_BYTES' ? 'BB' : l === 'PARSE_BUDGET' ? `PB${(st.d << 8) | st.e}:` : ''}${l === 'PARSE_BUDGET' ? -(((st.b << 8) | st.c) - 65536) : (st.h << 8) | st.l}@${owner(m.peek16(st.sp) - 3)}/${m.peek16(ua)}`); } });
  }
  const pushState = () => { tPush.set(pushed, s.t); push(packet(rxSize, pushed)); pushed++; };
  const offer = () => {
    offered++;
    const x = sent - done < queue ? s.send(packet(txSize, sent), (sent & 0x7f) + 1) : null;
    if (x && x.res.a === S.OK && x.commit.a === S.OK) { tOffer.set(sent, s.t); sent++; } else skipped++;
  };
  // --phase: the frame's own time line (what s.tick does, with the offer
  // and the state's arrival placed inside it): the actions at their ms
  // after the previous STEP, the STEP_ISR polls where s.tick puts them,
  // the STEP at the end of the frame.  A state reaches the card at once
  // (s.pump), as at the frame start of the plain path.
  const phasedTick = (f, stepOpts) => {
    const pts = [];
    if (f % rxEvery === 0) pts.push([stAt, () => { pushState(); s.pump(); }]);
    if (f % txEvery === 0) pts.push([inAt, offer]);
    for (let k = 1; isr && k <= polls; k++) pts.push([polls === 1 ? (pollAt >= 0 ? pollAt : dt >> 1) : Math.floor((dt * k) / (polls + 1)), () => s.stepIsr(C.src.TIMER, isr)]);
    pts.sort((a, b) => a[0] - b[0]);
    const t0 = s.t;
    s.pump();
    for (const [at, fn] of pts) { s.t = (t0 + at) >>> 0; fn(); }
    s.t = (t0 + dt) >>> 0;
    const r = s.step(s.nowMs(), budget, 0, stepOpts);
    s.pump();
    return r;
  };
  for (let f = 0; f < frames; f++) {
    if (!phased) {
      if (f % rxEvery === 0) pushState();
      if (f % txEvery === 0) offer();
    }
    let us = 0;
    for (let k = 0; k < steps; k++) {
      const on = tracer && f >= traceAt && f < traceAt + 20, log = [];
      const x = phased ? phasedTick(f, on ? tracer(log) : {})
        : s.tick(sub, budget, { ...(isr ? { isr: { budget: isr, n: polls } } : {}), ...(on ? tracer(log) : {}) });
      if (on) {
        const hw = s.layout().ctx + require('../harness/abi.json').ctx.fields.hwsm.offset, b = s.m.peekBytes(hw, 12);
        const backlog = s.isEsp ? (((b[10] | (b[11] << 8)) - (b[4] | (b[5] << 8))) & 511) : 0;
        console.log(`f${f} rx${f % rxEvery === 0 ? '+' : ' '} tx${f % txEvery === 0 ? '+' : ' '} ${x.us.toFixed(0)} us${s.isEsp ? ` ring ${backlog}` : ''}: ${log.join(' ')}`);
      }
      us += x.us;
      if (x.us > budget) over++;
      maxStep = Math.max(maxStep, x.us);
      for (const p of x.problems) prob.add(p);
      for (; seen < s.peer.udpIn.length; seen++) {
        const d = s.peer.udpIn[seen];
        const q = (d[0] << 8) | d[1];
        if (d.length === txSize && tOffer.has(q)) inLat.push(s.t - tOffer.get(q)); else bad++;
      }
    }
    stepUs.push(us);
    for (const e of s.events()) if (e.name === 'TX_DONE') { done++; if (e.status) txFail++; }
    const d = s.drain();
    let o = 0;
    for (const n of d.chunks) {
      const q = (d.bytes[o] << 8) | d.bytes[o + 1];
      if (n === rxSize && tPush.has(q)) { stLat.push(s.t - tPush.get(q)); got++; } else bad++;
      o += n;
    }
  }
  const st = s.getStats().stats;
  const mean = stepUs.reduce((p, q) => p + q, 0) / stepUs.length;
  return { offered, sent, skipped, wire: inLat.length, inLat, pushed, got, stLat, bad, over, maxStep, txFail,
    netMean: mean, netMax: Math.max(...stepUs), ovr: st.uart_overrun, hwo: st.hw_overflow, prob: [...prob].slice(0, 2),
    sec: frames * dt / 1000 };
}
module.exports = { run, stat };
if (require.main !== module) return;

const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args.splice(i, 2)[1] : def; };
const [txSize, txEvery] = opt('--tx', '20,2').split(',').map(Number);
const [rxSize, rxEvery] = opt('--rx', '88,5').split(',').map(Number);
const budget = +opt('--budget', '2000'), steps = +opt('--steps', '1'), isr = +opt('--isr', '0'), polls = +opt('--polls', '1');
const frames = +opt('--frames', '1500'), dt = +opt('--dt', '20'), queue = +opt('--queue', '1');
const traceAt = +opt('--trace', '-1'), espFw = +opt('--esp-fw', '1');
const trigger = +opt('--trigger', '0'), divisor = +opt('--divisor', '0');
const [inAt, stAt, pollAt = -1] = opt('--phase', '0,0').split(',').map(Number);
const dlls = args.length ? args : ['gudp509b', 'gudprtl', 'gudpesp'];
const O = { txSize, txEvery, rxSize, rxEvery, budget, steps, isr, polls, frames, dt, queue, traceAt, espFw, trigger, divisor, inAt, stAt, pollAt };

console.log(`${steps} STEP(s) of ${budget} us per ${dt} ms frame${espFw === 2 ? ', ESP transparent' : ''}${isr ? `, ${polls} STEP_ISR(${isr}) before each` : ''}; ${frames} frames; ` +
  `input ${txSize} B every ${txEvery} frame(s) (${(1000 / dt / txEvery).toFixed(1)}/s), state ${rxSize} B every ${rxEvery} (${(1000 / dt / rxEvery).toFixed(1)}/s)`);
console.log('latency: mean / p95 / max, ms');
for (const dll of dlls) {
  let x;
  try { x = run(dll, O); } catch (e) { x = { err: e.message }; }
  if (x.err) { console.log(`${dll.padEnd(9)} ERROR ${x.err}`); continue; }
  const sec = frames * dt / 1000;
  console.log(`${dll.padEnd(9)} input: ${(x.wire / sec).toFixed(1)}/s at the peer, skipped ${(100 * x.skipped / x.offered).toFixed(0)} %, latency ${stat(x.inLat)}` +
    `   state: ${(x.got / sec).toFixed(1)}/s read, lost ${x.pushed - x.got}, latency ${stat(x.stLat)}` +
    `   STEP us per frame ${x.netMean.toFixed(0)} / max ${x.netMax.toFixed(0)}, longest STEP ${x.maxStep.toFixed(0)}` +
    `${x.over ? `, OVER ${x.over}` : ''}${x.bad ? `, bad ${x.bad}` : ''}${x.txFail ? `, TX failed ${x.txFail}` : ''}${x.ovr ? `, uart overrun ${x.ovr}` : ''}${x.hwo ? `, hw overflow ${x.hwo}` : ''}${x.prob.length ? ' ' + x.prob.join('; ') : ''}`);
}
