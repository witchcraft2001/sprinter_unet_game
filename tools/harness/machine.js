// machine.js -- Sprinter model for the UNET-GAME Z stand.
// SPDX-License-Identifier: BSD-3-Clause
//
// Models what the core may legally touch and records every violation of the
// rules in CLAUDE.md instead of trusting the code:
//   * 1 MB RAM, four 16 KB windows (ports #82/#A2/#C2/#E2, low-byte decode);
//   * the ISA window: #1FFD bit 4 + latch #Dx written to #E2, card I/O at
//     0xC000+port, #9FBD address/AEN bits; exact restore of #1FFD/#9FBD/#E2;
//   * T-state accounting at 7/21 MHz plus ISA wait states per card access;
//   * DI sections, stack high-water, writes into the image, forbidden opcodes
//     and forbidden I/O ports executed from inside the image.
'use strict';

// z80core.js checks `this === window` (browser heritage); give Node a dummy.
if (typeof global.window === 'undefined') global.window = {};
const Z80 = require('./z80core.js');

const PAGE_PORTS = { 0x82: 0, 0xa2: 1, 0xc2: 2, 0xe2: 3 };
const FORBIDDEN_OPCODES = {
  0xd9: 'EXX', 0x08: "EX AF,AF'", 0xcf: 'RST #08', 0xd7: 'RST #10',
  0xf7: 'RST #30', 0xff: 'RST #38', 0x76: 'HALT',
};

class Machine {
  constructor(opts = {}) {
    this.mhz = opts.mhz || 21;
    this.isaWaitT = opts.isaWaitT ?? 8;     // extra T-states per ISA access (calibrated in M0)
    this.mem = new Uint8Array(0x100000);
    this.mem.fill(opts.poison ?? 0xaa);
    this.win = [0, 1, 2, 3];
    this.port1ffd = 0x01;                   // BIOS value: RAM-0 mode, ISA closed
    this.port9fbd = 0x00;
    this.isaLatch = 0x00;
    this.cards = [];                        // { slot, base, size, ioRead(off), ioWrite(off, v) }
    this.image = null;                      // { start, end, mutable: Set(address) }
    this.violations = [];
    this.trace = { io: [] };
    this.cycles = 0;
    this.extraCycles = 0;
    this.cpu = new Z80({
      mem_read: (a) => this.read(a),
      mem_write: (a, v) => this.write(a, v),
      io_read: (p) => this.ioRead(p),
      io_write: (p, v) => this.ioWrite(p, v),
    });
    const s = this.cpu.getState();
    s.sp = 0x3ff0; s.pc = 0x0000; s.iff1 = 1; s.iff2 = 1; s.imode = 1;
    this.cpu.setState(s);
  }

  // ---- memory -------------------------------------------------------------
  lin(a) { return this.win[(a >> 14) & 3] * 0x4000 + (a & 0x3fff); }
  isaOpen() { return (this.port1ffd & 0x10) !== 0 && (this.isaLatch & 0xf0) === 0xd0; }
  pcInImage() {
    if (!this.image) return false;
    const pc = this.cpu.getState().pc;
    return pc >= this.image.start && pc < this.image.end;
  }
  violation(kind, detail) {
    const pc = this.cpu.getState().pc;
    this.violations.push({ kind, detail, pc, cycles: this.cycles });
  }
  cardAt(address) {
    if (!this.isaOpen()) return null;
    if ((this.isaLatch & 0x04) === 0) return { mem: true };   // ISA memory mode: unused by the core
    const slot = (this.isaLatch >> 1) & 1;
    const port = address - 0xc000;
    for (const c of this.cards) {
      if (c.slot === slot && port >= c.base && port < c.base + c.size) return { card: c, off: port - c.base };
    }
    return { none: true };
  }
  isaAccess(address) {
    this.extraCycles += this.isaWaitT;
    if (this.cpu.getState().iff1) this.violation('isa-with-interrupts', `access 0x${address.toString(16)} with IFF1=1`);
    if ((this.port9fbd & 0xc0) !== 0) this.violation('isa-aen', `#9FBD=0x${this.port9fbd.toString(16)} during card access`);
  }
  read(a) {
    a &= 0xffff;
    if (a >= 0xc000 && this.isaOpen()) {
      this.isaAccess(a);
      const t = this.cardAt(a);
      if (t.card) return t.card.ioRead(t.off, this) & 0xff;
      return 0xff;
    }
    return this.mem[this.lin(a)];
  }
  write(a, v) {
    a &= 0xffff; v &= 0xff;
    if (a >= 0xc000 && this.isaOpen()) {
      this.isaAccess(a);
      const t = this.cardAt(a);
      if (t.card) t.card.ioWrite(t.off, v, this);
      return;
    }
    if (this.image && a >= this.image.start && a < this.image.end && !this.image.mutable.has(a)) {
      this.violation('image-write', `write 0x${v.toString(16)} to image 0x${a.toString(16)}`);
    }
    if (this.watchWrite) this.watchWrite(a, v);
    this.mem[this.lin(a)] = v;
  }
  peek(a) { return this.mem[this.lin(a & 0xffff)]; }
  poke(a, v) { this.mem[this.lin(a & 0xffff)] = v & 0xff; }
  peek16(a) { return this.peek(a) | (this.peek(a + 1) << 8); }
  poke16(a, v) { this.poke(a, v); this.poke(a + 1, v >> 8); }
  pokeBytes(a, bytes) { for (let i = 0; i < bytes.length; i++) this.poke(a + i, bytes[i]); }
  peekBytes(a, n) { const out = []; for (let i = 0; i < n; i++) out.push(this.peek(a + i)); return out; }

