// M1 ABI vectors on GLOOP (ABI §2, §3, §4, §5): slots, events, ordering,
// held notifications, ABORT/CLOSE/SHUTDOWN, CONFIG_EXPIRED, deadlines.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { Stand, C } = require('../../../tools/harness/stand.js');

const S = C.status;
const B = 500;                                   // STEP body budget used by the vectors
const clean = (r, what) => assert.deepEqual(r.problems, [], `${what}: ${r.problems.join('; ')}`);

function boot(over = {}, dll = 'gloop') {
  const s = new Stand({ dll });
  clean(s.call('INIT'), 'INIT');
  const cfg = s.defaultConfig({ step_budget_us: B, ...over });
  if (cfg.transport === C.transport.UDP) { cfg.tx_slot_size = over.tx_slot_size ?? 512; cfg.rx_slot_size = over.rx_slot_size ?? 512; }
  const r = s.initConfig(cfg);
  clean(r, 'INIT_CONFIG');
  assert.equal(r.a, S.OK);
  s.t = over.t0 ?? 1000;
  s.run = (n = 1, budget = B) => { let r; for (let i = 0; i < n; i++) { s.t = (s.t + 10) >>> 0; r = s.step(s.t, budget); clean(r, 'STEP'); } return r; };
  s.settle = (max = 400) => { for (let i = 0; i < max; i++) { const r = s.run(); if (r.a === S.IDLE) return r; } throw new Error('no IDLE'); };
  return s;
}
function connect(s) {
  assert.equal(s.open().a, S.OK);
  s.run();
  assert.deepEqual(s.events().map((e) => e.name), ['CONNECTED']);
}
const bytes = (n, seed = 1) => Array.from({ length: n }, (_, i) => (i * 31 + seed) & 255);

test('OPEN, repeated OPEN, CLOSE, CLOSED, reopen', () => {
  const s = boot();
  assert.equal(s.open().a, S.OK);
  assert.equal(s.open().a, S.STATE, 'OPEN in OPENING');
  s.run();
  assert.deepEqual(s.events().map((e) => e.name), ['CONNECTED']);
  assert.equal(s.open().a, S.STATE, 'OPEN in OPEN');
  assert.equal(s.call('CLOSE').a, S.OK);
  assert.equal(s.call('CLOSE').a, S.OK, 'CLOSE is idempotent');
  assert.equal(s.open().a, S.STATE, 'OPEN before CLOSED');
  s.settle();
  const ev = s.events();
  assert.deepEqual(ev.map((e) => e.name), ['CLOSED']);
  assert.equal(ev[0].channel, 0);
  assert.equal(s.call('CLOSE').a, S.OK, 'CLOSE in CLOSED');
  connect(s);
});

test('OPEN argument checks and explicit peer', () => {
  const s = boot();
  assert.equal(s.open({ ip: '0.0.0.0', port: 7 }).a, S.BAD_ARGUMENT);
  assert.equal(s.open({ ip: '10.0.0.9', port: 0 }).a, S.BAD_ARGUMENT);
  assert.equal(s.open({ ip: '10.0.0.9', port: 4000 }).a, S.OK);
  assert.deepEqual(s.ctx('peer_ip'), [10, 0, 0, 9]);
  assert.equal(s.ctx('peer_port'), 4000);
});

test('TX reservation rules and tag rules', () => {
  const s = boot();
  assert.equal(s.call('TX_RESERVE', { de: 10 }).a, S.STATE, 'no channel');
  connect(s);
  assert.equal(s.call('TX_RESERVE', { de: 0 }).a, S.BAD_ARGUMENT);
  assert.equal(s.call('TX_RESERVE', { de: 537 }).a, S.BAD_ARGUMENT);
  const r = s.call('TX_RESERVE', { de: 100 });
  clean(r, 'TX_RESERVE');
  assert.equal(r.a, S.OK);
  const slot = r.de & 0xff;
  assert.equal(s.call('TX_RESERVE', { de: 10 }).a, S.STATE, 'one reservation at a time');
  assert.equal(s.call('TX_COMMIT', { a: slot, de: 101, ix: 1 }).a, S.BAD_ARGUMENT, 'used > n');
  assert.equal(s.call('TX_COMMIT', { a: slot, de: 0, ix: 1 }).a, S.BAD_ARGUMENT, 'used = 0');
  assert.equal(s.call('TX_COMMIT', { a: slot, de: 10, ix: 0xffff }).a, S.BAD_ARGUMENT, 'reserved tag');
  assert.equal(s.call('TX_COMMIT', { a: (slot + 1) & 3, de: 10, ix: 1 }).a, S.BAD_ARGUMENT, 'wrong slot');
  assert.equal(s.call('TX_UNRESERVE', { a: (slot + 1) & 3 }).a, S.BAD_ARGUMENT);
  assert.equal(s.call('TX_COMMIT', { a: slot, de: 10, ix: 7 }).a, S.OK, 'reservation survived the errors');
  assert.equal(s.call('TX_COMMIT', { a: slot, de: 10, ix: 8 }).a, S.STATE, 'no reservation left');
  const r2 = s.call('TX_RESERVE', { de: 10 });
  assert.equal(s.call('TX_COMMIT', { a: r2.de & 0xff, de: 10, ix: 7 }).a, S.BAD_ARGUMENT, 'tag of an outstanding TX');
  assert.equal(s.call('TX_UNRESERVE', { a: r2.de & 0xff }).a, S.OK);
  assert.equal(s.call('TX_UNRESERVE', { a: r2.de & 0xff }).a, S.STATE);
  s.settle();
  const ev = s.events();
  assert.deepEqual(ev.filter((e) => e.name === 'TX_DONE').map((e) => [e.tag, e.status, e.slot]), [[7, C.txdone.OK, slot]]);
});

