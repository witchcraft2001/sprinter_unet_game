// audit.js -- budget audit: for every TAKE / BUDGET_BYTES entry, the work
// actually done until the next budget call (or the end of the call) is
// compared with what the previous call reserved.  Prints the worst
// deficits by caller label.  Debug aid for calibrating cost constants.
'use strict';
function budgetAudit(stand) {
  const syms = Object.entries(stand.syms).filter(([k]) => !k.includes('.') && /^[A-Z]/.test(k))
    .map(([k, v]) => [stand.base + 0x20 + v, k]).sort((a, b) => a[0] - b[0]);
  const owner = (pc) => { let best = '?'; for (const [a, k] of syms) { if (a <= pc) best = k; else break; } return best; };
  const take = stand.sym('TAKE'), bb = stand.sym('BUDGET_BYTES');
  const deficits = {};
  let last = null;
  const unitsAddr = stand.layout().ctx + require('./abi.json').ctx.fields.units.offset;
  const close = (m) => {
    if (!last) return;
    const real = (m.cycles - last.c) / m.mhz;
    last.reserved = last.u - m.peek16(unitsAddr);      // what the call actually consumed
    const d = real - last.reserved;
    const k = last.caller;
    if (!deficits[k] || deficits[k].d < d) deficits[k] = { d: +d.toFixed(1), real: +real.toFixed(1), reserved: last.reserved };
  };
  return {
    hook(m, st) {
      if (st.pc === take || st.pc === bb) {
        close(m);
        const ret = m.peek16(st.sp);
        const hl = (st.h << 8) | st.l;
        last = { c: m.cycles, u: m.peek16(unitsAddr), caller: owner(ret - 3) + (st.pc === bb ? '/bytes' : '') };
      }
    },
    end(m) { if (last) { const real = (m.cycles - last.c) / m.mhz; const d = real - 0; const k = last.caller + '/tail';
      if (!deficits[k] || deficits[k].d < d) deficits[k] = { d: +d.toFixed(1), real: +real.toFixed(1), reserved: 0 }; } last = null; },
    report(n = 8) { return Object.entries(deficits).sort((a, b) => b[1].d - a[1].d).slice(0, n); },
  };
}
module.exports = { budgetAudit };
