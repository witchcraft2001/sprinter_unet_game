#!/usr/bin/env node
// x_cts.js -- GUDPESP's transparent mode while the module holds CTS off.
// On the board the module stops the UART (CTS) while its sending stalls;
// the stand's UART model kept CTS on until 2026-11-24, so the core's TX
// under CTS was never run.  A stream of `--total` bytes in records of
// `--piece` (UGTEST S on Ж: 8192 in 500) goes out with CTS off for `--off`
// ms every `--every` ms at every phase of `--phases`; the bytes the module
// took (every packet it cut) must be the records the core was given, byte
// for byte, and the UART model must see no FIFO overrun.
// Usage: node tools/dev/x_cts.js [--piece 500] [--total 8192] [--every 200]
//        [--off 60] [--phases 12] [--budget 1280] [--dt 20] [--isr 0]
'use strict';
process.env.UG_WAITS = '1';
const { ethStand, C } = require('../harness/ethnet.js');
const xrec = require('../harness/net/xrec.js');

const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf(n); return i >= 0 ? args.splice(i, 2)[1] : d; };
const piece = +opt('--piece', '500'), total = +opt('--total', '8192');
const every = +opt('--every', '200') * 1000, off = +opt('--off', '60') * 1000, phases = +opt('--phases', '12');
const budget = +opt('--budget', '1280'), dt = +opt('--dt', '20'), isr = +opt('--isr', '0');
const S = C.status;

function run(phase) {
  let gateOn = false;
  const gate = (t) => {                     // CTS off in [k*every + phase, + off)
    if (!gateOn) return t;
    const k = Math.floor((t - phase) / every), w0 = k * every + phase;
    return t >= w0 && t < w0 + off ? w0 + off : t;
  };
  const s = ethStand({ dll: 'gudpesp', card: { ctsGate: gate } });
  s.call('INIT');
  const r = s.initConfig(s.defaultConfig({ step_budget_us: budget, esp_fw: 2 }));
  if (r.a !== S.OK) throw new Error(`INIT_CONFIG ${r.a}`);
  s.peer.echo = false;
  for (let i = 0; i < 4000 && s.ctx('hw_state') !== 2; i++) s.tick(2, budget);
  s.open();
  let ok = false;
  for (let i = 0; i < 3000 && !ok; i++) { s.tick(2, budget); ok = s.events().some((e) => e.name === 'CONNECTED'); }
  if (!ok) throw new Error('no CONNECTED');
  const packets = [];
  const flush = s.esp.xFlush.bind(s.esp);
  s.esp.xFlush = (t) => { packets.push(Buffer.from(s.esp.xbuf)); flush(t); };
  gateOn = true;
  const want = [];
  let sent = 0, done = 0, steps = 0, i = 0;
  const problems = [];
  while (done < Math.ceil(total / piece) && steps < 20000) {
    while (sent < total) {
      const n = Math.min(piece, total - sent);
      const data = Array.from({ length: n }, (_, k) => (7 + 31 * (sent + k)) & 255);
      if (s.send(data, (i & 0x7f) + 1).res.a !== S.OK) break;
      want.push(...xrec.encode(data)); sent += n; i++;
    }
    const res = s.tick(dt, budget, isr ? { isr: { budget: isr, n: 1 } } : {});
    problems.push(...res.problems);
    steps++;
    for (const e of s.events()) if (e.name === 'TX_DONE') done++;
  }
  for (let k = 0; k < 200; k++) s.tick(dt, budget);   // the module cuts the last packet
  const got = Buffer.concat(packets);
  const w = Buffer.from(want);
  let first = -1;
  for (let k = 0; k < Math.max(got.length, w.length); k++) if (got[k] !== w[k]) { first = k; break; }
  return { phase, got: got.length, want: w.length, first, problems: [...new Set(problems)], packets: packets.length };
}

let bad = 0;
console.log(`records of ${piece}, ${total} bytes; CTS off ${off / 1000} ms every ${every / 1000} ms; STEP ${budget} us every ${dt} ms${isr ? `, STEP_ISR ${isr}` : ''}`);
for (let p = 0; p < phases; p++) {
  const x = run(Math.round((p * every) / phases));
  const okRun = x.first < 0 && !x.problems.length;
  if (!okRun) bad++;
  console.log(`phase ${(x.phase / 1000).toFixed(1)} ms: ${x.packets} packets, ${x.got} of ${x.want} bytes, ${x.first < 0 ? 'stream exact' : `first wrong byte at ${x.first}`}${x.problems.length ? ' | ' + x.problems.slice(0, 3).join('; ') : ''}`);
}
console.log(bad ? `x_cts: ${bad} of ${phases} runs wrong` : 'x_cts: every run exact');
process.exit(bad ? 1 : 0);
