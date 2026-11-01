// m5_sdk.test.js -- the SDK gateway and time adapters on the Z application
// stand (tools/harness/appstand.js): tests/z/sdk/ugz.asm runs the real
// sdk/gateway/ugate.asm and sdk/time/ugtime.asm around a real DLL with IM2
// interrupts (CTC1 tick, frame pulse, injected key / CBL / card vectors).
// Every direct export call is checked like Stand.call (budget, stack,
// IX/IY/IFF/pages/shadows, lock), every DI section and ISR path, and the
// gateway's own paths against the costs it debits.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { AppStand, UG, DEFAULT_PROFILE, BUF } = require('../../../tools/harness/appstand.js');
const { C, DLLS, decodeBlock, ABI } = require('../../../tools/harness/stand.js');

const S = C.status;
const UHW_RUN = 2;
const CARDS = DLLS.filter((d) => d !== 'gloop');
const bytes = (n, seed = 1) => Array.from({ length: n }, (_, i) => (i * 31 + seed) & 255);
const isUdp = (dll) => dll.startsWith('gudp');

function boot(dll, profile = {}, cfgOver = {}, opts = {}) {
  const a = new AppStand({ dll, ...opts });
  assert.equal(a.gwInit().a, 0);
  assert.equal(a.call('INIT').a, 0);
  a.env = a.initEnv(cfgOver, profile);
  if (a.env.a !== S.OK) return a;
  assert.equal(a.start(opts.start || {}).a, 0);
  a.auto = opts.auto ?? 7;
  return a;
}
const clean = (a) => assert.deepEqual(a.problems, [], a.problems.slice(0, 3).join('; '));
function info(a) { return decodeBlock('INFO', Uint8Array.from(a.m.peekBytes(a.L.lock + UG.UGW_SCRATCH, ABI.blocks.INFO.size))); }
function stats(a) {
  a.call('GET_STATS', { ix: BUF, de: ABI.blocks.STATS.size });
  return decodeBlock('STATS', Uint8Array.from(a.m.peekBytes(BUF, ABI.blocks.STATS.size)));
}
function up(a) { a.until(() => a.ctx('hw_state') === UHW_RUN, 5000); }
function connect(a) {
  assert.equal(a.call('OPEN').a, S.OK);
  const ev = [];
  a.until(() => { ev.push(...a.events()); return ev.some((e) => e.name === 'CONNECTED'); }, 6000);
}
const has = (list, name) => list.some((e) => e.name === name);

// ---- UG_INIT_ENV -------------------------------------------------------------
for (const dll of DLLS) {
  test(`${dll}: UG_INIT_ENV fills the gateway fields and INIT_CONFIG accepts them`, () => {
    const a = boot(dll);
    const e = a.env, b = a.block(), inf = info(a);
    assert.equal(e.a, S.OK, `INIT_CONFIG ${e.a}, env ${e.env}`);
    const isrB = inf.empty_poll_us + inf.min_return_us;
    assert.equal(e.cfg.isr_budget_us, isrB);
    assert.equal(e.cfg.step_budget_us, inf.min_useful_budget_us);
    assert.equal(e.cfg.isa_lock_ptr, a.L.lock);
    assert.equal(e.cfg.shadow_1ffd_ptr, a.L.lock + 1);
    assert.equal(e.cfg.shadow_9fbd_ptr, a.L.lock + 2);
    assert.equal(e.cfg.worst_poll_gap_us, DEFAULT_PROFILE.tick_us + 1 + 200);
    assert.equal(e.cfg.worst_step_gap_ms, 20);
    assert.equal(e.cfg.time_read_cost_us, 20);
    assert.equal(b.costPoll, isrB + UG.UG_OVH_ISR_US);
    assert.equal(b.costStep, inf.min_useful_budget_us + UG.UG_OVH_STEP_US);
    const sum = 10 * b.costPoll + 2 * b.costStep + 100;
    assert.equal(b.sum, sum);
    assert.equal(b.env, sum <= 2000 ? UG.UG_ENV_OK : UG.UG_ENV_OVER);
    assert.ok(b.flags & (1 << UG.UGF_CONFIGURED));
    a.runMs(100);
    clean(a);
  });
}

