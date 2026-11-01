#!/usr/bin/env python3
"""parse_hw.py -- the Ж stand (real Sprinter) reports into evidence.

  tools/measure/parse_hw.py <folder with the .TXT files> [--frame-ms 20.48]
                            [--out docs/evidence/hw] [--dry-run]

Every report the Ж programs saved (tools/hw/build_hw.sh: UGTEST
U<card><T|U><scen>.TXT, NETDEMO N<card><T|U><scen>.TXT, UGPROBE
PROBE<c>.TXT) is decoded with tools/mame/ugreport.py (the same decoding
as the M stand) into docs/evidence/hw/<dll>_<prog>_<scen>/ and
docs/evidence/hw/probe_<card>/ (report.txt + summary.json, with the
pass criteria below in summary["criteria"]).  stdout: a Markdown table
for docs/MEASUREMENTS.md ("Стенд Ж") and the proposed rows of the
acceptance matrix -- docs/acceptance/matrix.md is never written here.

The CTC counts of UGTEST/UGPROBE become us through the video frame: on Ж
no harness times it, so --frame-ms (default ugreport.FRAME_MS_NOMINAL)
is the assumption, printed with every table.

Criteria (ТЗ §6, §8.3; an absent measurement is "не измерено", never a pass):
  result      RESULT: PASS
  step        UGTEST STEPTIME: max <= 500 us, no STEP over the budget
  overflow    STATS uart_overrun = ring_overflow = hw_overflow = 0
  latency     LAT: TX_DONE max <= 40 ms, no saturated sample
  soak        SOAK (K): frames >= 30000 (10 min), per-frame net max <= 2000 us
  isr         ISRTIME16 / 16 - trivial call <= isr_budget_us (150)
  bus_busy    BUSYTIME16 / 16 - trivial call <= GET_INFO bus_busy_us
  probe_ctc   UGPROBE: the APP_COUNTER sample <= 20 us (time_read_cost_us)
  probe_uart  UGPROBE E: no UART overrun at the configured trigger
"""
import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools' / 'mame'))
import ugreport  # noqa: E402

ISR_BUDGET_US = 150          # INIT_CONFIG.isr_budget_us of the Ж builds (tools/mame/mkcfg.js)
STEP_BUDGET_US = 500
LAT_MAX_US = 40000
SOAK_FRAMES_MIN = 30000
SOAK_NET_MAX_US = 2000
CTC_READ_MAX_US = 20         # sdk/time/ugtime.asm UGT_READ_US
CARD_OF = {'ESP': 'ESP', 'RTL': 'RTL', '509': 'EL3'}
DLL_OF = {('ESP', 'T'): 'gtcpesp', ('ESP', 'U'): 'gudpesp', ('RTL', 'T'): 'gtcprtl',
          ('RTL', 'U'): 'gudprtl', ('509', 'T'): 'gtcp509b', ('509', 'U'): 'gudp509b'}
PROBE_CARD = {'E': 'ESP', 'R': 'RTL', '3': 'EL3'}


def identify(name, lines):
    """(prog, dll, scen) from the file name, checked against the report's
    first line and its SCEN line; dll is the probe card for UGPROBE."""
    stem = pathlib.Path(name).stem.upper()
    first = lines[0].strip() if lines else ''
    scen = next((ln.split()[1] for ln in lines if ln.startswith('SCEN ') and len(ln.split()) > 1), None)
    m = re.fullmatch(r'PROBE([ER3])', stem)
    if m:
        return 'ugprobe', PROBE_CARD[m.group(1)], scen or m.group(1)
    m = re.fullmatch(r'([UN])(ESP|RTL|509)([TU])([A-Z])', stem)
    if not m:
        return None
    prog = 'ugtest' if m.group(1) == 'U' else 'netdemo'
    dll = DLL_OF[(m.group(2), m.group(3))]
    title = f'{prog.upper()} {dll.upper()}.DLL'
    if first and first != title:
        raise ValueError(f'{name}: first line {first!r}, expected {title!r}')
    return prog, dll, scen or m.group(4)


