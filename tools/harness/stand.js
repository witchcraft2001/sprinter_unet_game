// stand.js -- load a built UNET-GAME DLL into the Machine and call exports.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const fs = require('fs');
const path = require('path');
const { Machine } = require('./machine.js');
const { parseL1, relocate, readSymbols } = require('./dll-loader.js');

const ROOT = path.resolve(__dirname, '..', '..');
const ABI = JSON.parse(fs.readFileSync(path.join(__dirname, 'abi.json'), 'utf8'));
const C = ABI.consts;
const TRAP = 0x0100;                       // return address of every call
const DLLS = ['gtcpesp', 'gudpesp', 'gtcprtl', 'gudprtl', 'gtcp509b', 'gudp509b', 'gloop'];
const PROFILE = {
  gtcpesp: { hw: 'ESP', transport: 'TCP' }, gudpesp: { hw: 'ESP', transport: 'UDP' },
  gtcprtl: { hw: 'RTL', transport: 'TCP' }, gudprtl: { hw: 'RTL', transport: 'UDP' },
  gtcp509b: { hw: 'EL3', transport: 'TCP' }, gudp509b: { hw: 'EL3', transport: 'UDP' },
  gloop: { hw: 'LOOP', transport: 'TCP' },
};

function ip(v) { return typeof v === 'string' ? v.split('.').map(Number) : v; }

// Encode a block (CFG, PEER, ...) from a plain object using abi.json.
function encodeBlock(name, values) {
  const b = ABI.blocks[name];
  const out = new Uint8Array(b.size);
  for (const [field, f] of Object.entries(b.fields)) {
    let v = values[field];
    if (v === undefined) continue;
    if (f.type === 'ip4') v = ip(v);
    const put = (off, size, x) => { for (let i = 0; i < size; i++) out[off + i] = (x >>> (8 * i)) & 0xff; };
    if (f.type === 'ip4' || f.type === 'mac6') { for (let i = 0; i < f.size; i++) out[f.offset + i] = v[i] ?? 0; continue; }
    if (f.count > 1) {
      const es = f.size / f.count;
      for (let i = 0; i < f.count; i++) put(f.offset + i * es, es, v[i] ?? 0);
      continue;
    }
    put(f.offset, f.size, v);
  }
  return out;
}

function decodeBlock(name, bytes) {
  const b = ABI.blocks[name];
  const r = {};
  for (const [field, f] of Object.entries(b.fields)) {
    if (f.offset + f.size > bytes.length) continue;
    const get = (off, size) => { let x = 0; for (let i = size - 1; i >= 0; i--) x = x * 256 + bytes[off + i]; return x; };
    if (f.type === 'ip4' || f.type === 'mac6') { r[field] = Array.from(bytes.slice(f.offset, f.offset + f.size)); continue; }
    if (f.count > 1) { const es = f.size / f.count; r[field] = []; for (let i = 0; i < f.count; i++) r[field].push(get(f.offset + i * es, es)); continue; }
    r[field] = get(f.offset, f.size);
  }
  return r;
}

class Stand {
  // opts: dll (name), window (1|2), offset (256-aligned inside the page), mhz, isaWaitT
  constructor(opts = {}) {
    this.name = opts.dll || 'gloop';
    this.profile = PROFILE[this.name];
    this.m = new Machine({ mhz: opts.mhz, isaWaitT: opts.isaWaitT });
    const bytes = fs.readFileSync(path.join(ROOT, 'build', `${this.name.toUpperCase()}.DLL`));
    this.l1 = parseL1(bytes);
    this.syms = readSymbols(path.join(ROOT, 'build', `${this.name}.sym`));
    this.window = opts.window ?? 1;
    this.base = this.window * 0x4000 + (opts.offset ?? 0);
    this.m.win[this.window] = 8 + this.window;   // dedicated physical page for the DLL
    const img = relocate(this.l1, this.base);
    this.m.pokeBytes(this.base, img);
    const ctxPtr = this.sym('IMG_CTX_PTR');
    this.m.image = { start: this.base + 0x20, end: this.base + this.l1.codeSize, mutable: new Set([ctxPtr, ctxPtr + 1]) };
    // Application memory lives in the other data window.
    this.data = this.window === 1 ? 0x8000 : 0x4000;
    this.calls = [];
  }

