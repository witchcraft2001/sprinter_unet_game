// ethnet.js -- wire a Stand, an EL3 card model and a Peer together.
'use strict';
const { Stand, C } = require('./stand.js');
const { EL3 } = require('./devices/el3.js');
const { Peer } = require('./net/peer.js');

function ethStand(opts = {}) {
  const s = new Stand({ dll: opts.dll || 'gtcp509b', mhz: opts.mhz });
  const card = new EL3(opts.card || {});
  card.attach(s.m);
  const peer = new Peer(opts.peer || {});
  card.onTransmit = (f) => peer.input(f);
  s.card = card; s.peer = peer;
  s.t = opts.t0 ?? 1000;
  s.pump = () => { for (const f of peer.out.splice(0)) card.deliver(f); };
  s.tick = (dt = 10, budget = opts.budget ?? 500) => {
    s.pump();
    s.t = (s.t + dt) >>> 0;
    const r = s.step(s.t, budget);
    s.pump();
    return r;
  };
  return s;
}
module.exports = { ethStand, C };