  // ---- I/O ------------------------------------------------------------------
  ioRead(port) {
    port &= 0xffff;
    const low = port & 0xff;
    const fromImage = this.pcInImage();
    this.trace.io.push({ dir: 'in', port, fromImage });
    if (low in PAGE_PORTS) return this.win[PAGE_PORTS[low]] & 0xff;
    if (fromImage) this.violation('io-port', `IN from port 0x${port.toString(16)}`);
    if (this.ioHook) return this.ioHook('in', port) ?? 0xff;
    return 0xff;
  }
  ioWrite(port, v) {
    port &= 0xffff; v &= 0xff;
    const low = port & 0xff;
    const fromImage = this.pcInImage();
    this.trace.io.push({ dir: 'out', port, value: v, fromImage });
    if (port === 0x1ffd) {
      if ((v & 0x01) === 0) this.violation('1ffd-bit0', `#1FFD=0x${v.toString(16)} clears bit 0 (ROM in WIN0)`);
      this.port1ffd = v;
      return;
    }
    if (port === 0x9fbd) { this.port9fbd = v; return; }
    if (low === 0xe2 && (this.port1ffd & 0x10)) {
      // With #1FFD bit 4 set the FPGA latches #E2 writes as the ISA control byte.
      if ((v & 0xf0) !== 0xd0) this.violation('isa-latch', `#E2=0x${v.toString(16)} while #1FFD bit 4 is set`);
      this.isaLatch = v;
      return;
    }
    if (low in PAGE_PORTS) {
      if (fromImage && low !== 0xe2) this.violation('io-port', `page port 0x${low.toString(16)} written from the image`);
      if (v >= 64) this.violation('page-range', `window ${PAGE_PORTS[low]} mapped to page ${v}`);
      this.win[PAGE_PORTS[low]] = v & 0x3f;
      return;
    }
    if (fromImage) this.violation('io-port', `OUT to port 0x${port.toString(16)}`);
    if (this.ioHook) this.ioHook('out', port, v);
  }

  // ---- execution -------------------------------------------------------------
  regs() { return this.cpu.getState(); }
  setRegs(patch) { const s = this.cpu.getState(); Object.assign(s, patch); this.cpu.setState(s); }
  get us() { return this.cycles / this.mhz; }

  // Run from the current state until PC == stop.  Returns per-run metrics.
  runUntil(stop, opts = {}) {
    const limit = opts.maxCycles ?? 20_000_000;
    const start = this.cycles;
    let minSp = this.regs().sp, diStart = null, maxDi = 0;
    const isr = !!opts.isr;
    for (;;) {
      const s = this.cpu.getState();
      if (s.pc === stop) break;
      if (this.cycles - start > limit) throw new Error(`cycle limit reached at PC=0x${s.pc.toString(16)}`);
      if (this.image && s.pc >= this.image.start && s.pc < this.image.end) {
        const op = this.peek(s.pc);
        if (op in FORBIDDEN_OPCODES) this.violation('opcode', FORBIDDEN_OPCODES[op]);
        if (op === 0xfb && isr) this.violation('ei-in-isr', 'EI inside STEP_ISR');
      }
      if (opts.onStep) opts.onStep(this, s);
      this.extraCycles = 0;
      const t = this.cpu.run_instruction();
      this.cycles += t + this.extraCycles;
      const n = this.cpu.getState();
      if (n.sp < minSp) minSp = n.sp;
      if (!n.iff1 && diStart === null) diStart = this.cycles - t;
      if (n.iff1 && diStart !== null) { maxDi = Math.max(maxDi, this.cycles - diStart); diStart = null; }
    }
    if (diStart !== null && !opts.isr) maxDi = Math.max(maxDi, this.cycles - diStart);
    const cyc = this.cycles - start;
    return { cycles: cyc, us: cyc / this.mhz, minSp, maxDiUs: maxDi / this.mhz };
  }
}

module.exports = { Machine };
