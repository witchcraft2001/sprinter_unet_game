// m5_netenv.test.js -- sdk/loader/ugenv.asm on the Z stand: the card fields
// of INIT_CONFIG from the DSS environment (UG_NETENV), the derived fields
// (UG_NETFIX), the DLL names (UG_NETNAME) and the variable names
// (UG_NETVAR).  tests/z/sdk/ugenvz.asm runs the real code; DSS ENVIRON is
// the stub of tools/harness/dss.js (Estex-DSS GETENV semantics).  The block
// filled from each board's environment goes to the INIT_CONFIG of the real
// DLL of every card build in the same machine.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { Machine } = require('../../../tools/harness/machine.js');
const { Stand, C, DLLS, encodeBlock, decodeBlock, ABI } = require('../../../tools/harness/stand.js');
const { readSymbols } = require('../../../tools/harness/dll-loader.js');
const { DssEnv, runDss } = require('../../../tools/harness/dss.js');

const ROOT = path.join(__dirname, '..', '..', '..');
const BIN = fs.readFileSync(path.join(ROOT, 'build', 'ugenvz.bin'));
const SYM = readSymbols(path.join(ROOT, 'build', 'ugenvz.sym'));
const ORG = 0xb000;
const CFG = 0x2000, CTX = 0x8000, SP = 0xbff0;
const F = ABI.blocks.CFG.fields;
const off = (name) => F[name].offset;
const E = {
  OK: SYM.UGN_OK, CFG: SYM.UGN_E_CFG, NONET: SYM.UGN_E_NONET, ENV: SYM.UGN_E_ENV, FLOW: SYM.UGN_E_FLOW,
};
const V = {
  NET: SYM.UGN_V_NET, ESP_HW: SYM.UGN_V_ESP_HW, RTL_HW: SYM.UGN_V_RTL_HW, HW: SYM.UGN_V_HW, IDPORT: SYM.UGN_V_IDPORT,
  IP: SYM.UGN_V_IP, MASK: SYM.UGN_V_MASK, GW: SYM.UGN_V_GW, MAC: SYM.UGN_V_MAC, BAUD: SYM.UGN_V_BAUD, FLOW: SYM.UGN_V_ESP_FLOW,
};
const TCP = C.transport.TCP, UDP = C.transport.UDP;

// The environments the bring-up tools left on the boards (docs/evidence/hw
// state_*), with the addresses of the stand and the variables nobody reads.
const BOARD = {
  ESP: { NET: 'WIFI', NET_ESP_HW: '0/#3E8', NET_BAUD: '115200', NET_ESP_FLOW: '3', NET_ESP_FW: '2.2.2', NET_IP_SRC: 'DHCP', NET_LEASE_SEC: '25200' },
  RTL: {
    NET: 'RTL', NET_RTL_HW: '0/#300', NET_RTL_TYPE: 'RTL8019AS', NET_RTL_RESET: 'SOFT', NET_IP_SRC: 'DHCP',
    NET_IP: '192.168.0.10', NET_MASK: '255.255.255.0', NET_GW: '192.168.0.1', NET_MAC: '00:E0:4C:12:34:56',
    NET_DNS1: '192.168.0.1', NET_LEASE_SEC: '92.168.1.1',
  },
  EL3: {
    NET: '509B', NET_HW: '0/#300', NET_IDPORT: '#110', NET_IP_SRC: 'DHCP',
    NET_IP: '192.168.0.10', NET_MASK: '255.255.255.0', NET_GW: '192.168.0.1', NET_MAC: '00:60:08:AB:CD:EF',
  },
};
const HW = { ESP: C.hw.ESP, RTL: C.hw.RTL, EL3: C.hw.EL3 };
// Fields UG_NETENV may write, by card (and flags for ESP: FLOW_VERIFIED).
const COMMON = ['transport', 'cpu_khz', 'hw_profile', 'isa_slot', 'io_base'];
const WRITES = {
  ESP: [...COMMON, 'uart_divisor', 'uart_flow', 'esp_flow', 'flags'],
  RTL: [...COMMON, 'local_ip', 'netmask', 'gateway_ip', 'mac'],
  EL3: [...COMMON, 'local_ip', 'netmask', 'gateway_ip', 'mac', 'id_port'],
};

