// sdk_rate.js -- echo throughput through the real SDK gateway on the Z
// application stand, by STEPs per 20 ms budget period.
// Usage: node tools/dev/sdk_rate.js [dll ...] [--steps 2,5,10] [--bytes 2048]
'use strict';
const { AppStand, BUF } = require('../harness/appstand.js');
const { decodeBlock } = require('../harness/stand.js');

const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args.splice(i, 2)[1] : d; };
const steps = opt('--steps', '2,5,10').split(',').map(Number);
const total = Number(opt('--bytes', '2048'));
const dlls = args.length ? args : ['gtcprtl', 'gtcp509b', 'gudp509b', 'gtcpesp', 'gudpesp'];

for (const dll of dlls) {
  for (const n of steps) {
    const a = new AppStand({ dll });
    a.gwInit(); a.call('INIT'); a.initEnv({}, { steps: n }); a.start(); a.auto = 15;
    a.until(() => a.ctx('hw_state') === 2, 10000);
    a.call('OPEN');
    const ev = [];
    a.until(() => { ev.push(...a.events()); return ev.some((e) => e.name === 'CONNECTED'); }, 10000);
    const piece = dll.startsWith('gudp') ? 512 : 256;
    const d = Array.from({ length: total }, (_, i) => (i * 31 + 5) & 255);
    let off = 0, tag = 1;
    const rx = [], t0 = a.ms();
    a.until(() => {
      if (off < d.length) { const x = a.send(d.slice(off, off + piece), tag); if (x.res.a === 0) { off += piece; tag++; } }
      a.events(); rx.push(...a.drain());
      return rx.length >= d.length;
    }, 120000);
    const sec = (a.ms() - t0) / 1000;
    a.call('GET_STATS', { ix: BUF, de: 80 });
    const st = decodeBlock('STATS', Uint8Array.from(a.m.peekBytes(BUF, 80)));
    const b = a.block();
    console.log(`${dll} steps/period ${n}: ${(total / 1024 / sec).toFixed(2)} KiB/s each way, intact ${JSON.stringify(rx) === JSON.stringify(d)}, ` +
      `hw_overflow ${st.hw_overflow}, uart_overrun ${st.uart_overrun}, quota sum ${b.sum} us, largest period debit ${b.debitMax} us, problems ${a.problems.length}` + (a.problems.length ? ` (${a.problems.slice(0, 2).join("; ")})` : ""));
  }
}
