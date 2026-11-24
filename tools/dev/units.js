// units.js -- required first by the calibration tools of tools/dev.
// The core counts in units (a microsecond of a 21 MHz Z80 without memory
// waits, src/core/profile.inc) while the ABI budgets are real microseconds
// of the board.  These tools account in units: unless UG_WAITS=1 is given
// they run the stand without memory waits, where a microsecond is a unit,
// and pass the DLL US(n), the real budget that buys n units.
'use strict';
if (process.env.UG_WAITS === undefined) process.env.UG_WAITS = '0';
const { US, UNITS } = require('../harness/stand.js');
module.exports = { US, UNITS, real: process.env.UG_WAITS !== '0' };