function machine() {
  const m = new Machine({ waits: false });
  m.pokeBytes(ORG, BIN);
  return m;
}
// A block of a recognisable pattern with a usable context region.
function patternBlock(over = {}) {
  const b = new Uint8Array(ABI.blocks.CFG.size);
  for (let i = 0; i < b.length; i++) b[i] = (0x5a + 37 * i) & 0xff;
  const put16 = (name, v) => { b[off(name)] = v & 0xff; b[off(name) + 1] = v >> 8; };
  b[off('flags')] = over.flags ?? 0;
  put16('ctx_ptr', over.ctx_ptr ?? CTX);
  put16('ctx_len', over.ctx_len ?? 0x300);
  return b;
}
function run(m, entry, regs = {}, env = {}, sp = SP) {
  const dss = env instanceof DssEnv ? env : new DssEnv(env);
  m.setRegs({ a: 0, b: 0, c: 0, d: 0, e: 0, h: 0, l: 0, ix: CFG, iy: 0x5678, ...regs, sp, pc: SYM[entry], iff1: 0, iff2: 0 });
  runDss(m, SYM.ugv_stop, dss);
  const s = m.regs();
  return { a: s.a, b: s.b, cf: s.flags.C, hl: (s.h << 8) | s.l, de: (s.d << 8) | s.e, ix: s.ix, iy: s.iy, sp: s.sp, dss };
}
function netenv(env, transport = UDP, blockOver = {}) {
  const m = machine();
  const block = patternBlock(blockOver);
  m.pokeBytes(CFG, block);
  const before = m.peekBytes(0, 0x10000);
  const r = run(m, 'ugv_env', { a: transport }, env, blockOver.sp ?? SP);
  r.block = Uint8Array.from(m.peekBytes(CFG, block.length));
  r.cfg = decodeBlock('CFG', r.block);
  r.orig = block;
  r.mem = { before, after: m.peekBytes(0, 0x10000) };
  r.m = m;
  return r;
}
const ok = (r) => { assert.equal(r.cf, 0, `CF, A=${r.a} B=${r.b}`); assert.equal(r.a, E.OK); };
const fails = (r, code, v) => {
  assert.equal(r.cf, 1, 'CF');
  assert.equal(r.a, code, `A=${r.a} B=${r.b}`);
  if (v !== undefined) assert.equal(r.b, v, 'B = the variable');
};
const ip = (s) => s.split('.').map(Number);
const macOf = (s) => s.split(':').map((x) => parseInt(x, 16));
const with_ = (base, over) => { const e = { ...base, ...over }; for (const k of Object.keys(e)) if (e[k] === null) delete e[k]; return e; };

// Every byte outside the fields of the card, the value buffer and the stack
// is what it was; the IX / IY / SP of the caller come back.
function onlyFields(r, card) {
  assert.equal(r.ix, CFG, 'IX');
  assert.equal(r.iy, 0x5678, 'IY');
  assert.equal(r.sp, SP, 'SP');
  const allowed = new Set();
  for (const name of WRITES[card]) for (let i = 0; i < F[name].size; i++) allowed.add(CFG + off(name) + i);
  for (let i = 0; i < 256; i++) allowed.add(CTX + i);
  for (let a = SP - 64; a < SP; a++) allowed.add(a);
  const bad = [];
  for (let a = 0; a < 0x10000; a++) if (r.mem.before[a] !== r.mem.after[a] && !allowed.has(a)) bad.push(a);
  assert.deepEqual(bad.map((a) => a.toString(16)), [], 'bytes written outside the card fields');
  if (card !== 'ESP') assert.equal(r.block[off('flags')], r.orig[off('flags')], 'flags of an Ethernet card');
}

