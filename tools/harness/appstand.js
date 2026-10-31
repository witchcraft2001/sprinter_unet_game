// appstand.js -- the Z application stand: the real SDK (tests/z/sdk/ugz.asm
// with sdk/gateway, sdk/time) around a real DLL, with interrupts.
// SPDX-License-Identifier: BSD-3-Clause
//
// On top of stand.js / ethnet.js (DLL in WIN1, card model, peer):
//   * the program runs freely; virtual time is m.cycles (21 MHz);
//   * IM2 interrupts: the CTC model (tick on CTC1), the FPGA frame pulse
//     (vector #FF, a pulse of `frameUs` that is lost while IFF1 = 0, as in
//     MAME), injected key / CBL / card vectors; Z84C15 daisy chain order
//     CTC > injected > frame, an acknowledged device blocks lower ones
//     until its RETI;
//   * a sound owner that takes the ISA lock (3) in given windows;
//   * a tracker of every direct export call with the invariants of
//     Stand.call (body time excluding interrupts against the budget, stack,
//     IX/IY/IFF/pages/#1FFD/#9FBD restored, lock state), every ISR path
//     (acknowledge -> RETI), every DI section, PIO writes (forbidden for the
//     SDK) and the gateway's own paths (UG_STEP, UG_ISR_NET) against the
//     costs it debits.
// The program idles at UGZ_WAIT: the stand then skips the clock to the next
// interrupt request (nothing else can happen there).
'use strict';

const fs = require('fs');
const path = require('path');
const { ethStand, C } = require('./ethnet.js');
const { readSymbols } = require('./dll-loader.js');
const { Ctc } = require('./devices/ctc.js');
const { ABI, encodeBlock, decodeBlock } = require('./stand.js');

const ROOT = path.resolve(__dirname, '..', '..');
const PROG_BASE = 0xa000;
const CFG = 0x2000, PROFILE = 0x2100, BUF = 0x2800;
const FRAME_COUNTS = 17920;                 // 20.48 ms at 875 kHz
const OPCODES = { 0xd9: 'EXX', 0x08: "EX AF,AF'", 0xcf: 'RST #08', 0xd7: 'RST #10', 0xf7: 'RST #30', 0xff: 'RST #38', 0x76: 'HALT' };

// Gateway block layout (sdk/gateway/ugate.inc), parsed from the include so
// the two never disagree.
function ugateConsts() {
  const out = {};
  const text = fs.readFileSync(path.join(ROOT, 'sdk/gateway/ugate.inc'), 'utf8');
  for (const line of text.split('\n')) {
    const m = line.match(/^(UG[A-Z0-9_]+)\s+EQU\s+([0-9A-Fa-fx]+)\b/);
    if (m) out[m[1]] = Number(m[2]);
  }
  return out;
}
const UG = ugateConsts();

const PROFILE_FIELDS = [
  ['tick_us', 2], ['tick_frac', 1], ['period_ticks', 1], ['poll_ticks', 1], ['steps', 1], ['step_gap_ms', 1],
  ['card_n', 1], ['step_budget', 2], ['isr_budget', 2], ['q_service', 2], ['target', 2], ['other_isr', 2],
  ['flags', 1], ['mode', 1], ['timing', 1],
];
function encodeProfile(p) {
  const out = [];
  for (const [k, n] of PROFILE_FIELDS) { const v = p[k] ?? 0; out.push(v & 255); if (n === 2) out.push((v >> 8) & 255); }
  if (out.length !== UG.UGP_BYTES) throw new Error('profile layout differs from ugate.inc');
  return out;
}
// CTC1 timer /256 at 21 MHz: constant 164 = 41 984 T = 1999.238 us.
function tickProfile(constant = 164, mhz = 21) {
  const us = (256 * constant) / mhz;
  const whole = Math.floor(us);
  return { tick_us: whole, tick_frac: Math.round((us - whole) * 256) & 255, us };
}
const DEFAULT_PROFILE = {
  ...tickProfile(), period_ticks: 10, poll_ticks: 1, steps: 2, step_gap_ms: 20, card_n: 0,
  step_budget: 0, isr_budget: 0, q_service: 100, target: 2000, other_isr: 0,
  flags: UG.UGPF_RELAXED, mode: C.mode.POLL, timing: C.timing.FIXED_SCHEDULE,
};

