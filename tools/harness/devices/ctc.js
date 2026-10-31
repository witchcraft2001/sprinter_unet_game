// ctc.js -- Z84C15 CTC model for the Z application stand.
// SPDX-License-Identifier: BSD-3-Clause
//
// Four channels on ports #10..#13.  Timer mode counts the CPU clock through
// the /16 or /256 prescaler; counter mode counts the CLK/TRG input: 875 kHz
// on channels 0..2 (Sprinter: X / 48), the zero count of channel 2 on
// channel 3 (the Worms chain CTC2 -> CTC3).  Reading a channel returns its
// down counter (constant .. 1).  A channel with interrupts enabled keeps one
// latched request per zero count until the CPU acknowledges it (several
// zero counts while pending merge into one request, as on the chip).
// Everything is computed from m.cycles, so the stand may skip idle time.
'use strict';

class Ctc {
  constructor(m, opts = {}) {
    this.m = m;
    this.clkHz = opts.clkHz ?? 875000;
    this.vectorBase = 0;
    this.ch = [0, 1, 2, 3].map((i) => ({ i, ctrl: 0, tc: 256, wantTc: false, running: false, ie: false, counter: false, presc: 256, start: 0, acked: 0 }));
    this.writes = [];
  }
  // CLK/TRG edges (875 kHz) since cycle 0.
  clk(cycles) { return Math.floor((cycles * this.clkHz) / (this.m.mhz * 1e6)); }
  // Input edges seen by channel c since it started.
  edges(c, cycles) {
    if (!c.running) return 0;
    if (!c.counter) return Math.floor((cycles - c.start) / c.presc);
    if (c.i < 3) return this.clk(cycles) - c.start;
    return this.zeros(this.ch[2], cycles) - c.start;
  }
  zeros(c, cycles) { return c.running ? Math.floor(this.edges(c, cycles) / c.tc) : 0; }
  value(c, cycles) { return c.running ? c.tc - (this.edges(c, cycles) % c.tc) : c.tc & 0xff; }

  write(port, v) {
    const c = this.ch[port & 3], now = this.m.cycles;
    this.writes.push({ port, v, cycles: now });
    if (c.wantTc) {
      c.tc = v || 256;
      c.wantTc = false;
      c.running = true;
      if (!c.counter) c.start = now;
      else c.start = c.i < 3 ? this.clk(now) : this.zeros(this.ch[2], now);
      c.acked = 0;
      return;
    }
    if (v & 1) {
      c.ctrl = v;
      c.ie = (v & 0x80) !== 0;
      c.counter = (v & 0x40) !== 0;
      c.presc = (v & 0x20) ? 256 : 16;
      c.wantTc = (v & 0x04) !== 0;
      if (v & 0x02) { c.running = false; c.acked = 0; }
      return;
    }
    if (c.i === 0) this.vectorBase = v & 0xf8;
  }
  read(port) {
    const c = this.ch[port & 3], v = this.value(c, this.m.cycles) & 0xff;
    // test timing control: a scripted CTC3 read first moves the counter by
    // one count (true) or not (false), as when it decrements between two
    // reads of one sample; later reads see the moved counter
    if (c.i === 3 && this.script3 && this.script3.length && this.script3.shift()) {
      c.start -= 1;
      return this.value(c, this.m.cycles) & 0xff;
    }
    return v;
  }

  // Highest-priority pending channel (0 first) or null.
  pending(cycles = this.m.cycles) {
    for (const c of this.ch) if (c.ie && c.running && this.zeros(c, cycles) > c.acked) return c;
    return null;
  }
  vector(c) { return (this.vectorBase | (c.i << 1)) & 0xff; }
  ack(c) { c.acked = this.zeros(c, this.m.cycles); }
  // First cycle >= now at which a new request appears (Infinity if none).
  nextRequest(now = this.m.cycles) {
    let best = Infinity;
    for (const c of this.ch) {
      if (!c.ie || !c.running) continue;
      if (this.zeros(c, now) > c.acked) return now;
      const need = (c.acked + 1) * c.tc;                 // edges at the next zero count
      let t;
      if (!c.counter) t = c.start + need * c.presc;
      else if (c.i < 3) t = Math.ceil(((c.start + need) * this.m.mhz * 1e6) / this.clkHz);
      else continue;                                     // channel 3 interrupts: not used by the SDK
      best = Math.min(best, Math.max(now, t));
    }
    return best;
  }
}

module.exports = { Ctc };
