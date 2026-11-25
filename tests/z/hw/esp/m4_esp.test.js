// SprinterESP builds on the Z stand: TL16C550C + ESP-AT 2.2 model
// (tools/harness/devices/esp.js) with a payload-level peer, POLL mode.
// ESP-specific checks here, the shared transport scenarios in
// ../eth_scenarios.js (ТЗ §6.1, §8.2; ABI §5).
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { transportScenarios, boot: bootAt, clean, has, bytes, stream, isUdp, peerGot, UHW_RUN } = require('../eth_scenarios.js');
const { C, US } = require('../../../../tools/harness/ethnet.js');
const A = require('../../../../tools/harness/abi.json');

const S = C.status;
const UHW_FAULT = 5;
const SETUP_TCP = ['AT', 'ATE0', 'AT+CIPCLOSE=5', 'AT+CIPMUX=1', 'AT+CIPRECVMODE=1', 'AT+CIPDINFO=0', 'AT+CIPTCPOPT=5,-1,0,4000'];
const SETUP_UDP = ['AT', 'ATE0', 'AT+CIPCLOSE=5', 'AT+CIPMUX=1', 'AT+CIPRECVMODE=0', 'AT+CIPDINFO=0'];
const named = (ev, n) => ev.filter((e) => e.name === n);
const connect = (s) => { assert.equal(s.open().a, S.OK); return s.until(has('CONNECTED')); };
const echo = (s, d, tag = 1) => {
  assert.equal(s.send(d, tag).commit.a, S.OK);
  s.until((e) => has('RX_READY')(e) && has('TX_DONE')(e));
  const rx = [];
  for (let i = 0; i < 500 && rx.length < d.length; i++) { rx.push(...s.drain().bytes); s.run(1); s.events(); }
  return rx;
};

