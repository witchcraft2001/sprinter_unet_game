#!/usr/bin/env node
// oneway.js -- one-way throughput at one STEP per period, in the real time
// of the board: what a game that calls STEP once a frame can send and can
// receive.  The application offers / reads once per STEP.
//   send:    packets of a size, as fast as SEND accepts them, until every
//            TX_DONE came (TCP: acknowledged by the peer);
//   receive: the peer sends one packet every k periods; the smallest k at
//            which nothing is lost or retransmitted and the application
//            keeps up (the backlog does not grow).
// Usage: node tools/dev/oneway.js [dll...] [--dt 20] [--budget 2000]
//        [--sizes 16,64,512] [--n 60] [--isr us] [--polls n] [--kmax 40]
//        [--esp-fw 2] [--trigger 1|4|8|14] [--div n]
//   --isr     STEP_ISR(TIMER, us) between STEPs, --polls of them per STEP
//   --esp-fw  2: GUDPESP's transparent UDP (records); --trigger: the UART
//             RX FIFO trigger of the ESP builds; --div: the 16550 divisor
//             (8 = 115200, 4 = 230400, 2 = 460800)
'use strict';
process.env.UG_WAITS = '1';
const { ethStand, C } = require('../harness/ethnet.js');
const { be16 } = require('../harness/net/peer.js');

const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args.splice(i, 2)[1] : def; };
const dt = +opt('--dt', '20'), budget = +opt('--budget', '2000'), N = +opt('--n', '60');
const sizes = opt('--sizes', '16,64,512').split(',').map(Number);
const isr = opt('--isr', null), kmax = +opt('--kmax', '40'), polls = +opt('--polls', '1');
const espFw = +opt('--esp-fw', '1'), trigger = +opt('--trigger', '0'), div = +opt('--div', '0');
const dlls = args.length ? args : ['gudp509b', 'gudprtl', 'gtcp509b', 'gtcprtl', 'gudpesp', 'gtcpesp'];
const S = C.status;
const bytes = (n, seed) => Array.from({ length: n }, (_, i) => (i * 31 + seed) & 255);
const put16 = (a, o, v) => { a[o] = v >> 8; a[o + 1] = v & 255; };

function boot(dll, peerOpts) {
  const s = ethStand({ dll, peer: { echo: false, rto: 1000, ...peerOpts } });
  s.call('INIT');
  const esp = s.isEsp ? { esp_fw: espFw, ...(trigger ? { uart_rx_trigger: trigger } : {}), ...(div ? { uart_divisor: div } : {}) } : {};
  const r = s.initConfig(s.defaultConfig({ step_budget_us: budget, ...esp }));
  if (r.a !== S.OK) throw new Error(`${dll}: INIT_CONFIG ${r.a}`);
  if (s.isEsp) s.peer.echo = false;
  const step = () => s.tick(dt, budget, isr ? { isr: { budget: +isr, n: polls } } : {});
  for (let i = 0; i < 2000 && s.ctx('hw_state') !== 2; i++) s.tick(2, budget);
  s.open();
  let ok = false;
  for (let i = 0; i < 3000 && !ok; i++) { s.tick(2, budget); ok = s.events().some((e) => e.name === 'CONNECTED'); }
  if (!ok) throw new Error(`${dll}: no CONNECTED`);
  return { s, step };
}

function sendRun(dll, size) {
  const { s, step } = boot(dll);
  let sent = 0, done = 0, bad = 0, steps = 0;
  const t0 = s.t;
  while (done + bad < N && steps < 20000) {
    while (sent < N && s.send(bytes(size, sent), (sent & 0x7f) + 1).res.a === S.OK) sent++;
    step(); steps++;
    for (const e of s.events()) {
      if (e.name === 'TX_DONE') { if (e.status === S.OK || e.status === undefined || e.status === 0) done++; else bad++; }
    }
  }
  const t1 = s.t;
  const peerGot = () => (dll.startsWith('gudp') ? s.peer.udpIn.reduce((a, d) => a + d.length, 0) : s.peer.received.length);
  // what is past TX_DONE may still be on its way (the transparent ESP
  // module sends after 20 ms of UART silence): wait for it, bounded
  for (let i = 0; i < 100 && peerGot() < N * size; i++) step();
  const got = peerGot();
  return { pps: done / ((t1 - t0) / 1000), ok: done === N && bad === 0 && got === N * size, steps };
}

// the DLL's side of the flow, learnt from one datagram it sends
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

function recvRun(dll, size, k) {
  const { s, step } = boot(dll);
  const udp = dll.startsWith('gudp');
  let push = (d) => s.peer.sendData(d);
  if (udp && !s.isEsp) {
    const mk = udpSender(s);
    s.send([1, 2, 3, 4], 1);
    for (let i = 0; i < 50 && !s.peer.udpIn.length; i++) step();
    for (let i = 0; i < 10; i++) step();
    s.events();
    push = mk;
  }
  const r0 = s.isEsp ? 0 : s.peer.retransmits;
  let pushed = 0, got = 0, steps = 0, lastPush = 0, doneAt = 0;
  const t0 = s.t;
  while (got < N * size && steps < N * k + 400) {
    if (pushed < N && steps % k === 0) { push(bytes(size, pushed)); pushed++; lastPush = steps; }
    step(); steps++;
    s.events();
    got += s.drain().bytes.length;
    if (got >= N * size) doneAt = steps;
  }
  const retr = s.isEsp ? 0 : s.peer.retransmits - r0;
  // keeps up: everything arrived, nothing was sent twice, and the tail
  // after the last packet is no longer than a few packets' worth
  const lag = doneAt ? doneAt - lastPush : Infinity;
  return { ok: got === N * size && retr === 0 && lag <= Math.max(12, 4 * k), lag, got, retr, pps: 1000 / (k * dt) };
}

console.log(`one STEP of ${budget} us every ${dt} ms${isr ? `, ${polls} STEP_ISR(${isr}) between` : ''}${espFw === 2 ? ', esp_fw 2' : ''}; ${N} packets; packets/s (bytes/s)`);
for (const dll of dlls) {
  for (const size0 of sizes) {
    const size = size0 > 256 && !dll.startsWith('gudp') ? 536 : size0;
    let tx, rx = null;
    try { tx = sendRun(dll, size); } catch (e) { tx = { err: e.message }; }
    try {
      for (let k = 1; k <= kmax && !rx; k++) { const r = recvRun(dll, size, k); if (r.ok) rx = { ...r, k }; }
    } catch (e) { rx = { err: e.message }; }
    const f = (x) => (x.err ? `ERROR ${x.err}` : `${x.pps.toFixed(1)}/s (${Math.round(x.pps * size)} B/s)`);
    console.log(`${dll.padEnd(9)} ${String(size).padStart(4)} B: send ${tx.err || tx.ok ? f(tx) : 'INCOMPLETE ' + f(tx)}` +
      `   receive ${rx ? (rx.err ? f(rx) : `${f(rx)} [one per ${rx.k} STEP, tail ${rx.lag}]`) : `none up to 1 per ${kmax} STEPs`}`);
  }
}