class AppStand {
  // opts: dll, card, peer (model options), frameUs (pulse width, default 9),
  // frameLatched, t0 (now_ms at start, default 1000)
  constructor(opts = {}) {
    this.s = ethStand({ dll: opts.dll || 'gloop', card: opts.card, peer: opts.peer });
    this.m = this.s.m;
    this.dll = this.s.name;
    this.isLoop = this.dll === 'gloop';
    this.syms = readSymbols(path.join(ROOT, 'build', 'ugz.sym'));
    this.m.pokeBytes(PROG_BASE, fs.readFileSync(path.join(ROOT, 'build', 'ugz.bin')));
    this.ctc = new Ctc(this.m);
    this.frameCycles = (FRAME_COUNTS * this.m.mhz * 1e6) / this.ctc.clkHz;
    this.frameWidth = (opts.frameUs ?? 9) * this.m.mhz;
    this.frameLatched = !!opts.frameLatched;
    this.frameOn = opts.frame !== false;
    this.framesAcked = 0; this.framesLost = 0; this.frameLastK = -1;
    this.injected = [];                     // { vector, prio, at }
    this.inService = [];                    // priorities of acknowledged devices
    this.sound = [];                        // { from, to } cycles: lock byte 3
    this.soundHeld = false;
    this.pio = []; this.io = [];
    this.problems = [];
    this.t0 = opts.t0 ?? 1000;
    this.L = this.s.layout();
    this.m.ioHook = (dir, port, v) => this.ioHook(dir, port, v);
    this.exportAt = new Map(Object.entries(ABI.exports).map(([n, i]) => [this.s.base + 0x20 + 3 * i, n]));
    this.calls = [];                        // open export calls
    this.done = { STEP: [], STEP_ISR: [] };  // finished: { us, budget, stack, depth }
    this.isrs = [];                         // open ISRs
    this.isrPaths = [];                     // { vector, us, core }
    this.isrCycles = 0;                     // cycles spent inside interrupt handlers
    this.diStart = null; this.maxDiUs = 0;
    this.gw = { UG_STEP: [], UG_ISR_NET: [] };
    this.gwOpen = [];
    this.gwEntry = new Map([[this.sym('UG_STEP'), 'UG_STEP'], [this.sym('UG_ISR_NET'), 'UG_ISR_NET']]);
    this.retiAt = new Set();
    this.nextPump = 0;
    this.hooks = new Map();                 // pc -> fn(state) before the instruction
    this.evTail = 0;
    const st = this.m.cpu.getState();
    st.pc = this.sym('ugz_start'); st.iff1 = 0; st.iff2 = 0;
    this.m.cpu.setState(st);
    this.runTo(() => this.pc() === this.sym('UGZ_LOOP'), 100000);
  }

  onPc(name, fn) { this.hooks.set(typeof name === 'number' ? name : this.sym(name), fn); }
  sym(name) { if (!(name in this.syms)) throw new Error(`ugz symbol ${name}`); return this.syms[name]; }
  pc() { return this.m.cpu.getState().pc; }
  us() { return this.m.cycles / this.m.mhz; }
  ms() { return this.us() / 1000; }

  // ---- ports outside the core ---------------------------------------------------
  ioHook(dir, port, v) {
    const low = port & 0xff;
    if (low >= 0x10 && low <= 0x13) {
      if (dir === 'out') { this.ctc.write(low, v); return undefined; }
      return this.ctc.read(low);
    }
    if (low >= 0x1c && low <= 0x1f) {
      if (dir === 'out') { this.pio.push({ port, v }); this.problems.push(`PIO port 0x${port.toString(16)} written (the SDK never owns the PIO)`); }
      return 0xff;
    }
    this.io.push({ dir, port, v });
    return 0xff;
  }