  // Cycle profile by enclosing global label (debug aid).
  profileHook() {
    if (!Stand.equNames) {
      const names = new Set();
      const walk = (dir) => { for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) walk(p); else if (/\.(inc|asm|INC)$/.test(e.name)) {
          for (const line of fs.readFileSync(p, 'utf8').split('\n')) { const m = line.match(/^([A-Za-z_][\w]*)\s+EQU\b/); if (m) names.add(m[1]); }
        } } };
      walk(path.join(ROOT, 'include')); walk(path.join(ROOT, 'src'));
      Stand.equNames = names;
    }
    const labels = Object.entries(this.syms).filter(([k]) => !k.includes('.') && /^[A-Z]/.test(k) && !Stand.equNames.has(k))
      .map(([k, v]) => [this.base + 0x20 + v, k]).sort((a, b) => a[0] - b[0]);
    const acc = {};
    let lastPc = null, lastCyc = this.m.cycles;
    const owner = (pc) => { let lo = 0, hi = labels.length - 1, best = '?'; while (lo <= hi) { const mid = (lo + hi) >> 1; if (labels[mid][0] <= pc) { best = labels[mid][1]; lo = mid + 1; } else hi = mid - 1; } return best; };
    return {
      hook: (m, s) => { if (lastPc !== null) { const k = owner(lastPc); acc[k] = (acc[k] || 0) + (m.cycles - lastCyc); } lastPc = s.pc; lastCyc = m.cycles; },
      result: () => Object.entries(acc).sort((a, b) => b[1] - a[1]).map(([k, v]) => [k, +(v / this.m.mhz).toFixed(1)]),
    };
  }

  // Inclusive time of calls to the given labels: {label: [us per call]}.
  inclusiveHook(labels) {
    const entries = new Map(labels.map((l) => [this.sym(l), l]));
    const open = [], res = {};
    return {
      hook: (m, st) => {
        for (let i = open.length - 1; i >= 0; i--) {
          const o = open[i];
          if (st.pc === o.ret && st.sp === o.sp + 2) { (res[o.label] ||= []).push(+((m.cycles - o.c) / m.mhz).toFixed(1)); open.splice(i, 1); }
        }
        const l = entries.get(st.pc);
        if (l) open.push({ label: l, sp: st.sp, ret: m.peek16(st.sp), c: m.cycles });
      },
      result: () => res,
    };
  }

  sym(label) {
    if (!(label in this.syms)) throw new Error(`symbol ${label} not found`);
    return this.base + 0x20 + this.syms[label];
  }
  entry(exportName) { return this.base + 0x20 + 3 * ABI.exports[exportName]; }

  // Default, valid INIT_CONFIG for this profile and memory layout.
  layout() {
    const d = this.data;
    return {
      ctx: d + 0x0000, ctxLen: 0x300,
      tx: d + 0x0400, rx: d + 0x0d00, slotSize: 536, slots: 4,
      ev: d + 0x1600, evCap: 16,
      ring: d + 0x1700, ringLen: 512,
      lock: d + 0x1a00, sh1ffd: d + 0x1a01, sh9fbd: d + 0x1a02,
      gw: d + 0x1a00, gwLen: 0x100,
      istack: d + 0x1c00, istackLen: 0x100,
      mstack: 0x3800, mstackLen: 0x07f0,          // SP starts at 0x3FF0 in WIN0
      cfg: 0x2000, buf: 0x2800,
    };
  }

  defaultConfig(over = {}) {
    const L = this.layout();
    const hw = this.profile.hw;
    const cfg = {
      abi_version: ABI.abi_version, size: ABI.blocks.CFG.size,
      hw_profile: C.hw[hw], transport: C.transport[this.profile.transport],
      mode: C.mode.POLL, flags: 0, cpu_khz: 21000, timing_mode: C.timing.FIXED_SCHEDULE,
      isa_slot: 0, io_base: { ESP: 0x3e8, RTL: 0x300, EL3: 0x300, LOOP: 0 }[hw],
      id_port: hw === 'EL3' ? 0x110 : 0,
      local_ip: '192.168.0.10', netmask: '255.255.255.0', gateway_ip: '192.168.0.1',
      peer_ip: '192.168.0.2', peer_port: 7000, local_port: 7001,
      uart_divisor: hw === 'ESP' ? 8 : 0, uart_flow: hw === 'ESP' ? 1 : 0,
      esp_flow: hw === 'ESP' ? 3 : 0, esp_fw: hw === 'ESP' ? 1 : 0,
      uart_rx_trigger: hw === 'ESP' ? 8 : 0,
      connect_timeout_ms: 5000, retry_count: 4, retry_wait_ms: [500, 1000, 2000, 2000, 2000],
      send_stall_timeout_ms: 7500, close_timeout_ms: 2000, arp_ttl_ms: 60000,
      worst_poll_gap_us: 2000, worst_step_gap_ms: 20, step_budget_us: hw === 'RTL' || hw === 'EL3' ? 500 : 400, isr_budget_us: hw === 'RTL' || hw === 'EL3' ? 150 : 100,
      time_read_cost_us: 20,
      ctx_ptr: L.ctx, ctx_len: L.ctxLen,
      tx_slots_ptr: L.tx, tx_slot_size: L.slotSize, tx_slot_count: L.slots,
      rx_slot_count: L.slots, rx_slots_ptr: L.rx, rx_slot_size: L.slotSize,
      event_ptr: L.ev, event_cap: L.evCap,
      hw_ring_ptr: hw === 'ESP' ? L.ring : 0, hw_ring_len: hw === 'ESP' ? L.ringLen : 0,
      isa_lock_ptr: L.lock, shadow_1ffd_ptr: L.sh1ffd, shadow_9fbd_ptr: L.sh9fbd,
      gw_ptr: L.gw, gw_len: L.gwLen,
      main_stack_ptr: L.mstack, main_stack_len: L.mstackLen,
      isr_stack_ptr: L.istack, isr_stack_len: L.istackLen,
    };
    if (hw === 'ESP') cfg.flags |= C.cfgf.FLOW_VERIFIED;
    if (this.profile.transport === 'UDP') { cfg.tx_slot_size = 512; cfg.rx_slot_size = 512; }
    return Object.assign(cfg, over);
  }

  // Call an export.  regs: {a, bc, de, hl, ix, iy, f}.  Returns registers and
  // metrics; records invariant failures in result.problems.
  call(exportName, regs = {}, opts = {}) {
    const m = this.m;
    const before = m.regs();
    const entrySp = opts.sp ?? 0x3ff0;
    const ix = regs.ix ?? 0x1234, iy = regs.iy ?? 0x5678;
    const patch = {
      a: regs.a ?? 0, b: ((regs.bc ?? 0) >> 8) & 0xff, c: (regs.bc ?? 0) & 0xff,
      d: ((regs.de ?? 0) >> 8) & 0xff, e: (regs.de ?? 0) & 0xff,
      h: ((regs.hl ?? 0) >> 8) & 0xff, l: (regs.hl ?? 0) & 0xff,
      ix, iy, sp: entrySp - 2, pc: this.entry(exportName),
      iff1: opts.iff ?? 1, iff2: opts.iff ?? 1, halted: false,
    };
    m.poke16(entrySp - 2, TRAP);
    m.setRegs(patch);
    const v0 = m.violations.length;
    const page3 = m.win[3], p1ffd = m.port1ffd, p9fbd = m.port9fbd;
    const prof = opts.profile ? this.profileHook() : null;
    const incl = opts.inclusive ? this.inclusiveHook(opts.inclusive) : null;
    const user = opts.onStep;
    const hook = (prof || incl || user) && ((mm, st) => { if (prof) prof.hook(mm, st); if (incl) incl.hook(mm, st); if (user) user(mm, st); });
    const r = m.runUntil(TRAP, { isr: !!opts.isr, onStep: hook });
    if (prof) this.lastProfile = prof.result();
    if (incl) this.lastInclusive = incl.result();
    const s = m.regs();
    const res = {
      a: s.a, cf: s.flags.C, de: (s.d << 8) | s.e, hl: (s.h << 8) | s.l, bc: (s.b << 8) | s.c,
      ix: s.ix, iy: s.iy, iff1: s.iff1, ...r, stack: entrySp - r.minSp,
      violations: m.violations.slice(v0), problems: [],
    };
    const P = res.problems;
    if (exportName !== 'INIT' && exportName !== 'FINI') {
      if (s.ix !== ix) P.push(`IX not preserved (0x${s.ix.toString(16)})`);
      if (s.iy !== iy) P.push(`IY not preserved (0x${s.iy.toString(16)})`);
    }
    if (s.sp !== entrySp) P.push(`SP 0x${s.sp.toString(16)} != 0x${entrySp.toString(16)} after return`);
    if (s.iff1 !== patch.iff1) P.push(`IFF changed ${patch.iff1} -> ${s.iff1}`);
    if (m.win[3] !== page3) P.push('window 3 page not restored');
    if (m.port1ffd !== p1ffd) P.push(`#1FFD 0x${m.port1ffd.toString(16)} not restored`);
    if (m.port9fbd !== p9fbd) P.push(`#9FBD 0x${m.port9fbd.toString(16)} not restored`);
    const isr = !!opts.isr;
    const stackMax = isr ? ABI.consts.limits.STACK_ISR_MAX : ABI.consts.limits.STACK_MAIN_MAX;
    if (res.stack > stackMax) P.push(`stack ${res.stack} > ${stackMax}`);
    if (res.maxDiUs > 200) P.push(`DI section ${res.maxDiUs.toFixed(1)} us > 200`);
    if (exportName === 'STEP' || exportName === 'STEP_ISR') {
      const budget = regs.de ?? 0;
      const cap = exportName === 'STEP' ? 500 : 150;
      if (res.a !== C.status.STATE && res.a !== C.status.BAD_ARGUMENT && res.us > Math.min(budget, cap) + (opts.slackUs ?? 0)) {
        P.push(`${exportName} took ${res.us.toFixed(0)} us, budget ${budget}`);
      }
    }
    for (const v of res.violations) P.push(`${v.kind}: ${v.detail} at PC=0x${v.pc.toString(16)}`);
    this.calls.push({ name: exportName, us: res.us, stack: res.stack });
    return res;
  }

  // What the gateway owns and must prepare before INIT_CONFIG: a free ISA
  // lock byte and the real values of the write-only ports in their shadows.
  prepareGateway() {
    const L = this.layout();
    this.m.poke(L.lock, 0);
    this.m.poke(L.sh1ffd, this.m.port1ffd);
    this.m.poke(L.sh9fbd, this.m.port9fbd);
  }

  initConfig(cfg) {
    const L = this.layout();
    if (!this.gatewayReady) { this.prepareGateway(); this.gatewayReady = true; }
    const bytes = cfg instanceof Uint8Array ? cfg : encodeBlock('CFG', cfg);
    this.m.pokeBytes(L.cfg, bytes);
    return this.call('INIT_CONFIG', { ix: L.cfg });
  }

  getInfo(size = ABI.blocks.INFO.size) {
    const L = this.layout();
    for (let i = 0; i < 128; i++) this.m.poke(L.buf + i, 0xee);
    const r = this.call('GET_INFO', { ix: L.buf, de: size });
    r.info = decodeBlock('INFO', Uint8Array.from(this.m.peekBytes(L.buf, size)));
    r.raw = this.m.peekBytes(L.buf, 128);
    return r;
  }

  // ---- convenience wrappers -------------------------------------------------
  step(now, budget = 260, preacq = 0, opts = {}) {
    const r = this.call('STEP', { de: budget, ix: now & 0xffff, iy: (now >>> 16) & 0xffff, a: preacq }, opts);
    r.deadline = r.de;
    r.flags = r.hl & 0xff;
    return r;
  }
  stepIsr(source, budget = 150, preacq = false) {
    const r = this.call('STEP_ISR', { a: source | (preacq ? 0x80 : 0), de: budget }, { iff: 0, isr: true });
    r.flags = r.hl & 0xff;
    return r;
  }
  open(peer) {
    if (!peer) return this.call('OPEN', { ix: 0 });
    const L = this.layout();
    this.m.pokeBytes(L.buf, encodeBlock('PEER', peer));
    return this.call('OPEN', { ix: L.buf });
  }
  nextEvent() {
    const L = this.layout();
    const r = this.call('NEXT_EVENT', { ix: L.buf + 0x40 });
    if (r.a !== C.status.OK) return { status: r.a, r };
    const ev = decodeBlock('EVT', Uint8Array.from(this.m.peekBytes(L.buf + 0x40, 8)));
    const name = Object.entries(C.ev).find(([, v]) => v === ev.type)?.[0];
    return { status: r.a, r, ev: { ...ev, name } };
  }
  events() {
    const out = [];
    for (;;) { const e = this.nextEvent(); if (e.status !== C.status.OK) break; out.push(e.ev); }
    return out;
  }
  // Reserve, fill and commit one TX slot.  Returns {res, commit, slot}.
  send(bytes, tag, reserve = bytes.length) {
    const res = this.call('TX_RESERVE', { de: reserve });
    if (res.a !== C.status.OK) return { res };
    const slot = res.de & 0xff;
    this.m.pokeBytes(res.hl, bytes);
    const commit = this.call('TX_COMMIT', { a: slot, de: bytes.length, ix: tag });
    return { res, commit, slot };
  }
  // Drain RX with PEEK/RELEASE.  Returns {bytes, chunks}.
  drain(max = 64) {
    const bytes = [], chunks = [];
    for (let i = 0; i < max; i++) {
      const p = this.call('RX_PEEK');
      if (p.a !== C.status.OK) break;
      const again = this.call('RX_PEEK');
      if (again.hl !== p.hl || again.de !== p.de) throw new Error('repeated RX_PEEK returned a different region');
      const data = this.m.peekBytes(p.hl, p.de);
      bytes.push(...data);
      chunks.push(data.length);
      const rel = this.call('RX_RELEASE');
      if (rel.a !== C.status.OK) throw new Error(`RX_RELEASE ${rel.a}`);
    }
    return { bytes, chunks };
  }
  ctx(field) {
    const f = ABI.ctx.fields[field];
    const base = this.layout().ctx + f.offset;
    return f.size === 1 ? this.m.peek(base) : f.size === 2 ? this.m.peek16(base) : this.m.peekBytes(base, f.size);
  }

  getStats(size = ABI.blocks.STATS.size) {
    const L = this.layout();
    for (let i = 0; i < 128; i++) this.m.poke(L.buf + i, 0xee);
    const r = this.call('GET_STATS', { ix: L.buf, de: size });
    r.stats = decodeBlock('STATS', Uint8Array.from(this.m.peekBytes(L.buf, size)));
    r.raw = this.m.peekBytes(L.buf, 128);
    return r;
  }
}

module.exports = { Stand, ABI, C, DLLS, PROFILE, encodeBlock, decodeBlock, TRAP };