// ---- the environments of the boards -----------------------------------------
test('UG_NETENV: the SprinterESP board environment', () => {
  const r = netenv(BOARD.ESP, UDP, { flags: C.cfgf.UDP_RECORDS });
  ok(r);
  const c = r.cfg;
  assert.equal(c.hw_profile, HW.ESP);
  assert.equal(c.transport, UDP);
  assert.equal(c.cpu_khz, 21000);
  assert.equal(c.isa_slot, 0);
  assert.equal(c.io_base, 0x3e8);
  assert.equal(c.uart_divisor, 8);
  assert.equal(c.uart_flow, 1);
  assert.equal(c.esp_flow, 3);
  assert.equal(c.flags, C.cfgf.UDP_RECORDS | C.cfgf.FLOW_VERIFIED, 'FLOW_VERIFIED added, the game flags kept');
  onlyFields(r, 'ESP');
  assert.deepEqual(r.dss.calls.map((x) => x.name), ['NET', 'NET_ESP_HW', 'NET_BAUD', 'NET_ESP_FLOW']);
  assert.ok(r.dss.calls.every((x) => x.buffer === CTX), 'the value buffer is the context region');
});

test('UG_NETENV: the RTL8019AS board environment', () => {
  const r = netenv(BOARD.RTL, TCP);
  ok(r);
  const c = r.cfg;
  assert.equal(c.hw_profile, HW.RTL);
  assert.equal(c.transport, TCP);
  assert.equal(c.cpu_khz, 21000);
  assert.equal(c.isa_slot, 0);
  assert.equal(c.io_base, 0x300);
  assert.deepEqual(c.local_ip, ip('192.168.0.10'));
  assert.deepEqual(c.netmask, ip('255.255.255.0'));
  assert.deepEqual(c.gateway_ip, ip('192.168.0.1'));
  assert.deepEqual(c.mac, macOf('00:E0:4C:12:34:56'));
  onlyFields(r, 'RTL');
});

test('UG_NETENV: the 3C509B board environment', () => {
  const r = netenv(BOARD.EL3, UDP);
  ok(r);
  const c = r.cfg;
  assert.equal(c.hw_profile, HW.EL3);
  assert.equal(c.io_base, 0x300);
  assert.equal(c.id_port, 0x110);
  assert.deepEqual(c.local_ip, ip('192.168.0.10'));
  assert.deepEqual(c.mac, macOf('00:60:08:AB:CD:EF'));
  onlyFields(r, 'EL3');
});

test('UG_NETENV: any case of NET and of the hex digits, slot 1', () => {
  let r = netenv(with_(BOARD.ESP, { NET: 'esp', NET_ESP_HW: '1/#3e8' }));
  ok(r);
  assert.equal(r.cfg.hw_profile, HW.ESP);
  assert.equal(r.cfg.isa_slot, 1);
  assert.equal(r.cfg.io_base, 0x3e8);
  r = netenv(with_(BOARD.ESP, { NET: 'Wifi' }));
  ok(r);
  r = netenv(with_(BOARD.EL3, { NET: '509b', NET_HW: '1/#2a0', NET_IDPORT: '#1f0', NET_MAC: '0a:bC:De:f0:12:9F' }));
  ok(r);
  assert.equal(r.cfg.isa_slot, 1);
  assert.equal(r.cfg.io_base, 0x2a0);
  assert.equal(r.cfg.id_port, 0x1f0);
  assert.deepEqual(r.cfg.mac, [0x0a, 0xbc, 0xde, 0xf0, 0x12, 0x9f]);
  r = netenv(with_(BOARD.RTL, { NET: 'rtl' }));
  ok(r);
  assert.equal(r.cfg.hw_profile, HW.RTL);
});

