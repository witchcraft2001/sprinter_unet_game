// dss.js -- a DSS stub for the Z stand: RST #10 (PC = #0010) answered in JS.
// SPDX-License-Identifier: BSD-3-Clause
//
// Only ENVIRON #46 with B = 1 (get) is served, as Estex-DSS
// DSS/API/Environ.asm GETENV does it: the name at HL ends at 0 or '=' and
// is compared in upper case; the value buffer at DE gets a 0 first, then
// the value and its 0; DE ends at that 0; A = #FF found / 0 not found;
// CF = 0.  The stub then clobbers BC, HL, IX and IY (DSS documents no
// register it keeps besides its outputs), so the caller must save what it
// needs.  Any other DSS call throws: the code under test has no business
// with it.
'use strict';

const DSS_PC = 0x0010;

class DssEnv {
  constructor(env = {}) {
    this.env = new Map(Object.entries(env).map(([k, v]) => [k.toUpperCase(), String(v)]));
    this.calls = [];
  }

  // Serve the call at PC = #0010 and return to the caller.
  call(m) {
    const s = m.regs();
    if (s.c !== 0x46 || s.b !== 1) throw new Error(`DSS call C=#${s.c.toString(16)} B=${s.b} from the code under test`);
    let hl = (s.h << 8) | s.l, name = '';
    for (let i = 0; i < 255; i++) {
      const ch = m.peek(hl + i);
      if (ch === 0 || ch === 0x3d) break;
      name += String.fromCharCode(ch);
    }
    name = name.toUpperCase();
    let de = (s.d << 8) | s.e;
    m.poke(de, 0);
    const v = this.env.get(name);
    this.calls.push({ name, buffer: de, found: v !== undefined });
    if (v !== undefined) {
      for (let i = 0; i < v.length; i++) m.poke(de++, v.charCodeAt(i));
      m.poke(de, 0);
    }
    const sp = s.sp;
    const ret = m.peek16(sp);
    const flags = { ...s.flags, C: 0, Z: v === undefined ? 1 : 0 };
    m.setRegs({
      a: v === undefined ? 0 : 0xff, flags, d: (de >> 8) & 0xff, e: de & 0xff,
      b: 0xa5, c: 0x5a, h: 0xde, l: 0xad, ix: 0xdead, iy: 0xbeef, sp: (sp + 2) & 0xffff, pc: ret,
    });
  }
}

// Run from the current state until PC == stop, serving DSS calls.
function runDss(m, stop, dss, maxSteps = 2_000_000) {
  for (let n = 0; ; n++) {
    const pc = m.regs().pc;
    if (pc === stop) return n;
    if (n > maxSteps) throw new Error(`step limit at PC=0x${pc.toString(16)}`);
    if (pc === DSS_PC) dss.call(m);
    else m.exec();
  }
}

module.exports = { DssEnv, runDss, DSS_PC };
