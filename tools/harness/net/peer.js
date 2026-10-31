// peer.js -- scripted network partner for the Ethernet builds.
// SPDX-License-Identifier: BSD-3-Clause
//
// Answers ARP for its addresses, runs one TCP server connection and a UDP
// echo, and validates every frame the DLL sends: Ethernet length, IPv4
// header checksum, TCP/UDP checksum.  Invalid frames are recorded in
// `errors` (the tests assert there are none).
'use strict';

const be16 = (b, o) => (b[o] << 8) | b[o + 1];
const be32 = (b, o) => ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0;
const put16 = (b, o, v) => { b[o] = (v >> 8) & 255; b[o + 1] = v & 255; };
const put32 = (b, o, v) => { b[o] = (v >>> 24) & 255; b[o + 1] = (v >>> 16) & 255; b[o + 2] = (v >>> 8) & 255; b[o + 3] = v & 255; };
const ip4 = (s) => s.split('.').map(Number);
const eq = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);

function sum16(bytes, start, len, acc = 0) {
  for (let i = 0; i < len; i += 2) acc += (bytes[start + i] << 8) | (i + 1 < len ? bytes[start + i + 1] : 0);
  while (acc > 0xffff) acc = (acc & 0xffff) + (acc >>> 16);
  return acc;
}
function l4sum(frame, proto, len) {
  let acc = sum16(frame, 26, 8);
  acc += proto + len;
  return sum16(frame, 34, len, acc);
}

class Peer {
  constructor(opts = {}) {
    this.mac = opts.mac ?? [0x02, 0x00, 0x00, 0x00, 0x00, 0x02];
    this.ip = ip4(opts.ip ?? '192.168.0.2');
    this.port = opts.port ?? 7000;
    this.answerArp = opts.answerArp !== false;
    this.echo = opts.echo !== false;
    this.dropEvery = opts.dropEvery ?? 0;     // drop every N-th data segment from the DLL
    this.window = opts.window ?? 4096;
    this.errors = []; this.sent = []; this.log = []; this.received = [];
    this.tcp = null; this.udpIn = []; this.arpRequests = 0; this.segments = 0;
    this.out = [];                            // frames to deliver to the card
  }

  frame(dstMac, type, payload) { return [...dstMac, ...this.mac, type >> 8, type & 255, ...payload]; }

  ipFrame(dllMac, dllIp, proto, l4) {
    const ip = new Array(20).fill(0);
    ip[0] = 0x45; put16(ip, 2, 20 + l4.length); ip[6] = 0x40; ip[8] = 64; ip[9] = proto;
    ip.splice(12, 4, ...this.ip); ip.splice(16, 4, ...dllIp);
    put16(ip, 10, (~sum16(ip, 0, 20)) & 0xffff);
    const f = this.frame(dllMac, 0x0800, [...ip, ...l4]);
    const len = l4.length;
    if (proto === 6) put16(f, 50, (~l4sum(f, 6, len)) & 0xffff);
    if (proto === 17) { let c = (~l4sum(f, 17, len)) & 0xffff; if (c === 0) c = 0xffff; put16(f, 40, c); }
    return f;
  }

  tcpSegment(c, flags, data = [], opts = []) {
    const hl = 20 + opts.length;
    const t = new Array(hl).fill(0);
    put16(t, 0, this.port); put16(t, 2, c.dllPort); put32(t, 4, c.snd); put32(t, 8, c.rcv);
    t[12] = (hl / 4) << 4; t[13] = flags; put16(t, 14, this.window);
    opts.forEach((v, i) => { t[20 + i] = v; });
    return this.ipFrame(c.dllMac, c.dllIp, 6, [...t, ...data]);
  }

  // Frame transmitted by the DLL.
  input(f) {
    this.sent.push(f);
    const type = be16(f, 12);
    if (f.length < 60) this.errors.push(`short frame ${f.length}`);
    if (type === 0x0806) return this.arp(f);
    if (type !== 0x0800) return this.errors.push(`ethertype ${type.toString(16)}`);
    if (f[14] !== 0x45) return this.errors.push('IP header length');
    if (sum16(f, 14, 20) !== 0xffff) this.errors.push('IP header checksum');
    const total = be16(f, 16), len = total - 20, proto = f[23];
    if (proto === 6) {
      if (l4sum(f, 6, len) !== 0xffff) this.errors.push('TCP checksum');
      return this.tcpInput(f, len);
    }
    if (proto === 17) {
      const c = be16(f, 40);
      if (c !== 0 && l4sum(f, 17, len) !== 0xffff) this.errors.push('UDP checksum');
      return this.udpInput(f, len);
    }
    this.errors.push(`IP protocol ${proto}`);
  }

