// eth_scenarios.js -- Ethernet scenarios shared by the 3C509B and
// RTL8019AS builds (registered by tests/z/hw/<card>/*.test.js).
//
// The stand checks every STEP for budget, DI <= 200 us, stack, ISA
// discipline and the exact restore of #1FFD/#9FBD/#E2; the peer validates
// the IPv4/TCP/UDP checksums of every frame the DLL sends.  POLL mode only
// (v1 hardware profiles carry no qualified IRQ route).
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { ethStand, C } = require('../../../tools/harness/ethnet.js');

const S = C.status;
const UHW_RUN = 2;
const bytes = (n, seed = 1) => Array.from({ length: n }, (_, i) => (i * 31 + seed) & 255);

// STEP period of the scenarios: the default INIT_CONFIG promises a useful
// poll at least every worst_poll_gap_us = 2000 us, so the stand calls STEP
// every 2 ms of virtual time.
const DT = 2;

// Boot a build to the running card.  over: INIT_CONFIG fields; opts.card /
// opts.peer: model options; opts.budget: STEP budget (default 500).
function boot(dll, over = {}, opts = {}) {
  const s = ethStand({ dll, card: opts.card, peer: opts.peer });
  const budget = opts.budget ?? 500;
  assert.equal(s.call('INIT').a, 0);
  const cfg = s.defaultConfig({ step_budget_us: budget, ...over });
  assert.equal(s.initConfig(cfg).a, S.OK);
  s.probs = [];
  s.run = (n, dt = DT) => { for (let i = 0; i < n; i++) s.probs.push(...s.tick(dt, budget).problems); };
  s.until = (pred, max = 3000, dt = DT) => {
    const ev = [];
    for (let i = 0; i < max; i++) {
      s.probs.push(...s.tick(dt, budget).problems);
      ev.push(...s.events());
      if (pred(ev)) return ev;
    }
    throw new Error(`condition not met; events ${ev.map((e) => e.name)}`);
  };
  if (opts.noBoot) return s;
  for (let i = 0; i < 1000 && s.ctx('hw_state') !== UHW_RUN; i++) s.probs.push(...s.tick(DT, budget).problems);
  assert.equal(s.ctx('hw_state'), UHW_RUN, 'card running');
  return s;
}
const clean = (s) => {
  assert.deepEqual(s.probs, [], s.probs.slice(0, 3).join('; '));
  assert.deepEqual(s.peer.errors, []);
};
const has = (name) => (ev) => ev.some((e) => e.name === name);
const isUdp = (dll) => dll.startsWith('gudp');
const peerGot = (s, dll) => (isUdp(dll) ? s.peer.udpIn.flat() : s.peer.received);

// Send `data` in pieces of `piece` bytes as TX slots free up and collect the
// echo; returns the received bytes.
function stream(s, data, piece) {
  let off = 0, tag = 1;
  const rx = [];
  for (let i = 0; i < 20000 && (off < data.length || rx.length < data.length); i++) {
    if (off < data.length) {
      const n = Math.min(piece, data.length - off);
      const x = s.send(data.slice(off, off + n), tag);
      if (x.res.a === S.OK) { assert.equal(x.commit.a, S.OK); off += n; tag = (tag + 1) & 0xffff || 1; }
    }
    s.run(1);
    s.events();
    rx.push(...s.drain().bytes);
  }
  return rx;
}