test('unread TX_DONE keeps its tag reserved', () => {
  const s = boot();
  connect(s);
  s.send(bytes(5), 0x55);
  s.settle();
  const r = s.call('TX_RESERVE', { de: 5 });
  assert.equal(s.call('TX_COMMIT', { a: r.de & 0xff, de: 5, ix: 0x55 }).a, S.BAD_ARGUMENT);
  const ev = s.events();
  assert.ok(ev.some((e) => e.name === 'TX_DONE' && e.tag === 0x55));
  assert.equal(s.call('TX_COMMIT', { a: r.de & 0xff, de: 5, ix: 0x55 }).a, S.OK, 'tag free once read');
});

test('ring order, WOULD_BLOCK, short commit on the last slot, stream intact', () => {
  const s = boot();
  connect(s);
  const sent = [];
  for (let i = 0; i < 4; i++) { const d = bytes(i === 3 ? 7 : 50, i); const x = s.send(d, 0x10 + i, i === 3 ? 400 : 50); assert.equal(x.commit.a, S.OK); assert.equal(x.slot, i); sent.push(...d); }
  assert.equal(s.call('TX_RESERVE', { de: 5 }).a, S.WOULD_BLOCK, 'next slot still busy');
  s.settle();
  const ev = s.events();
  assert.deepEqual(ev.filter((e) => e.name === 'TX_DONE').map((e) => e.tag), [0x10, 0x11, 0x12, 0x13]);
  assert.equal(ev.filter((e) => e.name === 'RX_READY').length, 1);
  const x = s.send(bytes(9, 9), 0x20);
  assert.equal(x.slot, 0, 'after the last slot the ring starts again');
  sent.push(...bytes(9, 9));
  s.settle();
  assert.deepEqual(s.drain().bytes, sent);
});

test('RX_PEEK repeat, chunking at slot boundaries, RX_RELEASE without PEEK', () => {
  const s = boot();
  connect(s);
  assert.equal(s.call('RX_PEEK').a, S.EMPTY);
  assert.equal(s.call('RX_RELEASE').a, S.STATE);
  const all = [];
  for (let i = 0; i < 4; i++) { const d = bytes(500, i); s.send(d, i + 1); all.push(...d); s.settle(); s.events(); }
  const got = s.drain();
  assert.deepEqual(got.bytes, all);
  assert.ok(got.chunks.every((n) => n <= 536), 'a region never crosses a slot');
  assert.deepEqual(got.chunks.slice(0, 3), [536, 536, 536]);
});

test('RX_READY once per empty -> non-empty transition', () => {
  const s = boot();
  connect(s);
  s.send(bytes(10), 1); s.settle();
  s.send(bytes(10), 2); s.settle();
  let ev = s.events();
  assert.equal(ev.filter((e) => e.name === 'RX_READY').length, 1, 'merged while data waits');
  s.drain();
  s.send(bytes(10), 3); s.settle();
  ev = s.events();
  assert.equal(ev.filter((e) => e.name === 'RX_READY').length, 1, 'new transition after drain');
});

test('full event queue holds outcomes and publishes each exactly once', () => {
  const s = boot({ event_cap: 16 });
  connect(s);
  const tags = [];
  // 6 rounds x 4 slots = 24 TX_DONE plus RX_READY, more than 15 entries, read nothing.
  for (let round = 0; round < 6; round++) {
    for (let i = 0; i < 4; i++) {
      const tag = 0x200 + round * 4 + i;
      const x = s.send(bytes(3, tag), tag);
      if (x.res.a !== S.OK) break;
      tags.push(tag);
    }
    s.settle();
  }
  assert.ok(tags.length >= 15 && tags.length < 24, `slots stay busy while their TX_DONE is held (${tags.length})`);
  const ev = s.events();
  const done = ev.filter((e) => e.name === 'TX_DONE').map((e) => e.tag);
  assert.deepEqual(done, tags, 'every tag once, in order');
  assert.equal(s.events().length, 0);
});