// Every scenario runs twice: at the default budget (500 units: the plain
// STEP, one UART portion and one parser / sequencer visit) and at 2000 us,
// where the STEP is fat (profile.inc PROF_FAT_MIN_US: rounds of pump,
// ESP_LEAN's passes over whole answers, the pump paying for what it moves).
for (const [L, FAT] of [['', 0], [' (fat STEP)', 2000]]) for (const dll of ['gtcpesp', 'gudpesp']) {
  const udp = isUdp(dll);
  const boot = (d, over = {}, opts = {}) => bootAt(d, over, FAT ? { budget: FAT, ...opts } : opts);

  test(`${dll}${L}: bring-up programs the UART once and sets the module up`, () => {
    const s = boot(dll);
    const c = s.card;
    assert.equal(c.ier, 0, 'polling only in v1');
    assert.equal(c.lcr, 0x03, '8N1, DLAB off');
    assert.equal(c.dl, 8, '115200 at 14.7456 MHz');
    assert.equal(c.mcr, 0x22, 'auto flow + RTS');
    assert.equal(c.fcrWrites.length, 1, 'one FIFO reset per session');
    assert.equal(c.fcrWrites[0].v, 0x87, 'FIFO on, both resets, trigger 8');
    assert.equal(c.fcrWrites[0].afe, false, 'reset before auto flow is on');
    assert.ok(c.mcrWrites.every((w) => (w.v & 0x0c) === 0), 'module RESET/PGM lines untouched');
    assert.deepEqual(s.esp.cmds, udp ? SETUP_UDP : SETUP_TCP);
    clean(s);
  });

  test(`${dll}${L}: an empty slot ends the bring-up in FAULT without waiting`, () => {
    const s = boot(dll, {}, { noBoot: true, card: { present: false } });
    for (let i = 0; i < 50 && s.ctx('hw_state') !== UHW_FAULT; i++) s.run(1);
    assert.equal(s.ctx('hw_state'), UHW_FAULT);
    assert.deepEqual(s.probs, []);
  });

  test(`${dll}${L}: ESP-AT 2.2.1 (no passive receive): ${udp ? 'UDP still works' : 'TCP ends in FAULT'}`, () => {
    const s = boot(dll, {}, { noBoot: true, card: { esp: { fw: '2.2.1' } } });
    for (let i = 0; i < 3000 && s.ctx('hw_state') !== UHW_FAULT && s.ctx('hw_state') !== UHW_RUN; i++) s.run(1);
    if (udp) {
      assert.equal(s.ctx('hw_state'), UHW_RUN);
      connect(s);
      assert.deepEqual(echo(s, bytes(30, 2)), bytes(30, 2));
    } else {
      assert.equal(s.ctx('hw_state'), UHW_FAULT, 'not qualified: CIPRECVMODE refused');
      assert.ok(s.esp.cmds.includes('AT+CIPRECVMODE=1'));
    }
    assert.deepEqual(s.probs, []);
  });

  test(`${dll}${L}: the FIFO trigger follows INIT_CONFIG`, () => {
    for (const [trig, fcr] of [[1, 0x07], [4, 0x47], [14, 0xc7]]) {
      const s = boot(dll, { uart_rx_trigger: trig });
      assert.equal(s.card.fcrWrites[0].v, fcr, `trigger ${trig}`);
      clean(s);
    }
  });

  test(`${dll}${L}: a module answering "busy p..." gets the command again`, () => {
    const s = boot(dll, {}, { card: { esp: { busyFirst: 2 } } });
    assert.deepEqual(s.esp.cmds.slice(0, 3), ['AT', 'AT', 'AT']);
    connect(s);
    assert.deepEqual(echo(s, bytes(40, 2)), bytes(40, 2));
    clean(s);
  });

  test(`${dll}${L}: a refused connect gives PEER_CLOSED then CLOSED, no CONNECTED`, () => {
    const s = boot(dll, {}, { card: { esp: { connectFail: true } } });
    assert.equal(s.open().a, S.OK);
    const ev = s.until(has('CLOSED'));
    assert.deepEqual(ev.map((e) => e.name), ['PEER_CLOSED', 'CLOSED']);
    clean(s);
  });

  test(`${dll}${L}: SEND FAIL fails that slot only`, () => {
    const s = boot(dll);
    connect(s);
    s.esp.sendFail = 1;
    assert.equal(s.send(bytes(20, 1), 1).commit.a, S.OK);
    let ev = s.until(has('TX_DONE'));
    assert.deepEqual(named(ev, 'TX_DONE').map((e) => e.status), [C.txdone.FAILED]);
    assert.deepEqual(echo(s, bytes(30, 4), 2), bytes(30, 4));
    clean(s);
  });

  test(`${dll}${L}: payload bytes that look like AT lines are data`, () => {
    const s = boot(dll);
    connect(s);
    const tricky = [...Buffer.from('\r\nCLOSED\r\nOK\r\n+IPD,0,99:\r\nready\r\n0,CLOSED\r\nERROR\r\n> ', 'latin1'), 0, 0, 13, 10];
    assert.deepEqual(echo(s, tricky), tricky);
    assert.equal(s.ctx('chan'), 2, 'still open');
    assert.deepEqual(echo(s, bytes(50, 9), 2), bytes(50, 9));
    clean(s);
  });

  test(`${dll}${L}: the peer closing the link gives PEER_CLOSED then CLOSED`, () => {
    const s = boot(dll);
    connect(s);
    assert.deepEqual(echo(s, bytes(64, 3)), bytes(64, 3));
    s.peer.close();
    const ev = s.until(has('CLOSED'));
    assert.deepEqual(ev.map((e) => e.name), ['PEER_CLOSED', 'CLOSED']);
    clean(s);
  });

  // M scenario P (the echo server closes right behind its echo) lost the
  // echo in half of the runs: the CIPRECVDATA answer and "0,CLOSED" came
  // in one parse turn and the sequencer raised the failure before it took
  // the completed read.  The stream order is the order of events.
  if (!udp) test(`${dll}${L}: the peer's last data right before its close is delivered before PEER_CLOSED`, () => {
    for (const [budget, dt] of [[2000, 20], [2000, 2], [A.consts.limits.STEP_BODY_MAX_US, 10], [1280, 2]]) {
      for (let phase = 0; phase < 8; phase++) {
        const s = boot(dll, {}, { budget, dt });
        assert.equal(s.open().a, S.OK);
        s.until(has('CONNECTED'), 6000, dt);
        s.run(20 + phase, dt); s.events(); s.drain();
        const recv = s.peer.receive.bind(s.peer);
        // the FIN right behind the echo (never before it: the module would drop the echo)
        s.peer.receive = (conn, d, t) => { recv(conn, d, t); s.peer.esp.card.at(t + s.peer.esp.netUs * 2 + 1, () => s.peer.close()); };
        const d = bytes(64, 5 + phase);
        assert.equal(s.send(d, 1).commit.a, S.OK);
        const ev = [], rx = [];
        for (let i = 0; i < 6000 && !ev.includes('CLOSED'); i++) {
          s.run(1, dt);
          ev.push(...s.events().map((e) => e.name));
          rx.push(...s.drain().bytes);
        }
        assert.deepEqual(rx, d, `budget ${budget} dt ${dt} phase ${phase}: the echo (events ${ev})`);
        assert.ok(ev.indexOf('RX_READY') >= 0 && ev.indexOf('RX_READY') < ev.indexOf('PEER_CLOSED'), `RX_READY before PEER_CLOSED (${ev})`);
        clean(s);
      }
    }
  });

  test(`${dll}${L}: a module restart gives LINK_LOST, sets the module up again, OPEN works`, () => {
    const s = boot(dll);
    connect(s);
    const before = s.esp.cmds.length;
    s.esp.reboot();
    const ev = s.until(has('CLOSED'));
    assert.deepEqual(ev.map((e) => e.name), ['LINK_LOST', 'CLOSED']);
    s.run(200);
    assert.deepEqual(s.esp.cmds.slice(before, before + (udp ? SETUP_UDP : SETUP_TCP).length), udp ? SETUP_UDP : SETUP_TCP);
    connect(s);
    assert.deepEqual(echo(s, bytes(33, 5)), bytes(33, 5));
    clean(s);
  });

  test(`${dll}${L}: WIFI DISCONNECT gives LINK_LOST then CLOSED`, () => {
    const s = boot(dll);
    connect(s);
    s.esp.wifiDrop();
    const ev = s.until(has('CLOSED'));
    assert.deepEqual(ev.map((e) => e.name), ['LINK_LOST', 'CLOSED']);
    clean(s);
  });

  test(`${dll}${L}: a UART overrun fails the channel with STREAM_ERROR, a new OPEN works`, () => {
    // a reply lost in the overrun is waited for until its deadline
    const s = boot(dll, { send_stall_timeout_ms: 1500 });
    connect(s);
    s.card.inflight = 12;                          // the module ignores RTS for 12 bytes
    assert.equal(s.send(bytes(udp ? 512 : 536, 6), 1).commit.a, S.OK);
    const ev = [];
    for (let i = 0; i < 3000 && !has('CLOSED')(ev); i++) { s.run(1); ev.push(...s.events()); s.drain(); }
    const err = named(ev, 'STREAM_ERROR');
    assert.equal(err.length, 1, `events ${ev.map((e) => e.name)}`);
    assert.equal(err[0].detail, C.stream.UART_OVERRUN);
    assert.ok(named(ev, 'CLOSED').length === 1);
    const st = s.getStats().stats;
    assert.ok(st.uart_overrun >= 1 && st.stream_errors === 1);
    s.card.inflight = 1;
    s.drain();
    s.run(300);
    connect(s);
    assert.deepEqual(echo(s, bytes(40, 1), 2), bytes(40, 1));
    // no RX was published from the broken block
    assert.deepEqual(s.probs, []);
  });

  test(`${dll}${L}: a closing channel finishes the CIPSEND in progress first`, () => {
    const s = boot(dll);
    connect(s);
    const d = bytes(udp ? 512 : 536, 8);
    assert.equal(s.send(d, 1).commit.a, S.OK);
    for (let i = 0; i < 400 && !(s.esp.dataLeft > 0); i++) s.run(1);
    assert.ok(s.esp.dataLeft > 0, 'payload streaming');
    assert.equal(s.call('CLOSE').a, S.OK);
    // the application keeps reading: the echo of the payload may arrive
    // before the close ends, and CLOSED comes after the RX is drained
    // (ABI: an unread RX holds it back -- with 5 units less per STEP the
    // echo came first and this test, which read nothing, never saw CLOSED)
    const ev = s.until((e) => { s.drain(); return has('CLOSED')(e); });
    assert.ok(has('TX_DONE')(ev));
    assert.deepEqual(udp ? s.peer.udpIn[0] : s.peer.received, d, 'the whole payload went out');
    assert.equal(s.esp.cmds[s.esp.cmds.length - 1], 'AT+CIPCLOSE=0');
    clean(s);
  });

  // Ж, the first ESP series: SHUTDOWN cut a CIPSEND off (the command out,
  // the payload not yet); the module took the next session's AT set-up as
  // payload and nine GUDPESP runs ended in FAULT.  tools/dev/esp_shut_send.js
  // sweeps every STEP; here: before the prompt, at it, inside the payload.
  test(`${dll}${L}: SHUTDOWN during a CIPSEND lets the module take the whole payload; the next session sets it up`, () => {
    const d = bytes(udp ? 512 : 536, 9);
    for (const at of ['command', 'prompt', 'payload']) {
      const s = boot(dll);
      connect(s);
      assert.equal(s.send(d, 1).commit.a, S.OK);
      const cut = { command: () => s.esp.cmds.some((c) => c.startsWith('AT+CIPSEND')),
        prompt: () => s.esp.dataLeft === d.length, payload: () => s.esp.dataLeft > 0 && s.esp.dataLeft < d.length / 2 }[at];
      for (let i = 0; i < 400 && !cut(); i++) s.run(1);
      assert.ok(cut(), `SHUTDOWN at the ${at}`);
      let r;
      const ev = [];
      for (let i = 0; i < 2000; i++) { r = s.call('SHUTDOWN'); if (r.a === S.OK) break; s.run(1); ev.push(...s.events()); }
      assert.equal(r.a, S.OK, `SHUTDOWN at the ${at}`);
      assert.equal(s.esp.dataLeft, 0, `the module waits for no payload (${at})`);
      assert.deepEqual(udp ? s.peer.udpIn[0] : s.peer.received, d, `the whole payload went out (${at})`);
      assert.equal(named(ev, 'TX_DONE').length, 1, `one TX_DONE (${at})`);
      // a new session on the same module: its AT set-up is answered
      for (let i = 0; i < s.layout().ctxLen; i++) s.m.poke(s.layout().ctx + i, 0);
      assert.equal(s.initConfig(s.defaultConfig({ step_budget_us: FAT || US(500) })).a, S.OK);
      for (let i = 0; i < 3000 && s.ctx('hw_state') !== UHW_RUN; i++) s.run(1);
      assert.equal(s.ctx('hw_state'), UHW_RUN, `the next bring-up (${at})`);
      connect(s);
      assert.deepEqual(echo(s, bytes(20, 3), 2), bytes(20, 3));
      clean(s);
    }
  });

  test(`${dll}${L}: a lost CIPSEND reply ends in TIMEOUT(TX), the module is set up again`, () => {
    const s = boot(dll, { send_stall_timeout_ms: 1000 });
    connect(s);
    s.esp.mute = true;
    assert.equal(s.send(bytes(10, 1), 1).commit.a, S.OK);
    const ev = s.until(has('CLOSED'), 3000);
    const to = named(ev, 'TIMEOUT');
    assert.equal(to.length, 1, `events ${ev.map((e) => e.name)}`);
    assert.equal(to[0].detail, C.timeout.TX);
    s.esp.mute = false;
    s.run(300);
    connect(s);
    assert.deepEqual(echo(s, bytes(20, 2), 2), bytes(20, 2));
    clean(s);
  });

  if (!udp) {
    test(`${dll}${L}: an answer that trickles in byte by byte is reassembled`, () => {
      const s = boot(dll, {}, { card: { esp: { trickleUs: 2500 } } });
      connect(s);
      assert.deepEqual(echo(s, bytes(100, 7)), bytes(100, 7));
      clean(s);
    });

    test(`${dll}${L}: short and empty CIPRECVDATA answers: no FIN, no immediate retry`, () => {
      const s = boot(dll, {}, { card: { esp: { recvCap: 7 } } });
      connect(s);
      assert.deepEqual(echo(s, bytes(60, 1)), bytes(60, 1), 'answers of 7 bytes');
      s.esp.recvCap = 0;
      s.esp.zeroAnswers = 1;
      s.peer.sendData(bytes(20, 2));
      s.run(100);
      const reads = s.esp.cmds.filter((c) => c.startsWith('AT+CIPRECVDATA')).length;
      s.run(250);                                  // 500 ms
      assert.equal(s.esp.cmds.filter((c) => c.startsWith('AT+CIPRECVDATA')).length, reads, 'no retry loop');
      assert.equal(s.ctx('chan'), 2, 'still open');
      s.peer.sendData(bytes(5, 3));                // the next notice brings everything
      const rx = [];
      for (let i = 0; i < 500 && rx.length < 25; i++) { s.run(1); s.events(); rx.push(...s.drain().bytes); }
      assert.deepEqual(rx, [...bytes(20, 2), ...bytes(5, 3)]);
      clean(s);
    });

    test(`${dll}${L}: a full RX ring stops the reads; the module keeps the data`, () => {
      const s = boot(dll);
      connect(s);
      const d = bytes(3000, 5);
      s.peer.sendData(d);
      s.run(1500);                                 // nobody reads
      const total = s.ctx('rx_total');
      assert.equal(s.ctx('rx_used'), total, 'RX ring full');
      assert.ok(s.esp.link.held.length >= d.length - total, 'the rest is held by the module');
      const rx = [];
      for (let i = 0; i < 3000 && rx.length < d.length; i++) { rx.push(...s.drain().bytes); s.run(1); s.events(); }
      assert.deepEqual(rx, d);
      assert.equal(s.getStats().stats.uart_overrun, 0);
      clean(s);
    });
  } else {
    test(`${dll}${L}: a datagram longer than a slot, or without a free slot, is dropped and counted`, () => {
      const s = boot(dll);
      connect(s);
      s.peer.sendData(bytes(600, 1));              // > rx_slot_size 512
      s.run(200);
      assert.equal(s.call('RX_PEEK').a, S.EMPTY);
      assert.equal(s.getStats().stats.ring_overflow, 1);
      // fill every RX slot, then one more
      const n = s.ctx('rx_slot_count');
      for (let i = 0; i <= n; i++) { s.peer.sendData(bytes(10, i)); s.run(30); }
      assert.equal(s.getStats().stats.ring_overflow, 2);
      const got = s.drain().bytes;
      assert.equal(got.length, 10 * n);
      for (let i = 0; i < n; i++) assert.deepEqual(got.slice(10 * i, 10 * i + 10), bytes(10, i), `datagram ${i}`);
      assert.deepEqual(echo(s, bytes(30, 6), 3), bytes(30, 6));
      clean(s);
    });
  }

  test(`${dll}${L}: STEP_ISR drains the UART by itself when its budget allows`, () => {
    // WP4: EXP_STEP_ISR (sched.asm) converts its leftover budget into
    // ES_ISRCAP; ISRP_POLL (uart.asm) spends it moving bytes straight into
    // the ring, so a quiet main loop (no STEP at all) still sees the data.
    const s = boot(dll);
    connect(s);
    s.run(50); s.events(); s.drain();
    const d = bytes(32, 8);
    s.peer.sendData(d);
    s.idle(8);                                  // the notice crosses the network and the UART line
    const before = s.getStats().stats;
    const r = s.stepIsr(C.src.TIMER);
    assert.deepEqual(r.problems, []);
    assert.equal(r.a, S.WORK, 'data waiting');
    assert.ok(r.us <= A.consts.limits.ISR_BODY_MAX_US, `STEP_ISR took ${r.us} us`);
    const afterIsr = s.getStats().stats;
    assert.ok(afterIsr.polls_useful > before.polls_useful, 'the ISR itself moved bytes (not the next STEP)');
    assert.equal(afterIsr.uart_overrun, 0);
    const rx = [];
    for (let i = 0; i < 500 && rx.length < d.length; i++) { s.run(1); s.events(); rx.push(...s.drain().bytes); }
    assert.deepEqual(rx, d, 'the ISR-moved bytes still reach the application');
    clean(s);
  });

  test(`${dll}${L}: the SDK's default ISR budget (empty poll + return) moves no bytes, only the main STEP does`, () => {
    const s = boot(dll);
    connect(s);
    s.run(50); s.events(); s.drain();
    const d = bytes(16, 3);
    s.peer.sendData(d);
    s.idle(8);
    const before = s.getStats().stats;
    const info = s.getInfo().info;
    const r = s.stepIsr(C.src.TIMER, info.empty_poll_us + info.min_return_us);
    assert.deepEqual(r.problems, []);
    assert.equal(r.a, S.WORK, 'still reports data waiting');
    const after = s.getStats().stats;
    assert.equal(after.polls_useful, before.polls_useful, 'no regression to the unmodified default profile');
    const rx = [];
    for (let i = 0; i < 500 && rx.length < d.length; i++) { s.run(1); s.events(); rx.push(...s.drain().bytes); }
    assert.deepEqual(rx, d);
    clean(s);
  });

  test(`${dll}${L}: STEP_ISR at the largest budget injected between every STEP keeps an 8 KiB stream intact`, () => {
    const s = boot(dll);
    connect(s);
    s.stepOpts = { isr: { budget: A.consts.limits.ISR_BODY_MAX_US } };
    const d = bytes(8192, 5);
    const rx = stream(s, d, udp ? 512 : 536);
    assert.deepEqual(rx, d);
    assert.deepEqual(peerGot(s, dll), d);
    assert.equal(s.getStats().stats.uart_overrun, 0);
    clean(s);
  });

  // TCP needs the sequencer (main STEP only) to issue CIPRECVDATA before
  // any byte reaches the UART at all; only UDP's +IPD pushes data without
  // a command round-trip, so only UDP can accumulate ring backlog with no
  // main STEP running at all (same reason the RTS-by-parser-lag test below
  // is UDP-only).
  if (udp) test(`${dll}${L}: ISR-only draining past the pause threshold still lets the main pump pause and resume RTS`, () => {
    // nobody calls a main STEP for a while: STEP_ISR alone drains the UART
    // into the ring, which nothing reads (the parser only runs in STEP) --
    // the ring backlog grows past ER_PAUSE_AT, and the first main pump
    // after that must still see it and pause RTS explicitly.
    const s = boot(dll);
    connect(s);
    s.run(50); s.events(); s.drain();
    const total = 40 * 16;
    for (let k = 0; k < 40; k++) {
      s.peer.sendData(bytes(16, k));
      s.idle(8);
      s.stepIsr(C.src.TIMER);
    }
    s.run(1);
    // (a fat STEP parses the ring before its first portion: the backlog
    // is below the pause level again when the pump looks at it)
    if (!FAT) assert.ok(s.card.mcrWrites.some((w) => w.v === 0x20), 'RTS paused by the main pump');
    const rx = [];
    for (let i = 0; i < 3000 && rx.length < total; i++) { s.run(1); s.events(); rx.push(...s.drain().bytes); }
    assert.equal(rx.length, total);
    assert.equal(s.card.mcr, 0x22, 'RTS back once drained');
    assert.equal(s.getStats().stats.uart_overrun, 0);
    clean(s);
  });

  if (udp) test(`${dll}${L}: a parser behind the UART drops RTS explicitly, no overrun`, () => {
    // many small datagrams are line-heavy: at the minimum budget the pump
    // outruns the parser, which drops RTS until it has caught up
    const probe = boot(dll, {}, { noBoot: true });
    const min = probe.getInfo().info.min_useful_budget_us;
    const s = boot(dll, {}, { budget: min });
    connect(s);
    for (let k = 0; k < 40; k++) s.peer.sendData(bytes(6, k));
    const rx = [];
    for (let i = 0; i < 6000 && rx.length < 40 * 6; i++) { s.run(1); s.events(); rx.push(...s.drain().bytes); }
    const lost = s.getStats().stats.ring_overflow;
    assert.equal(rx.length + 6 * lost, 40 * 6, 'every datagram delivered or counted');
    assert.ok(s.card.mcrWrites.some((w) => w.v === 0x20), 'RTS dropped by the core');
    assert.equal(s.card.mcr, 0x22, 'RTS back');
    assert.equal(s.getStats().stats.uart_overrun, 0);
    clean(s);
  });

  transportScenarios(dll, FAT ? { budget: FAT, label: L } : {});
}

