#!/usr/bin/env node
// portions.js -- inclusive time (us, min/max/count) of the card portions and
// card-layer routines over the audit scenario.  Usage: node tools/dev/portions.js gtcprtl [gtcp509b ...]
'use strict';
const { ethStand } = require('../harness/ethnet.js');
const LABELS = ['RUN_PORTION', 'NIC_RX_STATUS', 'RXP_POLL', 'RXP_HEADER', 'RXP_COPY', 'NIC_RX_READ', 'RXP_DISCARD',
  'RXP_DISC_WAIT', 'TXP_BEGIN', 'TXP_DATA', 'TXP_END', 'TXP_CHECK', 'NIC_TX_WRITE', 'NIC_BRINGUP', 'NIC_STOP', 'ISRP_POLL'];
for (const dll of process.argv.slice(2).length ? process.argv.slice(2) : ['gtcprtl']) {
  const s = ethStand({ dll });
  s.call('INIT');
  s.initConfig(s.defaultConfig({ step_budget_us: 500 }));
  const labels = LABELS.filter((l) => l in s.syms);
  const acc = {};
  const run = (k) => { for (let i = 0; i < k; i++) {
    s.pump(); s.t += 10;
    const h = s.inclusiveHook(labels);
    s.step(s.t, 500, 0, { onStep: h.hook });
    s.pump();
    for (const [l, v] of Object.entries(h.result())) (acc[l] ||= []).push(...v);
  } };
  run(60); s.open(); run(60); s.events();
  s.send(Array.from({ length: 300 }, (_, i) => i & 255), 1); run(100); s.events(); s.drain();
  s.call('CLOSE'); run(60);
  console.log(dll);
  for (const [l, v] of Object.entries(acc)) console.log('  ', l.padEnd(14), 'n', String(v.length).padStart(4), 'min', String(Math.min(...v)).padStart(6), 'max', String(Math.max(...v)).padStart(6));
}