test('UG_INIT_ENV refusals: target, poll gap, budgets, profile, INIT_CONFIG', () => {
  const cases = [
    [{ flags: 0, target: 1500 }, {}, S.UNSUPPORTED_TIMING, UG.UG_ENV_REFUSED],   // quotas over a strict target
    [{ tick_us: 2400 }, {}, S.UNSUPPORTED_TIMING, UG.UG_ENV_GAP],
    [{ step_budget: 501 }, {}, S.UNSUPPORTED_TIMING, UG.UG_ENV_BUDGET],
    [{ step_budget: 300 }, {}, S.UNSUPPORTED_TIMING, UG.UG_ENV_BUDGET],
    [{ isr_budget: 151 }, {}, S.UNSUPPORTED_TIMING, UG.UG_ENV_BUDGET],
    [{ steps: 0 }, {}, S.BAD_CONFIG, UG.UG_ENV_PROFILE],
    [{}, { isr_stack_len: 0 }, S.BAD_CONFIG, UG.UG_ENV_PROFILE],
    [{}, { ctx_len: 0x100 }, S.BAD_CONFIG, UG.UG_ENV_CONFIG],
  ];
  for (const [prof, over, status, env] of cases) {
    const a = boot('gtcp509b', prof, over);
    assert.equal(a.env.a, status, JSON.stringify(prof) + JSON.stringify(over));
    assert.equal(a.block().env, env, JSON.stringify(prof) + JSON.stringify(over));
    assert.notEqual(a.ctx('state'), C.ctxstate.CONFIGURED, 'no context');
    assert.equal(a.m.peek16(a.s.sym('IMG_CTX_PTR')), 0, 'no context');
    clean(a);
  }
});

// ---- admission ------------------------------------------------------------------
test('gloop: periods, STEP spacing, main quota at the boundary, debit within the quotas', () => {
  const a = boot('gloop');
  const b0 = a.block();
  const bounds = [];
  let enter = null;
  a.onPc('UG_PERIOD', () => { enter = { active: a.b16(UG.UGW_ACTIVE) }; });
  a.onPc('UG_PERIOD_RET', () => { const b = a.block(); bounds.push({ ...enter, q: b.q, at: a.us() }); });
  a.runMs(2000);
  const b = a.block();
  assert.ok(b.period >= 97 && b.period <= 101, `periods ${b.period}`);
  let crossed = 0;
  for (const x of bounds) {
    assert.equal(x.q.main, Math.max(0, b0.qfull.main - x.active), 'main quota minus the running STEP');
    assert.equal(x.q.poll, b0.qfull.poll);
    assert.equal(x.q.service, b0.qfull.service);
    if (x.active) crossed++;
  }
  const steps = a.done.STEP.map((s) => s.at);
  assert.ok(steps.length >= 150, `STEPs ${steps.length}`);
  const tick = DEFAULT_PROFILE.us;
  for (let i = 1; i < steps.length; i++) {
    const gap = steps[i] - steps[i - 1];
    assert.ok(gap >= 4 * tick && gap <= 20000, `STEP gap ${gap.toFixed(0)} us`);
  }
  for (let i = 1; i < bounds.length; i++) {
    const n = steps.filter((t) => t > bounds[i - 1].at && t <= bounds[i].at).length;
    assert.ok(n <= 2, `${n} STEPs in one period`);
  }
  assert.ok(b.debitMax <= b.sum, `largest period debit ${b.debitMax} > quota sum ${b.sum}`);
  assert.ok(stats(a).max_step_gap_ms <= 20);
  const st = b.stats;
  assert.equal(st.late, 0, 'every guaranteed poll done in its tick');
  assert.ok(st.ticks >= 990 && st.ticks <= 1001, `ticks ${st.ticks}`);
  assert.ok(Math.abs(stats(a).isr_calls[C.src.TIMER - 1] - st.ticks) <= 1, 'one STEP_ISR per tick');
  // refusals are paid by the service quota only
  assert.ok(st.refuse <= crossed, `refusals ${st.refuse}, crossings ${crossed}`);
  clean(a);
});

