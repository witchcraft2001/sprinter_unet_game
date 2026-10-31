// esp.js -- SprinterESP model for the Z stand: TL16C550C UART at ISA I/O
// 0x3E8 wired to an ESP8266 running ESP-AT 2.2 (CIPMUX=1, link 0), and a
// payload-level network peer behind it.
// SPDX-License-Identifier: BSD-3-Clause
//
// Strict model, written from the TL16C550C data sheet (TI SLLS177, §7.7
// auto flow) and the ESP-AT 2.2 command set.  Reply formats follow the
// behaviour of the MAME esp8266_at device (holub/mame, 2.2.0.0 profile),
// used here as a reference only.
//
// Time: the UART line runs on a combined clock -- the stand's virtual
// milliseconds between calls (advance(tMs)) plus the CPU cycles inside a
// call (machine.cycles) -- so a byte takes 10 bit times (86.8 us at
// 115200) whether the Z80 is inside STEP or not.
//
// Checked: register access discipline (FIFO reset after auto flow is on,
// MCR OUT1/OUT2 = module RESET/PGM lines, THR overrun), and the AT side:
// every byte the DLL sends must form a valid command or payload.
'use strict';

const XIN = 14745600;
const LSR = { DR: 0x01, OE: 0x02, THRE: 0x20, TEMT: 0x40 };

class EspCard {
  constructor(opts = {}) {
    this.slot = opts.slot ?? 0;
    this.base = opts.base ?? 0x3e8;
    this.present = opts.present !== false;
    this.afe = opts.afe !== false;          // TL16C550C auto-RTS (false: NS16550)
    this.inflight = opts.inflight ?? 1;     // bytes the module still sends after RTS drops
    this.errors = [];                       // model-detected misuse (asserted empty)
    // UART registers
    this.ier = 0; this.lcr = 0; this.mcr = 0; this.scr = 0; this.dl = 0; this.fcr = 0;
    this.lsrErr = 0;
    this.rxFifo = []; this.trigger = 1; this.afeHold = false;
    this.fcrWrites = []; this.mcrWrites = []; this.overruns = 0; this.rtsDrops = 0;
    // line state
    this.t = 0;                             // us at the last sync
    this.baseUs = 0; this.baseCycles = 0; this.m = null;
    this.out = [];                          // module -> UART: { b, at }
    this.cur = null;                        // byte on the RX line { b, end }
    this.lineFree = 0; this.inflightLeft = 0;
    this.txq = [];                          // UART -> module: { b, done }
    this.txFree = 0;
    this.events = [];                       // scheduled module/network actions { at, fn }
    this.esp = new EspAt(this, opts.esp || {});
    this.peer = this.esp.peer;
  }

  attach(m) {
    this.m = m;
    if (!this.present) return;              // empty slot: the bus floats to 0xFF
    m.cards.push({ slot: this.slot, base: this.base, size: 8,
      ioRead: (off, mm) => this.read(off, mm), ioWrite: (off, v, mm) => this.write(off, v, mm) });
  }

  // ---- time -----------------------------------------------------------------
  now(m = this.m) {
    const t = this.baseUs + (m ? (m.cycles - this.baseCycles) / m.mhz : 0);
    return Math.max(t, this.t);
  }
  advance(tMs) {
    const t = Math.max(tMs * 1000, this.now());
    this.baseUs = t; this.baseCycles = this.m ? this.m.cycles : 0;
    this.sync(t);
  }
  byteUs() { return (10 * 16 * (this.dl || 8) * 1e6) / XIN; }
  at(t, fn) {
    const e = { at: t, fn };
    let i = this.events.length;
    while (i > 0 && this.events[i - 1].at > t) i--;
    this.events.splice(i, 0, e);
  }
  emit(t, text) {                           // module output becomes available at t
    const b = typeof text === 'string' ? Buffer.from(text, 'latin1') : text;
    for (const x of b) this.out.push({ b: x, at: t });
  }
  rtsOn() {
    if (!(this.mcr & 0x02)) return false;
    if (this.afe && (this.mcr & 0x20) && this.afeHold) return false;
    return true;
  }
  setRts(before, t) {
    const after = this.rtsOn();
    if (before && !after) { this.inflightLeft = this.inflight; this.rtsDrops++; }
    if (!before && after) this.lineFree = Math.max(this.lineFree, t);
  }
  // TL16C550C auto-RTS: RTS drops when the RX FIFO reaches the trigger
  // level (the 16th character for 14) and returns once it is read empty.
  afeLevel() {
    const level = this.trigger === 14 ? 15 : this.trigger;
    if (this.rxFifo.length >= level) this.afeHold = true;
    else if (this.rxFifo.length === 0) this.afeHold = false;
  }

