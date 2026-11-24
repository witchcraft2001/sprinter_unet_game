// xrec.js -- records of the transparent UDP mode of SprinterESP (GUDPESP,
// esp_fw = 2; docs/unet-game-abi.md "Прозрачный режим UDP").
//
// In the transparent mode (AT+CIPMODE=1) the module carries a byte stream:
// it cuts what the UART brings into UDP packets after 20 ms of silence (or
// 1460 bytes) and writes what it receives to the UART without +IPD.  The
// library therefore frames each datagram as a record:
//
//   byte 0 = check << 2 | len >> 8      check = (0x2B + (len & 0xFF) + (len >> 8)) & 0x3F
//   byte 1 = len & 0xFF                 len = 0..512 payload bytes
//   len payload bytes
//
// The peer (tools/mame/echo_server.py --framed, the stands' models) sends
// exactly one record per datagram and reads what it receives as a stream
// of records: the module may cut a record into two packets or put two
// records into one.  A header that fails its check (or a length above
// 512) drops what was gathered; the decoder looks for a header again at
// the start of the next datagram.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const XREC_MAX = 512;

function check(len) { return (0x2b + (len & 0xff) + (len >> 8)) & 0x3f; }

// encode(payload) -> header + payload
function encode(payload) {
  const n = payload.length;
  if (n > XREC_MAX) throw new Error(`record of ${n} bytes > ${XREC_MAX}`);
  return [(check(n) << 2) | (n >> 8), n & 0xff, ...payload];
}

// header(b0, b1) -> length, or -1 when it is no header
function header(b0, b1) {
  const n = ((b0 & 3) << 8) | b1;
  if (n > XREC_MAX || (b0 >> 2) !== check(n)) return -1;
  return n;
}

// Decoder of the record stream one side receives.  feed(bytes, {packet})
// returns the whole records it completes; packet = true marks the start
// of a datagram (a resync point after a bad header).  bad counts the
// headers that failed.
class Decoder {
  constructor() { this.buf = []; this.bad = 0; this.skip = false; }
  feed(bytes, { packet = false } = {}) {
    if (packet && this.skip) { this.skip = false; this.buf = []; }
    if (this.skip) return [];
    this.buf.push(...bytes);
    const out = [];
    for (;;) {
      if (this.buf.length < 2) break;
      const n = header(this.buf[0], this.buf[1]);
      if (n < 0) { this.bad++; this.buf = []; this.skip = true; break; }
      if (this.buf.length < 2 + n) break;
      out.push(this.buf.slice(2, 2 + n));
      this.buf = this.buf.slice(2 + n);
    }
    return out;
  }
}

module.exports = { XREC_MAX, check, encode, header, Decoder };
