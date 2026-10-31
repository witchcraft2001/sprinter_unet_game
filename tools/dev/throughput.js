#!/usr/bin/env node
// throughput.js -- echo throughput (KiB/s per direction) and the DLL's ACK
// latency for peer data on the Ethernet builds, STEP every 2 ms.
// Usage: node tools/dev/throughput.js [dll ...]
'use strict';
const { boot, bytes, has, stream } = require('../../tests/z/hw/eth_scenarios.js');
const { be32 } = require('../harness/net/peer.js');
const dlls = process.argv.slice(2).length ? process.argv.slice(2) : ['gtcprtl', 'gtcp509b', 'gudprtl', 'gudp509b'];
for (const dll of dlls) {
  const s = boot(dll, {}, { peer: { rto: 1e9 } });
  s.open(); s.until(has('CONNECTED'));
  const p = s.peer, sentAt = new Map(), lat = [];
  if (!dll.startsWith('gudp')) {
    const origSend = p.sendData.bind(p);
    p.sendData = (b) => { sentAt.set((p.tcp.snd + b.length) >>> 0, s.t); origSend(b); };
    const origIn = p.input.bind(p);
    s.card.onTransmit = (f) => {
      if (f[23] === 6 && (f[47] & 0x10)) { const a = be32(f, 42); if (sentAt.has(a)) { lat.push(s.t - sentAt.get(a)); sentAt.delete(a); } }
      origIn(f);
    };
  }
  const n = 8192, t0 = s.t;
  const rx = stream(s, bytes(n, 3), dll.startsWith('gudp') ? 512 : 536);
  const sec = (s.t - t0) / 1000;
  lat.sort((a, b) => a - b);
  const st = s.getStats().stats;
  console.log(`${dll.padEnd(9)} ${(n / sec / 1024).toFixed(2)} KiB/s per direction, intact ${JSON.stringify(rx) === JSON.stringify(bytes(n, 3))}` +
    (lat.length ? `, ACK latency median ${lat[lat.length >> 1]} ms max ${lat[lat.length - 1]} ms` : '') +
    `, hw_overflow ${st.hw_overflow}, retransmits ${st.tcp_retransmits}`);
}
