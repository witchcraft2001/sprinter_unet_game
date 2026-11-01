#!/usr/bin/env node
// esp_pump_calib.js -- direct, noise-free calibration of UART_PUMP: calls
// the routine straight (bypassing HW_RUN's budget sizing) with controlled
// ES_RXMAX / ES_TXN / FIFO content, for a grid of (rx, tx) byte counts.
// Fits cost = fixed + rxRate * rx + txRate * tx (upper bound, not least
// squares) so src/hw/esp/uart.asm's COST_PUMP_FIXED and the per-byte
// reserve can be set from real numbers instead of a guess.
// Usage: node tools/dev/esp_pump_calib.js [gtcpesp|gudpesp]
'use strict';
const { ethStand } = require('../harness/ethnet.js');

const dll = process.argv[2] || 'gtcpesp';
const s = ethStand({ dll });
s.call('INIT');
s.initConfig(s.defaultConfig({}));
for (let i = 0; i < 2000 && s.ctx('hw_state') !== 2; i++) s.tick(2, 500);

const L = s.layout();
const hwsm = L.ctx + s.syms.UCTX_HWSM;
const ctxIY = L.ctx + s.syms.CTX_BIAS;        // the IY value: IMG_CTX_PTR = ctx + CTX_BIAS
const ES_FLAGS = 3, ES_RT = 4, ES_TXN = 6, ES_RH = 10, ES_MCR = 12, ES_TXP = 14, ES_RXMAX = 17;
const TRAP = 0x0100;

// Call through RUN_PORTION (HL = UART_PUMP), exactly as HW_RUN does: this
// maps WIN3 to the card's I/O space, which a direct call to UART_PUMP
// would skip (UREG addresses would then hit whatever happens to sit in
// WIN3, not the card -- the bug this rewrite fixes).
function callPump(rx, tx) {
  const m = s.m;
  // FIFO: rx bytes waiting, nothing in flight behind them
  s.card.rxFifo = Array.from({ length: rx }, (_, i) => i & 0xff);
  s.card.lsrErr = 0;
  s.card.txq = []; s.card.txFree = 0;          // THRE true
  s.card.mcr = 0x22;
  m.poke(hwsm + ES_MCR, 0x22);
  m.poke(hwsm + ES_FLAGS, 0);
  m.poke16(hwsm + ES_RT, 0);
  m.poke16(hwsm + ES_RH, 0);
  m.poke16(hwsm + ES_TXN, tx);
  m.poke16(hwsm + ES_TXP, L.ring + 256);        // scratch source bytes (ring buffer, far from RH/RT)
  m.poke(hwsm + ES_RXMAX, rx);
  m.poke(L.lock, 0);
  const entrySp = 0x3ff0;
  m.poke16(entrySp - 2, TRAP);
  const routine = s.sym('UART_PUMP');
  m.setRegs({ h: (routine >> 8) & 0xff, l: routine & 0xff, iy: ctxIY, sp: entrySp - 2, pc: s.sym('RUN_PORTION'), iff1: 1, iff2: 1, halted: false });
  const c0 = m.cycles;
  m.runUntil(TRAP, {});
  return (m.cycles - c0) / m.mhz;
}

const fixed = [];
const rxOnly = [];
const txOnly = [];
for (let i = 0; i < 20; i++) fixed.push(callPump(0, 0));
for (const rx of [1, 2, 4, 8, 12, 16]) for (let i = 0; i < 5; i++) rxOnly.push([rx, callPump(rx, 0)]);
for (const tx of [1, 2, 4, 8, 12, 16]) for (let i = 0; i < 5; i++) txOnly.push([tx, callPump(0, tx)]);
const both = [];
for (const [rx, tx] of [[16, 16], [16, 8], [8, 16]]) for (let i = 0; i < 5; i++) both.push([rx, tx, callPump(rx, tx)]);

console.log('idle (rx=0,tx=0): min', Math.min(...fixed).toFixed(2), 'max', Math.max(...fixed).toFixed(2));
console.log('rx-only us = fixed + rate*rx:');
for (const rx of [1, 2, 4, 8, 12, 16]) {
  const pts = rxOnly.filter((p) => p[0] === rx).map((p) => p[1]);
  console.log('  rx', rx, 'min', Math.min(...pts).toFixed(2), 'max', Math.max(...pts).toFixed(2));
}
console.log('tx-only us = fixed + rate*tx:');
for (const tx of [1, 2, 4, 8, 12, 16]) {
  const pts = txOnly.filter((p) => p[0] === tx).map((p) => p[1]);
  console.log('  tx', tx, 'min', Math.min(...pts).toFixed(2), 'max', Math.max(...pts).toFixed(2));
}
console.log('both:');
for (const [rx, tx] of [[16, 16], [16, 8], [8, 16]]) {
  const pts = both.filter((p) => p[0] === rx && p[1] === tx).map((p) => p[2]);
  console.log('  rx', rx, 'tx', tx, 'min', Math.min(...pts).toFixed(2), 'max', Math.max(...pts).toFixed(2));
}

// HW_RUN itself: the full real cost HW_RUN's TAKE must cover, including
// its own wrapper arithmetic around RUN_PORTION (sizing, refund).  CX_UNITS
// is set generously so TAKE never refuses.
const EX_FLAGS = 0x68, EX_TXN = 0x6b, CX_UNITS = 5, CX_WORK = 10;
function callHwRun(rx, tx) {
  const m = s.m;
  s.card.rxFifo = Array.from({ length: rx }, (_, i) => i & 0xff);
  s.card.lsrErr = 0;
  s.card.txq = []; s.card.txFree = 0;
  s.card.mcr = 0x22;
  m.poke(hwsm + ES_MCR, 0x22);
  m.poke(hwsm + ES_FLAGS, 0);
  m.poke16(hwsm + ES_RT, 0);
  m.poke16(hwsm + ES_RH, 0);
  m.poke16(hwsm + ES_TXN, tx);
  m.poke16(ctxIY + EX_TXN, tx);
  m.poke(ctxIY + EX_FLAGS, 0);
  m.poke16(hwsm + ES_TXP, L.ring + 256);
  m.poke16(ctxIY + CX_UNITS, 1000);
  m.poke(ctxIY + CX_WORK, 0);
  m.poke(L.lock, 0);
  const entrySp = 0x3ff0;
  m.poke16(entrySp - 2, TRAP);
  m.setRegs({ iy: ctxIY, sp: entrySp - 2, pc: s.sym('HW_RUN'), iff1: 1, iff2: 1, halted: false });
  const c0 = m.cycles;
  m.runUntil(TRAP, {});
  return (m.cycles - c0) / m.mhz;
}
console.log('HW_RUN (units=1000, never refused):');
for (const [rx, tx] of [[0, 0], [16, 0], [0, 16], [16, 16], [16, 8], [8, 16]]) {
  const pts = []; for (let i = 0; i < 5; i++) pts.push(callHwRun(rx, tx));
  console.log('  fifo', rx, 'txn', tx, 'min', Math.min(...pts).toFixed(2), 'max', Math.max(...pts).toFixed(2));
}
