// dramwait.js -- real time of a Z80 instruction on the Sprinter in turbo.
// SPDX-License-Identifier: BSD-3-Clause
//
// At 21 MHz every memory cycle (RAM and ISA alike) is synchronised to the
// 3.5 MHz grid of the board: the access starts at the next multiple of
// 6 T-states and takes 3 wait T-states on top of its own; an I/O cycle
// takes 2.  This is the rule of the MAME driver (sprinter.cpp
// do_mem_wait), and it reproduces the board: the 35-T calibration loop of
// the stand programs takes 78 T by this rule, 78.4 T measured on the real
// Sprinter (UGPROBE CPU: 9.37 effective MHz) and in MAME.
//
// The vendored core reports only the T-states of a whole instruction, so
// the position of each access inside it comes from the instruction's
// M-cycle structure: an opcode fetch is 4 T, every other access 3 T, an
// I/O cycle 4 T, and the T-states left over (D) sit after the last access
// unless the table below places them earlier.
'use strict';

const up6 = (x) => { const r = x % 6; return r ? x + 6 - r : x; };

// Where the extra T-states of an instruction sit: [[access index, T], ...];
// whatever is not placed goes after the last access.
function place(b0, b1, n) {
  if (b0 === 0xcb) return (b1 & 7) === 6 ? [[2, 1]] : null;          // BIT/SET/RES/shift (HL)
  if (b0 === 0xed) {
    if (b1 === 0x67 || b1 === 0x6f) return [[2, 4]];                  // RRD / RLD
    if ((b1 & 0xe6) === 0xa2) return [[1, 1]];                        // INI/OUTI family: M1 of 5 T
    return null;
  }
  if (b0 === 0xdd || b0 === 0xfd) {
    if (b1 === 0xcb) return [[3, 2], [4, 1]];                         // DDCB d op
    if (b1 === 0x34 || b1 === 0x35) return [[2, 5], [3, 1]];          // INC/DEC (IX+d)
    if (b1 === 0x36) return [[3, 2]];                                 // LD (IX+d),n
    if (b1 === 0xe5) return [[1, 1]];                                 // PUSH IX
    if (b1 === 0xe3) return [[3, 1], [5, 2]];                         // EX (SP),IX
    const ld = (b1 & 0xc7) === 0x46 || ((b1 & 0xf8) === 0x70 && b1 !== 0x76) || (b1 & 0xc7) === 0x86;
    return ld ? [[2, 5]] : null;                                      // LD r,(IX+d) / LD (IX+d),r / ALU (IX+d)
  }
  if ((b0 & 0xcf) === 0xc5 || (b0 & 0xc7) === 0xc7 || (b0 & 0xc7) === 0xc0) return [[0, 1]];   // PUSH, RST, RET cc
  if (b0 === 0xcd || ((b0 & 0xc7) === 0xc4 && n === 5)) return [[2, 1]];                        // CALL (taken)
  if (b0 === 0x10) return [[0, 1]];                                   // DJNZ
  if (b0 === 0x34 || b0 === 0x35) return [[1, 1]];                    // INC/DEC (HL)
  if (b0 === 0xe3) return [[2, 1], [4, 2]];                           // EX (SP),HL
  return null;
}

// phase: real T-states so far (only its value modulo 6 matters);
// t: T-states the core reports; acc: the accesses in order (0 = memory,
// 1 = I/O); pre: how many of them belong to an interrupt acceptance that
// preceded the instruction (its 7-T acknowledge cycle has no wait).
// Returns the new phase; the real time is the difference.
function realTime(phase, t, acc, pre, b0, b1) {
  let cur = phase;
  let i = 0;
  if (pre) {
    cur += 7;
    t -= 7 + 3 * pre;
    for (; i < pre; i++) cur = up6(cur) + 6;
  }
  const n = acc.length - pre;
  if (n <= 0) return cur + t;
  const prefixed = b0 === 0xcb || b0 === 0xed || b0 === 0xdd || b0 === 0xfd;
  let d = t;
  const len = new Array(n);
  for (let k = 0; k < n; k++) {
    len[k] = acc[pre + k] ? 4 : (k === 0 || (k === 1 && prefixed) ? 4 : 3);
    d -= len[k];
  }
  const p = place(b0, b1, n);
  if (p) for (const [k, x] of p) if (k < n && d >= x) { len[k] += x; d -= x; }
  if (d > 0) len[n - 1] += d;
  for (let k = 0; k < n; k++) cur = up6(cur) + (acc[pre + k] ? 2 : 3) + len[k];
  return cur;
}

module.exports = { realTime, up6 };
