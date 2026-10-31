// ТЗ §5.1 timing targets checked against the values GET_INFO publishes
// (the measured costs plus their margin, docs/MEASUREMENTS.md).  A target
// the core does not meet yet would be marked `todo`, never weakened.
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