  sync(t) {
    if (t < this.t) t = this.t;
    // 1. bytes the UART finished sending reach the module
    while (this.txq.length && this.txq[0].done <= t) {
      const x = this.txq.shift();
      this.esp.input(x.b, x.done);
    }
    // 2. module and network actions due by t (they may append output)
    while (this.events.length && this.events[0].at <= t) this.events.shift().fn();
    // 3. the RX line: one byte at a time, gated by RTS at its start
    const bu = this.byteUs();
    for (;;) {
      if (!this.cur) {
        if (!this.out.length) break;
        const start = Math.max(this.lineFree, this.out[0].at);
        if (start > t) break;
        if (!this.rtsOn()) {
          if (this.inflightLeft <= 0) break;  // waits for RTS
          this.inflightLeft--;
        }
        const x = this.out.shift();
        this.cur = { b: x.b, end: start + bu };
      }
      if (this.cur.end > t) break;
      const before = this.rtsOn();
      if ((this.fcr & 1) && this.rxFifo.length >= 16) { this.lsrErr |= LSR.OE; this.overruns++; }
      else if (!(this.fcr & 1) && this.rxFifo.length >= 1) { this.lsrErr |= LSR.OE; this.overruns++; this.rxFifo[0] = this.cur.b; }
      else this.rxFifo.push(this.cur.b);
      this.lineFree = this.cur.end;
      this.cur = null;
      this.afeLevel();
      this.setRts(before, this.lineFree);
    }
    this.t = t;
  }

  // ---- registers ----------------------------------------------------------------
  read(off, m) {
    const t = this.now(m); this.sync(t);
    const dlab = this.lcr & 0x80;
    switch (off) {
      case 0: {
        if (dlab) return this.dl & 0xff;
        const before = this.rtsOn();
        const b = this.rxFifo.length ? this.rxFifo.shift() : 0;
        this.afeLevel(); this.setRts(before, t);
        return b;
      }
      case 1: return dlab ? this.dl >> 8 : this.ier & 0x0f;
      case 2: return (this.fcr & 1 ? 0xc0 : 0) | 0x01;
      case 3: return this.lcr;
      case 4: return this.mcr;
      case 5: {
        const thre = this.txq.length === 0 || this.txq[this.txq.length - 1].done - this.byteUs() <= t;
        const temt = this.txq.length === 0;
        const v = (this.rxFifo.length ? LSR.DR : 0) | this.lsrErr | (thre ? LSR.THRE : 0) | (temt ? LSR.TEMT : 0);
        this.lsrErr = 0;
        return v;
      }
      case 6: return 0x10;                  // CTS from the module
      default: return this.scr;
    }
  }
  write(off, v, m) {
    const t = this.now(m); this.sync(t);
    const dlab = this.lcr & 0x80;
    switch (off) {
      case 0:
        if (dlab) { this.dl = (this.dl & 0xff00) | v; return; }
        this.thr(v, t); return;
      case 1:
        if (dlab) { this.dl = (this.dl & 0xff) | (v << 8); return; }
        this.ier = v & 0x0f;
        if (v) this.errors.push(`IER=0x${v.toString(16)}: v1 is POLL-only`);
        return;
      case 2: {
        this.fcrWrites.push({ v, t, afe: !!(this.mcr & 0x20) });
        if ((v & 0x02) && (this.mcr & 0x20)) this.errors.push('RX FIFO reset with auto flow on (auto-RTS stays deasserted)');
        const before = this.rtsOn();
        if (v & 0x02) this.rxFifo = [];
        if (v & 0x04) this.txq = this.txq.filter((x) => x.done - this.byteUs() <= t);
        this.fcr = v & 0xc9;
        this.trigger = [1, 4, 8, 14][(v >> 6) & 3];
        this.afeLevel(); this.setRts(before, t);
        return;
      }
      case 3: this.lcr = v; return;
      case 4: {
        this.mcrWrites.push({ v, t });
        if (v & 0x0c) this.errors.push(`MCR=0x${v.toString(16)}: OUT1/OUT2 are the module RESET/PGM lines`);
        if (v & 0x10) this.errors.push('MCR loopback');
        const before = this.rtsOn();
        this.mcr = v & 0x3f;
        this.afeLevel(); this.setRts(before, t);
        return;
      }
      case 7: this.scr = v; return;
      default: this.errors.push(`write to read-only UART register ${off}`);
    }
  }
  thr(v, t) {
    const bu = this.byteUs();
    const queued = this.txq.filter((x) => x.done - bu > t).length;   // not yet started
    if (queued >= 16) { this.errors.push('TX FIFO overrun (THR written while full)'); return; }
    if ((this.lcr & 0x7f) !== 0x03) this.errors.push(`TX with LCR=0x${this.lcr.toString(16)} (not 8N1)`);
    const done = Math.max(this.txFree, t) + bu;
    this.txFree = done;
    this.txq.push({ b: v, done });
  }

