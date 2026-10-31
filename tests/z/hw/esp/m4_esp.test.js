// SprinterESP builds on the Z stand: TL16C550C + ESP-AT 2.2 model
// (tools/harness/devices/esp.js) with a payload-level peer, POLL mode.
// ESP-specific checks here, the shared transport scenarios in
// ../eth_scenarios.js (ТЗ §6.1, §8.2; ABI §5).
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { transportScenarios, boot, clean, has, bytes, stream, isUdp, UHW_RUN } = require('../eth_scenarios.js');
const { C } = require('../../../../tools/harness/ethnet.js');

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

for (const dll of ['gtcpesp', 'gudpesp']) {
  const udp = isUdp(dll);

  test(`${dll}: bring-up programs the UART once and sets the module up`, () => {
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

  test(`${dll}: an empty slot ends the bring-up in FAULT without waiting`, () => {
    const s = boot(dll, {}, { noBoot: true, card: { present: false } });
    for (let i = 0; i < 50 && s.ctx('hw_state') !== UHW_FAULT; i++) s.run(1);
    assert.equal(s.ctx('hw_state'), UHW_FAULT);
    assert.deepEqual(s.probs, []);
  });

  test(`${dll}: ESP-AT 2.2.1 (no passive receive): ${udp ? 'UDP still works' : 'TCP ends in FAULT'}`, () => {
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

  test(`${dll}: the FIFO trigger follows INIT_CONFIG`, () => {
    for (const [trig, fcr] of [[1, 0x07], [4, 0x47], [14, 0xc7]]) {
      const s = boot(dll, { uart_rx_trigger: trig });
      assert.equal(s.card.fcrWrites[0].v, fcr, `trigger ${trig}`);
      clean(s);
    }
  });

  test(`${dll}: a module answering "busy p..." gets the command again`, () => {
    const s = boot(dll, {}, { card: { esp: { busyFirst: 2 } } });
    assert.deepEqual(s.esp.cmds.slice(0, 3), ['AT', 'AT', 'AT']);
    connect(s);
    assert.deepEqual(echo(s, bytes(40, 2)), bytes(40, 2));
    clean(s);
  });

  test(`${dll}: a refused connect gives PEER_CLOSED then CLOSED, no CONNECTED`, () => {
    const s = boot(dll, {}, { card: { esp: { connectFail: true } } });
    assert.equal(s.open().a, S.OK);
    const ev = s.until(has('CLOSED'));
    assert.deepEqual(ev.map((e) => e.name), ['PEER_CLOSED', 'CLOSED']);
    clean(s);
  });

  test(`${dll}: SEND FAIL fails that slot only`, () => {
    const s = boot(dll);
    connect(s);
    s.esp.sendFail = 1;
    assert.equal(s.send(bytes(20, 1), 1).commit.a, S.OK);
    let ev = s.until(has('TX_DONE'));
    assert.deepEqual(named(ev, 'TX_DONE').map((e) => e.status), [C.txdone.FAILED]);
    assert.deepEqual(echo(s, bytes(30, 4), 2), bytes(30, 4));
    clean(s);
  });

  test(`${dll}: payload bytes that look like AT lines are data`, () => {
    const s = boot(dll);
    connect(s);
    const tricky = [...Buffer.from('\r\nCLOSED\r\nOK\r\n+IPD,0,99:\r\nready\r\n0,CLOSED\r\nERROR\r\n> ', 'latin1'), 0, 0, 13, 10];
    assert.deepEqual(echo(s, tricky), tricky);
    assert.equal(s.ctx('chan'), 2, 'still open');
    assert.deepEqual(echo(s, bytes(50, 9), 2), bytes(50, 9));
    clean(s);
  });

  test(`${dll}: the peer closing the link gives PEER_CLOSED then CLOSED`, () => {
    const s = boot(dll);
    connect(s);
    assert.deepEqual(echo(s, bytes(64, 3)), bytes(64, 3));
    s.peer.close();
    const ev = s.until(has('CLOSED'));
    assert.deepEqual(ev.map((e) => e.name), ['PEER_CLOSED', 'CLOSED']);
    clean(s);
  });

  test(`${dll}: a module restart gives LINK_LOST, sets the module up again, OPEN works`, () => {
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

  test(`${dll}: WIFI DISCONNECT gives LINK_LOST then CLOSED`, () => {
    const s = boot(dll);
    connect(s);
    s.esp.wifiDrop();
    const ev = s.until(has('CLOSED'));
    assert.deepEqual(ev.map((e) => e.name), ['LINK_LOST', 'CLOSED']);
    clean(s);
  });

  test(`${dll}: a UART overrun fails the channel with STREAM_ERROR, a new OPEN works`, () => {
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

  test(`${dll}: a closing channel finishes the CIPSEND in progress first`, () => {
    const s = boot(dll);
    connect(s);
    const d = bytes(udp ? 512 : 536, 8);
    assert.equal(s.send(d, 1).commit.a, S.OK);
    for (let i = 0; i < 400 && !(s.esp.dataLeft > 0); i++) s.run(1);
    assert.ok(s.esp.dataLeft > 0, 'payload streaming');
    assert.equal(s.call('CLOSE').a, S.OK);
    const ev = s.until(has('CLOSED'));
    assert.ok(has('TX_DONE')(ev));
    assert.deepEqual(udp ? s.peer.udpIn[0] : s.peer.received, d, 'the whole payload went out');
    assert.equal(s.esp.cmds[s.esp.cmds.length - 1], 'AT+CIPCLOSE=0');
    clean(s);
  });

  test(`${dll}: a lost CIPSEND reply ends in TIMEOUT(TX), the module is set up again`, () => {
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
    test(`${dll}: an answer that trickles in byte by byte is reassembled`, () => {
      const s = boot(dll, {}, { card: { esp: { trickleUs: 2500 } } });
      connect(s);
      assert.deepEqual(echo(s, bytes(100, 7)), bytes(100, 7));
      clean(s);
    });

    test(`${dll}: short and empty CIPRECVDATA answers: no FIN, no immediate retry`, () => {
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

    test(`${dll}: a full RX ring stops the reads; the module keeps the data`, () => {
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
    test(`${dll}: a datagram longer than a slot, or without a free slot, is dropped and counted`, () => {
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

  if (udp) test(`${dll}: a parser behind the UART drops RTS explicitly, no overrun`, () => {
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

  transportScenarios(dll);
}
