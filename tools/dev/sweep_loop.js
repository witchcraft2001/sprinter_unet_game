#!/usr/bin/env node
// sweep_loop.js -- GLOOP budget sweep: budgets x payload sizes x TCP/UDP.
// Reports any STEP above its budget and the smallest budget that moves data.
'use strict';
const { Stand, C } = require('../harness/stand.js');
let over = 0, minProgress = null, maxRatio = 0;
for (const B of [260, 300, 350, 400, 450, 500]) {
  let progressed = true;
  for (const n of [1, 7, 64, 200, 536]) for (const tp of ['TCP', 'UDP']) {
    const s = new Stand({ dll: 'gloop' }); s.call('INIT');
    const cfg = s.defaultConfig({ step_budget_us: B, transport: C.transport[tp] });
    if (tp === 'UDP') { cfg.tx_slot_size = 512; cfg.rx_slot_size = 512; }
    if (s.initConfig(cfg).a) { progressed = false; continue; }
    s.open(); let t = 1000; s.step(t, B); s.events();
    const sz = Math.min(n, tp === 'UDP' ? 512 : 536), d = Array.from({ length: sz }, (_, i) => (i * 7) & 255);
    for (let k = 0; k < 3; k++) s.send(d, 0x100 + k);
    for (let i = 0; i < 1500; i++) { const r = s.step(t += 10, B); maxRatio = Math.max(maxRatio, r.us / B); if (r.us > B) over++; s.events(); if (r.a === C.status.IDLE) break; }
    if (s.drain().bytes.length !== 3 * sz) progressed = false;
  }
  if (progressed && minProgress === null) minProgress = B;
}
console.log(JSON.stringify({ over, minProgress, maxRatio: +maxRatio.toFixed(3) }));
process.exit(over ? 1 : 0);