  pending() { return this.out.length + (this.cur ? 1 : 0); }
}

// ---------------------------------------------------------------------------
// ESP-AT 2.2 module (CIPMUX=1, link 0) with a payload-level peer.
// ---------------------------------------------------------------------------
class EspAt {
  constructor(card, o) {
    this.card = card;
    this.fw = o.fw || '2.2.2';
    this.respUs = o.respUs ?? 300;          // command processing time
    this.connectUs = o.connectUs ?? 3000;
    this.netUs = o.netUs ?? 2000;           // one-way network delay
    this.sendUs = o.sendUs ?? 1000;         // payload to SEND OK
    this.busyFirst = o.busyFirst ?? 0;      // first N commands answer "busy p..."
    this.sendFail = o.sendFail ?? 0;        // next N CIPSENDs end with SEND FAIL
    this.connectFail = !!o.connectFail;
    this.window = o.window ?? 5760;         // module receive buffer (passive TCP)
    this.trickleUs = o.trickleUs ?? 0;      // >0: CIPRECVDATA answers come one byte per trickleUs
    this.recvCap = o.recvCap ?? 0;          // >0: a CIPRECVDATA answer carries at most this many bytes
    this.zeroAnswers = o.zeroAnswers ?? 0;  // next N CIPRECVDATA answers are "+CIPRECVDATA:0,"
    this.mute = false;                      // true: commands get no answer at all
    this.echo = true; this.mux = 0; this.recvMode = 0; this.dinfo = 1;
    this.line = []; this.dataLeft = 0; this.data = [];
    this.link = null;                       // { proto, held: [], notice }
    this.cmds = [];                         // command lines received
    this.peer = new NetPeer(this, o.peer || {});
  }

  out(t, s) { this.card.emit(t, s); }
  input(b, t) {
    if (this.dataLeft > 0) {               // CIPSEND payload
      this.data.push(b);
      if (--this.dataLeft === 0) this.sent(t);
      return;
    }
    this.line.push(b);
    const n = this.line.length;
    if (n > 256) { this.card.errors.push('AT line longer than 256 bytes'); this.line = []; }
    if (n >= 2 && this.line[n - 2] === 13 && this.line[n - 1] === 10) {
      const text = Buffer.from(this.line.slice(0, -2)).toString('latin1');
      this.line = [];
      this.command(text, t);
    }
  }

