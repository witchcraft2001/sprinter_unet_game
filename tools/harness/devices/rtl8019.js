// rtl8019.js -- RTL8019AS / DP8390 (NE2000, 8-bit mode) register model
// for the Z stand.
// SPDX-License-Identifier: BSD-3-Clause
//
// Semantics follow sprinter-rtl8019a/tools/exe-harness/rtl8019-model.js,
// reduced to what a POLL driver needs and made strict for the rules of
// the UNET-GAME core:
//   * the reset port (0x1F) throws: the core resets softly (clones hang
//     the ISA cycle there, which no software timeout can catch);
//   * data-port access without an active remote DMA throws, as does a
//     remote DMA that runs past PSTOP*256 (the driver splits at the wrap);
//   * DCR.WTS (16-bit transfers) and page-2 writes throw;
//   * CR.TXP is set-only: CR writes with TXP=0 do not cancel a transmission.
// Options for resumable-state tests: txDelayReads (ISR reads before PTX),
// txHang (TXP never completes, cleared only by CR.STP), txError (count of
// frames ending in TXE), rdcLost (write DMA never sets RDC), storeFcs
// (count includes 4 stored FCS bytes, as the real chip), promLayout
// ('direct' | 'doubled'), present.
'use strict';

const ISR = { PRX: 0x01, PTX: 0x02, RXE: 0x04, TXE: 0x08, OVW: 0x10, CNT: 0x20, RDC: 0x40, RST: 0x80 };
const RAM_BASE = 0x4000, RAM_LIMIT = 0x6000;

function buildProm(mac, layout = 'direct', sig = 0x57) {
  const logical = new Array(16).fill(0);
  for (let i = 0; i < 6; i++) logical[i] = mac[i];
  logical[14] = sig; logical[15] = sig;
  if (layout === 'doubled') {
    const out = [];
    for (const b of logical) out.push(b, b);
    return out;
  }
  return [...logical, ...new Array(16).fill(0)];
}

class Rtl8019 {
  constructor(opts = {}) {
    this.slot = opts.slot ?? 0;
    this.base = opts.base ?? 0x300;
    this.present = opts.present !== false;
    this.mac = opts.mac ?? [0x02, 0x80, 0x19, 0x11, 0x22, 0x33];
    this.prom = buildProm(this.mac, opts.promLayout ?? 'direct');
    this.storeFcs = opts.storeFcs !== false;
    this.txDelayReads = opts.txDelayReads ?? 0;
    this.txHang = !!opts.txHang;
    this.txErrorLeft = opts.txError ?? 0;
    this.rdcLost = !!opts.rdcLost;
    this.ram = new Uint8Array(RAM_LIMIT - RAM_BASE).fill(0xaa);
    this.cr = 0x21; this.isr = ISR.RST; this.stopped = true;
    this.pstart = 0; this.pstop = 0; this.bnry = 0; this.curr = 0; this.tpsr = 0;
    this.tbcr = 0; this.rsar = 0; this.rbcr = 0; this.crda = 0;
    this.rcr = 0; this.tcr = 0; this.dcr = 0x04; this.imr = 0;
    this.par = [0, 0, 0, 0, 0, 0]; this.mar = new Array(8).fill(0);
    this.dma = null;                         // 'read' | 'write' while active
    this.rxHalted = false; this.txLeft = -1; // ISR reads until PTX/TXE, -1 idle
    this.transmitted = []; this.onTransmit = null;
    this.rejected = 0; this.overflows = 0; this.stopEdges = 0; this.accesses = 0;
  }

  attach(machine) {
    const self = this;
    if (!this.present) return;
    machine.cards.push({ slot: this.slot, get base() { return self.base; }, size: 32,
      ioRead: (off) => self.read(off), ioWrite: (off, v) => self.write(off, v) });
  }

  get page() { return (this.cr >> 6) & 3; }