  // ---- interrupt sources --------------------------------------------------------
  inject(vector, atUs = this.us(), prio = 4) { this.injected.push({ vector, prio, at: atUs * this.m.mhz }); }
  soundWindow(fromUs, toUs) { this.sound.push({ from: fromUs * this.m.mhz, to: toUs * this.m.mhz }); }
  blocked(prio) { return this.inService.length > 0 && Math.min(...this.inService) <= prio; }
  pick() {
    const now = this.m.cycles;
    const c = this.ctc.pending(now);
    if (c && !this.blocked(c.i)) return { vector: this.ctc.vector(c), prio: c.i, ack: () => this.ctc.ack(c) };
    for (let i = 0; i < this.injected.length; i++) {
      const j = this.injected[i];
      if (j.at <= now && !this.blocked(j.prio)) return { vector: j.vector, prio: j.prio, ack: () => this.injected.splice(i, 1) };
    }
    if (this.frameOn) {
      const k = Math.floor(now / this.frameCycles);
      const inPulse = now - k * this.frameCycles < this.frameWidth;
      if (k > this.frameLastK && (inPulse || this.frameLatched) && !this.blocked(9)) {
        return { vector: 0xff, prio: 9, ack: () => { this.framesLost += k - this.frameLastK - 1; this.frameLastK = k; this.framesAcked++; } };
      }
    }
    return null;
  }
  nextRequest() {
    let t = this.ctc.nextRequest();
    for (const j of this.injected) t = Math.min(t, Math.max(j.at, this.m.cycles));
    if (this.frameOn) t = Math.min(t, (Math.floor(this.m.cycles / this.frameCycles) + 1) * this.frameCycles);
    for (const w of this.sound) { if (w.from > this.m.cycles) t = Math.min(t, w.from); if (w.to > this.m.cycles) t = Math.min(t, w.to); }
    return t;
  }

  // ---- models ----------------------------------------------------------------------
  pump() {
    const ms = this.t0 + this.ms();
    if (this.s.isEsp) this.s.card.advance(ms);
    else { this.s.peer.tick(ms); for (const f of this.s.peer.out.splice(0)) this.s.card.deliver(f); }
    if (this.s.isEsp && this.s.card.errors.length) this.problems.push(...this.s.card.errors.splice(0).map((e) => `esp model: ${e}`));
  }
  soundStep() {
    const now = this.m.cycles, lock = this.L.lock;
    const want = this.sound.some((w) => now >= w.from && now < w.to);
    if (want && !this.soundHeld && this.m.peek(lock) === 0) { this.m.poke(lock, C.lock.SOUND); this.soundHeld = true; }
    else if (!want && this.soundHeld) { this.m.poke(lock, 0); this.soundHeld = false; }
  }

  // ---- the run loop ----------------------------------------------------------------
  runTo(stop, maxCycles = 50_000_000) {
    const m = this.m, cpu = m.cpu, limit = m.cycles + maxCycles;
    const WAIT = this.sym('UGZ_WAIT'), MB_CMD = this.sym('mb_cmd'), IRQS = this.sym('mb_irqs'), SEEN = this.sym('mb_seen');
    for (;;) {
      let s = cpu.getState();
      if (stop(s)) return true;
      if (m.cycles >= limit) return false;
      // idle: the wait loop would only spin until the next request
      if (s.pc === WAIT && s.iff1 && m.peek(MB_CMD) === 0 && m.peek(IRQS) === m.peek(SEEN) && !this.pick()) {
        const t = Math.min(this.nextRequest(), limit);
        if (t > m.cycles) m.cycles = Math.ceil(t);
        this.pump();
        this.soundStep();
        continue;
      }
      if (m.cycles >= this.nextPump) { this.pump(); this.nextPump = m.cycles + 100 * m.mhz; }
      if (this.sound.length) this.soundStep();
      if (s.iff1) {
        const r = this.pick();
        if (r) {
          r.ack();
          cpu.interrupt(false, r.vector);
          this.inService.push(r.prio);
          this.isrs.push({ vector: r.vector, c0: m.cycles, core: false, sp: s.sp });
          s = cpu.getState();
        }
      }
      this.track(s);
      const hook = this.hooks.get(s.pc);
      if (hook) hook(s);
      if (m.image && s.pc >= m.image.start && s.pc < m.image.end) {
        const op = m.peek(s.pc);
        if (op in OPCODES) m.violation('opcode', OPCODES[op]);
        if (op === 0xfb && this.isrs.length) m.violation('ei-in-isr', 'EI inside the network ISR path');
      }
      const reti = m.peek(s.pc) === 0xed && m.peek(s.pc + 1) === 0x4d;
      m.extraCycles = 0;
      const t = cpu.run_instruction();
      m.cycles += t + m.extraCycles;
      if (this.isrs.length) this.isrCycles += t + m.extraCycles;
      const n = cpu.getState();
      for (const c of this.calls) if (this.isrs.length === c.depth && n.sp < c.minSp) c.minSp = n.sp;
      if (!n.iff1 && this.diStart === null && this.armed) this.diStart = m.cycles - t;
      if (n.iff1 && this.diStart !== null) {
        const us = (m.cycles - this.diStart) / m.mhz;
        if (us > this.maxDiUs) this.maxDiUs = us;
        if (us > 200) this.problems.push(`DI section ${us.toFixed(1)} us > 200 ending at PC=0x${n.pc.toString(16)}`);
        this.diStart = null;
      }
      if (reti && this.isrs.length) {
        const i = this.isrs.pop();
        this.inService.pop();
        this.isrPaths.push({ vector: i.vector, us: (m.cycles - i.c0) / m.mhz, core: i.core });
      }
      if (m.violations.length) {
        for (const v of m.violations.splice(0)) this.problems.push(`${v.kind}: ${v.detail} at PC=0x${v.pc.toString(16)}`);
      }
    }
  }