// GUDPESP in its transparent mode (esp_fw = 2, esp_x.asm): the same
// transport scenarios over records (tools/harness/net/xrec.js), at the
// default budget and in the fat STEP.
for (const [L, FAT] of [[' (transparent)', 0], [' (transparent, fat STEP)', 2000]]) {
  transportScenarios('gudpesp', { ...(FAT ? { budget: FAT } : {}), label: L, over: { esp_fw: 2 } });
}

// ---- transparent UDP (esp_fw = 2, src/core/esp/esp_x.asm) -----------------
// The module as a byte pipe (AT+CIPMODE=1, AT+CIPSEND): datagrams framed as
// records (tools/harness/net/xrec.js), "+++" in and out of the data mode.
const SETUP_X = ['AT', 'ATE0', 'AT+CIPCLOSE=5', 'AT+CIPCLOSE', 'AT+CIPMUX=0', 'AT+CIPMODE=0', 'AT+CIPRECVMODE=0', 'AT+CIPDINFO=0'];
const OPEN_X = /^AT\+CIPCLOSE\nAT\+CIPSTART="UDP","[\d.]+",\d+,\d+,0\nAT\+CIPMODE=1\nAT\+CIPSEND$/;
for (const [L, FAT] of [['', 0], [' (fat STEP)', 2000]]) {
  const xboot = (over = {}, opts = {}) => bootAt('gudpesp', { esp_fw: 2, ...over }, FAT ? { budget: FAT, ...opts } : opts);
  const T = `gudpesp${L}: transparent`;

  test(`${T}: bring-up leaves any data mode first, sets up one link; GET_INFO publishes the mode`, () => {
    const s = xboot();
    assert.equal(s.esp.cmds[0], '+++AT', '"+++" before the first AT (refused by a module in command mode)');
    assert.deepEqual(s.esp.cmds.slice(-SETUP_X.length), SETUP_X);
    assert.equal(s.esp.mux, 0);
    assert.ok(s.getInfo().info.caps & A.consts.cap.ESP_TRANSPARENT, 'CAP_ESP_TRANSPARENT');
    clean(s);
  });

  test(`${T}: a module left in its data mode by a past session is brought out of it`, () => {
    const s = xboot({}, { noBoot: true });
    Object.assign(s.esp, { mux: 0, cipmode: 1, xdata: true, echo: false });
    for (let i = 0; i < 3000 && s.ctx('hw_state') !== UHW_RUN; i++) s.run(1);
    assert.equal(s.ctx('hw_state'), UHW_RUN);
    assert.equal(s.esp.escapes, 1, 'the module saw "+++"');
    assert.equal(s.esp.cmds[0], 'AT');
    assert.equal(s.esp.cipmode, 0);
    clean(s);
  });

  test(`${T}: OPEN enters the data mode; datagrams of 1..512 bytes keep their boundaries both ways`, () => {
    const s = xboot({ tx_slot_size: 512, rx_slot_size: 512 });
    const n0 = s.esp.cmds.length;
    connect(s);
    assert.match(s.esp.cmds.slice(n0).join('\n'), OPEN_X);
    assert.ok(s.esp.xdata, 'the module is in its data mode');
    let tag = 1;
    for (const n of [1, 61, 62, 63, 64, 200, 511, 512]) {
      const d = bytes(n, n + 3);
      const before = s.peer.udpIn.length;
      assert.deepEqual(echo(s, d, tag++), d, `${n} bytes`);
      assert.deepEqual(s.peer.udpIn.slice(before), [d], `${n} bytes: one datagram at the peer`);
    }
    assert.equal(s.getStats().stats.drop_checksum, 0);
    clean(s);
  });

  test(`${T}: CLOSE leaves the module in command mode ("+++", CIPMODE=0, CIPCLOSE), OPEN works again`, () => {
    const s = xboot();
    connect(s);
    assert.deepEqual(echo(s, bytes(20, 1)), bytes(20, 1));
    assert.equal(s.call('CLOSE').a, S.OK);
    s.until(has('CLOSED'), 3000);
    assert.equal(s.esp.escapes, 1);
    assert.deepEqual(s.esp.cmds.slice(-2), ['AT+CIPMODE=0', 'AT+CIPCLOSE']);
    assert.ok(!s.esp.xdata && s.esp.cipmode === 0 && !s.esp.link, 'command mode, no link');
    s.run(10); s.events();
    connect(s);
    assert.deepEqual(echo(s, bytes(30, 2), 2), bytes(30, 2));
    clean(s);
  });

  test(`${T}: SHUTDOWN in the middle of a record leaves the module in command mode`, () => {
    for (const after of [0, 1, 3]) {
      const s = xboot();
      connect(s);
      assert.equal(s.send(bytes(512, 5), 1).commit.a, S.OK);
      s.run(after);
      let r;
      for (let i = 0; i < 2000; i++) { r = s.call('SHUTDOWN'); if (r.a === S.OK) break; s.run(1); s.events(); }
      assert.equal(r.a, S.OK, `SHUTDOWN after ${after} STEPs`);
      assert.ok(!s.esp.xdata && s.esp.cipmode === 0 && !s.esp.link, 'command mode, no link');
      assert.deepEqual(s.card.errors, []);
    }
  });

  test(`${T}: a bad record header drops the bytes up to a silence, the next records arrive`, () => {
    const s = xboot();
    connect(s);
    s.peer.sendRaw([0xff, 0xff, 1, 2, 3, 4]);
    s.run(40); s.events();
    assert.equal(s.getStats().stats.drop_checksum, 1, 'counted');
    assert.deepEqual(s.drain().bytes, []);
    for (let k = 0; k < 3; k++) {
      s.peer.sendData(bytes(9, k));
      s.until(has('RX_READY'), 200);
      assert.deepEqual(s.drain().bytes, bytes(9, k));
    }
    clean(s);
  });

  test(`${T}: records the module cuts and merges reach the peer whole (packets of 50 bytes, 20 ms after the first byte)`, () => {
    const s = xboot({}, { card: { esp: { xMax: 50, xFirst: true } } });
    connect(s);
    const sent = [];
    for (let k = 0, i = 0; k < 6 && i < 2000; i++) {
      const d = bytes(40 + 17 * k, k);
      const x = s.send(d, k + 1);
      if (x.res.a === S.OK) { assert.equal(x.commit.a, S.OK); sent.push(d); k++; }
      s.run(1); s.events(); s.drain();
    }
    s.run(400); s.events(); s.drain();
    assert.deepEqual(s.peer.udpIn, sent);
    assert.ok(s.esp.xPackets.every((n) => n <= 50) && s.esp.xPackets.length > 6, 'cut into packets');
    clean(s);
  });

  test(`${T}: records left unread are lost whole and counted, RTS keeps the UART from overrunning`, () => {
    const s = xboot();
    connect(s);
    for (let k = 0; k < 30; k++) { s.peer.sendData(bytes(120, k)); s.run(2); }
    s.run(2000);
    const st = s.getStats().stats;
    const got = [];
    for (let i = 0; i < 40; i++) { const g = s.drain(); if (!g.chunks.length) break; got.push(...g.chunks); }
    assert.ok(st.ring_overflow >= 1, 'some lost for want of a slot');
    assert.equal(got.length + st.ring_overflow, 30, 'every record delivered or counted');
    assert.ok(got.every((n) => n === 120), 'whole');
    assert.equal(st.uart_overrun, 0);
    assert.equal(st.drop_checksum, 0);
    clean(s);
  });
}

