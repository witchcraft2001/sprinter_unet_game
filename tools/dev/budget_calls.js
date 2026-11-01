// budget_calls.js -- the budget calls of one STEP (TAKE / BUDGET_BYTES /
// PARSE_BUDGET) with what each really reserved and the real time of the
// item it bought, shared by profile_step.js and overrun.js.
//
// A call's reserve is the units it took (entry minus return), less the
// refunds (UNITS_REFUND) its caller gives back later in the STEP: the
// Ethernet poll reserve refunded before the poll is not an item, and a
// refund between two calls is not charged to the earlier one.  A TAKE
// that the routine of a parser round makes right after the round
// (ESP_PARSE: COST_PAY) is folded into the round.  An item's real time
// runs from its call to the next call or the next phase boundary (the
// dispatch and the STEP tail belong to the base path).
'use strict';
const A = require('../harness/abi.json');

const BOUNDS = ['EV_FLUSH', 'DEADLINES', 'TP_IF_RUNNING', 'ETH_AFFORD', 'ETH_AFFORD_E', 'ETH_RX_CONT', 'ETH_TX_CONT',
  'ETH_STEP_ODD', 'UNITS_REFUND'];

function budgetTracker(s, { bounds = BOUNDS } = {}) {
  const ua = s.layout().ctx + A.ctx.fields.units.offset;
  if (!s.constructor.equNames) s.profileHook();     // loads the EQU names
  const equ = s.constructor.equNames;
  const syms = Object.entries(s.syms).filter(([k]) => !k.includes('.') && /^[A-Z]/.test(k) && !equ.has(k))
    .map(([k, v]) => [s.base + 0x20 + v, k]).sort((x, y) => x[0] - y[0]);
  const owner = (pc) => { let lo = 0, hi = syms.length - 1, best = '?'; while (lo <= hi) { const mid = (lo + hi) >> 1; if (syms[mid][0] <= pc) { best = syms[mid][1]; lo = mid + 1; } else hi = mid - 1; } return best; };
  // table dispatch (engine.asm ETH_RX_STEP / ETH_TX_STEP): TAKE is entered by
  // JP with the state routine as its return address -- named by that local
  const locals = new Map(Object.entries(s.syms).filter(([k]) => k.includes('.') && !equ.has(k)).map(([k, v]) => [s.base + 0x20 + v, k]));
  const takeAt = s.sym('TAKE');
  const caller = (m, ret) => (m.peek(ret - 3) === 0xcd && m.peek16(ret - 2) === takeAt) || !locals.has(ret) ? owner(ret - 3) : locals.get(ret);
  const pts = { [s.sym('TAKE')]: '', [s.sym('BUDGET_BYTES')]: '/bytes' };
  if ('PARSE_BUDGET' in s.syms) pts[s.sym('PARSE_BUDGET')] = '/round';
  const refundPc = s.sym('UNITS_REFUND');
  const bset = new Set(bounds.filter((l) => l in s.syms).map((l) => s.sym(l)));
  let calls, marks, pending, c0;
  const reset = () => { calls = []; marks = []; pending = []; c0 = null; };
  reset();
  return {
    owner,
    reset,
    onStep(m, st) {
      if (c0 === null) c0 = m.cycles;
      const t = (m.cycles - c0) / m.mhz;
      for (let k = pending.length - 1; k >= 0; k--) {
        const p = pending[k];
        if (st.pc !== p.ret || st.sp !== p.sp + 2) continue;
        pending.splice(k, 1);
        const got = p.u - m.peek16(ua);
        if (got > 0) (p.into || p).taken += got;
        break;
      }
      const kind = pts[st.pc];
      if (kind !== undefined) {
        const ret = m.peek16(st.sp), who = kind === '' ? caller(m, ret) : owner(ret - 3);
        const call = { t, u: m.peek16(ua), who, kind, ret, sp: st.sp, taken: 0, refund: 0, cost: (st.h << 8) | st.l, bc: (st.b << 8) | st.c, de: (st.d << 8) | st.e };
        const prev = calls[calls.length - 1];
        if (kind === '' && prev && prev.kind === '/round' && prev.who === who && !marks.some((x) => x > prev.t)) call.into = prev;
        else calls.push(call);
        pending.push(call);
      } else if (st.pc === refundPc) {
        const who = owner(m.peek16(st.sp) - 3);
        let amount = (st.h << 8) | st.l;
        for (let k = calls.length - 1; k >= 0 && amount > 0; k--) {
          const c = calls[k];
          if (c.who !== who) continue;
          const back = Math.min(amount, c.taken - c.refund);
          c.refund += back; amount -= back;
        }
        marks.push(t);
      } else if (bset.has(st.pc)) marks.push(t);
    },
    // totalUs = the STEP time; returns the items of this STEP and their sum
    finish(totalUs) {
      const items = []; let reserved = 0;
      for (let k = 0; k < calls.length; k++) {
        const c = calls[k], res = c.taken - c.refund;
        if (res <= 0) continue;
        let end = k + 1 < calls.length ? calls[k + 1].t : totalUs;
        for (const x of marks) if (x > c.t && x < end) { end = x; break; }
        items.push({ who: c.who + c.kind, kind: c.kind, reserved: res, real: end - c.t, t: c.t, call: c });
        reserved += res;
      }
      return { items, reserved, calls };
    },
  };
}

module.exports = { budgetTracker, BOUNDS };