  command(text, t) {
    this.cmds.push(text);
    if (this.mute) return;
    const at = t + this.respUs;
    if (this.echo) this.out(at, text + '\r\n');
    if (this.busyFirst > 0) { this.busyFirst--; this.out(at, '\r\nbusy p...\r\n'); return; }
    const ok = () => this.out(at, '\r\nOK\r\n');
    const err = () => this.out(at, '\r\nERROR\r\n');
    const v22 = this.fw !== '2.2.1';
    let m;
    if (text === 'AT') return ok();
    if (text === 'ATE0') { this.echo = false; return ok(); }
    if (text === 'ATE1') { this.echo = true; return ok(); }
    if ((m = /^AT\+CIPMUX=([01])$/.exec(text))) {
      if (this.link) return err();
      this.mux = +m[1]; return ok();
    }
    if ((m = /^AT\+CIPRECVMODE=([01])$/.exec(text))) {
      if (!v22) return err();
      this.recvMode = +m[1]; return ok();
    }
    if ((m = /^AT\+CIPDINFO=([01])$/.exec(text))) { this.dinfo = +m[1]; return ok(); }
    if (/^AT\+CIPTCPOPT=\d,-?\d+,[01],\d+$/.test(text)) return v22 ? ok() : err();
    if ((m = /^AT\+CIPCLOSE=([0-5])$/.exec(text))) {
      const id = +m[1];
      if (this.link && (id === 0 || id === 5)) {
        this.peer.closedByModule(at);
        this.link = null;
        this.out(at, '0,CLOSED\r\n');
        return ok();
      }
      return id === 5 ? ok() : err();
    }
    if ((m = /^AT\+CIPSTART=0,"(TCP|UDP)","(\d+\.\d+\.\d+\.\d+)",(\d+)(?:,(\d+),(\d))?$/.exec(text))) {
      if (!this.mux) return err();
      if (this.link) { this.out(at, 'ALREADY CONNECTED\r\n'); return err(); }
      const proto = m[1];
      if (proto === 'TCP' && m[4] !== undefined) return err();
      const conn = { proto, host: m[2], port: +m[3], lport: m[4] !== undefined ? +m[4] : 0, held: [], notice: false };
      this.peer.target = conn;
      if (this.connectFail) {
        this.card.at(at + this.connectUs, (tt) => { this.out(at + this.connectUs, '0,CONNECT FAIL\r\n\r\nERROR\r\n'); });
        return;
      }
      this.card.at(at + this.connectUs, () => {
        this.link = conn;
        this.peer.connected(conn, at + this.connectUs);
        this.out(at + this.connectUs, '0,CONNECT\r\n\r\nOK\r\n');
      });
      return;
    }
    if ((m = /^AT\+CIPSEND=0,(\d+)$/.exec(text))) {
      const n = +m[1];
      if (!this.link || n < 1 || n > 2048) return err();
      this.out(at, '\r\nOK\r\n\r\n>');
      this.dataLeft = n; this.data = [];
      return;
    }
    if ((m = /^AT\+CIPRECVDATA=0,(\d+)$/.exec(text))) {
      const l = this.link;
      if (!this.recvMode || !l || l.proto !== 'TCP' || !l.held.length || +m[1] < 1) return err();
      if (this.zeroAnswers > 0) { this.zeroAnswers--; this.out(at, '+CIPRECVDATA:0,\r\nOK\r\n'); l.notice = false; return; }
      const n = Math.min(+m[1], l.held.length, this.recvCap || Infinity);
      const d = l.held.splice(0, n);
      const ans = Buffer.concat([Buffer.from(`+CIPRECVDATA:${n},`, 'latin1'), Buffer.from(d), Buffer.from('\r\nOK\r\n', 'latin1')]);
      if (this.trickleUs) ans.forEach((b, i) => this.card.emit(at + i * this.trickleUs, Buffer.from([b])));
      else this.out(at, ans);
      l.notice = false;
      this.notice(at);
      this.peer.windowOpened(at);
      return;
    }
    if (text === 'AT+CIPRECVLEN?') {
      if (!this.recvMode) return err();
      const n = this.link && this.link.proto === 'TCP' ? this.link.held.length : 0;
      this.out(at, `+CIPRECVLEN:${n},0,0,0,0\r\n\r\nOK\r\n`);
      return;
    }
    this.card.errors.push(`unknown AT command: ${JSON.stringify(text)}`);
    return err();
  }

