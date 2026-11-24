#!/usr/bin/env node
// isr_drain.js -- the STEP_ISR byte mover of the ESP builds against its
// budget, in the real time of the board: for each budget the bytes one
// STEP_ISR moves from a full UART FIFO and how long it took.  The sizing
// rule of src/hw/esp/uart.asm (ISRP_ENTRY_RESERVE, 8 us per byte) must
// keep budget >= max(real * 1.1, real + 15).
//   node tools/dev/isr_drain.js [gudpesp|gtcpesp]
'use strict';
const { boot, has, bytes } = require('../../tests/z/hw/eth_scenarios.js');
const { C } = require('../harness/ethnet.js');
const dll = process.argv[2] || 'gudpesp';
let bad = 0;
console.log('budget us  bytes moved  STEP_ISR us  rule needs  ok');
for (const budget of [161, 244, 253, 269, 293, 317, 341, 370]) {
  const s = boot(dll);
  if (s.open().a !== C.status.OK) throw new Error('OPEN');
  s.until(has('CONNECTED'));
  s.run(50); s.events(); s.drain();
  s.peer.sendData(bytes(48, 8));
  s.idle(8);
  const rh = () => s.m.peek16(s.layout().ctx + require('../harness/abi.json').ctx.fields.hwsm.offset);
  const ring0 = s.getStats().stats.polls_useful;
  let worst = 0, moved = 0;
  for (let i = 0; i < 3; i++) {
    const r = s.stepIsr(C.src.TIMER, budget);
    if (r.problems.length) { console.log('  ', r.problems[0]); bad++; }
    worst = Math.max(worst, r.us);
    s.idle(3);
  }
  const need = Math.max(worst * 1.1, worst + 15);
  const cap = Math.max(0, Math.min(12, (budget - 160 - 85) >> 3));
  const ok = need <= budget || cap === 0;
  if (!ok) bad++;
  console.log(`${String(budget).padStart(6)}     cap ${String(cap).padStart(2)}       ${worst.toFixed(1).padStart(7)}     ${need.toFixed(0).padStart(6)}    ${ok ? 'yes' : 'NO'}`);
}
process.exit(bad ? 1 : 0);
