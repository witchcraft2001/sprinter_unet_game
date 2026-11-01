#!/usr/bin/env node
// gw_costs.js -- the gateway's own paths on the Z application stand: the
// largest UG_ISR_NET and UG_STEP overhead around the core (admitted calls)
// over a 2 KiB echo, against UG_OVH_ISR_US / UG_OVH_STEP_US, and the quota
// sum of the default profile.
// Usage: node tools/dev/gw_costs.js [dll ...] [--steps 5]
'use strict';
const { AppStand, UG } = require('../harness/appstand.js');
const { C } = require('../harness/stand.js');

const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args.splice(i, 2)[1] : def; };
const steps = +opt('--steps', 5);
const dlls = args.length ? args : ['gtcprtl', 'gtcp509b', 'gudprtl', 'gtcpesp'];
const S = C.status;
const bytes = (n, seed = 1) => Array.from({ length: n }, (_, i) => (i * 31 + seed) & 255);

for (const dll of dlls) {
  const sum = (() => {
    const a = new AppStand({ dll });
    a.gwInit(); a.call('INIT'); a.initEnv({}, {});
    return a.block().sum;
  })();
  const a = new AppStand({ dll });
  a.gwInit(); a.call('INIT');
  const env = a.initEnv({}, { steps });
  if (env.a !== S.OK) { console.log(`${dll}: UG_INIT_ENV ${env.a} env ${env.env}`); continue; }
  a.start({}); a.auto = 15;
  if (dll !== 'gloop') a.until(() => a.ctx('hw_state') === 2, 5000);
  a.call('OPEN');
  const ev = [];
  a.until(() => { ev.push(...a.events()); return ev.some((e) => e.name === 'CONNECTED'); }, 6000);
  const d = bytes(2048, 5), piece = dll.startsWith('gudp') ? 512 : 256;
  let off = 0, tag = 1;
  const rx = [];
  a.until(() => {
    if (off < d.length) {
      const n = Math.min(piece, d.length - off);
      const x = a.send(d.slice(off, off + n), tag);
      if (x.res.a === S.OK) { off += n; tag++; }
    }
    a.events();
    rx.push(...a.drain());
    return rx.length >= d.length;
  }, 30000);
  const max = (l) => Math.max(...l.map((g) => g.ovh)).toFixed(1);
  const isr = a.gw.UG_ISR_NET.filter((g) => g.kind === 'admitted'), st = a.gw.UG_STEP.filter((g) => g.kind === 'admitted');
  console.log(`${dll}: quota sum ${sum} us; UG_ISR_NET overhead max ${max(isr)} us (published ${UG.UG_OVH_ISR_US}, n ${isr.length}), ` +
    `UG_STEP overhead max ${max(st)} us (published ${UG.UG_OVH_STEP_US}, n ${st.length})`);
}
