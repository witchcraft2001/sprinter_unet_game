// dll-loader.js -- parse and relocate libman L1 images like the libman 1.3
// loader does (code_size includes the 32-byte header; one relocation bit per
// body byte, MSB first; marked bytes get the high byte of the load base).
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const fs = require('fs');

function parseL1(bytes) {
  if (bytes[0] !== 0x4c || bytes[1] !== 0x31) throw new Error('not an L1 DLL');
  const u16 = (o) => bytes[o] | (bytes[o + 1] << 8);
  const prefix = u16(2), codeSize = u16(4), relocSize = u16(6), checksum = u16(8);
  if (prefix !== codeSize + relocSize) throw new Error('compressed L1 images are not supported by the stand');
  const image = bytes.slice(0, codeSize);
  const bitmap = bytes.slice(codeSize, codeSize + relocSize);
  let sum = 0;
  // mkdll: sum of the loaded bytes from offset 16 (code + relocation bitmap).
  for (let i = 16; i < codeSize + relocSize; i++) sum = (sum + bytes[i]) & 0xffff;
  if (sum !== checksum) throw new Error(`L1 checksum 0x${sum.toString(16)} != 0x${checksum.toString(16)}`);
  const name = Buffer.from(bytes.slice(16, 32)).toString('ascii').split('\0')[0];
  return { prefix, codeSize, relocSize, checksum, image, bitmap, name, version: u16(14) };
}

// Relocate for a header placed at `base` (256-aligned).  Returns the bytes
// (header included) as they appear in memory after loading.
function relocate(l1, base) {
  if (base & 0xff) throw new Error('libman places images on 256-byte boundaries');
  const out = Uint8Array.from(l1.image);
  const hi = base >> 8;
  const body = l1.codeSize - 32;
  for (let i = 0; i < body; i++) {
    if (l1.bitmap[i >> 3] & (0x80 >> (i & 7))) out[32 + i] = (out[32 + i] + hi) & 0xff;
  }
  return out;
}

function readSymbols(symPath) {
  const syms = {};
  for (const line of fs.readFileSync(symPath, 'utf8').split('\n')) {
    const m = line.match(/^([A-Za-z_.@][\w.@]*):\s+EQU\s+0x([0-9A-Fa-f]+)/);
    if (m) syms[m[1]] = parseInt(m[2], 16);
  }
  return syms;
}

module.exports = { parseL1, relocate, readSymbols };
