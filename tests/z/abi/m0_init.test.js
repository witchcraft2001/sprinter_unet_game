// M0 ABI vectors: INIT/FINI placement, GET_INFO, INIT_CONFIG validation,
// GET_STATS, SHUTDOWN.  Runs on all seven builds (ТЗ §8.3: one scenario,
// every profile).  Every call is also checked for the core invariants
// (IX/IY, SP, IFF, page/shadow restore, stack, DI, forbidden ops).
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { Stand, C, DLLS, ABI } = require('../../../tools/harness/stand.js');

const S = C.status;
const clean = (r, what) => assert.deepEqual(r.problems, [], `${what}: ${r.problems.join('; ')}`);

for (const dll of DLLS) {
  test(`${dll}: INIT in window 1/2 succeeds, window 3 is refused`, () => {
    for (const [window, offset] of [[1, 0], [1, 0x0a00], [2, 0], [2, 0x2300]]) {
      const s = new Stand({ dll, window, offset });
      const r = s.call('INIT');
      clean(r, 'INIT');
      assert.equal(r.cf, 0);
      assert.equal(r.a, 0);
      const i = s.getInfo();
      assert.equal(i.a, S.OK);
      assert.equal(i.info.image_base, s.base, 'GET_INFO.image_base is the relocated header address');
    }
    // Window 3: map the page there directly (libman refuses nothing; INIT must).
    const s = new Stand({ dll, window: 2 });
    const { relocate } = require('../../../tools/harness/dll-loader.js');
    s.m.win[3] = 12;
    s.m.pokeBytes(0xc000, relocate(s.l1, 0xc000));
    s.base = 0xc000;
    s.m.image = null;
    const r = s.call('INIT');
    assert.equal(r.cf, 1, 'INIT must set CF in window 3');
  });

  test(`${dll}: FINI is safe without INIT_CONFIG and after it`, () => {
    const s = new Stand({ dll });
    clean(s.call('INIT'), 'INIT');
    const f = s.call('FINI');
    clean(f, 'FINI');
    assert.equal(f.a, 0);
    const s2 = new Stand({ dll });
    s2.call('INIT');
    assert.equal(s2.initConfig(s2.defaultConfig()).a, S.OK);
    assert.equal(s2.call('FINI').a, 0);
    assert.equal(s2.m.peek16(s2.sym('IMG_CTX_PTR')), 0);
  });

  test(`${dll}: GET_INFO contents, truncation and bad buffers`, () => {
    const s = new Stand({ dll });
    s.call('INIT');
    const r = s.getInfo();
    clean(r, 'GET_INFO');
    const i = r.info;
    assert.equal(i.abi_version, 0x0100);
    assert.equal(i.size, ABI.blocks.INFO.size);
    assert.equal(i.hw_profile, C.hw[s.profile.hw]);
    assert.equal(i.image_size, s.l1.codeSize);
    assert.equal(i.ctx_size, ABI.ctx.size);
    assert.equal(i.event_size, 8);
    assert.equal(i.image_mutable_bytes, 2);
    assert.equal(i.max_step_gap_ms, 20);
    assert.ok(i.poll_gap_us <= i.auto_fallback_gap_us && i.auto_fallback_gap_us <= i.max_service_gap_us,
      'poll_gap <= auto_fallback_gap <= max_service_gap (ТЗ §4.2)');
    assert.ok(i.empty_poll_us <= i.isr_body_max_us && i.bus_busy_us <= i.isr_body_max_us);
    assert.equal(i.step_body_max_us, 500);
    assert.equal(i.isr_body_max_us, 150);
    assert.equal(i.caps & C.cap.IRQ_ROUTE_QUALIFIED, 0, 'v1: no qualified IRQ route');
    assert.equal(i.caps & C.cap.PROBE, 0, 'v1: no IRQ probe (AUTO is served through POLL)');
    assert.ok(i.caps & C.cap.POLL);
    if (s.profile.hw !== 'LOOP') assert.ok(i.caps & C.cap.AUTO);
    if (s.profile.hw === 'ESP') assert.equal(i.hw_ring_min, 512);
    // truncated copy: exactly n bytes written
    const t = s.getInfo(6);
    assert.equal(t.a, S.OK);
    assert.equal(t.raw[6], 0xee);
    assert.equal(t.raw[4], C.hw[s.profile.hw]);
    // too small / wrapping buffers
    assert.equal(s.getInfo(3).a, S.BAD_ARGUMENT);
    const w = s.call('GET_INFO', { ix: 0xfff0, de: 0x20 });
    assert.equal(w.a, S.BAD_ARGUMENT);
  });

  test(`${dll}: INIT_CONFIG accepts the default profile, refuses a second one`, () => {
    const s = new Stand({ dll });
    s.call('INIT');
    const r = s.initConfig(s.defaultConfig());
    clean(r, 'INIT_CONFIG');
    assert.equal(r.a, S.OK);
    const L = s.layout();
    for (let k = 0; k < 4; k++) assert.equal(s.m.peek(L.ctx + ABI.ctx.fields.guard.offset + k), 0xa5);
    assert.equal(s.m.peek16(s.sym('IMG_CTX_PTR')), L.ctx);
    assert.equal(s.initConfig(s.defaultConfig()).a, S.STATE, 'active context -> STATE');
    const st = s.getStats();
    clean(st, 'GET_STATS');
    assert.equal(st.a, S.OK);
    assert.equal(st.stats.abi_version, 0x0100);
    assert.equal(st.stats.size, ABI.blocks.STATS.size);
    assert.equal(st.stats.ctx_state, C.ctxstate.CONFIGURED);
    assert.equal(st.stats.mode_actual, C.mode.POLL);
    const sh = s.call('SHUTDOWN');
    clean(sh, 'SHUTDOWN');
    assert.equal(sh.a, S.OK);
    assert.equal(s.call('SHUTDOWN').a, S.OK, 'SHUTDOWN is idempotent');
    // fresh INIT_CONFIG after SHUTDOWN OK
    for (let i = 0; i < 0x300; i++) s.m.poke(L.ctx + i, 0);
    assert.equal(s.initConfig(s.defaultConfig()).a, S.OK);
  });

  test(`${dll}: AUTO without a qualified route reports POLL and NO_ROUTE`, () => {
    const s = new Stand({ dll });
    s.call('INIT');
    assert.equal(s.initConfig(s.defaultConfig({ mode: C.mode.AUTO })).a, S.OK);
    const st = s.getStats().stats;
    assert.equal(st.mode_actual, C.mode.POLL);
    assert.equal(st.route_state, C.route.NO_ROUTE);
    if (s.profile.hw !== 'LOOP') assert.equal(st.fallback_reason, C.fallback.NO_ROUTE);
  });

  test(`${dll}: exports need a context`, () => {
    const s = new Stand({ dll });
    s.call('INIT');
    for (const e of ['STEP', 'OPEN', 'CLOSE', 'ABORT', 'TX_RESERVE', 'RX_PEEK', 'NEXT_EVENT', 'GET_STATS']) {
      const r = s.call(e, { ix: s.layout().buf, de: 8 });
      clean(r, e);
      assert.equal(r.a, S.STATE, `${e} without a context`);
    }
    assert.equal(s.call('SHUTDOWN').a, S.OK, 'SHUTDOWN in a zeroed context is OK');
    // reserved table entries
    const m = s.m;
    for (let n = ABI.export_count - 7; n < ABI.export_count; n++) {
      m.poke16(0x3fee, 0x0100);
      m.setRegs({ pc: s.base + 0x20 + 3 * n, sp: 0x3fee });
      m.runUntil(0x0100);
      assert.equal(m.regs().a, S.STATE, `reserved entry ${n}`);
    }
  });

  // ---- BAD_CONFIG vectors ----------------------------------------------
  const hw = require('../../../tools/harness/stand.js').PROFILE[dll].hw;
  const bad = [
    ['major version 2', (c) => { c.abi_version = 0x0200; }],
    ['size below the v1.0 block', (c) => { c.size = ABI.blocks.CFG.size - 1; }],
    ['other card profile', (c) => { c.hw_profile = hw === 'ESP' ? C.hw.RTL : C.hw.ESP; }],
    ['mode 0', (c) => { c.mode = 0; }],
    ['mode 3 (no strict IRQ mode in v1)', (c) => { c.mode = 3; }],
    ['timing mode 0', (c) => { c.timing_mode = 0; }],
    ['reserved flag bit', (c) => { c.flags |= 0x80; }],
    ['reserved byte', (c) => { c.reserved1 = 1; }],
    ['cpu_khz 1000', (c) => { c.cpu_khz = 1000; }],
    ['retry_count 8', (c) => { c.retry_count = 8; }],
    ['zero retry interval', (c) => { c.retry_wait_ms = [500, 0, 2000, 2000, 2000]; }],
    ['zero connect timeout', (c) => { c.connect_timeout_ms = 0; }],
    ['zero close timeout', (c) => { c.close_timeout_ms = 0; }],
    ['3 TX slots', (c) => { c.tx_slot_count = 3; }],
    ['9 RX slots', (c) => { c.rx_slot_count = 9; }],
    ['TX slot too small', (c) => { c.tx_slot_size = 100; }],
    ['event cap not a power of two', (c) => { c.event_cap = 12; }],
    ['event cap too small', (c) => { c.event_cap = 8; }],
    ['context too small', (c) => { c.ctx_len = ABI.ctx.size - 1; }],
    ['context crosses into the ISA window', (c) => { c.ctx_ptr = 0xbf00; }],
    ['TX slots wrap past 0xFFFF', (c) => { c.tx_slots_ptr = 0xf800; }],
    ['RX slots overlap TX slots', (c) => { c.rx_slots_ptr = c.tx_slots_ptr + 0x100; }],
    ['events overlap the context', (c) => { c.event_ptr = c.ctx_ptr + 0x10; }],
    ['context inside the DLL window', (c) => { c.ctx_ptr = 0x4800; }],
    ['context overlaps the main stack', (c) => { c.ctx_ptr = 0x3a00; }],
    ['main stack too small below SP', (c) => { c.main_stack_ptr = 0x3f00; c.main_stack_len = 0x100; }],
    ['SP outside the main stack', (c) => { c.main_stack_ptr = 0x2000; c.main_stack_len = 0x400; }],
    ['shared stack without ISR room (300 < 416 bytes)', (c) => { c.isr_stack_ptr = 0; c.isr_stack_len = 0; c.main_stack_ptr = 0x3ff0 - 300; c.main_stack_len = 0x4000 - (0x3ff0 - 300); }],
    ['ISR stack too small', (c) => { c.isr_stack_len = 100; }],
    ['main stack zero length', (c) => { c.main_stack_len = 0; }],
    ['route PIO bit 2', (c) => { c.route_present = 1; c.route_pio_bit = 2; c.route_vector = 0xe0; }],
    ['odd IM2 vector', (c) => { c.route_present = 1; c.route_pio_bit = 0; c.route_vector = 0xe1; }],
  ];
  if (hw !== 'LOOP') {
    bad.push(
      ['ISA slot 2', (c) => { c.isa_slot = 2; }],
      ['I/O base 0', (c) => { c.io_base = 0; }],
      ['I/O base misaligned', (c) => { c.io_base = c.io_base + 1; }],
      ['I/O base beyond 14 bits', (c) => { c.io_base = 0x4000; }],
      ['no ISA lock byte', (c) => { c.isa_lock_ptr = 0; }],
      ['no #1FFD shadow', (c) => { c.shadow_1ffd_ptr = 0; }],
      ['lock byte inside the ISA window', (c) => { c.isa_lock_ptr = 0xc100; }],
      ['ring inside the context', (c) => { c.hw_ring_ptr = c.ctx_ptr; c.hw_ring_len = hw === 'ESP' ? 512 : 16; }],
    );
  }
  if (hw === 'RTL' || hw === 'EL3') {
    bad.push(['local IP 0.0.0.0', (c) => { c.local_ip = '0.0.0.0'; }], ['ARP TTL 999', (c) => { c.arp_ttl_ms = 999; }],
      ['software ring on an Ethernet card', (c) => { c.hw_ring_ptr = 0x9700; c.hw_ring_len = 16; }]);
  }
  if (hw === 'EL3') bad.push(['ID port 0x210', (c) => { c.id_port = 0x210; }], ['ID port 0x118', (c) => { c.id_port = 0x118; }]);
  if (hw === 'ESP') {
    bad.push(['UART divisor 0', (c) => { c.uart_divisor = 0; }], ['ESP-AT 2.2.1 profile', (c) => { c.esp_fw = 2; }],
      ['FIFO trigger 5', (c) => { c.uart_rx_trigger = 5; }], ['ring 511 bytes', (c) => { c.hw_ring_len = 511; }],
      ['no UART ring (pointer 0)', (c) => { c.hw_ring_ptr = 0; }]);
  }
  if (hw !== 'LOOP' && s_transport(dll) === 'TCP') bad.push(['UDP on a TCP build', (c) => { c.transport = C.transport.UDP; }]);
  if (s_transport(dll) === 'UDP') bad.push(['TCP on a UDP build', (c) => { c.transport = C.transport.TCP; }]);

  test(`${dll}: ${bad.length} BAD_CONFIG vectors leave the context untouched`, () => {
    for (const [what, mutate] of bad) {
      const s = new Stand({ dll });
      s.call('INIT');
      const cfg = s.defaultConfig();
      mutate(cfg);
      const L = s.layout();
      const before = s.m.peekBytes(L.ctx, 0x300);
      const r = s.initConfig(cfg);
      clean(r, what);
      assert.equal(r.a, S.BAD_CONFIG, `${what}: got status ${r.a}`);
      assert.deepEqual(s.m.peekBytes(L.ctx, 0x300), before, `${what}: context modified`);
      assert.equal(s.m.peek16(s.sym('IMG_CTX_PTR')), 0, `${what}: context published`);
    }
  });

  // ---- UNSUPPORTED_TIMING vectors ---------------------------------------
  const timing = [
    ['poll gap above the profile', (c, i) => { c.worst_poll_gap_us = i.poll_gap_us + 1; }],
    ['poll gap 0', (c) => { c.worst_poll_gap_us = 0; }],
    ['STEP gap 21 ms', (c) => { c.worst_step_gap_ms = 21; }],
    ['STEP budget below min_useful', (c, i) => { c.step_budget_us = i.min_useful_budget_us - 1; }],
    ['STEP budget above 500', (c) => { c.step_budget_us = 501; }],
    ['STEP_ISR budget above 150', (c) => { c.isr_budget_us = 151; }],
    ['APP_COUNTER read cost 21 us', (c) => { c.timing_mode = C.timing.APP_COUNTER; c.time_read_cost_us = 21; }],
  ];
  if (hw === 'ESP') {
    timing.push(['no verified flow control', (c) => { c.flags = 0; }],
      ['local UART without AFE', (c) => { c.uart_flow = 0; }], ['ESP side without RTS/CTS', (c) => { c.esp_flow = 0; }]);
  }
  test(`${dll}: ${timing.length} UNSUPPORTED_TIMING vectors`, () => {
    for (const [what, mutate] of timing) {
      const s = new Stand({ dll });
      s.call('INIT');
      const info = s.getInfo().info;
      const cfg = s.defaultConfig();
      mutate(cfg, info);
      const r = s.initConfig(cfg);
      clean(r, what);
      assert.equal(r.a, S.UNSUPPORTED_TIMING, `${what}: got status ${r.a}`);
      assert.equal(s.m.peek16(s.sym('IMG_CTX_PTR')), 0);
    }
  });

  if (hw === 'LOOP') {
    test('gloop: accepts both transports, UDP with 512-byte slots', () => {
      const s = new Stand({ dll });
      s.call('INIT');
      const r = s.initConfig(s.defaultConfig({ transport: C.transport.UDP, tx_slot_size: 512, rx_slot_size: 512 }));
      clean(r, 'INIT_CONFIG');
      assert.equal(r.a, S.OK);
      const t = new Stand({ dll });
      t.call('INIT');
      assert.equal(t.initConfig(t.defaultConfig({ transport: 3 })).a, S.BAD_CONFIG);
      assert.equal(t.initConfig(t.defaultConfig({ transport: C.transport.TCP, tx_slot_size: 512 })).a, S.BAD_CONFIG,
        'TCP needs 536-byte slots');
    });
  }

  test(`${dll}: BAD_CONFIG wins over UNSUPPORTED_TIMING`, () => {
    const s = new Stand({ dll });
    s.call('INIT');
    const r = s.initConfig(s.defaultConfig({ worst_step_gap_ms: 50, tx_slot_count: 2 }));
    assert.equal(r.a, S.BAD_CONFIG);
  });

  test(`${dll}: config with a larger declared size (future tail) is accepted`, () => {
    const s = new Stand({ dll });
    s.call('INIT');
    const cfg = s.defaultConfig({ size: ABI.blocks.CFG.size + 10 });
    assert.equal(s.initConfig(cfg).a, S.OK);
  });

  test(`${dll}: 7 MHz is UNSUPPORTED_TIMING in v1 (min_useful_budget_us is for 21 MHz)`, () => {
    const s = new Stand({ dll, mhz: 7 });
    clean(s.call('INIT'), 'INIT');
    const info = s.getInfo().info;
    assert.equal(info.profile_cpu_khz, 21000);
    assert.ok(info.min_useful_budget_us * 21 / 7 > 500, 'the 21 MHz minimum tripled exceeds the STEP limit');
    const r = s.initConfig(s.defaultConfig({ cpu_khz: 7000, step_budget_us: 500, isr_budget_us: 150 }));
    clean(r, 'INIT_CONFIG');
    assert.equal(r.a, S.UNSUPPORTED_TIMING);
  });
}

function s_transport(dll) { return require('../../../tools/harness/stand.js').PROFILE[dll].transport; }