test('UG_NETENV: defaults of the optional variables', () => {
  let r = netenv(with_(BOARD.ESP, { NET_BAUD: null }));
  ok(r);
  assert.equal(r.cfg.uart_divisor, 8, 'no NET_BAUD: 115200');
  r = netenv(with_(BOARD.RTL, { NET_GW: null, NET_MAC: null }));
  ok(r);
  assert.deepEqual(r.cfg.gateway_ip, [0, 0, 0, 0]);
  assert.deepEqual(r.cfg.mac, [0, 0, 0, 0, 0, 0], 'no NET_MAC: the PROM address');
  onlyFields(r, 'RTL');
  r = netenv(with_(BOARD.EL3, { NET_IDPORT: null, NET_GW: '', NET_MAC: '' }));
  ok(r);
  assert.equal(r.cfg.id_port, 0x110);
  assert.deepEqual(r.cfg.gateway_ip, [0, 0, 0, 0], 'an empty value is an absent one');
});

test('UG_NETENV: NET_BAUD to the 16550 divisor', () => {
  for (const [baud, div] of [['230400', 4], ['115200', 8], ['57600', 16], ['38400', 24], ['19200', 48], ['9600', 96]]) {
    const r = netenv(with_(BOARD.ESP, { NET_BAUD: baud }));
    ok(r);
    assert.equal(r.cfg.uart_divisor, div, baud);
  }
  for (const baud of ['115201', '115300', '100000', 'abc', '00', '000', '0', '1', '96OO', '9600 ', '+9600', '9216000', '99999900', 'x'.repeat(255)]) {
    fails(netenv(with_(BOARD.ESP, { NET_BAUD: baud })), E.ENV, V.BAUD);
  }
});

test('UG_NETENV: NET absent or not a card of the SDK (GLOOP never)', () => {
  for (const net of [null, '', 'LOOP', 'GLOOP', 'WIFI2', 'WIF', 'RTL8019', 'ETH', 'x'.repeat(255)]) {
    const r = netenv(with_(BOARD.RTL, { NET: net }));
    fails(r, E.NONET);
    assert.equal(r.dss.calls.length, 1, 'nothing read after NET');
  }
});

test('UG_NETENV: ESP without RTS/CTS verified by NETUP', () => {
  for (const flow of [null, '', '0', '1', '33', '3 ', ' 3']) {
    fails(netenv(with_(BOARD.ESP, { NET_ESP_FLOW: flow })), E.FLOW, V.FLOW);
  }
});

test('UG_NETENV: the card variable S/#HHH', () => {
  const cases = { ESP: ['NET_ESP_HW', V.ESP_HW], RTL: ['NET_RTL_HW', V.RTL_HW], EL3: ['NET_HW', V.HW] };
  for (const [card, [name, v]] of Object.entries(cases)) {
    for (const val of [null, '2/#300', '0#300', '0/300', '0/#', '0/#12345', '0/#300x', '0/#30G', '/#300', '0', '00/#300', 'x'.repeat(255)]) {
      fails(netenv(with_(BOARD[card], { [name]: val })), E.ENV, v);
    }
    // another card's variable is not this card's
    const other = card === 'RTL' ? 'NET_HW' : 'NET_RTL_HW';
    fails(netenv(with_(BOARD[card], { [name]: null, [other]: '0/#300' })), E.ENV, v);
  }
  const r = netenv(with_(BOARD.RTL, { NET_RTL_HW: '0/#3' }));
  ok(r);
  assert.equal(r.cfg.io_base, 3, 'ranges are INIT_CONFIG\'s');
});

test('UG_NETENV: addresses of the Ethernet cards', () => {
  for (const card of ['RTL', 'EL3']) {
    for (const [name, v, required] of [['NET_IP', V.IP, true], ['NET_MASK', V.MASK, true], ['NET_GW', V.GW, false]]) {
      if (required) fails(netenv(with_(BOARD[card], { [name]: null })), E.ENV, v);
      for (const val of ['192.168.0.256', '192.168.0', '192.168.0.1.5', '192.168.0.1x', '92.168..1', '.1.2.3', '1.2.3.4.', '65536.0.0.1', '1,2,3,4', 'x'.repeat(255)]) {
        fails(netenv(with_(BOARD[card], { [name]: val })), E.ENV, v);
      }
    }
    for (const val of ['00:11:22:33:44', '00:11:22:33:44:55:66', '0:11:22:33:44:55', '00-11-22-33-44-55', '00:11:22:33:44:5g', '001122334455']) {
      fails(netenv(with_(BOARD[card], { NET_MAC: val })), E.ENV, V.MAC);
    }
    const r = netenv(with_(BOARD[card], { NET_IP: '010.0.0.255', NET_MASK: '0.0.0.0' }));
    ok(r);
    assert.deepEqual(r.cfg.local_ip, [10, 0, 0, 255]);
  }
  for (const val of ['110', '#', '#12345', '#110 ']) fails(netenv(with_(BOARD.EL3, { NET_IDPORT: val })), E.ENV, V.IDPORT);
});

