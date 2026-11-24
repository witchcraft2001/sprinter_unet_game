#!/usr/bin/env node
// pkt_steps.js -- how many STEPs one packet takes at a given STEP budget:
// from TX_COMMIT to its TX_DONE and to the whole echo, on the Z stand
// (one packet at a time, the peer echoes at once).  The latency of a
// packet under a quota is (STEPs) x (the period between STEPs): the
// numbers explain NETDEMO's LATMS line (scenarios T and Q).
//   node tools/dev/pkt_steps.js [--budgets a,b,...] [--sizes a,b,...] [dll ...]
// "wire" is the STEP in which the card started the frame (Ethernet cards:
// what the partner waits for; TX_DONE only frees the slot), "rx" the STEPs
// from there to the whole echo (the echo reaches the card right after the
// STEP that sent the frame).
// (default: the six card builds at the minimum budget, 1500 and 2000 us; a
// budget INIT_CONFIG refuses is reported as such)
// Budgets and times are REAL microseconds of the board (the stand runs with
// the memory waits of turbo mode).  Also prints the time of all those STEPs
// together: what the packet costs in the quota.
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
  const res = { tx: [], echo: [], wire: [], us: [], max: 0, probs: 0 };
  for (let k = 0; k < n; k++) {
    const data = bytes(size, 7 + k);
    const x = s.send(data, k + 1);
    if (x.res.a !== S.OK || x.commit.a !== S.OK) throw new Error(`send ${x.res.a}`);
    let got = 0, tx = 0, echo = 0, us = 0, wire = 0;
    const sent0 = s.card && s.card.transmitted ? s.card.transmitted.length : -1;
    for (let i = 1; i <= 4000 && (!tx || !echo); i++) {
      const r = s.tick(2, budget, {});
      us += r.us ?? 0;
      res.max = Math.max(res.max, r.us ?? 0);
      res.probs += r.problems.length;
      if (!wire && sent0 >= 0 && s.card.transmitted.length > sent0) wire = i;
      if (!tx && s.events().some((e) => e.name === 'TX_DONE')) tx = i;
      got += s.drain().bytes.length;
      if (!echo && got >= size) echo = i;
    }
    if (!tx || !echo) throw new Error(`${dll} budget ${budget} size ${size}: no ${tx ? 'echo' : 'TX_DONE'}`);
    res.tx.push(tx); res.echo.push(echo); res.us.push(us); res.wire.push(wire);
    s.run(20); s.events(); s.drain();
  }
  const mean = (a) => (a.reduce((p, q) => p + q, 0) / a.length);
  return { tx: mean(res.tx), txMax: Math.max(...res.tx), wire: mean(res.wire), wireMax: Math.max(...res.wire), echo: mean(res.echo), echoMax: Math.max(...res.echo), us: mean(res.us),
    max: res.max, probs: res.probs + s.probs.length };
}

const argv = process.argv.slice(2);
const bi = argv.indexOf('--budgets');
const extra = bi >= 0 ? argv.splice(bi, 2)[1].split(',').map(Number) : null;
const zi = argv.indexOf('--sizes');
const sizes = zi >= 0 ? argv.splice(zi, 2)[1].split(',').map(Number) : [16, 64, 300];
const dlls = argv.length ? argv : ['gtcpesp', 'gudpesp', 'gtcprtl', 'gudprtl', 'gtcp509b', 'gudp509b'];
console.log('dll        budget  bytes  STEPs: wire mean/max  TX_DONE mean/max   echo mean/max   rx (echo - wire)  real us of them  longest STEP us  stand problems');
for (const dll of dlls) {
  const min = boot(dll).getInfo().info.min_useful_budget_us;
  for (const size of sizes) {
    for (const budget of extra || [min, 1500, 2000]) {
      try {
        const r = one(dll, budget, size);
        const w = r.wire ? `${r.wire.toFixed(1).padStart(6)} / ${String(r.wireMax).padEnd(3)}` : '     - / -  ';
        console.log(`${dll.padEnd(10)} ${String(budget).padStart(6)} ${String(size).padStart(6)}       ${w}     ${r.tx.toFixed(1).padStart(6)} / ${String(r.txMax).padEnd(4)}    ${r.echo.toFixed(1).padStart(6)} / ${String(r.echoMax).padEnd(4)}   ${(r.wire ? (r.echo - r.wire).toFixed(1) : '-').padStart(6)}          ${r.us ? Math.round(r.us) : '-'}   ${Math.round(r.max)}   ${r.probs}`);
      } catch (e) { console.log(`${dll.padEnd(10)} ${String(budget).padStart(6)} ${String(size).padStart(6)}  ${e.message}`); }
    }
  }
}
