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

for (const dll of DLLS) {
  const info = () => { const s = new Stand({ dll }); s.call('INIT'); return s.getInfo().info; };
  test(`${dll}: empty poll body <= 100 us (ТЗ §5.1)`, () => {
    assert.ok(info().empty_poll_us <= 100, `published ${info().empty_poll_us}`);
  });
  test(`${dll}: BUS_BUSY path <= 25 us (ТЗ §5.1)`, () => {
    assert.ok(info().bus_busy_us <= 25, `published ${info().bus_busy_us}`);
  });
}