function ethScenarios(dll) {
  test(`${dll}: configured MAC overrides the card address`, () => {
    const mac = [0x02, 0x11, 0x22, 0x33, 0x44, 0x55];
    const s = boot(dll, { mac });
    assert.deepEqual(s.cardMac(), mac);
    clean(s);
  });

  test(`${dll}: answers ARP requests for its address while idle`, () => {
    const s = boot(dll);
    const req = [...[255, 255, 255, 255, 255, 255], ...s.peer.mac, 0x08, 0x06,
      0, 1, 8, 0, 6, 4, 0, 1, ...s.peer.mac, ...s.peer.ip, 0, 0, 0, 0, 0, 0, 192, 168, 0, 10];
    s.card.deliver(req);
    s.run(100);
    const reply = s.peer.sent.find((f) => f[12] === 8 && f[13] === 6 && f[21] === 2);
    assert.ok(reply, 'ARP reply sent');
    assert.deepEqual(reply.slice(0, 6), s.peer.mac);
    assert.deepEqual(reply.slice(6, 12), s.cardMac());
    assert.deepEqual(reply.slice(28, 32), [192, 168, 0, 10]);
    clean(s);
  });

  test(`${dll}: connect, echo 300 bytes both ways, close`, () => {
    const s = boot(dll);
    assert.equal(s.open().a, S.OK);
    s.until(has('CONNECTED'));
    const d = bytes(300, 7);
    assert.equal(s.send(d, 0x42).commit.a, S.OK);
    const ev = s.until((e) => has('RX_READY')(e) && has('TX_DONE')(e));
    assert.deepEqual(ev.filter((e) => e.name === 'TX_DONE').map((e) => [e.tag, e.status]), [[0x42, C.txdone.OK]]);
    assert.deepEqual(s.drain().bytes, d, 'echo intact');
    assert.deepEqual(peerGot(s, dll), d, 'peer received the payload');
    assert.equal(s.call('CLOSE').a, S.OK);
    s.until(has('CLOSED'));
    const st = s.getStats().stats;
    assert.equal(st.drop_checksum + st.drop_size + st.drop_fragment + st.hw_overflow, 0);
    assert.ok(st.max_step_gap_ms > 0 && st.polls_total > 0);
    clean(s);
  });

  test(`${dll}: the minimum useful budget from GET_INFO still moves data`, () => {
    const probe = boot(dll, {}, { noBoot: true });
    const min = probe.getInfo().info.min_useful_budget_us;
    assert.ok(min <= 500, `min_useful_budget_us ${min}`);
    const s = boot(dll, {}, { budget: min });
    assert.equal(s.open().a, S.OK);
    s.until(has('CONNECTED'));
    const d = bytes(isUdp(dll) ? 512 : 536, 9);
    assert.equal(s.send(d, 7).commit.a, S.OK);
    s.until((e) => has('RX_READY')(e) && has('TX_DONE')(e));
    assert.deepEqual(s.drain().bytes, d);
    clean(s);
  });

  test(`${dll}: an 8 KiB stream both ways stays intact (card buffer wraps)`, () => {
    const s = boot(dll);
    assert.equal(s.open().a, S.OK);
    s.until(has('CONNECTED'));
    const d = bytes(8192, 3);
    const rx = stream(s, d, isUdp(dll) ? 512 : 536);
    assert.equal(rx.length, d.length);
    assert.deepEqual(rx, d);
    assert.deepEqual(peerGot(s, dll), d);
    const st = s.getStats().stats;
    assert.equal(st.hw_overflow + st.drop_checksum + st.drop_size, 0);
    clean(s);
  });

  test(`${dll}: a datagram for another IPv4 address is dropped and counted`, () => {
    const s = boot(dll);
    assert.equal(s.open().a, S.OK);
    s.until(has('CONNECTED'));
    s.send(bytes(10, 3), 1);
    s.until(has('RX_READY'));
    s.drain();
    const before = s.getStats().stats;
    const foreign = [...[255, 255, 255, 255, 255, 255], ...s.peer.mac, 0x08, 0x00,
      0x45, 0, 0, 28, 0, 0, 0x40, 0, 64, 17, 0, 0, 192, 168, 0, 2, 192, 168, 0, 99, 0, 1, 0, 2, 0, 8, 0, 0];
    s.card.deliver(foreign);
    s.run(150);
    assert.equal(s.getStats().stats.drop_foreign - before.drop_foreign, 1, 'foreign destination counted');
    clean(s);
  });

  test(`${dll}: steady foreign broadcast traffic does not starve the channel`, () => {
    const s = boot(dll);
    assert.equal(s.open().a, S.OK);
    s.until(has('CONNECTED'));
    const noise = [...[255, 255, 255, 255, 255, 255], 0x02, 9, 9, 9, 9, 9, 0x08, 0x00,
      0x45, 0, 0, 200, 0, 0, 0x40, 0, 64, 17, 0, 0, 192, 168, 0, 77, 192, 168, 0, 99, ...new Array(180).fill(0x55)];
    const d = bytes(1500, 11);
    let off = 0;
    const rx = [];
    for (let i = 0; i < 10000 && (rx.length < d.length || i < 3000); i++) {
      if (i % 10 === 0) s.card.deliver(noise);         // one foreign frame every 20 ms
      if (off < d.length) {
        const x = s.send(d.slice(off, off + 300), 1 + off / 300);
        if (x.res.a === S.OK) { assert.equal(x.commit.a, S.OK); off += 300; }
      }
      s.run(1);
      s.events();
      rx.push(...s.drain().bytes);
    }
    if (isUdp(dll)) {
      // UDP carries no delivery guarantee: datagrams lost to a full card
      // buffer are allowed, the delivered ones are whole and in order
      for (let k = 0; k < rx.length; k += 300) {
        const p = d.findIndex((_, j) => j % 300 === 0 && d.slice(j, j + 300).every((v, q) => v === rx[k + q]));
        assert.ok(p >= 0 && (k === 0 || p > lastPos), `datagram ${k / 300} intact and in order`);
        var lastPos = p;
      }
      assert.ok(rx.length >= 900, `at least 3 of 5 datagrams (${rx.length / 300})`);
    } else {
      assert.deepEqual(rx, d, 'TCP repairs the losses');
    }
    assert.deepEqual(peerGot(s, dll), d, 'everything the DLL sent arrived');
    assert.ok(s.getStats().stats.drop_foreign > 10);
    clean(s);
  });

  test(`${dll}: STEP_ISR polls within any budget, GET_INFO covers the measured costs`, () => {
    const s = boot(dll);
    assert.equal(s.open().a, S.OK);
    s.until(has('CONNECTED'));
    s.run(300);                                    // quiet channel
    s.events();
    const info = s.getInfo().info;
    let empty = 0;
    for (const b of [40, 60, 100, 135, 150]) {
      const r = s.stepIsr(C.src.TIMER, b);
      assert.deepEqual(r.problems, [], `budget ${b}`);
      assert.ok(r.a === S.IDLE || r.a === S.YIELD, `status ${r.a} on a quiet channel`);
      if (r.a === S.IDLE) empty = Math.max(empty, r.us);
    }
    assert.ok(empty > 0 && empty <= info.empty_poll_us, `empty poll ${empty.toFixed(0)} <= published ${info.empty_poll_us}`);
    // a frame found by the ISR poll is served by the next STEP
    if (!isUdp(dll)) s.peer.sendData(bytes(32, 8));
    else s.peer.out.push(s.peer.ipFrame(s.cardMac(), [192, 168, 0, 10], 17,
      [0x1b, 0x58, 0x1b, 0x59, 0, 40, 0, 0, ...bytes(32, 8)]));
    s.pump();
    const r = s.stepIsr(C.src.TIMER, 150);
    assert.equal(r.a, S.WORK, 'frame waiting');
    s.until(has('RX_READY'));
    assert.deepEqual(s.drain().bytes, bytes(32, 8));
    // a held bus: BUS_BUSY, counted, still inside the budget and the
    // published bound
    const before = s.getStats().stats.bus_busy;
    s.m.poke(s.layout().lock, C.lock.SOUND);
    const b = s.stepIsr(C.src.TIMER, 150);
    s.m.poke(s.layout().lock, C.lock.FREE);
    assert.equal(b.a, S.BUS_BUSY);
    assert.ok(b.us <= info.bus_busy_us, `BUS_BUSY ${b.us.toFixed(0)} <= published ${info.bus_busy_us}`);
    assert.equal(s.getStats().stats.bus_busy - before, 1);
    clean(s);
  });

  if (!isUdp(dll)) {
    test(`${dll}: a segment with a bad TCP checksum is not delivered`, () => {
      const s = boot(dll);
      assert.equal(s.open().a, S.OK);
      s.until(has('CONNECTED'));
      const seg = s.peer.tcpSegment(s.peer.tcp, 0x18, bytes(20, 5));
      seg[seg.length - 1] ^= 0x5a;
      s.card.deliver(seg);
      s.run(200);
      assert.equal(s.call('RX_PEEK').a, S.EMPTY, 'nothing published');
      assert.equal(s.getStats().stats.drop_checksum, 1);
      clean(s);
    });

    test(`${dll}: a segment lost on the way to the peer is retransmitted`, () => {
      const s = boot(dll);
      assert.equal(s.open().a, S.OK);
      s.until(has('CONNECTED'));
      s.peer.dropEvery = 1;
      const d = bytes(200, 13);
      assert.equal(s.send(d, 5).commit.a, S.OK);
      for (let i = 0; i < 500 && !s.peer.log.length; i++) s.run(1);
      assert.equal(s.peer.log.length, 1, 'first copy dropped');
      s.peer.dropEvery = 0;
      s.until((e) => has('RX_READY')(e) && has('TX_DONE')(e), 3000);
      assert.deepEqual(s.drain().bytes, d);
      assert.ok(s.getStats().stats.tcp_retransmits >= 1);
      clean(s);
    });
  }
}

module.exports = { DT, ethScenarios, boot, clean, has, bytes, stream, isUdp, peerGot, UHW_RUN };
