// 3C509B builds on the Z stand: card model (devices/el3.js) + validating
// network peer (net/peer.js), POLL mode.  Card-specific checks here, the
// shared Ethernet scenarios in ../eth_scenarios.js.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { ethScenarios, boot, clean } = require('../eth_scenarios.js');

for (const dll of ['gtcp509b', 'gudp509b']) {
  test(`${dll}: bring-up reads the station address from the EEPROM`, () => {
    const s = boot(dll);
    assert.deepEqual(s.card.station, s.card.mac);
    assert.equal(s.card.rxEnabled, true);
    assert.equal(s.card.txEnabled, true);
    assert.equal(s.card.window, 1, 'run phase in window 1');
    assert.equal(s.card.intrMask, 0, 'polling only in v1');
    clean(s);
  });

  test(`${dll}: CIP is waited for as a state, not a busy loop`, () => {
    const s = boot(dll, {}, { card: { cipReads: 3 } });
    clean(s);
  });

  ethScenarios(dll);
}