test('UG_NETENV: the context region must hold 256 bytes below #C000', () => {
  fails(netenv(BOARD.RTL, UDP, { ctx_len: 0xff }), E.CFG);
  fails(netenv(BOARD.RTL, UDP, { ctx_ptr: 0xbf01 }), E.CFG);
  fails(netenv(BOARD.RTL, UDP, { ctx_ptr: 0xc000 }), E.CFG);
  const r = netenv(BOARD.RTL, UDP, { ctx_ptr: 0xbf00, ctx_len: 0x100, sp: 0x7ff0 });
  assert.equal(r.cf, 0, 'the last 256 bytes below #C000 are fine');
  assert.ok(r.dss.calls.every((x) => x.buffer === 0xbf00));
});

test('UG_NETENV: a value of 255 characters stays inside the buffer', () => {
  const r = netenv(with_(BOARD.RTL, { NET_MAC: 'A'.repeat(255) }));
  fails(r, E.ENV, V.MAC);
  assert.equal(r.mem.after[CTX + 255], 0, 'the 0 of the value');
  assert.equal(r.mem.after[CTX + 256], r.mem.before[CTX + 256], 'nothing past 256 bytes');
});

// ---- UG_NETVAR / UG_NETNAME / UG_NETFIX --------------------------------------
function cstr(m, a) { let s = ''; for (let c; (c = m.peek(a)) !== 0; a++) s += String.fromCharCode(c); return s; }

test('UG_NETVAR: the name of every variable', () => {
  const m = machine();
  const names = ['NET', 'NET_ESP_HW', 'NET_RTL_HW', 'NET_HW', 'NET_IDPORT', 'NET_IP', 'NET_MASK', 'NET_GW', 'NET_MAC', 'NET_BAUD', 'NET_ESP_FLOW'];
  names.forEach((n, i) => assert.equal(cstr(m, run(m, 'ugv_var', { a: i }).hl), n));
  assert.equal(names.length, V.FLOW + 1);
});

test('UG_NETNAME: the six delivery names, nothing for other cards', () => {
  const m = machine();
  const want = { [HW.ESP]: 'ESP', [HW.RTL]: 'RTL', [HW.EL3]: '509B' };
  const BUF = 0x9000;
  for (const [hw, tag] of Object.entries(want)) {
    for (const [tp, tname] of [[TCP, 'TCP'], [UDP, 'UDP']]) {
      m.pokeBytes(BUF, new Array(16).fill(0xee));
      m.poke(CFG + off('hw_profile'), +hw);
      m.poke(CFG + off('transport'), tp);
      const r = run(m, 'ugv_name', { d: BUF >> 8, e: BUF & 0xff });
      assert.equal(r.cf, 0);
      const name = cstr(m, BUF);
      assert.equal(name, `G${tname}${tag}.DLL`);
      assert.ok(name.length + 1 <= 13);
      assert.equal(r.de, BUF + name.length, 'DE at the 0');
      assert.equal(m.peek(BUF + 13), 0xee);
    }
  }
  for (const hw of [0, C.hw.LOOP, 5, 0xff]) {
    m.pokeBytes(BUF, new Array(16).fill(0xee));
    m.poke(CFG + off('hw_profile'), hw);
    assert.equal(run(m, 'ugv_name', { d: BUF >> 8, e: BUF & 0xff }).cf, 1, `hw ${hw}`);
    assert.equal(m.peek(BUF), 0xee, 'nothing written');
  }
});