  // Export calls and the gateway's own routines (before the instruction at s.pc).
  track(s) {
    const m = this.m;
    for (let i = this.calls.length - 1; i >= 0; i--) {
      const c = this.calls[i];
      if (s.pc === c.ret && s.sp === c.sp + 2 && this.isrs.length === c.depth) { this.calls.splice(i, 1); this.closeCall(c, s); }
    }
    for (let i = this.gwOpen.length - 1; i >= 0; i--) {
      const g = this.gwOpen[i];
      if (s.pc === g.ret && s.sp === g.sp + 2 && this.isrs.length === g.depth) { this.gwOpen.splice(i, 1); this.closeGw(g); }
    }
    const name = this.exportAt.get(s.pc);
    if (name) {
      const c = {
        name, sp: s.sp, ret: m.peek16(s.sp), depth: this.isrs.length, c0: m.cycles, i0: this.isrCycles,
        ix: s.ix, iy: s.iy, iff1: s.iff1, page3: m.win[3], p1ffd: m.port1ffd, p9fbd: m.port9fbd,
        de: (s.d << 8) | s.e, a: s.a, minSp: s.sp,
      };
      this.calls.push(c);
      if (this.isrs.length && (name === 'STEP_ISR')) this.isrs[this.isrs.length - 1].core = true;
      for (const g of this.gwOpen) g.core = true;
    }
    const gw = this.gwEntry.get(s.pc);
    if (gw) this.gwOpen.push({ name: gw, sp: s.sp, ret: m.peek16(s.sp), depth: this.isrs.length, c0: m.cycles, i0: this.isrCycles, core: false, coreUs: 0, stats: this.stats() });
  }
  closeCall(c, s) {
    const m = this.m, P = this.problems;
    const own = c.depth > 0 ? m.cycles - c.c0 : (m.cycles - c.c0) - (this.isrCycles - c.i0);
    const us = own / m.mhz;
    const stack = c.sp + 2 - c.minSp;
    const where = `${c.name}@${(this.us() / 1000).toFixed(1)}ms`;
    if (!['INIT', 'FINI'].includes(c.name)) {
      if (s.ix !== c.ix) P.push(`${where}: IX not preserved`);
      if (s.iy !== c.iy) P.push(`${where}: IY not preserved`);
    }
    if (s.iff1 !== c.iff1) P.push(`${where}: IFF changed ${c.iff1} -> ${s.iff1}`);
    if (m.win[3] !== c.page3) P.push(`${where}: window 3 page not restored`);
    if (m.port1ffd !== c.p1ffd || m.port9fbd !== c.p9fbd) P.push(`${where}: #1FFD/#9FBD not restored`);
    const max = c.depth > 0 ? ABI.consts.limits.STACK_ISR_MAX : ABI.consts.limits.STACK_MAIN_MAX;
    if (stack > max) P.push(`${where}: stack ${stack} > ${max}`);
    const lock = m.peek(this.L.lock);
    if (c.depth === 0 && (lock === C.lock.NET_MAIN || lock === C.lock.NET_ISR)) P.push(`${where}: lock byte ${lock} left held`);
    for (const g of this.gwOpen) if (g.depth === c.depth) g.coreUs += us;
    if (c.name === 'STEP' || c.name === 'STEP_ISR') {
      const cap = c.name === 'STEP' ? 500 : 150;
      const st = s.a;
      if (st !== C.status.STATE && st !== C.status.BAD_ARGUMENT && us > Math.min(c.de, cap)) P.push(`${where}: took ${us.toFixed(0)} us, budget ${c.de}`);
      this.done[c.name].push({ us, budget: c.de, stack, status: st, nested: c.depth === 0 && this.isrCycles !== c.i0, at: this.us() });
    }
  }
  closeGw(g) {
    const m = this.m;
    const own = g.depth > 0 ? m.cycles - g.c0 : (m.cycles - g.c0) - (this.isrCycles - g.i0);
    const after = this.stats();
    const d = (k) => after[k] - g.stats[k];
    let kind = 'other';
    if (g.name === 'UG_STEP') kind = d('step') ? 'admitted' : d('refuse') ? 'refused' : d('early') ? 'early' : 'off';
    else kind = g.core ? 'admitted' : d('busy') ? 'busy' : d('refuse') ? 'refused' : 'skip';
    this.gw[g.name].push({ us: own / m.mhz, kind, core: g.core, ovh: own / m.mhz - g.coreUs, at: this.us() });
  }

