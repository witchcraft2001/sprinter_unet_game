// el3.js -- 3Com EtherLink III (3C509B) register model for the Z stand.
// SPDX-License-Identifier: BSD-3-Clause
//
// Semantics follow sprinter-3C509B/tools/exe-harness/harness.js (class
// EtherLinkIII), reduced to the register file; protocol answers come from
// net/peer.js.  Strict: wrong ID sequence bytes, FIFO access outside
// window 1, high-before-low 16-bit access and RX_DISCARD on an empty queue
// throw.  Extras for the core's resumable states: commands can keep CIP
// set for a number of status reads, TX completion can be delayed.
'use strict';

function lfsr(index) {
  let v = 0xff;
  for (let i = 0; i < index; i++) v = ((v << 1) & 0xff) ^ ((v & 0x80) ? 0xcf : 0);
  return v;
}

class EL3 {
  constructor(opts = {}) {
    this.slot = opts.slot ?? 0;
    this.idPort = opts.idPort ?? 0x110;
    this.base = opts.base ?? 0x300;
    this.mac = opts.mac ?? [0x00, 0x60, 0x08, 0x12, 0x34, 0x56];
    this.cipReads = opts.cipReads ?? 0;       // status reads with CIP set after each command
    this.txDelayReads = opts.txDelayReads ?? 0;
    this.present = opts.present !== false;
    this.eeprom = new Array(64).fill(0);
    for (let i = 0; i < 3; i++) this.eeprom[i] = (this.mac[2 * i] << 8) | this.mac[2 * i + 1];
    this.eeprom[3] = 0x9550; this.eeprom[7] = 0x6d50;
    this.active = false; this.window = 0;
    this.idZeros = 0; this.idIndex = -1; this.idSelected = false; this.serial = [];
    this.rxEnabled = false; this.txEnabled = false; this.rxFilter = 0;
    this.intrMask = 0; this.netDiag = 0; this.media = 0; this.station = [0, 0, 0, 0, 0, 0];
    this.rxQueue = []; this.txFifo = []; this.txExpected = 0; this.txStatus = [];
    this.cipLeft = 0; this.lowW = new Map(); this.highR = new Map();
    this.transmitted = []; this.commands = []; this.rejected = 0; this.onTransmit = null;
    this.rxFifoLimit = opts.rxFifoBytes ?? 2048;
  }

  // ---- ISA attachment: two apertures (ID port, I/O block) ----------------
  attach(machine) {
    const self = this;
    machine.cards.push({ slot: this.slot, get base() { return self.idPort; }, size: 1,
      ioRead: () => self.idRead(), ioWrite: (off, v) => self.idWrite(v) });
    machine.cards.push({ slot: this.slot, get base() { return self.base; }, size: 16,
      ioRead: (off) => self.readByte(off), ioWrite: (off, v) => self.writeByte(off, v) });
  }

  // ---- network side ----------------------------------------------------
  accepts(frame) {
    const d = frame.slice(0, 6);
    if (d.every((v) => v === 0xff)) return (this.rxFilter & 4) !== 0;
    return (this.rxFilter & 1) !== 0 && d.every((v, i) => v === this.station[i]);
  }
  deliver(frame) {
    if (!this.rxEnabled || !this.accepts(frame)) { this.rejected++; return false; }
    const used = this.rxQueue.reduce((n, q) => n + q.frame.length, 0);
    if (used + frame.length > this.rxFifoLimit) { this.rejected++; return false; }
    this.rxQueue.push({ frame: Array.from(frame), cursor: 0 });
    return true;
  }

  // ---- ID port ------------------------------------------------------------
  idWrite(value) {
    if (!this.present) return;
    value &= 0xff;
    if (this.idIndex >= 0) {
      const want = lfsr(this.idIndex);
      if (value !== want) throw new Error(`EL3: bad ID byte ${this.idIndex}: ${value.toString(16)} != ${want.toString(16)}`);
      if (++this.idIndex === 255) { this.idIndex = -1; this.idSelected = true; }
      return;
    }
    if (value === 0) { if (++this.idZeros === 2) { this.idZeros = 0; this.idIndex = 0; this.idSelected = false; } return; }
    this.idZeros = 0;
    if (!this.idSelected) throw new Error(`EL3: ID command ${value.toString(16)} without the ID sequence`);
    if (value === 0xd0) return;
    if ((value & 0xc0) === 0x80) {
      const w = this.eeprom[value & 0x3f];
      this.serial = Array.from({ length: 16 }, (_, i) => (w >> (15 - i)) & 1);
      return;
    }
    if ((value & 0xe0) === 0xe0) { this.base = 0x200 + ((value & 0x1f) << 4); this.active = true; this.window = 0; return; }
    throw new Error(`EL3: unknown ID command ${value.toString(16)}`);
  }
  idRead() { return this.serial.length ? this.serial.shift() : 1; }