  // ---- registers ----------------------------------------------------------
  read(off) {
    this.accesses++;
    if (off === 0x00) return this.cr;
    if (off === 0x10) return this.dataRead();
    if (off >= 0x11) throw new Error(`RTL: read of port +0x${off.toString(16)} (reset port / mirrors are not used)`);
    if (this.page === 0) {
      switch (off) {
        case 0x03: return this.bnry;
        case 0x04: return 0x01;                // TSR: transmitted OK
        case 0x07: return this.isrRead();
        case 0x0a: return 0x50;                // 8019ID0 'P'
        case 0x0b: return 0x70;                // 8019ID1 'p'
        case 0x0c: return 0x01;                // RSR
        default: return 0;
      }
    }
    if (this.page === 1) {
      if (off <= 0x06) return this.par[off - 1];
      if (off === 0x07) return this.curr;
      return this.mar[off - 8];
    }
    throw new Error(`RTL: read on page ${this.page} at +0x${off.toString(16)}`);
  }

  write(off, v) {
    this.accesses++;
    v &= 0xff;
    if (off === 0x00) return this.writeCr(v);
    if (off === 0x10) return this.dataWrite(v);
    if (off >= 0x11) throw new Error(`RTL: write to port +0x${off.toString(16)} (reset port / mirrors are not used)`);
    if (this.page === 0) {
      switch (off) {
        case 0x01: this.pstart = v; return;
        case 0x02: this.pstop = v; return;
        case 0x03: this.bnry = v; return;
        case 0x04: this.tpsr = v; return;
        case 0x05: this.tbcr = (this.tbcr & 0xff00) | v; return;
        case 0x06: this.tbcr = (this.tbcr & 0xff) | (v << 8); return;
        case 0x07: this.isr &= ~v & 0xff; return;
        case 0x08: this.rsar = (this.rsar & 0xff00) | v; return;
        case 0x09: this.rsar = (this.rsar & 0xff) | (v << 8); return;
        case 0x0a: this.rbcr = (this.rbcr & 0xff00) | v; return;
        case 0x0b: this.rbcr = (this.rbcr & 0xff) | (v << 8); return;
        case 0x0c: this.rcr = v; return;
        case 0x0d: this.tcr = v; return;
        case 0x0e: if (v & 1) throw new Error('RTL: DCR.WTS=1 (16-bit transfers) on the 8-bit Sprinter bus'); this.dcr = v; return;
        case 0x0f: this.imr = v; return;
        default: throw new Error(`RTL: write page 0 +0x${off.toString(16)}`);
      }
    }
    if (this.page === 1) {
      if (off <= 0x06) { this.par[off - 1] = v; return; }
      if (off === 0x07) { this.curr = v; return; }
      this.mar[off - 8] = v; return;
    }
    throw new Error(`RTL: write on page ${this.page} at +0x${off.toString(16)}`);
  }

  isrRead() {
    if (this.txLeft > 0) this.txLeft--;
    else if (this.txLeft === 0) this.finishTx();
    return this.isr;
  }

  writeCr(v) {
    const txp = this.cr & 0x04;
    this.cr = (v & ~0x04) | txp;
    if (v & 0x01) {
      if (!this.stopped) this.stopEdges++;
      this.stopped = true;
      this.cr &= ~0x04; this.txLeft = -1;      // a stop aborts the transmitter
    } else if ((v & 0x02) && this.stopped) {
      this.stopped = false; this.rxHalted = false;
    }
    const rd = (v >> 3) & 7;
    if (rd === 1 || rd === 2) {
      this.crda = this.rsar;
      this.dma = rd === 1 ? 'read' : 'write';
      if (this.rbcr === 0) { this.isr |= ISR.RDC; this.dma = null; }
    } else if (rd === 4) {
      this.dma = null;
    }
    if ((v & 0x04) && !txp) this.startTx();
  }

