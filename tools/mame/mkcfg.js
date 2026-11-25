#!/usr/bin/env node
// mkcfg.js -- memory map and INIT_CONFIG block of the M stand test programs
// (sdk/example/ugtest.asm, netdemo.asm) for one build, as an sjasmplus include.
// The block is encoded by the Z stand's own encoder (tools/harness), so
// both stands use the same field layout from abi/unetgame_abi.toml.
//
// Usage: node tools/mame/mkcfg.js [--prog ugtest|netdemo] <dll> <out.inc> [peer_ip] [peer_port] [local_port]
// The positional peer_ip/peer_port/local_port (run_m.py's call) are the
// same as --peer/--port/--local-port; named options also reach the fields
// run_m.py never varies (tools/hw/build_hw.sh, the Ж build, needs them for
// the real card's slot/IO base/ID port/UART trigger and LAN addresses).
// Every option defaults to today's M-stand value, so an M run's ugcfg.inc
// is unchanged when no option is given.
// --auto (NETDEMO V, the SDK auto-loader sdk/loader/ugnet.asm): the block
// is the game's form -- every card field empty (hw_profile, transport,
// cpu_khz, slot, base, ID port, addresses, UART fields, esp_fw -- with
// --esp-fw 2 the records flag alone asks for the transparent mode --, the
// FIFO trigger unless --trigger, no FLOW_VERIFIED), the UART
// ring set whatever the card -- and the macro UG_ENV_SET holds the DSS
// environment the bring-up tools would publish for this card and these
// values ("NAME=VALUE", 0 ... 0; the M program sets it with #46 B=2).
'use strict';
const fs = require('fs');
const { encodeBlock, ABI, C, PROFILE } = require('../harness/stand.js');

const argv = process.argv.slice(2);
function takeOpt(name) {
  const i = argv.indexOf(name);
  if (i < 0) return undefined;
  return argv.splice(i, 2)[1];
}
const prog = takeOpt('--prog') ?? 'ugtest';
const optLocalIp = takeOpt('--local-ip');
const optNetmask = takeOpt('--netmask');
const optGateway = takeOpt('--gateway');
const optSlot = takeOpt('--slot');
const optIoBase = takeOpt('--io-base');
const optIdPort = takeOpt('--id-port');
const optTrigger = takeOpt('--trigger');
const optEspFw = takeOpt('--esp-fw');           // 2: GUDPESP's transparent UDP (records)
// --records 0|1: UNETG_CFGF_UDP_RECORDS (docs/unet-game-abi.md); default on for
// the Ethernet UDP builds and the transparent mode, off elsewhere
const optRecords = takeOpt('--records');
const optLocalPort = takeOpt('--local-port');
const optPeer = takeOpt('--peer');
const optPort = takeOpt('--port');
const auto = argv.includes('--auto');
if (auto) argv.splice(argv.indexOf('--auto'), 1);
const [dll, out, peerIpPos = '127.0.0.1', peerPortPos = '7000', localPortPos = '7001'] = argv;
if (!dll || !out || !PROFILE[dll] || !['ugtest', 'netdemo'].includes(prog)) {
  console.error('usage: mkcfg.js [--prog ugtest|netdemo] <dll> <out.inc> [peer_ip] [peer_port] [local_port]');
  console.error('  or:  mkcfg.js [--prog p] [--local-ip ip] [--netmask m] [--gateway ip] [--slot n]');
  console.error('                [--io-base n] [--id-port n] [--trigger n] [--local-port n]');
  console.error('                [--esp-fw 1|2] [--records 0|1]');
  console.error('                [--peer ip] [--port n] <dll> <out.inc>');
  process.exit(2);
}
const peerIp = optPeer ?? peerIpPos;
const peerPort = optPort ?? peerPortPos;
const localPort = optLocalPort ?? localPortPos;
const prof = PROFILE[dll];
const udp = prof.transport === 'UDP';
const espFw = prof.hw === 'ESP' ? (optEspFw !== undefined ? +optEspFw : 1) : 0;
const records = optRecords !== undefined ? optRecords === '1' : udp && (prof.hw !== 'ESP' || espFw === 2);
if (records && (!udp || espFw === 1)) throw new Error('--records 1: UDP builds only, not the ESP command mode');