def judge(prog, s):
    """summary -> {criterion: True / False / None (not measured)}."""
    c = {'result': s.get('result') == 'PASS'}
    st = s.get('stats', {})
    if 'stats' in s:
        c['overflow'] = all(st.get(k, 0) == 0 for k in ('uart_overrun', 'ring_overflow', 'hw_overflow'))
    if prog == 'ugtest':
        step = s.get('step')
        c['step'] = None if not step else step['max_us'] <= STEP_BUDGET_US and step['over_budget'] == 0
    hw = s.get('hw', {})
    lat = hw.get('lat')
    if lat and lat['txdone']['n']:
        c['latency'] = lat['saturated'] == 0 and lat['txdone'].get('max_us', 1e9) <= LAT_MAX_US
    soak = hw.get('soak')
    if soak:
        c['soak'] = soak['frames'] >= SOAK_FRAMES_MIN and (soak['net_max_us'] or 1e9) <= SOAK_NET_MAX_US
    costs = hw.get('costs16', {})
    trivial = s.get('trivial_call_us') or 0
    if 'isr' in costs and costs['isr']['per_call_us'] is not None:
        c['isr'] = costs['isr']['per_call_us'] - trivial <= ISR_BUDGET_US
    if 'busy' in costs and costs['busy']['per_call_us'] is not None and 'info' in s:
        c['bus_busy'] = costs['busy']['per_call_us'] - trivial <= s['info']['bus_busy_us']
    pr = s.get('probe')
    if pr:
        if 'CTC' in pr and pr['CTC']['sample_us'] is not None:
            c['probe_ctc'] = pr['CTC']['sample_us'] <= CTC_READ_MAX_US
        trig = s.get('uart_trigger')
        key = f'UART{trig:02X}' if trig else None
        if key and key in pr:
            c['probe_uart'] = pr[key]['overruns'] == 0
    return c


def parse_file(path, frame_ms, uart_trigger):
    text = path.read_text(errors='replace')
    lines = text.splitlines()
    ident = identify(path.name, lines)
    if not ident:
        return None
    prog, dll, scen = ident
    s = {'stand': 'Ж', 'prog': prog, 'dll' if prog != 'ugprobe' else 'card': dll, 'scenario': scen,
         'file': path.name, 'frame_ms_assumed': frame_ms,
         'result': 'PASS' if 'RESULT: PASS' in text else 'FAIL' if 'RESULT:' in text else 'none'}
    s.update(ugreport.parse_report(lines, frame_ms=frame_ms))
    if prog == 'ugprobe':
        s['probe'] = ugreport.parse_probe(lines, frame_ms)
        s['uart_trigger'] = uart_trigger if dll == 'ESP' else None
    s['save_failed'] = 'SAVE FAIL' in text
    s['report_full'] = 'REPORT FULL' in text
    s['criteria'] = judge(prog, s)
    return text, s


def mark(v):
    return 'не измерено' if v is None else 'да' if v else 'НЕТ'


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('folder', type=pathlib.Path)
    ap.add_argument('--frame-ms', type=float, default=ugreport.FRAME_MS_NOMINAL)
    ap.add_argument('--uart-trigger', type=int, default=8, help='HW_UART_TRIGGER of the build')
    ap.add_argument('--out', type=pathlib.Path, default=ROOT / 'docs' / 'evidence' / 'hw')
    ap.add_argument('--dry-run', action='store_true', help='print only, write no evidence')
    a = ap.parse_args(argv)
    rows = []
    for path in sorted(a.folder.glob('*.[Tt][Xx][Tt]')):
        got = parse_file(path, a.frame_ms, a.uart_trigger)
        if not got:
            print(f'parse_hw: {path.name}: not a Ж report name, skipped', file=sys.stderr)
            continue
        text, s = got
        sub = (f'probe_{s["card"]}' if s['prog'] == 'ugprobe' else f'{s["dll"]}_{s["prog"]}_{s["scenario"]}')
        if not a.dry_run:
            ev = a.out / sub
            ev.mkdir(parents=True, exist_ok=True)
            (ev / 'report.txt').write_text(text)
            (ev / 'summary.json').write_text(json.dumps(s, indent=2, ensure_ascii=False) + '\n')
        rows.append((sub, s))
    print(f'Стенд Ж: {len(rows)} отчётов, кадр {a.frame_ms} мс (допущение для пересчёта счётов CTC)\n')
    print('| прогон | итог | STEP max, мкс | LAT TX_DONE max, мкс | SOAK кадров / net max, мкс | критерии не выполнены |')
    print('|---|---|---|---|---|---|')
    for sub, s in rows:
        step = s.get('step', {}).get('max_us', '—')
        lat = s.get('hw', {}).get('lat', {})
        lat_s = ('—' if not lat or not lat['txdone']['n'] else
                 '> 40 000' if lat['saturated'] else lat['txdone'].get('max_us', '—'))
        soak = s.get('hw', {}).get('soak')
        soak_s = '—' if not soak else f'{soak["frames"]} / {soak["net_max_us"]}'
        bad = [k for k, v in s['criteria'].items() if v is False]
        print(f'| {sub} | {s["result"]} | {step} | {lat_s} | {soak_s} | {", ".join(bad) or "—"} |')
    print('\nПредлагаемые строки матрицы (графа Ж; переносить вручную из summary.json):')
    for sub, s in rows:
        crit = '; '.join(f'{k}: {mark(v)}' for k, v in s['criteria'].items())
        print(f'- {sub}: {"пройдено" if all(v is not False for v in s["criteria"].values()) else "не пройдено"} ({crit})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