test('esp_fw: 2 only for GUDPESP; other values refused', () => {
  for (const [dll, fw, ok] of [['gudpesp', 2, true], ['gtcpesp', 2, false], ['gudpesp', 3, false], ['gudpesp', 0, false]]) {
    const s = bootAt(dll, {}, { noBoot: true });
    s.call('SHUTDOWN');
    const t = require('../../../../tools/harness/ethnet.js').ethStand({ dll });
    t.call('INIT');
    assert.equal(t.initConfig(t.defaultConfig({ esp_fw: fw })).a, ok ? S.OK : S.BAD_CONFIG, `${dll} esp_fw ${fw}`);
  }
});

// A real-time game's flow (games/headball/specs.md §15.4) on GUDPESP in
// its transparent mode: one STEP of 3000 us and two byte-moving polls
// (STEP_ISR, 341 us) per 20 ms frame, the UART FIFO trigger at 8
// (tools/dev/game_load.js; docs/MEASUREMENTS.md).  Trigger 14 overran in
// MAME (auto-RTS only at the 16th character).  In command mode the same
// profile carries 1.6 inputs a second.
const gameFlow = (o) => {
  const { run } = require('../../../../tools/dev/game_load.js');
  const x = run('gudpesp', { budget: A.consts.limits.STEP_BODY_MAX_US, espFw: 2, trigger: 8, isr: 341, polls: 2, frames: 250, ...o });
  assert.ok(!x.err, x.err);
  assert.equal(x.over, 0, 'no STEP over its budget');
  assert.equal(x.bad, 0, 'nothing unexpected arrived');
  assert.equal(x.ovr, 0, 'no UART overrun');
  assert.deepEqual(x.prob, []);
  return { ...x, inputs: x.wire / x.sec, states: x.got / x.sec, inMax: Math.max(...x.inLat), stMax: Math.max(...x.stLat) };
};