test('UG_NETFIX: ring off on Ethernet, esp_fw and FIFO trigger on ESP', () => {
  const m = machine();
  const fix = (o) => {
    const b = encodeBlock('CFG', { hw_ring_ptr: 0x9700, hw_ring_len: 512, ...o });
    m.pokeBytes(CFG, b);
    run(m, 'ugv_fix');
    return decodeBlock('CFG', Uint8Array.from(m.peekBytes(CFG, b.length)));
  };
  for (const hw of [HW.RTL, HW.EL3]) {
    const c = fix({ hw_profile: hw, esp_fw: 0, uart_rx_trigger: 0 });
    assert.equal(c.hw_ring_ptr, 0);
    assert.equal(c.hw_ring_len, 0);
    assert.equal(c.esp_fw, 0);
    assert.equal(c.uart_rx_trigger, 0);
  }
  let c = fix({ hw_profile: HW.ESP, esp_fw: 0, uart_rx_trigger: 0 });
  assert.equal(c.hw_ring_ptr, 0x9700);
  assert.equal(c.hw_ring_len, 512);
  assert.equal(c.esp_fw, 1, 'commands without records');
  assert.equal(c.uart_rx_trigger, 8);
  c = fix({ hw_profile: HW.ESP, flags: C.cfgf.UDP_RECORDS, esp_fw: 0, uart_rx_trigger: 0 });
  assert.equal(c.esp_fw, 2, 'records: transparent mode');
  c = fix({ hw_profile: HW.ESP, flags: C.cfgf.UDP_RECORDS, esp_fw: 1, uart_rx_trigger: 14 });
  assert.equal(c.esp_fw, 1, 'the game\'s own choice stays');
  assert.equal(c.uart_rx_trigger, 14);
});

// ---- end to end: the filled block to the INIT_CONFIG of every card DLL -------
for (const dll of DLLS.filter((d) => d !== 'gloop')) {
  const card = dll.includes('esp') ? 'ESP' : dll.includes('rtl') ? 'RTL' : 'EL3';
  const tp = dll.startsWith('gtcp') ? TCP : UDP;
  for (const records of tp === UDP ? [false, true] : [false]) {
    test(`${dll}${records ? ' (UDP records)' : ''}: INIT_CONFIG accepts the block filled from the ${card} board environment`, () => {
      const s = new Stand({ dll, waits: false });
      assert.equal(s.call('INIT').a, 0);
      const L = s.layout();
      // the game's part: regions, timeouts, peer; card fields left as garbage
      const block = s.defaultConfig({
        hw_profile: 0, transport: 0, cpu_khz: 0, isa_slot: 0x77, io_base: 0xffff, id_port: 0xffff,
        mac: [1, 2, 3, 4, 5, 6], local_ip: '0.0.0.0', netmask: '0.0.0.0', gateway_ip: '0.0.0.0',
        uart_divisor: 0, uart_flow: 0, esp_flow: 0, esp_fw: 0, uart_rx_trigger: 0,
        hw_ring_ptr: L.ring, hw_ring_len: L.ringLen, flags: records ? C.cfgf.UDP_RECORDS : 0,
      });
      s.m.pokeBytes(ORG, BIN);
      s.m.pokeBytes(L.cfg, encodeBlock('CFG', block));
      const env = card === 'EL3' ? with_(BOARD.EL3, { NET_IDPORT: null }) : BOARD[card];
      const r = run(s.m, 'ugv_env', { a: tp, ix: L.cfg }, env);
      ok(r);
      run(s.m, 'ugv_fix', { ix: L.cfg });
      s.prepareGateway();
      const init = s.call('INIT_CONFIG', { ix: L.cfg });
      assert.equal(init.a, C.status.OK, `INIT_CONFIG ${init.a}`);
      assert.deepEqual(init.problems, []);
      const info = s.getInfo().info;
      assert.equal(info.hw_profile, HW[card]);
    });
  }
}
