"""ugreport.py -- decode the UGTEST/NETDEMO report lines shared by the M
stand (tools/mame/run_m.py) and the Ж stand (tools/measure/parse_hw.py).

Pure decoding, no I/O beyond the two include files it reads for field
layout (tools/harness/abi.json, sdk/gateway/ugate.inc); callers own the
report text and the resulting summary dict.
"""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]


def decode(name, hexstr):
    abi = json.loads((ROOT / 'tools' / 'harness' / 'abi.json').read_text())
    b = bytes.fromhex(hexstr)
    out = {}
    for field, f in abi['blocks'][name]['fields'].items():
        if f['offset'] + f['size'] > len(b) or f.get('count', 1) > 1 or f['type'] in ('ip4', 'mac6'):
            continue
        out[field] = int.from_bytes(b[f['offset']:f['offset'] + f['size']], 'little')
    return out


def gateway(b):
    """Decode the gateway snapshot (sdk/gateway/ugate.inc offsets)."""
    c = {}
    for line in (ROOT / 'sdk' / 'gateway' / 'ugate.inc').read_text().splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] == 'EQU' and parts[0].startswith('UG'):
            try:
                c[parts[0]] = int(parts[2], 0)
            except ValueError:
                pass
    u16 = lambda o: int.from_bytes(b[o:o + 2], 'little')
    q = lambda o: {'poll': u16(o), 'card': u16(o + 2), 'main': u16(o + 4), 'service': u16(o + 6)}
    st = {k[4:].lower(): u16(c['UGW_STATS'] + v) for k, v in c.items() if k.startswith('UGS_') and k != 'UGS_COUNT'}
    return {'quota_full': q(c['UGW_QFULL']), 'cost_poll_us': u16(c['UGW_COST_POLL']), 'cost_step_us': u16(c['UGW_COST_STEP']),
            'periods': u16(c['UGW_PERIOD_NO']), 'largest_period_debit_us': u16(c['UGW_DEBIT_MAX']),
            'now_ms': int.from_bytes(b[c['UGW_NOW']:c['UGW_NOW'] + 4], 'little'), 'stats': st}


# NETDEMO's stopwatch (TIMING, CBL): counts of 16 CPU clocks at 21 MHz
# (turbo, confirmed by UGTEST's calibration)
SW_US = 16 / 21.0
# Sprinter video frame (the IM1 tick) when the report has no CLOCK_RATE
# line (Ж: no ugstand.lua to time it): the MAME model's period, the same
# 312 x 448 / 7 MHz raster as the real board
FRAME_MS_NOMINAL = 20.48