test('gtcp509b: a held ISA lock: busy path before the core, debited, poll stays due', () => {
  const a = boot('gtcp509b');
  up(a);
  const t = a.us();
  a.soundWindow(t + 1000, t + 41000);                // 40 ms: ~20 ticks
  const before = a.block().stats;
  const isr0 = a.done.STEP_ISR.length;
  a.runMs(30);
  const during = a.done.STEP_ISR.filter((x) => x.at > t + 1200 && x.at < t + 31000).length;
  assert.equal(during, 0, 'no STEP_ISR while the sound owner holds the bus');
  const mid = a.block().stats;
  assert.ok(mid.busy - before.busy >= 12, `busy refusals ${mid.busy - before.busy}`);
  assert.ok(mid.late - before.late >= 10, 'the guaranteed poll stays due');
  const busy = a.gw.UG_ISR_NET.filter((g) => g.kind === 'busy');
  assert.ok(Math.max(...busy.map((g) => g.us)) <= UG.UG_BUSY_PATH_US, `busy path ${Math.max(...busy.map((g) => g.us)).toFixed(1)} us`);
  assert.ok(a.done.STEP.some((x) => x.status === S.BUS_BUSY), 'main STEPs see BUS_BUSY');
  a.runMs(60);
  assert.ok(a.done.STEP_ISR.length > isr0 + 10, 'polls resume after the window');
  clean(a);
});

test('gloop: card IRQ quota: one entry, then refused and masked, a later poll unmasks', () => {
  const a = boot('gloop', { card_n: 1 });
  let at = null;
  a.onPc('UG_PERIOD_RET', () => { if (at === null) at = a.us(); });
  a.until(() => at !== null, 100);
  a.runMs(1);
  const t = a.us(), irq0 = stats(a).irq_count, b0 = a.block().stats;
  a.inject(0x50, t + 100); a.inject(0x50, t + 300); a.inject(0x50, t + 500);
  a.runMs(1);
  const b1 = a.block();
  assert.equal(stats(a).irq_count - irq0, 1, 'one card entry admitted');
  assert.equal(b1.stats.refuse - b0.refuse, 1, 'the second refused');
  assert.equal(b1.stats.mask - b0.mask, 1, 'and the route masked');
  assert.ok(b1.flags & (1 << UG.UGF_MASKED));
  a.runMs(25);                                         // next period + its poll
  assert.equal(a.block().flags & (1 << UG.UGF_MASKED), 0, 'unmasked by a later poll');
  clean(a);
});