// WIN2 (0x8000..0xBFFF): the EXE code from 0x8100, then the regions of
// the library.  WIN1 holds the DLL page during l_call; WIN3 is the ISA
// window: nothing here may live at 0xC000 or above.
const slot = udp ? 512 : 536;
const UGTEST_MAP = {
  CODE_END: 0x9a00,
  CTX: 0x9a00, CTX_LEN: 0x300,
  TXS: 0x9d00, TX_N: 4,                         // UNETG_SLOTS_MIN = 4
  RXS: 0xa560, RX_N: 4,
  EVQ: 0xadc0, EV_N: 16,
  RING: 0xae40, RING_LEN: 512,
  GW: 0xb040, GW_LEN: 0x40,
  ISTK: 0xb080, ISTK_LEN: 0x100,
  REPORT: 0xb180, REPORT_LEN: 0x680,
  MSTK: 0xb800, MSTK_LEN: 0x7f0,
  SLOT: slot,
};
// NETDEMO.EXE (the SDK example): the gateway block (256-aligned) with the
// IM2 table and its default handler behind it, the network ISR stack.
// The code area ends at 0x9D00 (the UG_HW build with the latency scenario
// needs it); the main stack keeps 1008 bytes.
const NETDEMO_MAP = {
  CODE_END: 0x9d00,
  CTX: 0x9d00, CTX_LEN: 0x300,
  TXS: 0xa000, TX_N: 4,
  RXS: 0xa860, RX_N: 4,
  EVQ: 0xb0c0, EV_N: 16,
  RING: 0xb140, RING_LEN: 512,
  GW: 0xb400, GW_LEN: 0x300,                    // block 0x100, IM2 table 0x101, default stub at 0xB6B6
  ISTK: 0xb700, ISTK_LEN: 0x100,
  REPORT: 0xb800, REPORT_LEN: 0x400,
  MSTK: 0xbc00, MSTK_LEN: 0x3f0,
  SLOT: slot,
};
const M = prog === 'netdemo' ? NETDEMO_MAP : UGTEST_MAP;
if (M.CTX + M.CTX_LEN > M.TXS || M.TXS + M.TX_N * 536 > M.RXS || M.RXS + M.RX_N * 536 > M.EVQ || M.EVQ + M.EV_N * 8 > M.RING ||
    M.RING + M.RING_LEN > M.GW || M.GW + M.GW_LEN > M.ISTK || M.ISTK + M.ISTK_LEN > M.REPORT ||
    M.REPORT + M.REPORT_LEN > M.MSTK || M.MSTK + M.MSTK_LEN > 0xc000) throw new Error('regions overlap');

