#!/usr/bin/env node
// e2e.js -- manual end-to-end smoke of an Ethernet build on the Z stand:
// bring-up, ARP, connect, send/echo, close.  Usage: node tools/dev/e2e.js [gtcp509b|gudp509b]
'use strict';
const { ethStand } = require('../harness/ethnet.js');
const dll = process.argv[2] || 'gtcp509b';
const s = ethStand({ dll });
s.call('INIT');
const cfg = s.defaultConfig({ step_budget_us: 500 });
if (dll.startsWith('gudp')) { cfg.tx_slot_size = 512; cfg.rx_slot_size = 512; }
console.log('INIT_CONFIG', s.initConfig(cfg).a);
const probs = [];
let boot = 0;
for (let i = 0; i < 200 && s.ctx('hw_state') !== 2; i++) { probs.push(...s.tick().problems); boot++; }
console.log('bring-up steps', boot, 'hw', s.ctx('hw_state'), 'mac', s.cardMac().map((x) => x.toString(16)).join(':'));
console.log('OPEN', s.open().a);
let ev = [], n = 0;
for (; n < 400 && !ev.some((e) => e.name === 'CONNECTED'); n++) { probs.push(...s.tick().problems); ev.push(...s.events()); }
console.log('steps to CONNECTED', n, 'events', ev.map((e) => e.name), 'peer', s.peer.tcp && s.peer.tcp.state, 'peer errors', s.peer.errors);
const d = Array.from({ length: 300 }, (_, i) => (i * 7) & 255);
const x = s.send(d, 0x42);
console.log('send', x.res.a, x.commit && x.commit.a);
ev = []; n = 0;
for (; n < 400 && !(ev.some((e) => e.name === 'RX_READY') && ev.some((e) => e.name === 'TX_DONE')); n++) { probs.push(...s.tick().problems); ev.push(...s.events()); }
console.log('steps to echo', n, 'events', ev.map((e) => e.name + (e.name === 'TX_DONE' ? ':' + e.status : '')),
  'peer got', s.peer.received.length + s.peer.udpIn.reduce((a, b) => a + b.length, 0), 'peer errors', s.peer.errors);
const rx = s.drain();
console.log('rx', rx.bytes.length, 'echo intact', JSON.stringify(rx.bytes) === JSON.stringify(d));
const st = s.getStats().stats;
console.log('stats', JSON.stringify({ rx: st.rx_frames, tx: st.tx_frames, drops: [st.drop_size, st.drop_checksum, st.drop_foreign, st.drop_fragment], rtx: st.tcp_retransmits, busy: st.bus_busy }));
console.log('CLOSE', s.call('CLOSE').a);
ev = []; n = 0;
for (; n < 400 && !ev.some((e) => e.name === 'CLOSED'); n++) { probs.push(...s.tick().problems); ev.push(...s.events()); }
console.log('steps to CLOSED', n, 'events', ev.map((e) => e.name), 'peer', s.peer.tcp && s.peer.tcp.state, 'peer errors', s.peer.errors);
console.log('problems', probs.length, probs.slice(0, 5));