// ---- data through the real gateway -------------------------------------------------
for (const dll of ['gloop', 'gtcp509b', 'gudp509b', 'gtcprtl', 'gtcpesp', 'gudpesp']) {
  // 5 STEPs per 20 ms period: with 2 (the ТЗ §7 example) the current core
  // moves 0.15-0.18 KiB/s and the RTL ring overflows (tools/dev/sdk_rate.js)
  test(`${dll}: echo and a stream through the gateway, the game's page in WIN1`, () => {
    const a = boot(dll, { steps: 5 }, {}, { auto: 15 });
    if (dll !== 'gloop') up(a);
    connect(a);
    const total = dll.endsWith('esp') ? 1024 : 2048, piece = isUdp(dll) ? 512 : 256;
    const d = bytes(total, 5);
    let off = 0, tag = 1;
    const rx = [];
    a.until(() => {
      if (off < d.length) {
        const n = Math.min(piece, d.length - off);
        const x = a.send(d.slice(off, off + n), tag);
        if (x.res.a === S.OK) { assert.equal(x.commit.a, S.OK); off += n; tag++; }
      }
      a.events();
      rx.push(...a.drain());
      return rx.length >= d.length;
    }, 30000);
    assert.deepEqual(rx, d);
    const st = stats(a);
    assert.deepEqual([st.hw_overflow, st.uart_overrun, st.drop_checksum], [0, 0, 0], 'overflow, overrun, checksum');
    const paths = a.isrPaths.filter((p) => p.core).map((p) => p.us);
    assert.ok(Math.max(...paths) <= 200, `ISR path ${Math.max(...paths).toFixed(1)} us > 200 (ТЗ §3)`);
    const isrNet = a.gw.UG_ISR_NET.filter((g) => g.kind === 'admitted');
    const step = a.gw.UG_STEP.filter((g) => g.kind === 'admitted');
    const b = a.block();
    assert.ok(Math.max(...isrNet.map((g) => g.ovh)) <= UG.UG_OVH_ISR_US, `ISR entry overhead ${Math.max(...isrNet.map((g) => g.ovh)).toFixed(1)}`);
    assert.ok(Math.max(...step.map((g) => g.ovh)) <= UG.UG_OVH_STEP_US, `STEP overhead ${Math.max(...step.map((g) => g.ovh)).toFixed(1)}`);
    assert.ok(Math.max(...isrNet.map((g) => g.us)) <= b.costPoll, 'ISR entry within its debit');
    assert.ok(Math.max(...step.map((g) => g.us)) <= b.costStep, 'STEP within its debit');
    assert.ok(a.done.STEP.some((x) => x.nested), 'ISRs interrupted main STEPs');
    assert.equal(a.m.win[1], 20, 'the game page is back in WIN1');
    clean(a);
  });
}

// ---- time adapters ---------------------------------------------------------------
// now_ms moves at the ticks: sampled between two ticks it lags by up to one
// tick plus the interrupt latency; a wrong tick length (2000 us instead of
// 1999.238) would drift 7.6 ms in 20 s.
const DRIFT_MS = 2.5;
test('FIXED_SCHEDULE: now_ms follows the real tick length', () => {
  const a = boot('gloop');
  const now = () => { const r = a.cmd(8); return (r.hl + r.de * 65536) >>> 0; };
  const t0 = now(), m0 = a.ms();
  a.runMs(20000);
  const drift = (now() - t0) - (a.ms() - m0);
  assert.ok(Math.abs(drift) <= DRIFT_MS, `drift ${drift.toFixed(2)} ms over 20 s`);
  clean(a);
});

test('APP_COUNTER: CTC2/CTC3 chain read, one retry, modulo 17472, within its cost', () => {
  const a = boot('gloop', { timing: C.timing.APP_COUNTER }, {}, { start: { chain: true } });
  assert.equal(a.env.a, S.OK);
  // The model's tick and chain are strictly periodic, so a CTC3 change
  // between two reads is scripted: one decrement between the first and the
  // third read (the retry gives the stamp) on sample 100, a second one
  // during the retry (no stamp, the next tick catches up) on sample 200.
  let retries = 0, samples = 0;
  a.onPc('UGT_PHASE.again', () => retries++);
  let missAt150 = null, one = false, two = false;
  const far = () => a.ctc.value(a.ctc.ch[2], a.m.cycles) > 40;   // CTC2 far from its reload
  a.onPc('UGT_CTC_SAMPLE', () => {
    samples++;
    if (samples >= 100 && !one && far()) { one = true; a.ctc.script3 = [false, true, false]; }
    if (samples === 150) missAt150 = a.block().tMiss;
    if (samples >= 200 && !two && far()) { two = true; a.ctc.script3 = [false, true, true]; }
  });
  for (const n of ['UGT_TICK']) { a.gwEntry.set(a.sym(n), n); a.gw[n] = []; }
  const now = () => { const r = a.cmd(8); return (r.hl + r.de * 65536) >>> 0; };
  const t0 = now(), m0 = a.ms();
  a.runMs(20000);
  const b = a.block();
  const drift = (now() - t0) - (a.ms() - m0);
  assert.ok(Math.abs(drift) <= DRIFT_MS, `drift ${drift.toFixed(2)} ms over 20 s`);
  assert.ok(samples > 9900, `samples ${samples}`);
  assert.ok(retries >= 2, 'a retry on each scripted change');
  assert.equal(missAt150, 0, 'one change: the retry gives the stamp');
  assert.equal(b.tMiss, 1, 'two changes: one sample without a stamp');
  const cost = Math.max(...a.gw.UGT_TICK.map((g) => g.us));
  assert.ok(cost <= 20, `APP_COUNTER sample ${cost.toFixed(1)} us > 20 (ТЗ §5.2)`);
  assert.ok(a.ctc.writes.every((w) => w.cycles < a.m.cycles), 'CTC written only by the program');
  clean(a);
});

