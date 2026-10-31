#!/usr/bin/env node
// di_find.js -- report the STEPs whose longest DI section exceeds a limit,
// with the card/RX/TX states before the call.  Usage: node tools/dev/di_find.js gtcprtl [limit_us]
'use strict';
const { ethStand } = require('../harness/ethnet.js');
const dll = process.argv[2] || 'gtcprtl';
const lim = +(process.argv[3] || 150);
const s = ethStand({ dll });
s.call('INIT');
s.initConfig(s.defaultConfig({ step_budget_us: 500 }));
const hs = (o) => s.m.peek(s.layout().ctx + require('../harness/stand.js').ABI.ctx.fields.hwsm.offset + o);
let n = 0;
const go = (k) => { for (let i = 0; i < k; i++) {
  const before = { hw: s.ctx('hw_state'), rxs: hs(16), txs: hs(31), phase: hs(0), step: hs(1) };
  const r = s.tick();
  if (r.maxDiUs > lim) console.log(`step ${n} DI ${r.maxDiUs.toFixed(1)} us`, JSON.stringify(before));
  n++;
} };
go(40); s.open(); go(60); s.events();
s.send(Array.from({ length: 300 }, (_, i) => i & 255), 1); go(80); s.events(); s.drain(); s.call('CLOSE'); go(60);
