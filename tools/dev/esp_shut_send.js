// esp_shut_send.js -- SHUTDOWN of a SprinterESP build while a CIPSEND is in
// progress (command written, prompt pending or payload streaming), swept
// over the STEP it lands on: does the module wait for payload bytes after
// SHUTDOWN OK (model dataLeft > 0)?  Such a module swallows the next
// session's AT commands as payload (Ж, first ESP series: GUDPESP NETDEMO
// FAIL H in nine runs after the UGTEST K soak).
//   node tools/dev/esp_shut_send.js [gudpesp|gtcpesp] [--len n] [--budget us]
'use strict';
const { boot, has, bytes } = require('../../tests/z/hw/eth_scenarios.js');
const { C } = require('../harness/ethnet.js');
const S = C.status;
const args = process.argv.slice(2);
const dll = args.find((a) => !a.startsWith('--') && !/^\d+$/.test(a)) || 'gudpesp';
const opt = (n, d) => { const i = args.indexOf(n); return i >= 0 ? +args[i + 1] : d; };
const len = opt('--len', 512), budget = opt('--budget', 0);
let bad = 0, n = 0;
for (let after = 0; after < 60; after++) {
  const s = boot(dll, {}, budget ? { budget } : {});
  if (s.open().a !== S.OK) throw new Error('OPEN');
  s.until(has('CONNECTED'));
  if (s.send(bytes(len, 3), 1).commit.a !== S.OK) throw new Error('commit');
  s.run(after);
  const sawPrompt = s.esp.dataLeft > 0;
  let r;
  for (let i = 0; i < 3000; i++) { r = s.call('SHUTDOWN'); if (r.a === S.OK) break; s.run(1); s.events(); }
  n++;
  const left = s.esp.dataLeft;
  if (left > 0 || r.a !== S.OK) bad++;
  console.log(`after ${String(after).padStart(2)} STEPs: SHUTDOWN ${r.a === S.OK ? 'OK' : r.a}, ` +
    `streaming before ${sawPrompt ? 'yes' : 'no '}, module waits for ${left} payload bytes`);
}
console.log(`${dll} len ${len}: ${bad} of ${n} SHUTDOWNs leave the module inside a CIPSEND`);
process.exitCode = bad ? 1 : 0;