// ---- events, CBL, key, exit -----------------------------------------------------------
test('gtcp509b: CBL flag, key opportunity, SHUTDOWN with the channel open, exit restore', () => {
  const p1ffd = 0x01, p9fbd = 0;
  const a = boot('gtcp509b');
  up(a);
  connect(a);
  assert.equal(a.send(bytes(100), 9).commit.a, S.OK);
  a.runMs(100);
  // CBL: only a flag in the ISR, the next tick turns it into the poll
  const c0 = a.block().stats.cbl, sv = a.block().q.service;
  a.inject(0x40, a.us() + 50);
  a.runMs(3);
  assert.equal(a.block().stats.cbl - c0, 1);
  // key: an extra poll while the guaranteed one is still due
  const t = a.us();
  a.soundWindow(t + 100, t + 2600);                   // the tick poll meets a busy bus
  a.inject(0x20, t + 2700);
  const k0 = stats(a).isr_calls[C.src.KEY - 1];
  a.runMs(4);
  assert.ok(stats(a).isr_calls[C.src.KEY - 1] - k0 >= 1, 'the key entry polled the card');
  // SHUTDOWN while the channel is open
  const r = a.cmd(5, { de: 3000 });
  assert.equal(r.a, S.OK, `SHUTDOWN ${r.a}`);
  assert.equal(a.ctx('state'), C.ctxstate.STOPPED);
  assert.equal(a.m.peek16(a.s.sym('IMG_CTX_PTR')), 0, 'context released');
  const stop = a.stop();
  assert.equal(stop.a, 0, 'lock free at exit');
  assert.equal(a.m.cpu.getState().imode, 1);
  assert.deepEqual(a.pio, []);
  assert.equal(a.m.port1ffd, p1ffd);
  assert.equal(a.m.port9fbd, p9fbd);
  assert.ok([1, 2, 3].every((ch) => a.ctc.writes.some((w) => w.port === 0x10 + ch && w.v === 3)), 'CTC channels reset by the program');
  assert.equal(a.call('FINI').a, 0);
  assert.ok(sv >= 0);
  clean(a);
});

// ---- ТЗ §5.1 / §3 bounds of the default profile ------------------------------------
for (const dll of CARDS) {
  // 10 polls x (empty poll + return + UG_OVH_ISR_US) + 2 STEPs x (min_useful
  // + UG_OVH_STEP_US) + service 100 (docs/MEASUREMENTS.md)
  test(`${dll}: network quotas within 2000 us per period (ТЗ §5.1)`, () => {
    const a = boot(dll);
    assert.equal(a.env.a, S.OK);
    assert.equal(a.block().env, UG.UG_ENV_OK);
    assert.ok(a.block().sum <= 2000, `quota sum ${a.block().sum} us`);
  });
  test(`${dll}: ISR path bound (STEP_ISR budget + gateway + tick) <= 200 us (ТЗ §3)`, () => {
    const a = boot(dll);
    const bound = a.block().isrBudget + UG.UG_OVH_ISR_US + 30 + 12 + 5;   // tick with a period boundary, FIXED clock, entry/RETI
    assert.ok(bound <= 200, `bound ${bound} us`);
  });
}