test('ABORT: CANCEL for every unfinished slot incl. the reservation, RX dropped, CLOSED once', () => {
  const s = boot();
  connect(s);
  s.send(bytes(30), 0x31); s.settle(); s.events();      // data waiting in RX
  // stop the loop from moving data: fill RX ring first
  s.send(bytes(536), 0x32); s.send(bytes(536), 0x33);
  const r = s.call('TX_RESERVE', { de: 20 });
  assert.equal(r.a, S.OK);
  assert.equal(s.call('ABORT').a, S.OK);
  assert.equal(s.call('ABORT').a, S.OK);
  const ev = s.events();
  const done = ev.filter((e) => e.name === 'TX_DONE');
  assert.deepEqual(done.map((e) => e.status), done.map(() => C.txdone.CANCEL));
  assert.ok(done.some((e) => e.tag === 0xffff && e.slot === (r.de & 0xff)), 'reservation cancelled with tag 0xFFFF');
  assert.deepEqual(new Set(done.map((e) => e.tag)), new Set([0x32, 0x33, 0xffff]));
  assert.equal(ev.filter((e) => e.name === 'CLOSED').length, 1);
  assert.equal(ev[ev.length - 1].name, 'CLOSED');
  assert.equal(s.call('RX_PEEK').a, S.EMPTY, 'ABORT drops RX');
  s.run(3);
  assert.equal(s.events().length, 0, 'repeated ABORT creates nothing');
});

test('CLOSE: queued TX completes, RX stays readable, CLOSED after drain', () => {
  const s = boot();
  connect(s);
  s.send(bytes(40), 0x41);
  assert.equal(s.call('CLOSE').a, S.OK);
  assert.equal(s.call('TX_RESERVE', { de: 1 }).a, S.STATE, 'no new TX after CLOSE');
  s.settle();
  let ev = s.events().map((e) => e.name);
  assert.ok(ev.includes('TX_DONE'));
  assert.ok(!ev.includes('CLOSED'), 'CLOSED waits for RX to be read');
  assert.deepEqual(s.drain().bytes, bytes(40));
  ev = s.events().map((e) => e.name);
  assert.deepEqual(ev, ['CLOSED']);
});

test('CONFIG_EXPIRED across the now_ms wrap', () => {
  const s = boot({ flags: C.cfgf.HAS_EXPIRY, expires_ms: 0x00000010, t0: 0xffffff00 });
  connect(s);
  const r0 = s.run();
  assert.ok(r0.deadline > 0 && r0.deadline < 0x200, `deadline before the wrap: ${r0.deadline}`);
  s.send(bytes(536), 0x61); s.send(bytes(536), 0x62); s.send(bytes(536), 0x63);
  for (let i = 0; i < 40; i++) s.run();               // crosses 0xFFFFFFFF -> 0
  const ev = s.events();
  assert.equal(ev.filter((e) => e.name === 'CONFIG_EXPIRED').length, 1);
  assert.equal(ev.find((e) => e.name === 'CONFIG_EXPIRED').channel, 0xff);
  assert.equal(s.open().a, S.STATE, 'OPEN after expiry');
  s.drain();
  s.run();
  const tail = s.events().map((e) => e.name);
  assert.ok([...ev.map((e) => e.name), ...tail].includes('CLOSED'));
  s.run(10);
  assert.equal(s.events().filter((e) => e.name === 'CONFIG_EXPIRED').length, 0, 'raised once');
});

test('CONFIG_EXPIRED without a channel synthesises no CLOSED', () => {
  const s = boot({ flags: C.cfgf.HAS_EXPIRY, expires_ms: 1100 });
  s.run(20);
  assert.deepEqual(s.events().map((e) => e.name), ['CONFIG_EXPIRED']);
});

test('STEP deadline: none, OPEN deadline, 0xFFFE clip', () => {
  const s = boot({ flags: C.cfgf.HAS_EXPIRY, expires_ms: 1000 + 200000 });
  let r = s.run();
  assert.equal(r.deadline, 0xfffe, 'far configuration deadline is clipped');
  const t = boot();
  r = t.run();
  assert.equal(r.deadline, 0xffff, 'no protocol deadline');
  const h = boot({}, 'gtcprtl');                       // no transport yet: OPEN only times out
  assert.equal(h.open().a, S.OK);
  r = h.run();
  assert.ok(r.deadline > 4900 && r.deadline <= 5000, `connect deadline ${r.deadline}`);
});

