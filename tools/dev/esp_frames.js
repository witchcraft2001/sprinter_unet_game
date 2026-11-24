#!/usr/bin/env node
// esp_frames.js -- what a game gets from a card build at one STEP per 20 ms
// frame, in the real time of the board: frames per packet and packets per
// second, send only and send + echo (the application offers one packet and
// reads once per frame).  Written for the SprinterESP builds (the AT
// exchange of a packet takes several frames); works on every card build.
// Usage: node tools/dev/esp_frames.js [dll...] [--sizes 16,64] [--budget 2000]
//        [--isr us] [--polls n] [--div n] [--trigger n] [--n 40] [--dt 20]
//   --isr      STEP_ISR(TIMER, us) calls spread over every frame, --polls of
//              them (default 1; a poll that moves n UART bytes needs
//              245 + 8 n us: 341 for 12)
//   --div      16550 divisor (8 = 115200, 2 = 460800), --trigger FIFO trigger
'use strict';
process.env.UG_WAITS = '1';
const { ethStand } = require('../harness/ethnet.js');
const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args.splice(i, 2)[1] : def; };
const sizes = opt('--sizes', '16,64').split(',').map(Number), budget = +opt('--budget', '2000');
const isr = +opt('--isr', '0'), polls = +opt('--polls', '1'), div = opt('--div', null), trig = opt('--trigger', null), N = +opt('--n', '40'), dt = +opt('--dt', '20');
const dlls = args.length ? args : ['gudpesp', 'gtcpesp'];

function run(dll, size, echo) {
  const s = ethStand({ dll, peer: { echo } });
  s.call('INIT');
  const over = { step_budget_us: budget };
  if (div && s.isEsp) over.uart_divisor = +div;
  if (trig && s.isEsp) over.uart_rx_trigger = +trig;
  const r = s.initConfig(s.defaultConfig(over));
  if (r.a !== 0) return { err: `INIT_CONFIG ${r.a}` };
  s.peer.echo = echo;
  for (let i = 0; i < 2000 && s.ctx('hw_state') !== 2; i++) s.tick(2, budget);
  s.open();
  let ok = false;
  for (let i = 0; i < 3000 && !ok; i++) { s.tick(2, budget); ok = s.events().some((e) => e.name === 'CONNECTED'); }
  if (!ok) return { err: 'no CONNECTED' };
  let sent = 0, done = 0, got = 0, frames = 0, over2 = 0, maxUs = 0;
  const prob = new Set(), errs = new Set();
  while ((done < N || (echo && got < N * size)) && frames < 4000) {
    if (sent < N && s.send(Array.from({ length: size }, (_, i) => (i * 31 + sent) & 255), (sent & 63) + 1).res.a === 0) sent++;
    const x = s.tick(dt, budget, isr ? { isr: { budget: isr, n: polls } } : {});
    frames++;
    if (x.us > budget) over2++;
    maxUs = Math.max(maxUs, x.us);
    for (const p of x.problems) prob.add(p);
    for (const e of s.events()) { if (e.name === 'TX_DONE') done++; else if (e.name !== 'RX_READY') errs.add(e.name); }
    got += s.drain().bytes.length;
  }
  const st = s.getStats().stats;
  return { frames: frames / N, pps: N / (frames * dt / 1000), complete: done >= N && (!echo || got >= N * size), over: over2, maxUs,
    ovr: st.uart_overrun, yields: st.budget_yields, prob: [...prob].slice(0, 2), errs: [...errs] };
}

console.log(`one STEP of ${budget} us every ${dt} ms${isr ? `, ${polls} STEP_ISR(${isr}) between` : ''}${div ? `, divisor ${div}` : ''}${trig ? `, trigger ${trig}` : ''}; ${N} packets`);
let bad = 0;
for (const dll of dlls) for (const size of sizes) {
  const cell = (echo) => {
    const r = run(dll, size, echo);
    if (r.err) { bad++; return `ERROR ${r.err}`; }
    const notes = [];
    if (!r.complete) notes.push('INCOMPLETE');
    if (r.over) notes.push(`over ${r.over}`);
    if (r.ovr) notes.push(`uart_overrun ${r.ovr}`);
    if (r.errs.length) notes.push(r.errs.join(','));
    if (r.prob.length) notes.push(r.prob.join('; '));
    if (notes.length) bad++;
    return `${r.frames.toFixed(1)} frames, ${r.pps.toFixed(1)}/s, max STEP ${r.maxUs.toFixed(0)}${notes.length ? ' ! ' + notes.join(' ! ') : ''}`;
  };
  console.log(`${dll.padEnd(9)} ${String(size).padStart(3)} B  send: ${cell(false)}   send + echo: ${cell(true)}`);
}
process.exit(bad ? 1 : 0);
