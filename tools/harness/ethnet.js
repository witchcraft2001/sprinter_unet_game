// ethnet.js -- wire a Stand, a card model (3C509B or RTL8019AS, chosen by
// the DLL name) and a Peer together.
'use strict';
const { Stand, C } = require('./stand.js');
const { EL3 } = require('./devices/el3.js');
const { Rtl8019 } = require('./devices/rtl8019.js');
const { EspCard } = require('./devices/esp.js');
const { Peer } = require('./net/peer.js');

const isRtl = (dll) => /rtl$/.test(dll);
const isEsp = (dll) => /esp$/.test(dll);

// ESP builds: the UART + ESP-AT model with its payload-level peer.  The
// UART line runs on virtual time: tick() moves the card clock with s.t,
// idle(ms) moves it without a STEP (time between calls).
function espStand(opts) {
  const dll = opts.dll;
  const s = new Stand({ dll, mhz: opts.mhz });
  const card = new EspCard(opts.card || {});
  card.attach(s.m);
  s.card = card; s.peer = card.peer; s.esp = card.esp; s.isEsp = true;
  s.t = opts.t0 ?? 1000;
  card.advance(s.t);
  s.pump = () => card.advance(s.t);
  s.idle = (ms) => { s.t = (s.t + ms) >>> 0; card.advance(s.t); };
  s.tick = (dt = 10, budget = opts.budget ?? 400) => {
    s.t = (s.t + dt) >>> 0;
    card.advance(s.t);
    const r = s.step(s.t, budget);
    card.advance(s.t);
    if (card.errors.length) r.problems.push(...card.errors.splice(0).map((e) => `esp model: ${e}`));
    return r;
  };
  return s;
}

function ethStand(opts = {}) {
  const dll = opts.dll || 'gtcp509b';
  if (isEsp(dll)) return espStand(opts);
  const s = new Stand({ dll, mhz: opts.mhz });
  const card = isRtl(dll) ? new Rtl8019(opts.card || {}) : new EL3(opts.card || {});
  card.attach(s.m);
  const peer = new Peer(opts.peer || {});
  card.onTransmit = (f) => peer.input(f);
  s.card = card; s.peer = peer;
  s.cardMac = () => (isRtl(dll) ? card.par : card.station);
  s.t = opts.t0 ?? 1000;
  s.pump = () => { peer.tick(s.t); for (const f of peer.out.splice(0)) card.deliver(f); };
  s.idle = (ms) => { s.t = (s.t + ms) >>> 0; };
  s.tick = (dt = 10, budget = opts.budget ?? 500) => {
    s.pump();
    s.t = (s.t + dt) >>> 0;
    const r = s.step(s.t, budget);
    s.pump();
    return r;
  };
  return s;
}
module.exports = { ethStand, isRtl, isEsp, C };
