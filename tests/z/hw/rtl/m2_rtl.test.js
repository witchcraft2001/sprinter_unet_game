// RTL8019AS builds on the Z stand: card model (devices/rtl8019.js) +
// validating peer, POLL mode.  Card-specific checks here, the shared
// Ethernet scenarios in ../eth_scenarios.js.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { ethScenarios, boot, clean, has, bytes, stream, isUdp, inject, UHW_RUN } = require('../eth_scenarios.js');
const { C } = require('../../../../tools/harness/ethnet.js');

const S = C.status;
const UHW_FAULT = 5;

for (const dll of ['gtcprtl', 'gudprtl']) {
  test(`${dll}: bring-up programs the DP8390 for 8-bit polling`, () => {
    const s = boot(dll);
    const c = s.card;
    assert.equal(c.dcr, 0x48, 'byte-wide DMA');
    assert.equal(c.rcr, 0x04, 'own address + broadcast');
    assert.equal(c.tcr, 0x00, 'normal transmit');
    assert.equal(c.imr, 0x00, 'polling only in v1');
    assert.deepEqual([c.tpsr, c.pstart, c.pstop, c.bnry, c.curr], [0x40, 0x46, 0x60, 0x46, 0x47]);
    assert.equal(c.stopped, false);
    assert.deepEqual(c.par, c.mac, 'station address from the PROM');
    clean(s);
  });

  test(`${dll}: a doubled PROM layout yields the same station address`, () => {
    const s = boot(dll, {}, { card: { promLayout: 'doubled' } });
    assert.deepEqual(s.card.par, s.card.mac);
    clean(s);
  });

  test(`${dll}: an empty slot ends the bring-up in FAULT without waiting`, () => {
    const s = boot(dll, {}, { card: { present: false }, noBoot: true });
    for (let i = 0; i < 100 && s.ctx('hw_state') !== UHW_FAULT; i++) s.run(1);
    assert.equal(s.ctx('hw_state'), UHW_FAULT);
    assert.equal(s.open().a, S.OK);
    clean(s);
  });

  test(`${dll}: frames without a stored FCS (count = frame + 4) are read correctly`, () => {
    const s = boot(dll, {}, { card: { storeFcs: false } });
    assert.equal(s.open().a, S.OK);
    s.until(has('CONNECTED'));
    const d = bytes(1500, 21);
    assert.deepEqual(stream(s, d, isUdp(dll) ? 512 : 536), d);
    clean(s);
  });

  test(`${dll}: a receive ring overflow is recovered by a ring reset`, () => {
    const s = boot(dll);
    assert.equal(s.open().a, S.OK);
    s.until(has('CONNECTED'));
    // 40 broadcast frames of 600 bytes without a STEP: more than 26 pages
    const flood = [...[255, 255, 255, 255, 255, 255], 0x02, 9, 9, 9, 9, 9, 0x08, 0x00, ...new Array(586).fill(0x33)];
    for (let i = 0; i < 40; i++) s.card.deliver(flood);
    assert.ok(s.card.overflows > 0 && s.card.rxHalted, 'card overflowed');
    s.run(300);
    assert.equal(s.card.rxHalted, false, 'receiver restarted');
    assert.equal(s.getStats().stats.hw_overflow, 1);
    const d = bytes(400, 2);
    assert.deepEqual(stream(s, d, 400), d, 'channel works after the reset');
    clean(s);
  });

  test(`${dll}: a transmit error fails or retransmits the frame, the next one goes out`, () => {
    const s = boot(dll, {}, { card: { txError: 0 } });
    assert.equal(s.open().a, S.OK);
    s.until(has('CONNECTED'));
    s.card.txErrorLeft = 1;
    const d = bytes(100, 4);
    assert.equal(s.send(d, 9).commit.a, S.OK);
    if (isUdp(dll)) {
      const ev = s.until(has('TX_DONE'));
      assert.equal(ev.find((e) => e.name === 'TX_DONE').status, C.txdone.FAILED, 'no false delivery guarantee');
      assert.equal(s.send(d, 10).commit.a, S.OK);
    }
    s.until((e) => has('RX_READY')(e), 3000);
    assert.deepEqual(s.drain().bytes, d);
    clean(s);
  });

  test(`${dll}: a transmitter that never completes is reset, then sending resumes`, () => {
    const s = boot(dll);
    assert.equal(s.open().a, S.OK);
    s.until(has('CONNECTED'));
    s.card.txHang = true;
    const d = bytes(120, 6);
    assert.equal(s.send(d, 3).commit.a, S.OK);
    s.run(50);                                       // the frame hangs in the card
    s.card.txHang = false;
    if (isUdp(dll)) {
      const ev = s.until(has('TX_DONE'), 1000);
      assert.equal(ev.find((e) => e.name === 'TX_DONE').status, C.txdone.FAILED);
      assert.equal(s.send(d, 4).commit.a, S.OK);
    }
    s.until(has('RX_READY'), 3000);
    assert.deepEqual(s.drain().bytes, d);
    assert.ok(s.getStats().stats.hw_overflow >= 1, 'ring/transmitter reset counted');
    assert.equal(s.card.cr & 0x04, 0);
    clean(s);
  });

  test(`${dll}: a lost remote-DMA completion fails the frame instead of starting it`, () => {
    const s = boot(dll);
    assert.equal(s.open().a, S.OK);
    s.until(has('CONNECTED'));
    s.card.rdcLost = true;
    const sent = s.card.transmitted.length;
    assert.equal(s.send(bytes(80, 1), 2).commit.a, S.OK);
    s.run(isUdp(dll) ? 150 : 25);
    assert.equal(s.card.transmitted.length, sent, 'no frame started without RDC');
    s.card.rdcLost = false;
    if (isUdp(dll)) {
      const ev = s.events();
      assert.ok(ev.some((e) => e.name === 'TX_DONE' && e.status === C.txdone.FAILED), ev.map((e) => e.name).join());
    } else {
      s.until(has('RX_READY'), 3000);
    }
    clean(s);
  });

  test(`${dll}: two frames waiting in the ring are both read with STEP_ISR before every STEP`, () => {
    // The main poll acknowledges ISR.PRX before it reads CURR; the second
    // frame must not lose its notice to that acknowledgement (STEP_ISR
    // samples only ISR, and a STEP skips its own poll after an empty
    // sample): RF_MORE keeps the hint until the main poll sees the ring
    // empty.  No third frame arrives to raise PRX again.
    const s = boot(dll);
    assert.equal(s.open().a, S.OK);
    s.until(has('CONNECTED'));
    s.run(50); s.events(); s.drain();
    const a = bytes(60, 31), b = bytes(70, 32);
    inject(s, dll, a);
    inject(s, dll, b);
    assert.equal(s.card.pending(), 2, 'both frames in the ring');
    const rx = [];
    for (let i = 0; i < 400 && rx.length < a.length + b.length; i++) {
      const r = s.stepIsr(C.src.TIMER, 150);
      assert.deepEqual(r.problems, []);
      s.run(1);
      s.events();
      rx.push(...s.drain().bytes);
    }
    assert.deepEqual(rx, [...a, ...b]);
    clean(s);
  });

  ethScenarios(dll);
}