  // ---- mailbox -------------------------------------------------------------------
  cmd(n, r = {}) {
    const m = this.m;
    m.poke(this.sym('mb_a'), r.a ?? 0);
    m.poke(this.sym('mb_b'), r.b ?? 0);
    m.poke16(this.sym('mb_de'), r.de ?? 0);
    m.poke16(this.sym('mb_ix'), r.ix ?? 0);
    m.poke16(this.sym('mb_hl'), r.hl ?? 0);
    m.poke(this.sym('mb_cmd'), n);
    const MB = this.sym('mb_cmd'), LOOP = this.sym('UGZ_LOOP');
    let left = false;
    const ok = this.runTo((s) => { if (s.pc !== LOOP) left = true; return left && s.pc === LOOP && m.peek(MB) === 0; }, r.maxCycles ?? 400_000_000);
    if (!ok) throw new Error(`command ${n} did not finish`);
    return { a: m.peek(this.sym('mb_ra')), de: m.peek16(this.sym('mb_rde')), hl: m.peek16(this.sym('mb_rhl')), cf: m.peek(this.sym('mb_rf')) };
  }
  call(name, r = {}) { return this.cmd(1, { ...r, b: ABI.exports[name] }); }
  gwInit() {
    return this.cmd(7, { a: this.m.port1ffd, b: this.m.port9fbd, de: (this.s.base & 0xff00) | this.m.win[this.s.window] });
  }
  // INIT_CONFIG fields (stand.js defaults) + profile -> UG_INIT_ENV
  initEnv(cfgOver = {}, profile = {}) {
    const cfg = this.s.defaultConfig({ gw_ptr: this.L.gw, gw_len: 0x100, ...cfgOver });
    this.m.pokeBytes(CFG, encodeBlock('CFG', cfg));
    this.profile = { ...DEFAULT_PROFILE, ...profile };
    this.m.pokeBytes(PROFILE, encodeProfile(this.profile));
    const r = this.cmd(2, { ix: CFG, hl: PROFILE });
    r.env = this.block().env;
    r.cfg = decodeBlock('CFG', Uint8Array.from(this.m.peekBytes(CFG, ABI.blocks.CFG.size)));
    return r;
  }
  start({ constant = 164, chain = false } = {}) {
    this.armed = true;
    return this.cmd(3, { a: constant, b: chain ? 1 : 0, hl: this.t0 & 0xffff, de: (this.t0 >>> 16) & 0xffff });
  }
  stop() { return this.cmd(4); }
  set auto(bits) { this.m.poke(this.sym('mb_auto'), bits); }
  // Run the main loop for `ms` of virtual time.
  runMs(ms) {
    const end = this.m.cycles + ms * 1000 * this.m.mhz;
    this.runTo(() => this.m.cycles >= end, ms * 1000 * this.m.mhz + 1_000_000);
  }
  // Run until pred() (checked every ms of virtual time) or fail after maxMs.
  until(pred, maxMs = 5000) {
    for (let t = 0; t < maxMs; t++) { this.runMs(1); if (pred()) return t; }
    throw new Error(`condition not met in ${maxMs} ms; events ${this.evNames}`);
  }
  // Events the program drained into its log since the last call.
  events() {
    const head = this.m.peek(this.sym('mb_evhead')), log = this.sym('ev_log'), out = [];
    while (this.evTail !== head) {
      const ev = decodeBlock('EVT', Uint8Array.from(this.m.peekBytes(log + this.evTail * 8, 8)));
      ev.name = Object.entries(C.ev).find(([, v]) => v === ev.type)?.[0];
      out.push(ev);
      this.evTail = (this.evTail + 1) & 31;
    }
    this.evNames = (this.evNames || []).concat(out.map((e) => e.name)).slice(-20);
    return out;
  }

