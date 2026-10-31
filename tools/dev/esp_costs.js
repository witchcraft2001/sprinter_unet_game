#!/usr/bin/env node
// esp_costs.js -- inclusive time of the ESP layer routines (us at 21 MHz,
// min / max / count) over the 8 KiB echo stream at a 2 ms STEP period,
// plus the per-byte cost of the parser rounds and of the UART pump.
// Calibrates the COST_* constants of src/hw/esp and src/core/esp.
// Usage: node tools/dev/esp_costs.js [gtcpesp|gudpesp] [budget]
'use strict';
const { ethStand } = require('../harness/ethnet.js');
const dll = process.argv[2] || 'gtcpesp';
const budget = +(process.argv[3] || 500);
const LABELS = ['ESP_PEND', 'ESP_PARSE.one', 'PARSE_BUDGET', 'TP_STEP', 'HW_RUN', 'RUN_PORTION', 'UART_PUMP', 'ISRP_PUMP', 'ESP_PARSE', 'ESP_BYTES', 'ESP_LBYTE',
  'ESP_LINE', 'ESP_TOKEN', 'ESP_HDR_RECV', 'ESP_HDR_IPD', 'ESP_PAY', 'ESP_PROMPT', 'ESP_SEQ', 'ESP_PICK', 'ESP_ISSUE',
  'ESP_BUILD', 'ESP_SUBST', 'DEC16', 'ESP_DONE', 'ESP_TIMEOUT', 'ESP_OVERRUN', 'CH_FAIL', 'RXR_COMMIT', 'EV_FLUSH'];
const s = ethStand({ dll });
s.call('INIT');
s.initConfig(s.defaultConfig({ step_budget_us: budget }));
const labels = LABELS.filter((l) => l in s.syms);
const acc = {};
const perByte = { ESP_BYTES: [], UART_PUMP: [] };
const bytesAt = { [s.sym('ESP_BYTES')]: 'ESP_BYTES' };
let maxStep = 0;
// run with hooks: wrap s.step through the stand's onStep option
const step0 = s.step.bind(s);
s.step = (t, b) => {
  const h = s.inclusiveHook(labels);
  const calls = [];
  const r = step0(t, b, 0, { onStep: (m, st) => {
    h.hook(m, st);
    if (bytesAt[st.pc]) calls.push({ n: (st.b << 8) | st.c, c: m.cycles, sp: st.sp, ret: m.peek16(st.sp) });
    for (let i = calls.length - 1; i >= 0; i--) {
      const o = calls[i];
      if (st.pc === o.ret && st.sp === o.sp + 2) {
        const left = (st.b << 8) | st.c;
        const done = o.n - left;
        if (done > 0) perByte.ESP_BYTES.push([done, (m.cycles - o.c) / m.mhz]);
        calls.splice(i, 1);
      }
    }
  } });
  for (const [l, v] of Object.entries(h.result())) (acc[l] ||= []).push(...v);
  maxStep = Math.max(maxStep, r.us);
  return r;
};
let n = 0;
for (; n < 2000 && s.ctx('hw_state') !== 2; n++) s.tick(2, budget);
s.open();
for (let i = 0; i < 2000 && !s.events().some((e) => e.name === 'CONNECTED'); i++) s.tick(2, budget);
const piece = dll.startsWith('gudp') ? 512 : 536;
const d = Array.from({ length: 8192 }, (_, i) => (i * 31 + 3) & 255);
let off = 0, tag = 1, got = 0, steps = 0;
for (; steps < 40000 && got < d.length; steps++) {
  if (off < d.length) {
    const x = s.send(d.slice(off, off + Math.min(piece, d.length - off)), tag);
    if (x.res.a === 0) {
      if (x.commit.a !== 0) throw new Error(`TX_COMMIT ${x.commit.a} at ${off}`);
      off += Math.min(piece, d.length - off); tag++;
    }
  }
  s.tick(2, budget); s.events(); got += s.drain().bytes.length;
}
console.log(dll, 'budget', budget, 'stream', got, 'of', d.length, 'in', steps, 'steps', `(${(got / (steps * 2)).toFixed(2)} KB/s)`, 'max STEP', maxStep.toFixed(0));
for (const [l, v] of Object.entries(acc)) {
  const avg = v.reduce((a, b) => a + b, 0) / v.length;
  console.log('  ', l.padEnd(13), 'n', String(v.length).padStart(6), 'min', Math.min(...v).toFixed(0).padStart(5),
    'avg', avg.toFixed(0).padStart(5), 'max', Math.max(...v).toFixed(0).padStart(5));
}
// per byte of the parser rounds: least squares fit t = a + b * n
for (const [k, pts] of Object.entries(perByte)) {
  if (pts.length < 2) continue;
  const N = pts.length, sx = pts.reduce((a, p) => a + p[0], 0), sy = pts.reduce((a, p) => a + p[1], 0);
  const sxx = pts.reduce((a, p) => a + p[0] * p[0], 0), sxy = pts.reduce((a, p) => a + p[0] * p[1], 0);
  const b = (N * sxy - sx * sy) / (N * sxx - sx * sx), a = (sy - b * sx) / N;
  const worst = Math.max(...pts.map((p) => p[1] / p[0]));
  console.log('  ', k, 'fit', a.toFixed(1), '+', b.toFixed(2), 'us/byte; worst per byte', worst.toFixed(1), 'samples', N);
}
console.log('AT commands', s.esp.cmds.length, 'uart overruns', s.card.overruns, 'rts drops', s.card.rtsDrops);
if (process.env.DUMP) {
  const L = s.layout(), tp = L.ctx + 299, hw = L.ctx + 243, w = (o) => s.m.peek16(o);
  console.log('tp job', s.m.peek(tp), 'idx', s.m.peek(tp + 1), 'cst', s.m.peek(tp + 2), 'term', s.m.peek(tp + 3), 'fl', s.m.peek(tp + 5).toString(2),
    'pst', s.m.peek(tp + 10), 'llen', s.m.peek(tp + 11), 'pleft', w(tp + 12), 'pkind', s.m.peek(tp + 14), 'avail', w(tp + 15), 'req', w(tp + 17), 'got', w(tp + 19), 'pfail', s.m.peek(tp + 41));
  console.log('hw flags', s.m.peek(hw + 3).toString(2), 'rt', w(hw + 4), 'txn', w(hw + 6), 'rh', w(hw + 10), 'mcr', s.m.peek(hw + 12).toString(16),
    'tx_state', s.ctx('tx_state').join(','), 'tx_send', s.ctx('tx_send'), 'tx_next', s.ctx('tx_next'), 'rx_used', s.ctx('rx_used'), 'chan', s.ctx('chan'), 'sent', off);
  console.log('cmds', JSON.stringify(s.esp.cmds.slice(-6)), 'held', s.esp.link && s.esp.link.held.length, 'notice', s.esp.link && s.esp.link.notice,
    'out', s.card.pending(), 'fifo', s.card.rxFifo.length, 'rts', s.card.rtsOn(), 'peer got', s.peer.received.length, 'pendingOut', s.peer.pendingOut.length, 'events', s.events().map((e) => e.name));
}
