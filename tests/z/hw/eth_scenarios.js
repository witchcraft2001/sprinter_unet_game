// eth_scenarios.js -- scenarios shared by the card builds, registered by
// tests/z/hw/<card>/*.test.js: transportScenarios() for every card
// (RTL8019AS, 3C509B, SprinterESP), ethScenarios() adds the Ethernet ones.
//
// The stand checks every STEP for budget, DI <= 200 us, stack, ISA
// discipline and the exact restore of #1FFD/#9FBD/#E2; the Ethernet peer
// validates the IPv4/TCP/UDP checksums of every frame the DLL sends, the
// ESP model every AT command and payload byte.  POLL mode only (v1
// hardware profiles carry no qualified IRQ route).
'use strict';
const xrec = require('../../../tools/harness/net/xrec.js');

const test = require('node:test');
const assert = require('node:assert/strict');
const { ethStand, C, US } = require('../../../tools/harness/ethnet.js');
const A = require('../../../tools/harness/abi.json');
// Budgets are real microseconds; US(n) buys n units (tools/harness/stand.js).
const ISR_BUDGET = A.consts.limits.ISR_BODY_MAX_US;

const S = C.status;
const UHW_RUN = 2;
const bytes = (n, seed = 1) => Array.from({ length: n }, (_, i) => (i * 31 + seed) & 255);

// STEP period of the scenarios: the default INIT_CONFIG promises a useful
// poll at least every worst_poll_gap_us = 2000 us, so the stand calls STEP
// every 2 ms of virtual time.
const DT = 2;
const DT_DEFAULT = DT;

