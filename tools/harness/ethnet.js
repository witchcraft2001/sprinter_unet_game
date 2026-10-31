// ethnet.js -- wire a Stand, a card model (3C509B or RTL8019AS, chosen by
// the DLL name) and a Peer together.
'use strict';
const { Stand, C } = require('./stand.js');
const { EL3 } = require('./devices/el3.js');
const { Rtl8019 } = require('./devices/rtl8019.js');
const { Peer } = require('./net/peer.js');

const isRtl = (dll) => /rtl$/.test(dll);

function ethStand(opts = {}) {
  const dll = opts.dll || 'gtcp509b';
  const s = new Stand({ dll, mhz: opts.mhz });
  const card = isRtl(dll) ? new Rtl8019(opts.card || {}) : new EL3(opts.card || {});
  card.attach(s.m);
  const peer = new Peer(opts.peer || {});
  card.onTransmit = (f) => peer.input(f);
  s.card = card; s.peer = peer;
  s.cardMac = () => (isRtl(dll) ? card.par : card.station);
  s.t = opts.t0 ?? 1000;
  s.pump = () => { peer.tick(s.t); for (const f of peer.out.splice(0)) card.deliver(f); };
  s.tick = (dt = 10, budget = opts.budget ?? 500) => {
    s.pump();
    s.t = (s.t + dt) >>> 0;
    const r = s.step(s.t, budget);
    s.pump();
    return r;
  };
  return s;
}
module.exports = { ethStand, isRtl, C };