  // ---- commands -------------------------------------------------------------
  command(word) {
    this.commands.push(word);
    this.cipLeft = this.cipReads;
    const op = word & 0xf800, p = word & 0x07ff;
    switch (op) {
      case 0x0800: if (p > 6) throw new Error(`EL3: bad window ${p}`); this.window = p; break;
      case 0x1800: this.rxEnabled = false; break;
      case 0x2000: this.rxEnabled = true; break;
      case 0x2800: this.rxEnabled = false; this.rxQueue = []; break;
      case 0x4000: if (!this.rxQueue.length) throw new Error('EL3: RX_DISCARD on an empty queue'); this.rxQueue.shift(); break;
      case 0x4800: this.txEnabled = true; break;
      case 0x5000: this.txEnabled = false; break;
      case 0x5800: this.txEnabled = false; this.txFifo = []; this.txExpected = 0; this.txStatus = []; break;
      case 0x6800: case 0x7800: case 0x8800: case 0x9000: case 0x9800: case 0xa800: case 0xb000: break;
      case 0x7000: this.intrMask = p; break;
      case 0x8000: this.rxFilter = p; break;
      default: throw new Error(`EL3: unknown command ${word.toString(16)}`);
    }
  }

  txByte(v) {
    if (this.window !== 1) throw new Error(`EL3: TX FIFO write in window ${this.window}`);
    this.txFifo.push(v & 0xff);
    if (this.txFifo.length === 2) { const len = (this.txFifo[0] | (this.txFifo[1] << 8)) & 0x7ff; this.txExpected = 4 + ((len + 3) & ~3); }
    if (this.txExpected && this.txFifo.length === this.txExpected) {
      if (!this.txEnabled) throw new Error('EL3: frame completed with the transmitter disabled');
      const len = (this.txFifo[0] | (this.txFifo[1] << 8)) & 0x7ff;
      if (this.txFifo[2] || this.txFifo[3]) throw new Error('EL3: non-zero preamble word 2');
      if (!(this.txFifo[1] & 0x80)) throw new Error('EL3: preamble without completion request');
      const frame = this.txFifo.slice(4, 4 + len);
      if (this.txFifo.slice(4 + len).some(Boolean)) throw new Error('EL3: non-zero DWORD padding');
      this.transmitted.push(frame);
      this.txStatus.push({ value: 0xc0, remaining: this.txDelayReads });
      this.txFifo = []; this.txExpected = 0;
      if (this.onTransmit) this.onTransmit(frame);
    }
  }
  rxByte() {
    if (this.window !== 1) throw new Error(`EL3: RX FIFO read in window ${this.window}`);
    if (!this.rxQueue.length) throw new Error('EL3: RX FIFO read on an empty queue');
    const q = this.rxQueue[0];
    return q.cursor < q.frame.length ? q.frame[q.cursor++] : 0;
  }

  readWord(off) {
    if (off === 0x0e) { const cip = this.cipLeft > 0 ? 0x1000 : 0; if (this.cipLeft > 0) this.cipLeft--; return (this.window << 13) | cip; }
    switch (this.window) {
      case 0: if (off === 0) return this.eeprom[7]; if (off === 2) return this.eeprom[3]; return 0;
      case 1:
        if (off === 0x08) return this.rxQueue.length ? this.rxQueue[0].frame.length : 0;
        if (off === 0x0c) return 0x0800;
        return 0;
      case 4:
        if (off === 0x06) return this.netDiag;
        if (off === 0x0a) return this.media | 0x0800;
        return 0;
      default: return 0;
    }
  }
  writeWord(off, v) {
    if (off === 0x0e) return this.command(v);
    if (this.window === 4 && off === 0x06) { this.netDiag = v & 0xf000; return; }
    if (this.window === 4 && off === 0x0a) { this.media = v & 0x00cc; return; }
    throw new Error(`EL3: unknown word write w${this.window}+${off.toString(16)}=${v.toString(16)}`);
  }
  readByte(off) {
    if (!this.active) return 0xff;
    if (this.window === 1 && off === 0) return this.rxByte();
    if (this.window === 1 && off === 0x0b) {
      const s = this.txStatus[0];
      if (!s) return 0;
      if (s.remaining > 0) { s.remaining--; return 0; }
      return s.value;
    }
    if (this.window === 2 && off < 6) return this.station[off];
    if (this.window === 6 && off < 14) return 0;
    if (off & 1) {
      if (!this.highR.has(off - 1)) throw new Error(`EL3: high byte read without the low byte at ${off.toString(16)}`);
      const h = this.highR.get(off - 1); this.highR.delete(off - 1); return h;
    }
    const w = this.readWord(off);
    this.highR.set(off, (w >> 8) & 0xff);
    return w & 0xff;
  }
  writeByte(off, v) {
    if (!this.active) return;
    if (this.window === 1 && off === 0) return this.txByte(v);
    if (this.window === 1 && off === 0x0b) { this.txStatus.shift(); return; }
    if (this.window === 2 && off < 6) { this.station[off] = v & 0xff; return; }
    if (off & 1) {
      if (!this.lowW.has(off - 1)) throw new Error(`EL3: high byte write without the low byte at ${off.toString(16)}`);
      const lo = this.lowW.get(off - 1); this.lowW.delete(off - 1);
      return this.writeWord(off - 1, lo | ((v & 0xff) << 8));
    }
    this.lowW.set(off, v & 0xff);
  }
}

module.exports = { EL3, lfsr };
