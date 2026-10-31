#!/usr/bin/env node
// trace.js -- per-STEP trace of an Ethernet build after OPEN: status, time,
// timer cache, ARP/TCP/engine states and every budget call with its caller.
'use strict';
const { ethStand } = require('../harness/ethnet.js');
const A = require('../harness/abi.json');
const dll = process.argv[2] || 'gtcp509b';
const steps = +(process.argv[3] || 24);
const s = ethStand({ dll });
s.call('INIT');
const cfg = s.defaultConfig({ step_budget_us: 500 });
if (dll.startsWith('gudp')) { cfg.tx_slot_size = 512; cfg.rx_slot_size = 512; }
s.initConfig(cfg);
for (let i = 0; i < 200 && s.ctx('hw_state') !== 2; i++) s.tick(10, 500);
s.open();
if (process.argv[4] === 'send') {
  for (let i = 0; i < 60 && !s.events().some((e) => e.name === 'CONNECTED'); i++) s.tick(10, 500);
  const x = s.send(Array.from({ length: +(process.argv[5] || 300) }, (_, i) => (i * 7) & 255), 0x42);
  console.log('send', x.res.a, x.commit && x.commit.a);
}
const ctx = s.layout().ctx, F = A.ctx.fields, ua = ctx + F.units.offset;
const syms = Object.entries(s.syms).filter(([k]) => !k.includes('.') && /^[A-Z]/.test(k)).map(([k, v]) => [s.base + 0x20 + v, k]).sort((a, b) => a[0] - b[0]);
const owner = (pc) => { let b = '?'; for (const [a, k] of syms) { if (a <= pc) b = k; else break; } return b; };
const pts = {}; for (const l of ['TAKE', 'BUDGET_BYTES']) pts[s.sym(l)] = l;
for (let i = 0; i < steps; i++) {
  const log = [];
  s.pump(); s.t += 10;
  const r = s.step(s.t, 500, 0, { onStep: (m, st) => { const l = pts[st.pc]; if (l) log.push(`${l === 'TAKE' ? '' : 'BB'}${(st.h << 8) | st.l}@${owner(m.peek16(st.sp) - 3)}/${m.peek16(ua)}`); } });
  s.pump();
  const tp = s.m.peekBytes(ctx + F.tp.offset, 72), hw = s.m.peekBytes(ctx + F.hwsm.offset, 56), arp = s.m.peekBytes(ctx + F.arp.offset, 32);
  console.log(i, 'st', r.a, r.us.toFixed(0), 'tmr', s.ctx('tmr_flags'), 'arp', arp[0], arp[20], 'tcp', tp[0], tp[1], 'prep', tp[59], 'rxs', hw[16], 'txs', hw[31], 'peer', s.peer.sent.length, r.problems.join(';'));
  console.log('   ', log.join(' '));
}
