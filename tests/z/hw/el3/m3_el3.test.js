// 3C509B builds on the Z stand: card model (devices/el3.js) + validating
// network peer (net/peer.js).  POLL mode, no IRQ.  Every STEP is checked
// by the stand for budget, DI <= 200 us, stack, ISA discipline and the
// exact restore of #1FFD/#9FBD/#E2.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { ethStand, C } = require('../../../../tools/harness/ethnet.js');

const S = C.status;
const bytes = (n, seed = 1) => Array.from({ length: n }, (_, i) => (i * 31 + seed) & 255);

function boot(dll, over = {}, opts = {}) {
  const s = ethStand({ dll, card: opts.card, peer: opts.peer });
  assert.equal(s.call('INIT').a, 0);
  const cfg = s.defaultConfig({ step_budget_us: 500, ...over });
  if (dll.startsWith('gudp')) { cfg.tx_slot_size = 512; cfg.rx_slot_size = 512; }
  assert.equal(s.initConfig(cfg).a, S.OK);
  s.probs = [];
  s.run = (n) => { for (let i = 0; i < n; i++) s.probs.push(...s.tick(10, 500).problems); };
  s.until = (pred, max = 600) => { const ev = []; for (let i = 0; i < max; i++) { s.probs.push(...s.tick(10, 500).problems); ev.push(...s.events()); if (pred(ev)) return ev; } throw new Error(`condition not met; events ${ev.map((e) => e.name)}`); };
  for (let i = 0; i < 200 && s.ctx('hw_state') !== 2; i++) s.probs.push(...s.tick(10, 500).problems);
  assert.equal(s.ctx('hw_state'), 2, 'card running');
  return s;
}
const clean = (s) => { assert.deepEqual(s.probs, [], s.probs.slice(0, 3).join('; ')); assert.deepEqual(s.peer.errors, []); };

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

  test(`${dll}: configured MAC overrides the EEPROM`, () => {
    const mac = [0x02, 0x11, 0x22, 0x33, 0x44, 0x55];
    const s = boot(dll, { mac });
    assert.deepEqual(s.card.station, mac);
    clean(s);
  });

  test(`${dll}: CIP is waited for as a state, not a busy loop`, () => {
    const s = boot(dll, {}, { card: { cipReads: 3 } });
    clean(s);
  });

  test(`${dll}: answers ARP requests for its address while idle`, () => {
    const s = boot(dll);
    const req = [...[255, 255, 255, 255, 255, 255], ...s.peer.mac, 0x08, 0x06,
      0, 1, 8, 0, 6, 4, 0, 1, ...s.peer.mac, ...s.peer.ip, 0, 0, 0, 0, 0, 0, 192, 168, 0, 10];
    s.card.deliver(req);
    s.run(20);
    const reply = s.peer.sent.find((f) => f[12] === 8 && f[13] === 6 && f[21] === 2);
    assert.ok(reply, 'ARP reply sent');
    assert.deepEqual(reply.slice(0, 6), s.peer.mac);
    assert.deepEqual(reply.slice(28, 32), [192, 168, 0, 10]);
    clean(s);
  });

  test(`${dll}: connect, echo 300 bytes both ways, close`, () => {
    const s = boot(dll);
    assert.equal(s.open().a, S.OK);
    s.until((ev) => ev.some((e) => e.name === 'CONNECTED'));
    const d = bytes(300, 7);
    assert.equal(s.send(d, 0x42).commit.a, S.OK);
    const ev = s.until((e) => e.some((x) => x.name === 'RX_READY') && e.some((x) => x.name === 'TX_DONE'));
    assert.deepEqual(ev.filter((e) => e.name === 'TX_DONE').map((e) => [e.tag, e.status]), [[0x42, C.txdone.OK]]);
    assert.deepEqual(s.drain().bytes, d, 'echo intact');
    const got = dll.startsWith('gudp') ? s.peer.udpIn.flat() : s.peer.received;
    assert.deepEqual(got, d, 'peer received the payload');
    assert.equal(s.call('CLOSE').a, S.OK);
    s.until((e) => e.some((x) => x.name === 'CLOSED'));
    const st = s.getStats().stats;
    assert.equal(st.drop_checksum + st.drop_size + st.drop_fragment, 0);
    assert.ok(st.max_step_gap_ms > 0 && st.polls_total > 0);
    clean(s);
  });

  test(`${dll}: a datagram for another IPv4 address is dropped and counted`, () => {
    const s = boot(dll);
    assert.equal(s.open().a, S.OK);
    s.until((ev) => ev.some((e) => e.name === 'CONNECTED'));
    const before = s.getStats().stats;
    // a valid exchange first, so the channel is known to work
    s.send(bytes(10, 3), 1);
    s.until((ev) => ev.some((e) => e.name === 'RX_READY'));
    s.drain();
    // foreign: frame to another station MAC is rejected by the card filter;
    // a broadcast IPv4 to another address reaches the core and is dropped
    const foreign = [...[255, 255, 255, 255, 255, 255], ...s.peer.mac, 0x08, 0x00,
      0x45, 0, 0, 28, 0, 0, 0x40, 0, 64, 17, 0, 0, 192, 168, 0, 2, 192, 168, 0, 99, 0, 1, 0, 2, 0, 8, 0, 0];
    s.card.deliver(foreign);
    s.run(30);
    const st = s.getStats().stats;
    assert.equal(st.drop_foreign - before.drop_foreign, 1, 'foreign destination counted');
    clean(s);
  });
}

test('gtcp509b: a segment with a bad TCP checksum is not delivered', () => {
  const s = boot('gtcp509b');
  assert.equal(s.open().a, S.OK);
  s.until((ev) => ev.some((e) => e.name === 'CONNECTED'));
  const c = s.peer.tcp;
  const seg = s.peer.tcpSegment(c, 0x18, bytes(20, 5));
  seg[seg.length - 1] ^= 0x5a;                         // payload corrupted after the checksum
  s.card.deliver(seg);
  s.run(40);
  assert.equal(s.call('RX_PEEK').a, S.EMPTY, 'nothing published');
  assert.equal(s.getStats().stats.drop_checksum, 1);
  clean(s);
});
