#!/usr/bin/env node
// esp_close_race.js -- GTCPESP: the peer echoes and closes at once (the M
// scenario P, echo_server.py --close-after): the echo must reach the
// application before PEER_CLOSED whatever the STEP timing.  Sweeps the
// STEP budget, the STEP period and the phase of the send.
//   node tools/dev/esp_close_race.js [dll]
'use strict';
const { boot, has, bytes } = require('../../tests/z/hw/eth_scenarios.js');
const { C } = require('../harness/ethnet.js');
const S = C.status;
const dll = process.argv[2] || 'gtcpesp';
let bad = 0, n = 0;
for (const budget of [1047, 1280, 1500, 2000]) {
  for (const dt of [1, 2, 10, 20]) {
    for (let phase = 0; phase < 12; phase++) {
      const s = boot(dll, {}, { budget, dt });
      if (s.open().a !== S.OK) throw new Error('OPEN');
      s.until(has('CONNECTED'), 6000, dt);
      s.run(20 + phase, dt); s.events(); s.drain();
      const recv = s.peer.receive.bind(s.peer);
      // the FIN right behind the echo (never before it: the module would drop the echo)
      s.peer.receive = (conn, d, t) => { recv(conn, d, t); s.peer.esp.card.at(t + s.peer.esp.netUs * 2 + 1, () => s.peer.close()); };
      const d = bytes(64, 5 + phase);
      if (s.send(d, 1).commit.a !== S.OK) throw new Error('send');
      const ev = [], rx = [];
      for (let i = 0; i < 6000 && !ev.includes('CLOSED'); i++) {
        s.run(1, dt);
        ev.push(...s.events().map((e) => e.name));
        rx.push(...s.drain().bytes);
      }
      n++;
      const ok = rx.length === 64 && rx.every((v, i) => v === d[i]) && ev.includes('CLOSED');
      if (!ok) { bad++; console.log(`budget ${budget} dt ${dt} phase ${phase}: rx ${rx.length} events [${ev.join(',')}]`); }
    }
  }
}
console.log(`${dll}: ${n - bad} of ${n} deliver the echo before the close`);
process.exit(bad ? 1 : 0);