def parse_report(lines, frame_ms=None):
    """Decode the LOAD/ENV/GW/STATS/INFO/CLOCK_RATE/CAL/STEPTIME/CALLTIME16
    lines common to UGTEST and NETDEMO (both stands) into a summary dict
    (the same fields run_m.py used to build inline), plus the UG_HW lines
    (SCEN, LAT, ISRTIME16, BUSYTIME16, EMPTYSTEP16, SOAK, CBL) when present.
    frame_ms: the video frame when no CLOCK_RATE line gives it (Ж)."""
    out = {}
    cal_ctc = cal_loop = None
    tick_ms = None
    steptime = None
    hw = {}
    calltime = None
    for ln in lines:
        if ln.startswith('LOAD '):
            f = ln[5:].split()
            out['load'] = {'status': int(f[0], 16), 'libman_reason': int(f[1], 16), 'handle': int(f[2], 16),
                           'page': int(f[3], 16), 'base': hex(int(f[4], 16) << 8)}
        if ln.startswith('ENV '):
            f = ln[4:].split()
            out['env'] = {'init_config': int(f[0], 16), 'env': int(f[1], 16), 'quota_sum_us': int(f[2], 16)}
        if ln.startswith('GW '):
            out['gateway'] = gateway(bytes.fromhex(ln[3:].strip()))
        if ln.startswith('CLOCK_RATE '):
            out['clock'] = ln.strip()
            frame_ms = float(ln.split('FRAME_MS ')[1].split(',')[0])   # video frame = IM1 tick during the calibration
            tick_ms = float(ln.split('TICK_MS ')[1].split(',')[0])     # ticks seen while the library runs
        if ln.startswith('TIMING '):
            # stopwatch counts of 16 CPU clocks at 21 MHz (turbo, confirmed by UGTEST's calibration)
            isr, step, gap, late = (int(x, 16) for x in ln[7:].split())
            us = 16 / 21.0
            out['timing_us'] = {'tick_isr_max': round(isr * us), 'admitted_ug_step_max': round(step * us),
                                'largest_tick_gap': round(gap * us), 'late_ticks': late}
        if ln.startswith('STATS '):
            out['stats'] = {k: v for k, v in decode('STATS', ln[6:].strip()).items() if v}
        if ln.startswith('INFO '):
            info = decode('INFO', ln[5:].strip())
            out['info'] = {k: info[k] for k in ('min_useful_budget_us', 'empty_poll_us', 'bus_busy_us') if k in info}
        if ln.startswith('CAL '):
            cal_ctc, cal_loop = (int(x, 16) for x in ln[4:].split())
        if ln.startswith('STEPTIME '):
            steptime = [int(x, 16) for x in ln[9:].split()]
        if ln.startswith('CALLTIME16 '):
            calltime = int(ln[11:].strip(), 16)
        for key in ('SCEN', 'LAT', 'ISRTIME16', 'BUSYTIME16', 'EMPTYSTEP16', 'SOAK', 'CBL'):
            if ln.startswith(key + ' '):
                hw[key] = ln[len(key) + 1:].split()
    if cal_ctc and frame_ms is not None and steptime is not None:
        # CTC timer counts (16 CTC clocks) -> real us via the video frame
        # (= the IM1 tick while nothing holds DI); the CTC clock = the CPU clock
        us_per_count = frame_ms * 1000 / cal_ctc
        mx, n, total, over = steptime
        out['cpu_mhz'] = round(cal_ctc * 16 / (frame_ms * 1000), 2)
        out['frame_ms'] = frame_ms
        out['ticks_missed_ratio'] = round(1 - frame_ms / tick_ms, 3) if tick_ms else None
        out['step'] = {
            'max_us': round(mx * us_per_count), 'mean_us': round(total * us_per_count / max(n, 1)),
            'steps': n, 'over_budget': over}
        if calltime is not None:
            out['trivial_call_us'] = round(calltime * us_per_count / 16)
    elif cal_ctc and frame_ms is not None:
        us_per_count = frame_ms * 1000 / cal_ctc
    else:
        us_per_count = None
    if hw:
        out['hw'] = hw_lines(hw, us_per_count)
    return out


def hw_lines(hw, us_per_count):
    """The UG_HW report lines (sdk/example/ugtest.asm, netdemo.asm) in us.
    UGTEST lines are CTC counts (us_per_count from CAL); NETDEMO's CBL is
    stopwatch counts (SW_US).  A field without a calibration stays raw."""
    h = lambda v: int(v, 16)
    us = (lambda c: round(c * us_per_count, 1)) if us_per_count else (lambda c: None)
    out = {}
    if 'SCEN' in hw and hw['SCEN']:
        out['scen'] = hw['SCEN'][0]
    if 'LAT' in hw and len(hw['LAT']) >= 6:
        f = [h(v) for v in hw['LAT']]
        n_sat = f[6] if len(f) > 6 else 0
        k_max = f[7] if len(f) > 7 else 0

        def side(n, mx, total):
            # a saturated sample (0xFFFF) is over 40 ms: its max is not a time
            d = {'n': n, 'max_counts': mx}
            if mx != 0xFFFF:
                d['max_us'] = us(mx)
            if n and not n_sat:
                d['mean_us'] = us(total / n)
            return d
        out['lat'] = {'txdone': side(f[0], f[1], f[2]), 'echo': side(f[3], f[4], f[5]),
                      'saturated': n_sat, 'saturated_max_frames': k_max}
    for key, name in (('ISRTIME16', 'isr'), ('BUSYTIME16', 'busy'), ('EMPTYSTEP16', 'empty_step')):
        if key in hw and hw[key]:
            c = h(hw[key][0])
            # 16 calls through libman: the trivial call (CALLTIME16) is in it
            out.setdefault('costs16', {})[name] = {'counts': c, 'per_call_us': us(c / 16)}
    if 'SOAK' in hw and len(hw['SOAK']) >= 5:
        frames, net_max, net_sum, nbytes, rx_bad = (h(v) for v in hw['SOAK'][:5])
        out['soak'] = {'frames': frames, 'net_max_us': us(net_max),
                       'net_mean_us': us(net_sum / frames) if frames else None,
                       'bytes': nbytes, 'rx_bad': rx_bad}
    if 'CBL' in hw and len(hw['CBL']) >= 3:
        n, mx, total = (h(v) for v in hw['CBL'][:3])
        out['cbl'] = {'n': n, 'max_us': round(mx * SW_US), 'mean_us': round(total * SW_US / n) if n else None}
    return out