// Boot a build to the running card.  over: INIT_CONFIG fields; opts.card /
// opts.peer: model options; opts.budget: STEP budget (default US(500): 500 units);
// opts.clockMs: now_ms moves in ticks of this length (ethnet.js);
// opts.dt: real ms between STEPs (default DT).
function boot(dll, over = {}, opts = {}) {
  const s = ethStand({ dll, card: opts.card, peer: opts.peer, clockMs: opts.clockMs });
  const DT = opts.dt ?? DT_DEFAULT;
  const budget = opts.budget ?? US(500);
  assert.equal(s.call('INIT').a, 0);
  const cfg = s.defaultConfig({ step_budget_us: budget, ...over });
  assert.equal(s.initConfig(cfg).a, S.OK);
  s.probs = [];
  s.stepOpts = {};
  s.run = (n, dt = DT) => { for (let i = 0; i < n; i++) s.probs.push(...s.tick(dt, budget, s.stepOpts).problems); };
  s.until = (pred, max = 3000, dt = DT) => {
    const ev = [];
    for (let i = 0; i < max; i++) {
      s.probs.push(...s.tick(dt, budget, s.stepOpts).problems);
      ev.push(...s.events());
      if (pred(ev)) return ev;
    }
    throw new Error(`condition not met; events ${ev.map((e) => e.name)}`);
  };
  if (opts.noBoot) return s;
  // (3000 ticks: the transparent profile of GUDPESP starts with "+++" and
  // its pauses, about 2.3 s)
  for (let i = 0; i < 3000 && s.ctx('hw_state') !== UHW_RUN; i++) s.probs.push(...s.tick(DT, budget).problems);
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
function stream(s, data, piece, dt = DT) {
  let off = 0, tag = 1;
  const rx = [];
  for (let i = 0; i < 20000 && (off < data.length || rx.length < data.length); i++) {
    if (off < data.length) {
      const n = Math.min(piece, data.length - off);
      const x = s.send(data.slice(off, off + n), tag);
      if (x.res.a === S.OK) { assert.equal(x.commit.a, S.OK); off += n; tag = (tag + 1) & 0xffff || 1; }
    }
    s.run(1, dt);
    s.events();
    rx.push(...s.drain().bytes);
  }
  return rx;
}

// Peer data for the DLL: a TCP segment / UDP datagram (Ethernet) or bytes
// handed to the ESP module's link.
function inject(s, dll, data) {
  if (s.isEsp) s.peer.sendData(data);
  else if (!isUdp(dll)) s.peer.sendData(data);
  else {
    const body = s.peer.udpWrap(data);     // a record with UDP records on
    s.peer.out.push(s.peer.ipFrame(s.cardMac(), [192, 168, 0, 10], 17,
      [0x1b, 0x58, 0x1b, 0x59, (8 + body.length) >> 8, (8 + body.length) & 255, 0, 0, ...body]));
  }
  s.pump();
}

// A network ISR that interrupts the main STEP (ABI §1: the network may
// interrupt a main call): an IM1 stub in WIN0 switches to the ISR stack,
// calls STEP_ISR(TIMER) without pre-acquire and returns with EI; RETI.
// s.stepOpts makes every STEP take one such interrupt at a pseudo-random
// instruction where IFF1 = 1 inside the image.
const ISR_STUB = 0x0300, ISR_SAVE = 0x0380, ISR_LOG = 0x0382;
function nestedIsr(s, seed = 12345) {
  const m = s.m, L = s.layout(), top = L.istack + L.istackLen;
  const e = s.entry('STEP_ISR');
  m.pokeBytes(0x0038, [0xc3, ISR_STUB & 255, ISR_STUB >> 8]);
  m.pokeBytes(ISR_STUB, [
    0xed, 0x73, ISR_SAVE & 255, ISR_SAVE >> 8,     // LD (save),SP
    0x31, top & 255, top >> 8,                      // LD SP,top
    0xf5, 0xc5, 0xd5, 0xe5,                         // PUSH AF/BC/DE/HL
    0x3e, C.src.TIMER, 0x11, ISR_BUDGET & 255, ISR_BUDGET >> 8,   // LD A,TIMER : LD DE,budget
    0xcd, e & 255, e >> 8,                          // CALL STEP_ISR
    0x32, ISR_LOG & 255, ISR_LOG >> 8,              // LD (log),A
    0xe1, 0xd1, 0xc1, 0xf1,                         // POP HL/DE/BC/AF
    0xed, 0x7b, ISR_SAVE & 255, ISR_SAVE >> 8,     // LD SP,(save)
    0xfb, 0xed, 0x4d,                               // EI : RETI
  ]);
  let x = seed, taken = 0, insideIsr = false, c0 = 0, saved = null;
  const st = { taken: 0, statuses: [], maxUs: 0, touched: new Set() };
  // the per-call fields of the interrupted STEP: STEP_ISR writes none
  const callFields = ['call_flags', 'work', 'units', 'flags_out'].map((k) => [k, L.ctx + A.ctx.fields[k].offset, A.ctx.fields[k].size]);
  const snap = () => callFields.map(([, a, n]) => m.peekBytes(a, n).join(','));
  s.stepOpts = {
    slackUs: ISR_BUDGET + 120,                      // the ISR and its stub run inside the measured STEP
    onStep: (mm, cpu) => {
      if (cpu.pc === ISR_STUB) { insideIsr = true; saved = snap(); }
      if (insideIsr && cpu.pc === e) c0 = mm.cycles;
      if (insideIsr && cpu.pc === ISR_STUB + 19) st.maxUs = Math.max(st.maxUs, (mm.cycles - c0) / mm.mhz);
      if (insideIsr && cpu.pc === ISR_STUB + 30) {
        insideIsr = false; st.statuses.push(mm.peek(ISR_LOG));
        snap().forEach((v, i) => { if (v !== saved[i]) st.touched.add(callFields[i][0]); });
      }
      // a real Z80 takes no interrupt right after DI (the vendored core
      // applies DI one instruction late: do_delayed_di)
      if (taken > 0 || !cpu.iff1 || cpu.do_delayed_di || !mm.pcInImage()) return;
      if (--x <= 0) { taken = 1; st.taken++; mm.cpu.interrupt(false, 0xff); }
    },
  };
  const arm = () => { taken = 0; x = 1 + ((seed = (seed * 1103515245 + 12345) >>> 0) % 2500); };
  arm();
  s.armIsr = arm;
  return st;
}

// o.budget / o.label: the same scenarios at another STEP budget (the fat
// STEP of the SprinterESP builds), with the label in every test name;
// o.over: INIT_CONFIG fields of every boot (GUDPESP's transparent mode,
// esp_fw = 2).
const bootAt = (...a) => boot(...a);
function transportScenarios(dll, o = {}) {
  // eslint-disable-next-line no-shadow
  const boot = (d, over = {}, opts = {}) => bootAt(d, { ...o.over, ...over }, o.budget ? { budget: o.budget, ...opts } : opts);
  const L = o.label || '';
  test(`${dll}${L}: connect, echo 300 bytes both ways, close`, () => {
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
    if (!s.isEsp && !isUdp(dll)) {
      // CLOSED means the last ACK is on the wire: the SHUTDOWN a game issues
      // next must not cut it off (found in MAME: the peer resent its FIN)
      const c = s.peer.tcp;
      assert.equal(c.state, 'closed');
      assert.equal(c.acked, c.snd, 'peer FIN acknowledged before CLOSED');
    }
    const st = s.getStats().stats;
    assert.equal(st.drop_checksum + st.drop_size + st.drop_fragment + st.hw_overflow, 0);
    assert.ok(st.max_step_gap_ms > 0 && st.polls_total > 0);
    clean(s);
  });

  test(`${dll}${L}: the minimum useful budget from GET_INFO still moves data`, () => {
    const probe = boot(dll, {}, { noBoot: true });
    const min = probe.getInfo().info.min_useful_budget_us;
    assert.ok(min <= US(437), `min_useful_budget_us ${min}`);   // 437 units (GTCP509B: base 212 + item 215 + return 10)
    const s = boot(dll, {}, { budget: min });
    assert.equal(s.open().a, S.OK);
    s.until(has('CONNECTED'));
    const d = bytes(isUdp(dll) ? 512 : 536, 9);
    assert.equal(s.send(d, 7).commit.a, S.OK);
    s.until((e) => has('RX_READY')(e) && has('TX_DONE')(e));
    const rx = s.drain().bytes;                    // ESP: passive reads come in pieces
    for (let i = 0; i < 3000 && rx.length < d.length; i++) { s.run(1); s.events(); rx.push(...s.drain().bytes); }
    assert.deepEqual(rx, d);
    clean(s);
  });

  test(`${dll}${L}: at the minimum budget STEP itself publishes the TX_DONE of a lone send`, () => {
    // A full card poll and the TX scan left less than one publication in a
    // minimum STEP: TX_DONE was refused in every STEP (and the scan paid
    // again) until the game read its events -- NEXT_EVENT flushes without a
    // budget.  UCLK_EV_FIRST: the next STEP flushes the events first.  The
    // queue is checked without reading it.
    const probe = boot(dll, {}, { noBoot: true });
    const min = probe.getInfo().info.min_useful_budget_us;
    const s = boot(dll, {}, { budget: min });
    assert.equal(s.open().a, S.OK);
    s.until(has('CONNECTED'), 3000, 10);
    s.run(50, 10); s.events(); s.drain();
    assert.equal(s.send(bytes(100, 4), 0x31).commit.a, S.OK);
    s.run(300, 10);                                // nobody reads the events
    assert.equal(s.ctx('ev_flags') & 0x80, 0, 'no TX outcome held (UEVF_TXDONE)');
    assert.notEqual(s.ctx('ev_head'), s.ctx('ev_tail'), 'events queued by STEP');
    assert.ok(s.events().some((e) => e.name === 'TX_DONE' && e.tag === 0x31));
    clean(s);
  });

  test(`${dll}${L}: an 8 KiB stream both ways stays intact`, () => {
    const s = boot(dll);
    assert.equal(s.open().a, S.OK);
    s.until(has('CONNECTED'));
    const d = bytes(8192, 3);
    const rx = stream(s, d, isUdp(dll) ? 512 : 536);
    assert.equal(rx.length, d.length);
    assert.deepEqual(rx, d);
    assert.deepEqual(peerGot(s, dll), d);
    const st = s.getStats().stats;
    assert.equal(st.hw_overflow + st.drop_checksum + st.drop_size + st.uart_overrun, 0);
    clean(s);
  });

  // ТЗ §6.1/§8.2 "базовая нагрузка": 2048 B/s useful payload each way, at
  // the default STEP period (2 ms) and budget (500 units).  Ethernet already
  // clears this with the SDK's default ISR budget; SprinterESP needs a
  // game to raise UGP_ISR_BUDGET (docs/SDK.md) so STEP_ISR's leftover
  // budget can run a second UART drain (WP4, ES_ISRCAP) -- modelled here
  // by injecting STEP_ISR at the largest budget between STEPs, same as
  // `profile_step.js --isr` (docs/MEASUREMENTS.md, "Этап ESP 2
  // КиБ/с").  GUDPESP clears the target this way; GTCPESP does not --
  // CIPRECVDATA's main-STEP-only round trip still caps it, so it stays a
  // `todo` test, never a weakened assert, until closed or accepted as the
  // Ж (real hardware) outcome.
  test(`${dll}${L}: an 8 KiB stream both ways reaches >= 2048 B/s (ТЗ §6.1/§8.2)`,
    { todo: dll === 'gtcpesp' ? 'GTCPESP: CIPRECVDATA round trip caps it below 2048 B/s even with the STEP_ISR RX pump' : false }, () => {
    const s = boot(dll);
    if (s.isEsp) s.stepOpts = { isr: { budget: ISR_BUDGET } };
    assert.equal(s.open().a, S.OK);
    s.until(has('CONNECTED'));
    const d = bytes(8192, 3);
    const t0 = s.t;
    const rx = stream(s, d, isUdp(dll) ? 512 : 536);
    const ms = s.t - t0;
    assert.deepEqual(rx, d);
    const rate = d.length / (ms / 1000);
    assert.ok(rate >= 2048, `${rate.toFixed(0)} B/s both ways in ${ms} ms`);
    clean(s);
  });

  // The SDK gateway spreads STEPs over the budget period (ТЗ §7: 2 per
  // 20 ms); GET_INFO allows gaps up to max_step_gap_ms = 20
  // (tools/dev/profile_step.js --dt 2,10,20).  Ethernet TCP holds since the
  // STEP admission order of ETH_SCHED, ESP since its CIPRECVDATA deadline
  // counts from the last received byte (ESP_PROGRESS).
  for (const gap of [10, 20]) {
    test(`${dll}${L}: an 8 KiB stream with a STEP every ${gap} ms stays within budget`, () => {
        const s = boot(dll);
        assert.equal(s.open().a, S.OK);
        s.until(has('CONNECTED'));
        const d = bytes(8192, 11);
        const rx = stream(s, d, isUdp(dll) ? 512 : 536, gap);
        assert.deepEqual(rx, d);
        clean(s);
      });
  }

  test(`${dll}${L}: STEP_ISR interrupting a STEP leaves the STEP state intact`, () => {
    const s = boot(dll);
    const st = nestedIsr(s);
    const tick = s.tick;
    s.tick = (...a) => { s.armIsr(); return tick(...a); };
    assert.equal(s.open().a, S.OK);
    s.until(has('CONNECTED'));
    const d = bytes(8192, 5);                      // long enough for > 100 interrupts at any speed
    const rx = stream(s, d, isUdp(dll) ? 512 : 536);
    assert.deepEqual(rx, d);
    assert.deepEqual(peerGot(s, dll), d);
    assert.ok(st.taken > 100, `interrupts taken ${st.taken}`);
    assert.ok(st.maxUs <= ISR_BUDGET, `nested STEP_ISR took ${st.maxUs.toFixed(1)} us, budget ${ISR_BUDGET}`);
    assert.equal(s.m.peek(s.layout().lock), 0, 'ISA lock free');
    assert.equal(s.ctx('call_flags'), 0);
    assert.deepEqual([...st.touched], [], 'per-call fields written by STEP_ISR');
    assert.ok(st.statuses.every((a) => [S.OK, S.IDLE, S.WORK, S.BUS_BUSY].includes(a)), `STEP_ISR statuses ${[...new Set(st.statuses)]}`);
    clean(s);
  });

  test(`${dll}${L}: SHUTDOWN at any point of a send finishes, the slot outcome is published`, () => {
    // a frame needs tens of STEPs at the minimum budget (MEASUREMENTS.md):
    // SHUTDOWN lands before, inside and after its TX pipeline
    for (const k of [0, 4, 8, 10, 12, 16, 20, 26, 32, 40]) {
      const probe = boot(dll, {}, { noBoot: true });
      const min = probe.getInfo().info.min_useful_budget_us;
      const s = boot(dll, {}, { budget: min });
      assert.equal(s.open().a, S.OK);
      s.until(has('CONNECTED'));
      assert.equal(s.send(bytes(isUdp(dll) ? 512 : 536, k), 0x77).commit.a, S.OK);
      s.run(k);                                    // the frame is k STEPs into its pipeline
      let r, n;
      const ev = [];
      for (n = 0; n < 1000; n++) {
        r = s.call('SHUTDOWN');
        if (r.a === S.OK) break;
        s.run(1);
        ev.push(...s.events());
      }
      assert.equal(r.a, S.OK, `SHUTDOWN after ${k} STEPs: ${r.a}`);
      assert.ok(ev.some((e) => e.name === 'TX_DONE' && e.tag === 0x77), `TX_DONE after ${k} STEPs`);
      clean(s);
    }
  });

  test(`${dll}${L}: STEP_ISR polls within any budget, GET_INFO covers the measured costs`, () => {
    const s = boot(dll);
    assert.equal(s.open().a, S.OK);
    s.until(has('CONNECTED'));
    s.run(300);                                    // quiet channel
    s.events();
    const info = s.getInfo().info;
    let empty = 0;
    for (const b of [40, 60, 64, 65, 70, 100, 135, 150].map(US)) {   // units around PROF_ISR_MIN_US
      const r = s.stepIsr(C.src.TIMER, b);
      assert.deepEqual(r.problems, [], `budget ${b}`);
      assert.ok(r.a === S.IDLE || r.a === S.YIELD, `status ${r.a} on a quiet channel`);
      if (r.a === S.IDLE) empty = Math.max(empty, r.us);
    }
    assert.ok(empty > 0 && empty <= info.empty_poll_us, `empty poll ${empty.toFixed(0)} <= published ${info.empty_poll_us}`);
    // data found by the ISR poll is served by the next STEP
    inject(s, dll, bytes(32, 8));
    s.idle(s.isEsp ? 8 : 0);                       // ESP: the notice crosses the network and the UART line
    const r = s.stepIsr(C.src.TIMER);
    assert.deepEqual(r.problems, []);
    assert.equal(r.a, S.WORK, 'data waiting');
    s.until(has('RX_READY'));
    const rx = s.drain().bytes;
    for (let i = 0; i < 1000 && rx.length < 32; i++) { s.run(1); s.events(); rx.push(...s.drain().bytes); }
    assert.deepEqual(rx, bytes(32, 8));
    // a held bus: BUS_BUSY, counted, still inside the budget and the
    // published bound
    const before = s.getStats().stats.bus_busy;
    s.m.poke(s.layout().lock, C.lock.SOUND);
    const b = s.stepIsr(C.src.TIMER);
    s.m.poke(s.layout().lock, C.lock.FREE);
    assert.equal(b.a, S.BUS_BUSY);
    assert.ok(b.us <= info.bus_busy_us, `BUS_BUSY ${b.us.toFixed(0)} <= published ${info.bus_busy_us}`);
    assert.equal(s.getStats().stats.bus_busy - before, 1);
    clean(s);
  });
}

function ethScenarios(dll) {
  transportScenarios(dll);

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

  // ---- small packets and the short path (docs/MEASUREMENTS.md "Короткий путь") --
  // GUDP509B at a budget of about 1800 us and more: the card portions of a
  // small frame fused (BEGIN + header, payload + END, poll + header), a
  // frame dropped by the card in the portion that reads its last byte, a
  // small datagram as one software item each way.  The other builds keep
  // the plain items; the outcomes below are the same for all.
  const BIG = A.consts.limits.STEP_BODY_MAX_US;
  const SHORT = dll === 'gudp509b';
  const sentFrames = (s) => s.card.transmitted.length;
  const minBudget = () => boot(dll).getInfo().info.min_useful_budget_us;

  test(`${dll}: streams in small pieces stay intact (padding, the short path) at the largest and the smallest budget`, () => {
    for (const budget of [BIG, minBudget()]) {
      for (const piece of [1, 17, 18, 22, 23, 40, 41, 57, 64]) {
        const s = boot(dll, {}, { budget });
        assert.equal(s.open().a, S.OK);
        s.until(has('CONNECTED'), 20000);
        const d = bytes(piece * 12, piece);
        assert.deepEqual(stream(s, d, piece), d, `piece ${piece} budget ${budget}`);
        assert.deepEqual(peerGot(s, dll), d);
        clean(s);
      }
    }
  });

  if (isUdp(dll)) {
    // What a game gets at the largest budget, one STEP per frame: the
    // datagram on the wire and the echo readable after so many STEPs.
    // GUDP509B (short path): 2 and 3 STEPs up to 16 bytes; the plain items
    // need 3 and 5.  These numbers are the reason for the short path --
    // a change that loses them is a regression.
    test(`${dll}: a small datagram at the largest budget: STEPs to the wire and to the echo`, () => {
      for (const n of [1, 8, 16]) {
        const s = boot(dll, {}, { budget: BIG });
        assert.equal(s.open().a, S.OK);
        s.until(has('CONNECTED'));
        s.run(50); s.events(); s.drain();
        for (let k = 0; k < 4; k++) {
          const d = bytes(n, 9 + k), f0 = sentFrames(s);
          assert.equal(s.send(d, k + 1).commit.a, S.OK);
          let wire = 0, echo = 0;
          const rx = [];
          for (let i = 1; i <= 12 && !echo; i++) {
            s.run(1);
            s.events();
            if (!wire && sentFrames(s) > f0) wire = i;
            rx.push(...s.drain().bytes);
            if (rx.length >= n) echo = i;
          }
          assert.deepEqual(rx, d);
          assert.ok(wire <= (SHORT ? 2 : 3), `${n} bytes: on the wire after ${wire} STEPs`);
          assert.ok(echo <= (SHORT ? 3 : 5), `${n} bytes: echo after ${echo} STEPs`);
          s.run(20); s.events(); s.drain();
        }
        clean(s);
      }
    });

    test(`${dll}: a received datagram of up to 22 bytes is readable ${SHORT ? 'after the one STEP that polls it' : 'within three STEPs'} at the largest budget`, () => {
      for (const n of [0, 1, 16, 22]) {
        const s = boot(dll, {}, { budget: BIG });
        assert.equal(s.open().a, S.OK);
        s.until(has('CONNECTED'));
        s.run(50); s.events();
        const d = bytes(n, 40 + n);
        const before = s.getStats().stats;
        inject(s, dll, d);
        let steps = 0;
        for (; steps < 6 && s.getStats().stats.rx_bytes - before.rx_bytes < n; steps++) s.run(1);
        if (n === 0) { s.run(SHORT ? 1 : 3); steps = SHORT ? 1 : 3; }
        assert.ok(steps <= (SHORT ? 1 : 3), `${n} bytes after ${steps} STEPs`);
        assert.deepEqual(s.drain().bytes, d);
        s.until(has('RX_READY'), 4);
        clean(s);
      }
    });

    // Datagrams of 23..96 bytes: GUDP509B checks, accepts and reads them
    // from the card in the item that finds them (UDP_RX_MID) and publishes
    // them in the STEP that polls them -- up to 88 bytes: the item of 96
    // (673 units) does not fit beside the poll and the header (668 left at
    // 3000 us), it takes two; the other builds take the plain items (the
    // plain numbers are what they measure today).
    test(`${dll}: a received datagram of 23..96 bytes is readable ${SHORT ? 'after the one STEP that polls it (88 bytes and less)' : 'within four STEPs'} at the largest budget`, () => {
      for (const n of [23, 40, 41, 62, 63, 64, 88, 96]) {
        const s = boot(dll, {}, { budget: BIG });
        assert.equal(s.open().a, S.OK);
        s.until(has('CONNECTED'));
        s.run(50); s.events();
        const d = bytes(n, 60 + n);
        const before = s.getStats().stats;
        inject(s, dll, d);
        let steps = 0;
        for (; steps < 8 && s.getStats().stats.rx_bytes - before.rx_bytes < n; steps++) s.run(1);
        assert.ok(steps <= (SHORT ? (n <= 88 ? 1 : 2) : 4), `${n} bytes after ${steps} STEPs`);
        assert.deepEqual(s.drain().bytes, d);
        s.until(has('RX_READY'), 4);
        clean(s);
      }
    });

    // A card portion of a mid datagram refused for the bus (the sound
    // owner takes the try-lock between the accept and the copy): the
    // generic states read the rest, nothing is lost or duplicated.
    if (SHORT) {
      test(`${dll}: a busy bus in the middle of a datagram of 88 bytes leaves the rest to the generic states`, () => {
        const s = boot(dll, {}, { budget: BIG });
        assert.equal(s.open().a, S.OK);
        s.until(has('CONNECTED'));
        s.run(50); s.events();
        const at = s.sym('UDP_RX_MID.portion'), lock = s.layout().lock;
        let held = 0;
        s.stepOpts = { onStep: (m, st) => { if (st.pc === at && !held) { held = 1; m.poke(lock, 3); } } };
        const d = bytes(88, 7), before = s.getStats().stats;
        inject(s, dll, d);
        s.run(1);
        assert.equal(held, 1, 'the mid path reached its first card portion');
        s.m.poke(lock, 0);
        s.stepOpts = {};
        for (let i = 0; i < 8 && s.getStats().stats.rx_bytes - before.rx_bytes < 88; i++) s.run(1);
        assert.deepEqual(s.drain().bytes, d);
        assert.ok(s.getStats().stats.bus_busy > before.bus_busy, 'the refusal is counted');
        inject(s, dll, bytes(40, 3));
        s.run(10);
        assert.deepEqual(s.drain().bytes, bytes(40, 3), 'the next datagram');
        clean(s);
      });
    }

    // Everything the short path is not sure about goes to the generic
    // states: the outcome and the statistics are the same with it (largest
    // budget) and without it (smallest budget: its items never fit).
    test(`${dll}: doubtful datagrams (12, 60, 88 bytes) are dropped and counted the same at any budget`, () => {
     // UDP records (UG_RECORDS=1): the payload is a record (header at 42)
     const R = process.env.UG_RECORDS === '1';
     for (const size of [12, 60, 88]) {
      const dg = (s, over = {}, data = bytes(size, 9)) => {
        const body = s.peer.udpWrap(data);
        const f = s.peer.ipFrame(s.cardMac(), [192, 168, 0, 10], 17, [0x1b, 0x58, 0x1b, 0x59, 0, 8 + body.length, 0, 0, ...body]);
        for (const [o, v] of Object.entries(over)) f[+o] = v;
        return f;
      };
      const fixIp = (f) => { f[24] = 0; f[25] = 0; let c = 0; for (let i = 14; i < 34; i += 2) c += (f[i] << 8) | f[i + 1];
        while (c > 0xffff) c = (c & 0xffff) + (c >>> 16); c = (~c) & 0xffff; f[24] = c >> 8; f[25] = c & 255; return f; };
      const cases = [
        ['another destination port', (s) => dg(s, { 37: 0x5a }), 'drop_foreign', 0],
        ['another source port', (s) => dg(s, { 35: 0x5a }), 'drop_foreign', 0],
        ['another source address', (s) => fixIp(dg(s, { 29: 77 })), 'drop_foreign', 0],
        ['a bad UDP checksum', (s) => dg(s, { 45: 0xee }), 'drop_checksum', 0],
        ['a bad IPv4 header checksum', (s) => dg(s, { 24: 0x12, 25: 0x34 }), 'drop_checksum', 0],
        ['a fragment', (s) => fixIp(dg(s, { 20: 0x20 })), 'drop_fragment', 0],
        ['no checksum (0)', (s) => dg(s, { 40: 0, 41: 0 }), null, size],
        // records: the shorter datagram no longer holds its whole record
        ['a UDP length below the IPv4 payload, no checksum', (s) => dg(s, { 39: 8 + (R ? 2 : 0) + size - 2, 40: 0, 41: 0 }), R ? 'drop_checksum' : null, R ? 0 : size - 2],
      ];
      if (R) {
        const other = xrec.encode(bytes(size - 1, 9));          // a valid header of another length
        cases.push(['a bad record header, no checksum', (s) => dg(s, { 40: 0, 41: 0, 42: 0xff }), 'drop_checksum', 0]);
        cases.push(['a record shorter than its datagram, no checksum', (s) => dg(s, { 40: 0, 41: 0, 42: other[0], 43: other[1] }), 'drop_checksum', 0]);
      }
      for (const budget of [BIG, minBudget()]) {
        for (const [name, make, stat, len] of cases) {
          const s = boot(dll, {}, { budget });
          assert.equal(s.open().a, S.OK);
          s.until(has('CONNECTED'), 20000);
          s.run(10); s.events();
          const before = s.getStats().stats;
          s.card.deliver(make(s));
          s.run(60);
          const after = s.getStats().stats, got = s.drain().bytes;
          assert.equal(got.length, len, `${name}, ${size} bytes, budget ${budget}: delivered bytes`);
          for (const k of ['drop_foreign', 'drop_checksum', 'drop_fragment', 'drop_size', 'ring_overflow']) {
            assert.equal(after[k] - before[k], k === stat ? 1 : 0, `${name}, ${size} bytes, budget ${budget}: ${k}`);
          }
          inject(s, dll, bytes(8, 3));          // the channel still works
          s.run(60);
          assert.deepEqual(s.drain().bytes, bytes(8, 3), `${name}: the next datagram`);
          clean(s);
        }
      }
     }
    });

    test(`${dll}: a full RX queue drops and counts a datagram (3 and 60 bytes), the stored ones stay whole`, () => {
      for (const len of [3, 60]) {
        const s = boot(dll, {}, { budget: BIG });
        assert.equal(s.open().a, S.OK);
        s.until(has('CONNECTED'));
        let n = 0;
        for (; n < 40 && s.getStats().stats.ring_overflow === 0; n++) { inject(s, dll, new Array(len).fill(n)); s.run(4); }
        assert.ok(s.getStats().stats.ring_overflow >= 1, `overflow counted after ${n} unread datagrams`);
        const all = [];
        for (let i = 0; i < 40; i++) { const g = s.drain().bytes; if (!g.length) break; all.push(...g); }
        assert.ok(all.length >= len && all.length % len === 0);
        for (let i = 0; i < all.length; i += len) assert.deepEqual(all.slice(i, i + len), new Array(len).fill(i / len), 'whole and in order');
        clean(s);
      }
    });

    // A real-time game's flow (games/headball/specs.md §15.4: an input of
    // 20 bytes 25 times a second up and a state of 88 bytes 10 times a
    // second down, at once) at one STEP of the largest budget per 20 ms
    // frame (tools/dev/game_load.js; docs/MEASUREMENTS.md).  Both carry
    // all of it with one input in flight: GUDP509B by its short path and
    // further passes, GUDPRTL by the TX-first order and the portions
    // priced by their bytes (UGB_TXFIRST / UGB_BYTECOST, 2026-11-23) --
    // the numbers of today, a regression guard.
    test(`${dll}: a real-time game's flow at one STEP of ${BIG} us per frame`, () => {
      const { run } = require('../../../tools/dev/game_load.js');
      const x = run(dll, { budget: BIG, frames: 250 });
      assert.ok(!x.err, x.err);
      const inputs = x.wire / x.sec, states = x.got / x.sec;
      assert.ok(inputs >= 24.5, `inputs ${inputs}/s`);
      assert.ok(states >= 9.5 && x.pushed - x.got <= 1, `states ${states}/s, lost ${x.pushed - x.got}`);
      assert.equal(x.over, 0, 'no STEP over its budget');
      assert.equal(x.bad, 0, 'nothing unexpected arrived');
      assert.deepEqual(x.prob, []);
      assert.ok(Math.max(...x.inLat) <= 40, `input latency ${Math.max(...x.inLat)} ms`);
      assert.ok(Math.max(...x.stLat) <= (SHORT ? 60 : 80), `state latency ${Math.max(...x.stLat)} ms`);
    });

    // More than one STEP carries (a state every 3 frames, or of 200 bytes,
    // or inputs of 64 bytes): inputs may be skipped, states may come late,
    // but none is lost on the card -- GUDPRTL's TX first yields to a ring
    // that holds more than the frame being read (HS_BEHIND); without it
    // these flows overflowed the ring (17..43 states lost).
    for (const [name, o] of [['a state every 3 frames', { rxEvery: 3 }], ['states of 200 bytes', { rxSize: 200 }], ['inputs of 64 bytes', { txSize: 64 }]]) {
      test(`${dll}: an overloaded game flow at ${BIG} us loses no state on the card: ${name}`, () => {
        const { run } = require('../../../tools/dev/game_load.js');
        const x = run(dll, { budget: BIG, frames: 250, ...o });
        assert.ok(!x.err, x.err);
        assert.equal(x.hwo, 0, 'no card ring overflow');
        assert.ok(x.pushed - x.got <= 2, `states lost ${x.pushed - x.got} (the last ones may still be on the way)`);
        assert.equal(x.over, 0, 'no STEP over its budget');
        assert.equal(x.bad, 0);
        assert.deepEqual(x.prob, []);
      });
    }
  }

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

module.exports = { DT, ethScenarios, transportScenarios, boot, clean, has, bytes, stream, isUdp, peerGot, inject, UHW_RUN };