  arp(f) {
    const op = be16(f, 20), tpa = f.slice(38, 42);
    if (op !== 1) return;
    this.arpRequests++;
    if (!this.answerArp || !eq(tpa, this.ip)) return;
    const sha = f.slice(22, 28), spa = f.slice(28, 32);
    const a = [0, 1, 8, 0, 6, 4, 0, 2, ...this.mac, ...this.ip, ...sha, ...spa];
    this.out.push(this.frame(sha, 0x0806, a));
  }

  tcpInput(f, len) {
    const sport = be16(f, 34), dport = be16(f, 36), seq = be32(f, 38), ack = be32(f, 42);
    const hl = (f[46] >> 4) * 4, flags = f[47], data = f.slice(34 + hl, 34 + len);
    if (dport !== this.port) return this.errors.push(`TCP port ${dport}`);
    const dllMac = f.slice(6, 12), dllIp = f.slice(26, 30);
    if (flags & 0x02) {                                   // SYN
      this.tcp = { dllPort: sport, dllMac, dllIp, rcv: (seq + 1) >>> 0, snd: 0x10000000, state: 'syn', mss: hl > 20 ? be16(f, 56) : 536 };
      this.out.push(this.tcpSegment(this.tcp, 0x12, [], [2, 4, 0x02, 0x18]));
      this.tcp.snd = (this.tcp.snd + 1) >>> 0;
      return;
    }
    const c = this.tcp;
    if (!c) return this.errors.push('TCP segment without a connection');
    c.peerWindow = be16(f, 48);
    if (flags & 0x10) c.acked = ack;
    if (c.state === 'syn' && (flags & 0x10)) c.state = 'est';
    if (data.length) {
      this.segments++;
      if (this.dropEvery && this.segments % this.dropEvery === 0) { this.log.push(`dropped seg ${seq}`); return; }
      if (seq === c.rcv) {
        c.rcv = (c.rcv + data.length) >>> 0;
        this.received.push(...data);
        this.out.push(this.tcpSegment(c, 0x10));
        if (this.echo) { this.out.push(this.tcpSegment(c, 0x18, data)); c.snd = (c.snd + data.length) >>> 0; }
      } else {
        this.out.push(this.tcpSegment(c, 0x10));        // duplicate ACK
      }
    }
    if (flags & 0x01) {                                   // FIN
      c.rcv = (c.rcv + 1) >>> 0;
      this.out.push(this.tcpSegment(c, 0x11));
      c.snd = (c.snd + 1) >>> 0;
      c.state = 'closed';
    }
  }

  // Server-side helpers for tests
  sendData(bytes) { const c = this.tcp; this.out.push(this.tcpSegment(c, 0x18, bytes)); c.snd = (c.snd + bytes.length) >>> 0; }
  sendFin() { const c = this.tcp; this.out.push(this.tcpSegment(c, 0x11)); c.snd = (c.snd + 1) >>> 0; }
  sendRst() { const c = this.tcp; this.out.push(this.tcpSegment(c, 0x14)); }

  udpInput(f, len) {
    const sport = be16(f, 34), dport = be16(f, 36), ulen = be16(f, 38);
    if (dport !== this.port) return this.errors.push(`UDP port ${dport}`);
    if (ulen !== len) this.errors.push(`UDP length ${ulen} != ${len}`);
    const data = f.slice(42, 34 + ulen);
    this.udpIn.push(data);
    if (!this.echo) return;
    const u = new Array(8).fill(0);
    put16(u, 0, this.port); put16(u, 2, sport); put16(u, 4, 8 + data.length);
    this.out.push(this.ipFrame(f.slice(6, 12), f.slice(26, 30), 17, [...u, ...data]));
  }
}

module.exports = { Peer, sum16, be16, be32 };