def parse_probe(lines, frame_ms):
    """UGPROBE's PROBE lines (tools/measure/ugprobe.asm header) in us.
    frame_ms: the video frame the CAL counts refer to (CLOCK_RATE on M,
    FRAME_MS_NOMINAL or the operator's value on Ж).  Returns {'raw': {name:
    [ints]}, name: decoded, ...}; a section that is absent is absent."""
    raw = {}
    cal_ctc = None
    for ln in lines:
        if ln.startswith('CAL '):
            cal_ctc = int(ln.split()[1], 16)
        if ln.startswith('PROBE '):
            f = ln.split()
            if f[1].startswith('RTS') and len(f) >= 4:
                raw[f[1]] = [int(f[2], 16), f[3]]   # reads, verdict letter
            else:
                raw[f[1]] = [int(v, 16) for v in f[2:]]
    out = {'raw': raw, 'frame_ms': frame_ms}
    frame_us = frame_ms * 1000
    upc = frame_us / cal_ctc if cal_ctc else None
    if 'CPU' in raw and len(raw['CPU']) >= 2:
        clk = raw['CPU'][0] * 16 / frame_us
        eff = [n * 35 / frame_us for n in raw['CPU'][1:]]
        out['CPU'] = {'ctc_clock_mhz': round(clk, 3), 'effective_mhz': [round(e, 3) for e in eff],
                      'wait_share': round(1 - (sum(eff) / len(eff)) / clk, 3) if clk else None}
    for name in ('ISA_RD', 'ISA_WR'):
        v = raw.get(name)
        if v and len(v) >= 8 and upc:
            d = [(v[i] - v[i + 4]) * upc / 64 for i in range(4)]
            out[name] = {'extra_us_per_access_max': round(max(d), 3), 'extra_us_per_access_mean': round(sum(d) / 4, 3),
                         'portion_64_us_max': round(max(v[:4]) * upc, 1)}
    v = raw.get('BRACKET')
    if v and len(v) >= 2 and upc:
        out['BRACKET'] = {'us_per_bracket': round((v[0] - v[1]) * upc / 256, 3)}
    v = raw.get('CTC')
    if v and len(v) >= 4:
        with_, without, counts, miss = v[:4]     # counts: one u32 token
        out['CTC'] = {'sample_us': round(frame_us * (1 / with_ - 1 / without), 2) if with_ and without else None,
                      'chain_counts_per_frame': counts, 'chain_counts_expected': round(875 * frame_ms),
                      'chain_counting': counts > 0, 'samples_without_stamp': miss}
    for name, v in raw.items():
        if name.startswith('UART') and len(v) >= 20:
            out[name] = {'trigger': int(name[4:], 16), 'bytes': v[0], 'drains': v[1], 'max_per_drain': v[2],
                         'overruns': v[3], 'hist_1_16plus': v[4:20]}
        if name.startswith('RTS') and len(v) >= 2:
            out[name] = {'trigger': int(name[3:], 16), 'reads_before_empty': v[0],
                         'resume': {'B': 'below_trigger', 'A': 'after_empty', 'S': 'inconclusive (short reply)'}.get(v[1], v[1])}
    return out
