#!/usr/bin/env node
// pkt_steps.js -- how many STEPs one packet takes at a given STEP budget:
// from TX_COMMIT to its TX_DONE and to the whole echo, on the Z stand
// (one packet at a time, the peer echoes at once).  The latency of a
// packet under a quota is (STEPs) x (the period between STEPs): the
// numbers explain NETDEMO's LATMS line (scenarios T and Q).
//   node tools/dev/pkt_steps.js [--budgets a,b,...] [dll ...]
// (default: the six card builds at the minimum budget and 500; a budget
// INIT_CONFIG refuses is reported as such)
// Also prints the model time of all those STEPs together (us at 21 MHz,
// no memory waits): what the packet costs in the quota.
'use strict';
const { boot, has, bytes } = require('../../tests/z/hw/eth_scenarios.js');
const { C } = require('../harness/ethnet.js');
const S = C.status;

function one(dll, budget, size, n = 8) {
  const s = boot(dll, {}, { budget });
  if (s.open().a !== S.OK) throw new Error('OPEN');
  s.until(has('CONNECTED'), 6000);
  s.run(50);                                  // settle: ARP, window, events
  s.events(); s.drain();
  const res = { tx: [], echo: [], us: [], max: 0, probs: 0 };
  for (let k = 0; k < n; k++) {
    const data = bytes(size, 7 + k);
    const x = s.send(data, k + 1);
    if (x.res.a !== S.OK || x.commit.a !== S.OK) throw new Error(`send ${x.res.a}`);
    let got = 0, tx = 0, echo = 0, us = 0;
    for (let i = 1; i <= 4000 && (!tx || !echo); i++) {
      const r = s.tick(2, budget, {});
      us += r.us ?? 0;
      res.max = Math.max(res.max, r.us ?? 0);
      res.probs += r.problems.length;
      if (!tx && s.events().some((e) => e.name === 'TX_DONE')) tx = i;
      got += s.drain().bytes.length;
      if (!echo && got >= size) echo = i;
    }
    if (!tx || !echo) throw new Error(`${dll} budget ${budget} size ${size}: no ${tx ? 'echo' : 'TX_DONE'}`);
    res.tx.push(tx); res.echo.push(echo); res.us.push(us);
    s.run(20); s.events(); s.drain();
  }
  const mean = (a) => (a.reduce((p, q) => p + q, 0) / a.length);
  return { tx: mean(res.tx), txMax: Math.max(...res.tx), echo: mean(res.echo), echoMax: Math.max(...res.echo), us: mean(res.us),
    max: res.max, probs: res.probs + s.probs.length };
}

const argv = process.argv.slice(2);
const bi = argv.indexOf('--budgets');
const extra = bi >= 0 ? argv.splice(bi, 2)[1].split(',').map(Number) : null;
const dlls = argv.length ? argv : ['gtcpesp', 'gudpesp', 'gtcprtl', 'gudprtl', 'gtcp509b', 'gudp509b'];
console.log('dll        budget  bytes  STEPs to TX_DONE mean/max  STEPs to echo mean/max  model us of them  longest STEP us  stand problems');
for (const dll of dlls) {
  const min = boot(dll).getInfo().info.min_useful_budget_us;
  for (const size of [64, 300]) {
    for (const budget of extra || [min, 500]) {
      try {
        const r = one(dll, budget, size);
        console.log(`${dll.padEnd(10)} ${String(budget).padStart(6)} ${String(size).padStart(6)}  ${r.tx.toFixed(1).padStart(8)} / ${String(r.txMax).padEnd(4)}          ${r.echo.toFixed(1).padStart(8)} / ${String(r.echoMax).padEnd(4)}      ${r.us ? Math.round(r.us) : '-'}   ${Math.round(r.max)}   ${r.probs}`);
      } catch (e) { console.log(`${dll.padEnd(10)} ${String(budget).padStart(6)} ${String(size).padStart(6)}  ${e.message}`); }
    }
  }
}
