// 3C509B builds on the Z stand: card model (devices/el3.js) + validating
// network peer (net/peer.js), POLL mode.  Card-specific checks here, the
// shared Ethernet scenarios in ../eth_scenarios.js.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { ethScenarios, boot, clean, bytes, stream, has, UHW_RUN } = require('../eth_scenarios.js');
const { C } = require('../../../../tools/harness/ethnet.js');
const A = require('../../../../tools/harness/abi.json');

const S = C.status;
const UHW_FAULT = 5;

// Drive a booted (or noBoot) stand until the card runs.
function toRun(s, dt) {
  for (let i = 0; i < 2000 && s.ctx('hw_state') !== UHW_RUN; i++) s.run(1, dt);
  assert.equal(s.ctx('hw_state'), UHW_RUN, 'card running');
}
// OPEN, a 300-byte echo in pieces of 100, SHUTDOWN until OK (events read).
function session(s, dll, dt, seed) {
  assert.equal(s.open().a, S.OK);
  s.until(has('CONNECTED'), 3000, dt);
  const data = bytes(300, seed);
  assert.deepEqual(stream(s, data, 100, dt), data, 'echo');
  let r;
  for (let n = 0; n < 2000; n++) {
    r = s.call('SHUTDOWN');
    if (r.a === S.OK) break;
    s.run(1, dt);
    s.events();
  }
  assert.equal(r.a, S.OK, 'SHUTDOWN');
  // what the system driver (UNET509B) finds: it reads the manufacturer ID
  // without selecting window 0 (fifth Zh series: STATA3.TXT showed window 1)
  assert.equal(s.card.window, 0, 'SHUTDOWN leaves window 0');
  assert.equal(s.card.rxEnabled, false, 'receiver off');
  assert.equal(s.card.txEnabled, false, 'transmitter off');
  assert.equal(s.card.intrMask, 0);
}

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

  // RX_DISCARD takes its time on the card: until CIP clears the model
  // still shows the dropped frame in the RX status and throws on a FIFO
  // read.  GUDP509B (short path) has no wait state for it -- its poll
  // checks CIP; the other builds wait in ERX_DISC_WAIT.
  test(`${dll}: a slow RX_DISCARD is waited for: streams in small and large pieces stay intact`, () => {
    for (const budget of [A.consts.limits.STEP_BODY_MAX_US, 0]) {
      for (const piece of [8, 22, 60, 300]) {
        const s = boot(dll, {}, { card: { cipReads: 3 }, ...(budget ? { budget } : {}) });
        assert.equal(s.open().a, S.OK);
        s.until(has('CONNECTED'), 20000);
        const d = bytes(piece * 8, piece);
        assert.deepEqual(stream(s, d, piece), d, `piece ${piece} budget ${budget || 'default'}`);
        clean(s);
      }
    }
  });

  // The first Zh runs (docs/MEASUREMENTS.md): the application's now_ms
  // moves in 20 ms video frames (UGTEST) or 2 ms CTC ticks (NETDEMO) while
  // STEPs come every ms; the card model throws on an ID port access before
  // the EEPROM read (4 ms) or the global reset (1 ms) is complete.
  // The fourth series: a global reset drops the link for seconds (the
  // model loses every frame for linkDownMs), so a card that answers is
  // attached to as it is, without a reset.
  for (const clockMs of [20, 2]) {
    test(`${dll}: bring-up waits real time on a ${clockMs} ms now_ms clock`, () => {
      const s = boot(dll, {}, { clockMs, dt: 1 });
      assert.deepEqual(s.card.station, s.card.mac);
      assert.equal(s.card.resets, 0, 'no global reset of a card that answers');
      session(s, dll, 1, clockMs);
      assert.equal(s.card.lostTx + s.card.lostRx, 0, 'no frame lost to a dropped link');
      assert.equal(s.card.transmitted.filter((f) => f[12] === 0x08 && f[13] === 0x06 && f[21] === 1).length, 1,
        'the first ARP request is answered');
      clean(s);
    });

    // Recovery: a card that ignores the ID commands gets one global reset
    // (ID sequence, reset, wait, discovery again) and then runs; the link
    // is down for a while after it, which the OPEN retries cover.
    test(`${dll}: a card that does not answer is reset once (${clockMs} ms clock)`, () => {
      const s = boot(dll, {}, { clockMs, dt: 1, noBoot: true, card: { deaf: true, linkDownMs: 600 } });
      toRun(s, 1);
      assert.equal(s.card.resets, 1, 'one global reset');
      assert.deepEqual(s.card.station, s.card.mac);
      session(s, dll, 1, 40 + clockMs);
      clean(s);
    });
  }

  test(`${dll}: an activation that did not take is recovered by one reset`, () => {
    const s = boot(dll, {}, { noBoot: true, card: { activateFails: 1, linkDownMs: 600 } });
    toRun(s, 2);
    assert.equal(s.card.resets, 1);
    session(s, dll, 2, 11);
    clean(s);
  });

  test(`${dll}: a card that never answers: one reset, then FAULT`, () => {
    const s = boot(dll, {}, { noBoot: true, card: { deaf: 'always' } });
    for (let i = 0; i < 3000 && s.ctx('hw_state') !== UHW_FAULT; i++) s.run(1, 2);
    assert.equal(s.ctx('hw_state'), UHW_FAULT, 'bring-up fault');
    assert.equal(s.card.resets, 1, 'exactly one global reset');
    assert.equal(s.card.active, false);
    clean(s);
  });

  test(`${dll}: bring-up after another driver left the card running in window 1`, () => {
    const s = boot(dll, {}, { noBoot: true });
    Object.assign(s.card, { active: true, window: 1, rxEnabled: true, txEnabled: true, rxFilter: 5 });
    toRun(s, 2);
    assert.equal(s.card.resets, 0, 'attached without a reset');
    assert.equal(s.card.window, 1, 'run phase in window 1');
    session(s, dll, 2, 9);
    assert.equal(s.card.lostTx + s.card.lostRx, 0);
    clean(s);
  });

  test(`${dll}: a series of runs on one card (UGRUN509.BAT): INIT_CONFIG after SHUTDOWN`, () => {
    const s = boot(dll, {}, { clockMs: 20, dt: 1 });
    for (let run = 0; run < 4; run++) {
      session(s, dll, 1, 20 + run);
      for (let i = 0; i < s.layout().ctxLen; i++) s.m.poke(s.layout().ctx + i, 0);
      assert.equal(s.initConfig(s.defaultConfig()).a, S.OK, `INIT_CONFIG of run ${run + 2}`);
      toRun(s, 1);
    }
    assert.equal(s.card.resets, 0, 'no run resets the card');
    assert.equal(s.card.lostTx + s.card.lostRx, 0);
    clean(s);
  });

  ethScenarios(dll);
}
