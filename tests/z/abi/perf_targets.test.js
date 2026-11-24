// ТЗ §5.1 timing targets checked against the values GET_INFO publishes
// (the measured costs plus their margin, docs/MEASUREMENTS.md).  A target
// the core does not meet yet would be marked `todo`, never weakened.
//
// The ТЗ §6.1/§8.2 throughput target (2048 B/s each way) is checked
// against the live 8 KiB stream, not GET_INFO, in
// tests/z/hw/eth_scenarios.js ("an 8 KiB stream both ways reaches >= 2048
// B/s"), run per card build by tests/z/hw/*/m*.test.js; GTCPESP's `todo`
// there is this project's one open instance of that target.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { Stand, DLLS } = require('../../../tools/harness/stand.js');

// Since 2026-11-22 every published number is REAL time of the board (one
// unit of the 21 MHz model the costs were measured in is 2.46 us in turbo:
// memory waits).  The ТЗ numbers were met in model microseconds only; in
// real time the card builds do not meet them, and that stays visible here.
for (const dll of DLLS) {
  const info = () => { const s = new Stand({ dll }); s.call('INIT'); return s.getInfo().info; };
  const card = dll !== 'gloop';
  test(`${dll}: empty poll body <= 100 us (ТЗ §5.1)`, { todo: card && 'real time: 136 us published (55 units); the 100 us were met in model time only' }, () => {
    assert.ok(info().empty_poll_us <= 100, `published ${info().empty_poll_us}`);
  });
  test(`${dll}: BUS_BUSY path <= 25 us (ТЗ §5.1)`, { todo: 'real time: 62 us published (25 units); the 25 us were met in model time only' }, () => {
    assert.ok(info().bus_busy_us <= 25, `published ${info().bus_busy_us}`);
  });
  test(`${dll}: STEP_ISR body <= 150 us (ТЗ §5)`, { todo: card && 'real time: an empty poll needs a budget of 161 us, the ESP byte mover 341 for 12 bytes' }, () => {
    const i = info();
    assert.ok(i.empty_poll_us + i.min_return_us <= 150, `smallest useful STEP_ISR budget ${i.empty_poll_us + i.min_return_us}`);
  });
  test(`${dll}: no DI section above 200 us (ТЗ §5.1)`, { todo: 'real time: max_atomic_us 444 published (180 units); the stand allows 500' }, () => {
    assert.ok(info().max_atomic_us <= 200, `published ${info().max_atomic_us}`);
  });
}