const cfg = {
  abi_version: ABI.abi_version, size: ABI.blocks.CFG.size,
  hw_profile: C.hw[prof.hw], transport: C.transport[prof.transport],
  mode: C.mode.POLL, flags: (prof.hw === 'ESP' ? C.cfgf.FLOW_VERIFIED : 0) | (records ? C.cfgf.UDP_RECORDS : 0),
  cpu_khz: 21000, timing_mode: C.timing.FIXED_SCHEDULE,
  isa_slot: optSlot !== undefined ? parseInt(optSlot, 0) : 1,   // -isa1 in MAME: latch #D6
  io_base: optIoBase !== undefined ? parseInt(optIoBase, 0) : ({ ESP: 0x3e8, RTL: 0x300, EL3: 0x300 }[prof.hw] ?? 0),
  id_port: optIdPort !== undefined ? parseInt(optIdPort, 0) : (prof.hw === 'EL3' ? 0x110 : 0),
  // ESP: the module owns the IP layer (the fields are unused); Ethernet:
  // the Sprinter end of the feth pair (tools/mame/net_feth.sh, host 192.168.7.1)
  local_ip: optLocalIp ?? (prof.hw === 'ESP' ? '192.168.0.10' : (process.env.MAME_NET_LOCAL || '192.168.7.21')),
  netmask: optNetmask ?? '255.255.255.0',
  gateway_ip: optGateway ?? (prof.hw === 'ESP' ? '192.168.0.1' : peerIp),
  peer_ip: peerIp, peer_port: +peerPort, local_port: +localPort,
  uart_divisor: prof.hw === 'ESP' ? 8 : 0, uart_flow: prof.hw === 'ESP' ? 1 : 0,
  esp_flow: prof.hw === 'ESP' ? 3 : 0, esp_fw: espFw,
  uart_rx_trigger: optTrigger !== undefined ? parseInt(optTrigger, 0) : (prof.hw === 'ESP' ? 8 : 0),
  connect_timeout_ms: 10000, retry_count: 4, retry_wait_ms: [500, 1000, 2000, 2000, 2000],
  send_stall_timeout_ms: 7500, close_timeout_ms: 3000, arp_ttl_ms: 60000,
  worst_poll_gap_us: 2000, worst_step_gap_ms: 20, step_budget_us: 1280, isr_budget_us: 370,
  time_read_cost_us: 20,
  ctx_ptr: M.CTX, ctx_len: M.CTX_LEN,
  tx_slots_ptr: M.TXS, tx_slot_size: slot, tx_slot_count: M.TX_N,
  rx_slot_count: M.RX_N, rx_slots_ptr: M.RXS, rx_slot_size: slot,
  event_ptr: M.EVQ, event_cap: M.EV_N,
  hw_ring_ptr: prof.hw === 'ESP' ? M.RING : 0, hw_ring_len: prof.hw === 'ESP' ? M.RING_LEN : 0,
  isa_lock_ptr: M.GW, shadow_1ffd_ptr: M.GW + 1, shadow_9fbd_ptr: M.GW + 2,
  gw_ptr: M.GW, gw_len: M.GW_LEN,
  main_stack_ptr: M.MSTK, main_stack_len: M.MSTK_LEN,
  isr_stack_ptr: M.ISTK, isr_stack_len: M.ISTK_LEN,
};
// ABI isa_slot is 0 or 1 (#E2 = #D4 / #D6, the Sprinter's own slot numbers);
// INIT_CONFIG answers BAD_CONFIG to anything else (the first Ж runs with
// HW_SLOT_EL3=2 did exactly that).
if (cfg.isa_slot !== 0 && cfg.isa_slot !== 1) throw new Error(`--slot ${optSlot}: the ISA slot is 0 or 1`);
const env = [];
let blockCfg = cfg;
if (auto) {
  const hs = (v) => '#' + v.toString(16).toUpperCase();
  env.push(`NET=${{ ESP: 'WIFI', RTL: 'RTL', EL3: '509B' }[prof.hw]}`);
  env.push(`${{ ESP: 'NET_ESP_HW', RTL: 'NET_RTL_HW', EL3: 'NET_HW' }[prof.hw]}=${cfg.isa_slot}/${hs(cfg.io_base)}`);
  if (prof.hw === 'EL3') env.push(`NET_IDPORT=${hs(cfg.id_port)}`);
  if (prof.hw === 'ESP') env.push('NET_BAUD=115200', 'NET_ESP_FLOW=3');
  else env.push(`NET_IP=${cfg.local_ip}`, `NET_MASK=${cfg.netmask}`, `NET_GW=${cfg.gateway_ip}`);
  blockCfg = {
    ...cfg, hw_profile: 0, transport: 0, cpu_khz: 0, isa_slot: 0, io_base: 0, id_port: 0,
    local_ip: '0.0.0.0', netmask: '0.0.0.0', gateway_ip: '0.0.0.0',
    uart_divisor: 0, uart_flow: 0, esp_flow: 0, esp_fw: 0,
    uart_rx_trigger: optTrigger !== undefined ? parseInt(optTrigger, 0) : 0,
    hw_ring_ptr: M.RING, hw_ring_len: M.RING_LEN, flags: cfg.flags & ~C.cfgf.FLOW_VERIFIED,
  };
}
const block = encodeBlock('CFG', blockCfg);
const hex = (v) => '0x' + v.toString(16).toUpperCase();
const lines = [`; generated by tools/mame/mkcfg.js --prog ${prog} ${dll} -- do not edit`];
for (const [k, v] of Object.entries(M)) lines.push(`UG_${k}\tEQU\t${hex(v)}`);
// UG_HWPFX: 5 static bytes for the Ж report file name (ughw.inc
// hw_build_fname appends the scenario letter + ".TXT" + 0 at runtime):
// prog letter (U ugtest, N netdemo) + card code (ESP/RTL/509) + transport
// letter (T/U) -- "UESPTS.TXT" for GTCPESP's UGTEST S, 8.3-safe.
const progLetter = prog === 'netdemo' ? 'N' : 'U';
const cardCode = { ESP: 'ESP', RTL: 'RTL', EL3: '509' }[prof.hw];
// (X: GUDPESP in its transparent mode, esp_fw = 2: "NESPXE.TXT")
const transLetter = cfg.esp_fw === 2 ? 'X' : udp ? 'U' : 'T';
// the card's ISA slot and I/O base for the program's own ISA accesses
// (NETUP's UART on ESP builds): the same values INIT_CONFIG carries
lines.push(`UG_ISA_SLOT\tEQU\t${cfg.isa_slot}`, `UG_IO_BASE\tEQU\t${hex(cfg.io_base)}`,
  `UG_ID_PORT\tEQU\t${hex(cfg.id_port)}`, `UG_CARD\tEQU\t'${{ ESP: 'E', RTL: 'R', EL3: '3' }[prof.hw] ?? 'L'}'`);
lines.push(`UG_UDP\tEQU\t${udp ? 1 : 0}`, `UG_ESP\tEQU\t${prof.hw === 'ESP' ? 1 : 0}`,
  `\tMACRO\tUG_DLLNAME`, `\tDB\t"${dll.toUpperCase()}.DLL", 0`, `\tENDM`,
  `\tMACRO\tUG_HWPFX`, `\tDB\t"${progLetter}${cardCode}${transLetter}"`, `\tENDM`,
  `UG_CFG_BYTES\tEQU\t${block.length}`, `\tMACRO\tUG_CFG_BLOCK`);
for (let i = 0; i < block.length; i += 16) lines.push('\tDB\t' + Array.from(block.slice(i, i + 16), hex).join(', '));
lines.push('\tENDM');
if (auto) {
  lines.push('\tMACRO\tUG_ENV_SET');
  for (const e of env) lines.push(`\tDB\t"${e}", 0`);
  lines.push('\tDB\t0', '\tENDM');
}
lines.push('');
fs.writeFileSync(out, lines.join('\n'));