// A record of up to 17 bytes is one FIFO load: it leaves in one STEP, and
// the module, which cuts a packet after 20 ms of UART silence, sends
// every input alone.  The stand measured 25 / 10 a second, inputs 60 ms
// late at most, states 80 (both baud rates, both rules of the cut).
test('gudpesp: transparent: inputs of 15 bytes 25 a second and states 10 a second at one STEP of 3000 us', () => {
  for (const divisor of [8, 2]) for (const xFirst of [false, true]) {
    const x = gameFlow({ divisor, txSize: 15, espModel: { xFirst } });
    const k = `divisor ${divisor}, cut ${xFirst ? 'from the first' : 'after the last'} byte`;
    assert.ok(x.inputs >= 24.5 && x.skipped <= 2, `${k}: inputs ${x.inputs}/s, skipped ${x.skipped}`);
    assert.ok(x.states >= 9.5 && x.pushed - x.got <= 1, `${k}: states ${x.states}/s, lost ${x.pushed - x.got}`);
    assert.ok(x.inMax <= 80 && x.stMax <= 120, `${k}: latency ${x.inMax} / ${x.stMax} ms`);
  }
});

// A 22-byte record (Headball's 20-byte input) takes two STEPs at one STEP
// a frame (one FIFO load per STEP), and inputs every 40 ms then never
// left the module 20 ms of silence: one packet grew to 1460 bytes and an
// input arrived 2.7 s late.  The core keeps a packet the module gathers
// at most ESP_XAGE_MS old and then waits for its silence (esp_x.asm
// ESP_XSEND): inputs arrive within ~140 ms, at ~19 a second.
test('gudpesp: transparent: records that follow each other closer than 20 ms of silence arrive within 140 ms', () => {
  for (const [divisor, rxSize, rxEvery] of [[8, 88, 1e6], [8, 88, 5], [2, 88, 1e6]]) {
    const x = gameFlow({ divisor, rxSize, rxEvery, espModel: { xFirst: false } });
    const k = `divisor ${divisor}, states every ${rxEvery}`;
    assert.ok(x.inMax <= 140, `${k}: inputs ${x.inMax} ms late`);
    assert.ok(x.inputs >= 18, `${k}: inputs ${x.inputs}/s`);
    if (rxEvery === 5) assert.ok(x.states >= 9.5 && x.stMax <= 120, `${k}: states ${x.states}/s, ${x.stMax} ms`);
  }
});