test('OPEN timeout on a silent network: TIMEOUT(OPEN) then CLOSED, no CONNECTED', () => {
  const s = boot({}, 'gudp509b');
  assert.equal(s.open().a, S.OK);
  for (let i = 0; i < 520; i++) s.run();               // 5.2 s
  const ev = s.events();
  assert.deepEqual(ev.map((e) => e.name), ['TIMEOUT', 'CLOSED']);
  assert.equal(ev[0].detail, C.timeout.OPEN);
  assert.equal(s.open().a, S.OK, 'a new OPEN after CLOSED');
});

test('SHUTDOWN: WORK until events are read, then OK; STATE for INIT_CONFIG meanwhile', () => {
  const s = boot();
  connect(s);
  s.send(bytes(20), 0x71);
  const r = s.call('SHUTDOWN');
  clean(r, 'SHUTDOWN');
  assert.equal(r.a, S.WORK);
  assert.equal(s.open().a, S.STATE);
  assert.equal(s.initConfig(s.defaultConfig()).a, S.STATE, 'context still owned');
  s.run();
  assert.equal(s.call('SHUTDOWN').a, S.WORK, 'unread events');
  const ev = s.events();
  assert.deepEqual(ev.map((e) => [e.name, e.status]), [['TX_DONE', C.txdone.CANCEL], ['CLOSED', 0]]);
  assert.equal(s.call('SHUTDOWN').a, S.OK);
  assert.equal(s.call('SHUTDOWN').a, S.OK, 'repeat after OK');
  for (let i = 0; i < 0x300; i++) s.m.poke(s.layout().ctx + i, 0);
  assert.equal(s.initConfig(s.defaultConfig()).a, S.OK, 'INIT_CONFIG after OK');
});

test('SHUTDOWN without a channel is immediately OK', () => {
  const s = boot();
  assert.equal(s.call('SHUTDOWN').a, S.OK);
});

test('max_observed_step_gap_ms with a pause and a wrap', () => {
  const s = boot({ t0: 0xfffffff0 });
  s.run();                                             // first useful STEP: no maximum yet
  let st = s.getStats().stats;
  assert.equal(st.avail & C.avail.MAX_STEP_GAP, 0);
  s.t = (s.t + 35) >>> 0;                              // crosses the wrap
  clean(s.step(s.t, B), 'STEP');
  st = s.getStats().stats;
  assert.equal(st.max_step_gap_ms, 35);
  assert.ok(st.avail & C.avail.MAX_STEP_GAP);
  // a budget refusal is not a useful step and leaves the reference point
  s.t += 100;
  const r = s.step(s.t, 20);
  assert.equal(r.a, S.YIELD);
  s.t += 5;
  s.step(s.t, B);
  assert.equal(s.getStats().stats.max_step_gap_ms, 105, 'gap from the last useful STEP, the refused one does not count');
});

test('UDP loopback: datagram boundaries, overflow drops whole datagrams', () => {
  const s = boot({ transport: C.transport.UDP });
  connect(s);
  const d = [bytes(5, 1), bytes(512, 2), bytes(1, 3), bytes(77, 4)];
  for (let i = 0; i < 4; i++) s.send(d[i], i + 1);
  s.settle();
  s.events();
  const got = s.drain();
  assert.deepEqual(got.chunks, [5, 512, 1, 77]);
  assert.deepEqual(got.bytes, d.flat());
  // RX full (4 slots) -> the 5th..8th datagrams are lost, TX still completes
  for (let k = 0; k < 2; k++) { for (let i = 0; i < 4; i++) s.send(bytes(10, i), 0x40 + k * 4 + i); s.settle(); }
  const ev = s.events();
  assert.equal(ev.filter((e) => e.name === 'TX_DONE').length, 8);
  assert.equal(s.drain().chunks.length, 4);
  assert.equal(s.getStats().stats.ring_overflow, 4);
});

test('STEP_ISR: source validation, CBL needs a qualified profile, counters', () => {
  const s = boot();
  assert.equal(s.stepIsr(0).a, S.BAD_ARGUMENT);
  assert.equal(s.stepIsr(7).a, S.BAD_ARGUMENT);
  assert.equal(s.stepIsr(C.src.CBL).a, S.STATE);
  for (const src of [1, 2, 2, 3, 4, 6]) { const r = s.stepIsr(src); clean(r, 'STEP_ISR'); assert.equal(r.a, S.IDLE); }
  const st = s.getStats().stats;
  assert.deepEqual(st.isr_calls, [1, 2, 1, 1, 0, 1]);
  assert.equal(st.irq_count, 1);
});