  dataRead() {
    if (this.dma !== 'read') throw new Error('RTL: data port read without a remote read DMA');
    const a = this.crda;
    let v;
    if (a < 0x0020) v = this.prom[a];
    else if (a >= RAM_BASE && a < RAM_LIMIT) {
      if (this.pstop && a === this.pstop * 256) throw new Error('RTL: remote read ran past PSTOP (split at the ring end)');
      v = this.ram[a - RAM_BASE];
    } else throw new Error(`RTL: remote read outside RAM at 0x${a.toString(16)}`);
    this.dmaStep();
    return v;
  }
  dataWrite(v) {
    if (this.dma !== 'write') throw new Error('RTL: data port write without a remote write DMA');
    const a = this.crda;
    if (a < RAM_BASE || a >= RAM_LIMIT) throw new Error(`RTL: remote write outside RAM at 0x${a.toString(16)}`);
    if (this.pstart && a >= this.pstart * 256) throw new Error('RTL: remote write into the RX ring');
    this.ram[a - RAM_BASE] = v;
    this.dmaStep();
  }
  dmaStep() {
    this.crda = (this.crda + 1) & 0xffff;
    if (--this.rbcr === 0) {
      if (!(this.dma === 'write' && this.rdcLost)) this.isr |= ISR.RDC;
      this.dma = null;
    }
  }

  // ---- transmit -------------------------------------------------------------
  startTx() {
    if (this.stopped) throw new Error('RTL: TXP with the NIC stopped');
    if (this.dcr !== 0x48) throw new Error(`RTL: transmit with DCR 0x${this.dcr.toString(16)}`);
    if (this.tbcr < 60 || this.tbcr > 1514) throw new Error(`RTL: TBCR ${this.tbcr}`);
    this.cr |= 0x04;
    this.txLeft = this.txHang ? -2 : this.txDelayReads;
    if (this.txLeft === 0) this.finishTx();
  }
  finishTx() {
    this.txLeft = -1;
    this.cr &= ~0x04;
    if (this.txErrorLeft > 0) { this.txErrorLeft--; this.isr |= ISR.TXE; return; }
    const s = (this.tpsr << 8) - RAM_BASE;
    const frame = Array.from(this.ram.slice(s, s + this.tbcr));
    this.isr |= ISR.PTX;
    if (this.tcr & 0x06) return;               // loopback: not on the wire
    this.transmitted.push(frame);
    if (this.onTransmit) this.onTransmit(frame);
  }

  // ---- receive ----------------------------------------------------------------
  accepts(frame) {
    if (this.stopped || this.rxHalted || (this.rcr & 0x20)) return false;
    const d = frame.slice(0, 6);
    if (d.every((x) => x === 0xff)) return (this.rcr & 0x04) !== 0;
    if (d[0] & 1) return (this.rcr & 0x18) !== 0;
    return (this.rcr & 0x10) !== 0 || d.every((x, i) => x === this.par[i]);
  }
  deliver(frame) {
    if (!this.present || !this.accepts(frame)) { this.rejected++; return false; }
    const R = this.pstop - this.pstart;
    const pos = (p) => (((p - this.pstart) % R) + R) % R;
    const count = frame.length + 4 + (this.storeFcs ? 4 : 0);
    const pages = Math.ceil(count / 256);
    const gap = (((pos(this.bnry) - pos(this.curr)) % R) + R) % R;
    if (pages > gap) { this.isr |= ISR.OVW; this.rxHalted = true; this.overflows++; this.rejected++; return false; }
    const next = this.pstart + ((pos(this.curr) + pages) % R);
    const bytes = [0x01 | ((frame[0] & 1) ? 0x20 : 0), next, count & 0xff, count >> 8, ...frame];
    if (this.storeFcs) bytes.push(0xde, 0xad, 0xbe, 0xef);
    let a = this.curr * 256;
    for (const b of bytes) { this.ram[a - RAM_BASE] = b; a++; if (a >= this.pstop * 256) a = this.pstart * 256; }
    this.curr = next;
    this.isr |= ISR.PRX;
    return true;
  }
  // Frames stored and not yet released by BNRY.
  pending() {
    const R = this.pstop - this.pstart;
    let p = this.bnry + 1 >= this.pstop ? this.pstart : this.bnry + 1, n = 0;
    while (p !== this.curr && n < R) { p = this.ram[p * 256 + 1 - RAM_BASE]; n++; }
    return n;
  }
}

module.exports = { Rtl8019, buildProm, ISR };