// The target of the stage (Headball's 20-byte inputs 25 a second at one
// STEP a frame) is not met: ~19 a second.  Two STEPs of 2000 us a frame
// carry 25 (MEASUREMENTS.md).
test('gudpesp: transparent: Headball inputs of 20 bytes 25 a second at one STEP of 3000 us', { todo: 'one FIFO load per STEP: ~19 a second' }, () => {
  const x = gameFlow({ divisor: 8 });
  assert.ok(x.inputs >= 24.5, `inputs ${x.inputs}/s`);
});

// ---- the fat STEP (profile.inc PROF_FAT_MIN_US): what only it does --------
// One STEP of 2000 us per 20 ms frame is how a game calls the library
// (docs/MEASUREMENTS.md: the plain STEP needed 12 frames for a small
// packet -- one UART portion and one parser visit per STEP).
const FRAME = 20, GAME = 2000;
const framesPerPacket = (dll, size, n, isr) => {
  const s = bootAt(dll, {}, { budget: GAME });
  connect(s);
  s.peer.echo = false;
  if (isr) s.stepOpts = { isr: { budget: isr } };
  let sent = 0, done = 0, frames = 0;
  while (done < n && frames < 40 * n) {
    if (sent < n && s.send(bytes(size, sent), sent + 1).res.a === S.OK) sent++;
    s.run(1, FRAME);
    frames++;
    done += named(s.events(), 'TX_DONE').length;
  }
  assert.equal(done, n, 'every packet sent');
  assert.equal(s.getStats().stats.uart_overrun, 0);
  clean(s);
  return frames / n;
};