  sent(t) {
    const d = this.data; this.data = [];
    const at = t + this.respUs;
    this.out(at, `\r\nRecv ${d.length} bytes\r\n`);
    if (this.sendFail > 0) { this.sendFail--; this.out(at + this.sendUs, '\r\nSEND FAIL\r\n'); return; }
    this.card.at(at + this.sendUs, () => {
      if (!this.link) return;
      this.out(at + this.sendUs, '\r\nSEND OK\r\n');
      this.peer.receive(this.link, d, at + this.sendUs);
    });
  }

  // data from the network for link 0
  arrive(conn, d, t) {
    if (this.link !== conn) return false;
    if (conn.proto === 'UDP') {
      this.out(t, Buffer.concat([Buffer.from(`\r\n+IPD,0,${d.length}:`, 'latin1'), Buffer.from(d)]));
      return true;
    }
    if (!this.recvMode) {
      this.out(t, Buffer.concat([Buffer.from(`\r\n+IPD,0,${d.length}:`, 'latin1'), Buffer.from(d)]));
      return true;
    }
    if (conn.held.length + d.length > this.window) return false;    // peer must wait
    conn.held.push(...d);
    this.notice(t);
    return true;
  }
  notice(t) {
    const l = this.link;
    if (!l || l.notice || !l.held.length) return;
    l.notice = true;
    this.out(t, `\r\n+IPD,0,${l.held.length}\r\n`);
  }
  // the peer closed the TCP link: held data stays readable, CLOSED follows it
  peerClosed(conn, t) {
    if (this.link !== conn) return;
    const finish = () => {
      if (this.link !== conn) return;
      if (conn.held.length) { this.card.at(this.card.now() + 2000, finish); return; }
      this.link = null;
      this.out(Math.max(t, this.card.now()), '0,CLOSED\r\n');
    };
    finish();
  }

  // test hooks (t defaults to the card clock)
  reboot(t = this.card.now()) {
    this.echo = true; this.mux = 0; this.recvMode = 0; this.link = null; this.dataLeft = 0; this.line = [];
    this.out(t, Buffer.from([0x00, 0xfe, 0x8a, 0x13]));    // boot ROM noise at 74880 baud
    this.out(t + 300, '\r\nready\r\n');
  }
  wifiDrop(t = this.card.now()) {
    this.out(t, 'WIFI DISCONNECT\r\n');
    if (this.link) { this.link = null; this.out(t, '0,CLOSED\r\n'); }
  }
}

// Payload-level peer: TCP echo server or UDP echo, with a network delay.
class NetPeer {
  constructor(esp, o) {
    this.esp = esp;
    this.echo = o.echo !== false;
    this.received = [];                     // TCP bytes from the DLL
    this.udpIn = [];                        // UDP datagrams from the DLL
    this.errors = [];
    this.pendingOut = [];                   // TCP bytes waiting for module window
    this.conn = null; this.target = null; this.closes = 0;
  }
  connected(conn) { this.conn = conn; }
  closedByModule() { this.closes++; this.conn = null; this.pendingOut = []; }
  receive(conn, d, t) {
    if (conn.proto === 'UDP') this.udpIn.push(d); else this.received.push(...d);
    if (this.echo) this.send(d, t + this.esp.netUs * 2, conn);
  }
  send(d, t, conn = this.conn) {
    if (!conn) return;
    const card = this.esp.card;
    card.at(t, () => {
      if (conn.proto === 'UDP') { this.esp.arrive(conn, d, t); return; }
      this.pendingOut.push(...d);
      this.flush(t);
    });
  }
  flush(t) {
    const conn = this.conn;
    if (!conn || !this.pendingOut.length) return;
    const room = this.esp.window - conn.held.length;
    if (room <= 0) return;
    const d = this.pendingOut.splice(0, room);
    this.esp.arrive(conn, d, t);
  }
  windowOpened(t) { this.esp.card.at(t + this.esp.netUs, () => this.flush(t + this.esp.netUs)); }
  // test API (same names as net/peer.js where they overlap)
  sendData(bytes) { this.send(bytes, this.esp.card.now() + this.esp.netUs); }
  close() {
    const conn = this.conn;
    if (!conn) return;
    const t = this.esp.card.now() + this.esp.netUs;
    this.esp.card.at(t, () => { this.conn = null; this.esp.peerClosed(conn, t); });
  }
}

module.exports = { EspCard, EspAt, NetPeer };
