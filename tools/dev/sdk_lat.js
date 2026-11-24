#!/usr/bin/env node
// sdk_lat.js -- latency of one packet and the network time per period
// through the real SDK gateway on the Z application stand, in the real time
// of the board: what a game with this profile gets and what it pays.
// One packet at a time: TX_COMMIT -> TX_DONE and -> the whole echo (ms),
// then the time really spent in the gateway paths (UG_ISR_NET + UG_STEP,
// with the core inside) per 20 ms period, and the quota sum of the profile.
// Usage: node tools/dev/sdk_lat.js [dll ...] [--steps n] [--budget us]
//        [--polls ticks] [--isr us] [--bytes 64,300] [--n 12]
//   --steps   STEPs per period (default 1)
//   --budget  STEP body budget, real us (default 2000; 0 = the minimum)
//   --polls   ticks between guaranteed STEP_ISR polls (default 1 = every 2 ms)
'use strict';
const { AppStand } = require('../harness/appstand.js');

const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args.splice(i, 2)[1] : d; };
const steps = +opt('--steps', '1'), budget = +opt('--budget', '2000'), polls = +opt('--polls', '1'), isr = +opt('--isr', '0');
const sizes = opt('--bytes', '64,300').split(',').map(Number), N = +opt('--n', '12');
const dlls = args.length ? args : ['gudp509b', 'gtcp509b', 'gudprtl', 'gtcprtl', 'gudpesp', 'gtcpesp'];
const PERIOD_US = 20000;

console.log(`profile: ${steps} STEP(s) of ${budget || 'min'} us per period, a poll every ${polls} tick(s)`);
console.log('dll        quota sum  bytes   TX_DONE ms mean/max   echo ms mean/max   net us per period mean/max   longest UG_STEP us  problems');
for (const dll of dlls) {
  const a = new AppStand({ dll });
  a.gwInit(); a.call('INIT');
  const env = a.initEnv({}, { steps, step_budget: budget, isr_budget: isr, poll_ticks: polls });
  if (env.a !== 0) { console.log(`${dll.padEnd(10)} refused: status ${env.a}, env ${env.env}`); continue; }
  a.start(); a.auto = 15;
  a.until(() => a.ctx('hw_state') === 2, 10000);
  a.call('OPEN');
  const ev = [];
  a.until(() => { ev.push(...a.events()); return ev.some((e) => e.name === 'CONNECTED'); }, 10000);
  a.runMs(200); a.events(); a.drain();
  for (const size of sizes) {
    const tx = [], echo = [];
    const g0 = { isr: a.gw.UG_ISR_NET.length, step: a.gw.UG_STEP.length }, t0 = a.us();
    for (let k = 0; k < N; k++) {
      a.runMs(7 + (k * 3) % 13);                    // not in phase with the period
      const d = Array.from({ length: size }, (_, i) => (i * 31 + k) & 255);
      const x = a.send(d, k + 1);
      if (x.res.a !== 0 || x.commit.a !== 0) throw new Error(`${dll}: send ${x.res.a}`);
      const s0 = a.ms();
      let done = -1, got = 0, all = -1;
      a.until(() => {
        if (done < 0 && a.events().some((e) => e.name === 'TX_DONE')) done = a.ms() - s0;
        got += a.drain().length;
        if (all < 0 && got >= size) all = a.ms() - s0;
        return done >= 0 && all >= 0;
      }, 20000);
      tx.push(done); echo.push(all);
    }
    // time really spent in the gateway paths, per period
    const per = {};
    const add = (g) => { const p = Math.floor((g.at - t0) / PERIOD_US); per[p] = (per[p] || 0) + g.us; };
    a.gw.UG_ISR_NET.slice(g0.isr).forEach(add);
    // (a refusal "early" is this stand program asking every pass of its
    // main loop; a game calls UG_STEP once per frame)
    a.gw.UG_STEP.slice(g0.step).filter((g) => g.kind !== 'early').forEach(add);
    const v = Object.values(per), mean = (x) => x.reduce((p, q) => p + q, 0) / Math.max(1, x.length);
    const stepMax = Math.max(0, ...a.gw.UG_STEP.slice(g0.step).map((g) => g.us));
    console.log(`${dll.padEnd(10)} ${String(a.block().sum).padStart(8)}  ${String(size).padStart(5)}   ${mean(tx).toFixed(0).padStart(6)} / ${Math.max(...tx).toFixed(0).padEnd(5)}      ${mean(echo).toFixed(0).padStart(6)} / ${Math.max(...echo).toFixed(0).padEnd(5)}     ` +
      `${mean(v).toFixed(0).padStart(6)} / ${Math.max(...v).toFixed(0).padEnd(6)}          ${stepMax.toFixed(0).padStart(6)}        ${a.problems.length}${a.problems.length ? ' ' + a.problems[0] : ''}`);
  }
}
