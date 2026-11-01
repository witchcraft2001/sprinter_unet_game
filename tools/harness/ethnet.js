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

// stepOpts.isr = {budget, src}: inject one STEP_ISR call at the midpoint
// of this tick's dt (half the virtual time passes, STEP_ISR runs, the
// rest of dt passes, then the normal STEP) -- models a network IRQ
// landing between two STEPs, with the card's own ISR-side byte pump
// (WP4) getting a chance to drain the UART before the main STEP does.
function injectIsr(s, card, dt, isr) {
  const half = dt >> 1;
  s.t = (s.t + half) >>> 0;
  if (card) card.advance(s.t);
  const ir = s.stepIsr(isr.src ?? C.src.TIMER, isr.budget);
  s.t = (s.t + (dt - half)) >>> 0;
  return ir.problems;
}

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
  s.tick = (dt = 10, budget = opts.budget ?? 400, stepOpts = {}) => {
    const { isr, ...callOpts } = stepOpts;    // isr is ours, not Stand.call's (opts.isr marks an ISR call there)
    let isrProblems = [];
    if (isr) isrProblems = injectIsr(s, card, dt, isr);
    else s.t = (s.t + dt) >>> 0;
    card.advance(s.t);
    const r = s.step(s.t, budget, 0, callOpts);
    card.advance(s.t);
    if (card.errors.length) r.problems.push(...card.errors.splice(0).map((e) => `esp model: ${e}`));
    r.problems.push(...isrProblems);
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
  s.tick = (dt = 10, budget = opts.budget ?? 500, stepOpts = {}) => {
    s.pump();
    const { isr, ...callOpts } = stepOpts;
    let isrProblems = [];
    if (isr) isrProblems = injectIsr(s, null, dt, isr);
    else s.t = (s.t + dt) >>> 0;
    const r = s.step(s.t, budget, 0, callOpts);
    s.pump();
    r.problems.push(...isrProblems);
    return r;
  };
  return s;
}
module.exports = { ethStand, isRtl, isEsp, C };