  // ---- gateway block --------------------------------------------------------------
  b16(off) { return this.m.peek16(this.L.lock + off); }
  b8(off) { return this.m.peek(this.L.lock + off); }
  stats() {
    const o = UG.UGW_STATS, g = (k) => this.b16(o + UG[k]);
    return { refuse: g('UGS_REFUSE'), busy: g('UGS_BUSY'), isr: g('UGS_ISR'), step: g('UGS_STEP'), early: g('UGS_EARLY'),
      frames: g('UGS_FRAMES'), ticks: g('UGS_TICKS'), mask: g('UGS_MASK'), cbl: g('UGS_CBL'), key: g('UGS_KEY'), late: g('UGS_LATE') };
  }
  block() {
    const q = (base) => ({ poll: this.b16(base), card: this.b16(base + 2), main: this.b16(base + 4), service: this.b16(base + 6) });
    return {
      lock: this.b8(UG.UGW_LOCK), flags: this.b8(UG.UGW_FLAGS), flags2: this.b8(UG.UGW_FLAGS2), env: this.b8(UG.UGW_ENV),
      q: q(UG.UGW_Q), qfull: q(UG.UGW_QFULL), active: this.b16(UG.UGW_ACTIVE), sum: this.b16(UG.UGW_SUM),
      costPoll: this.b16(UG.UGW_COST_POLL), costStep: this.b16(UG.UGW_COST_STEP), costBusy: this.b16(UG.UGW_COST_BUSY), costRefuse: this.b16(UG.UGW_COST_REFUSE),
      isrBudget: this.b16(UG.UGW_ISR_BUDGET), stepBudget: this.b16(UG.UGW_STEP_BUDGET), spacing: this.b8(UG.UGW_SPACING),
      period: this.b16(UG.UGW_PERIOD_NO), debit: this.b16(UG.UGW_DEBIT), debitMax: this.b16(UG.UGW_DEBIT_MAX),
      now: (this.b16(UG.UGW_NOW) + this.b16(UG.UGW_NOW + 2) * 65536) >>> 0, tMiss: this.b16(UG.UGW_T_MISS),
      stats: this.stats(),
    };
  }
  ctx(field) { return this.s.ctx(field); }
  drain(max = 16) {
    const out = [];
    for (let i = 0; i < max; i++) {
      const p = this.call('RX_PEEK');
      if (p.a !== C.status.OK) break;
      out.push(...this.m.peekBytes(p.hl, p.de));
      if (this.call('RX_RELEASE').a !== C.status.OK) throw new Error('RX_RELEASE');
    }
    return out;
  }
  send(bytes, tag) {
    const res = this.call('TX_RESERVE', { de: bytes.length });
    if (res.a !== C.status.OK) return { res };
    this.m.pokeBytes(res.hl, bytes);
    const commit = this.call('TX_COMMIT', { a: res.de & 0xff, de: bytes.length, ix: tag });
    return { res, commit };
  }
  max(list, kind) { return Math.max(0, ...list.filter((x) => !kind || x.kind === kind).map((x) => x.us)); }
}

module.exports = { AppStand, UG, DEFAULT_PROFILE, tickProfile, encodeProfile, CFG, PROFILE, BUF };