for (const dll of ['gtcpesp', 'gudpesp']) {
  const udp = isUdp(dll);

  test(`${dll}: a 16-byte packet per ~6 frames at one 2000 us STEP a frame, ~4 with one byte-moving poll`, () => {
    // stand: 6.1 frames without a poll, 4.1 with one STEP_ISR(341) per frame
    // (the plain STEP: 12.0 and 10.0)
    const alone = framesPerPacket(dll, 16, 20, 0), polled = framesPerPacket(dll, 16, 20, 341);
    assert.ok(alone <= 7, `${alone} frames per packet`);
    assert.ok(polled <= 5, `${polled} frames per packet with a poll`);
  });

  test(`${dll}: the command of a send is one UART portion of 17 bytes (transmitter idle)`, () => {
    const s = bootAt(dll, {}, { budget: GAME });
    connect(s);
    s.peer.echo = false;
    const writes = [];
    const thr = s.card.thr.bind(s.card);
    s.card.thr = (v, t) => { writes.push(t); thr(v, t); };
    assert.equal(s.send(bytes(16, 3), 1).commit.a, S.OK);
    s.run(1, FRAME);
    // "AT+CIPSEND=0,16" CR LF: all 17 bytes inside one portion (< 1 ms)
    assert.equal(writes.length, 17);
    assert.ok(writes[16] - writes[0] < 1000, 'one portion');
    s.until(has('TX_DONE'), 100, FRAME);
    clean(s);
  });

  test(`${dll}: fat and plain STEPs in any order keep small and large pieces intact`, () => {
    // the budget changes from STEP to STEP: ESP_LEAN's passes and marks
    // (a line or a datagram seen in part, the awaited CIPSEND answer) and
    // the generic parser take the same stream in turns; the UART ring
    // wraps several times
    const s = bootAt(dll, {}, { budget: GAME });
    connect(s);
    const data = bytes(3000, 5);
    const sizes = [1, 16, 40, 7, 64, 300, 22, udp ? 512 : 536, 3, 41, 100];
    let off = 0, tag = 1, k = 0, seed = 12345;
    const rx = [];
    for (let i = 0; i < 30000 && (off < data.length || rx.length < data.length); i++) {
      if (off < data.length) {
        const n = Math.min(sizes[k % sizes.length], data.length - off);
        const x = s.send(data.slice(off, off + n), tag);
        if (x.res.a === S.OK) { off += n; tag++; k++; }
      }
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      const budget = [GAME, GAME, 1231, 1100, GAME, 1500][(seed >> 8) % 6];
      const dt = [2, 20, 2, 6][(seed >> 12) & 3];
      s.probs.push(...s.tick(dt, budget, (seed >> 16) % 3 === 0 ? { isr: { budget: 341 } } : {}).problems);
      assert.deepEqual(s.events().filter((e) => !['TX_DONE', 'RX_READY'].includes(e.name)), []);
      rx.push(...s.drain().bytes);
    }
    assert.deepEqual(rx, data, 'echo intact');
    assert.equal(s.getStats().stats.uart_overrun, 0);
    clean(s);
  });

  if (udp) test(`${dll}: fat STEP: a datagram with no free RX slot is lost whole and counted, the next ones arrive`, () => {
    const s = bootAt(dll, {}, { budget: GAME });
    connect(s);
    s.peer.echo = false;
    const slots = 4;                                 // RX slots of the default configuration
    for (let k = 0; k < slots + 2; k++) s.peer.sendData(bytes(16, k));
    s.run(40, FRAME);
    assert.equal(s.getStats().stats.ring_overflow, 2, 'two datagrams had no slot');
    const first = s.drain(16);
    assert.equal(first.bytes.length, slots * 16);
    s.peer.sendData(bytes(16, 99));
    s.run(10, FRAME);
    assert.deepEqual(s.drain().bytes, bytes(16, 99));
    assert.equal(s.getStats().stats.uart_overrun, 0);
    clean(s);
  });

  if (udp) test(`${dll}: fat STEP: datagrams of 1..64 bytes back to back arrive whole and in order`, () => {
    // up to LEAN_IPD_WAIT a datagram is waited for and taken as one item;
    // a longer one is parsed as it comes; both from the same stream
    const s = bootAt(dll, {}, { budget: GAME });
    connect(s);
    s.peer.echo = false;
    const sizes = [1, 16, 40, 41, 64, 22, 2, 63, 40, 9];
    const want = [];
    const rx = [];
    for (let k = 0; k < sizes.length; k++) {
      const d = bytes(sizes[k], 30 + k);
      want.push(...d);
      s.peer.sendData(d);
      for (let i = 0; i < 12; i++) { s.run(1, k & 1 ? FRAME : 2); s.events(); rx.push(...s.drain().bytes); }
    }
    for (let i = 0; i < 200 && rx.length < want.length; i++) { s.run(1, FRAME); s.events(); rx.push(...s.drain().bytes); }
    assert.deepEqual(rx, want);
    assert.equal(s.getStats().stats.ring_overflow, 0);
    clean(s);
  });
}

// The module holds CTS off while its sending stalls (the Ж series of
// 2026-11-24; the UART model kept CTS on until then).  With auto-CTS the
// transmitter waits, and a pump that counted on the idle shift register
// (17 bytes on TEMT) overran the TX FIFO: the stream lost bytes at the fat
// budgets.  tools/dev/x_cts.js: every byte the module took is the records.
test('gudpesp: transparent stream with CTS off (60 of every 200 ms), plain and fat STEP: the module gets every record exactly', () => {
  const { execFileSync } = require('node:child_process');
  const path = require('node:path');
  const tool = path.join(__dirname, '../../../../tools/dev/x_cts.js');
  for (const b of ['1280', '3000']) {
    const out = execFileSync(process.execPath, [tool, '--total', '2048', '--phases', '3', '--budget', b], { encoding: 'utf8' });
    assert.match(out, /x_cts: every run exact/, out);
  }
});
