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
  step        UGTEST STEPTIME: max - trivial call <= STEP_BUDGET_US (the
              program measures a STEP with its libman call; budgets are
              real time since 2026-11-22)
  overflow    STATS uart_overrun = ring_overflow = hw_overflow = 0
  latency     LAT: TX_DONE max <= 40 ms, no saturated sample
  soak        SOAK (K): frames >= 30000 (10 min), per-frame net max <= 2000 us
  isr         ISRTIME16 / 16 - trivial call <= isr_budget_us (370)
  bus_busy    BUSYTIME16 / 16 - trivial call <= GET_INFO bus_busy_us
  probe_ctc   UGPROBE: the APP_COUNTER sample <= 50 us (time_read_cost_us)
  probe_uart  UGPROBE E: no UART overrun at the configured trigger
  flow        NETDEMO F: at least FLOW_MIN_SHARE of the offered inputs at the
              server and no state lost (the game flow of Headball)
  card_found  SLOT: some ISA slot answered as the card (ughw.inc hw_slot);
              a card found only in the other slot is not a failure of the
              run (the program used that slot) but a wrong HW_SLOT_* in
              tools/hw/hw.env: printed as a warning
"""
import argparse
import hashlib
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools' / 'mame'))
import ugreport  # noqa: E402

ISR_BUDGET_US = 370          # INIT_CONFIG.isr_budget_us of the Ж builds (tools/mame/mkcfg.js), real us
STEP_BUDGET_US = 1280        # sdk/example/ugtest.asm STEP_BUDGET, real us
LAT_MAX_US = 40000
SOAK_FRAMES_MIN = 30000
SOAK_NET_MAX_US = 2000
FLOW_MIN_SHARE = 0.96       # NETDEMO F: inputs at the server / offered (25 a second)
CTC_READ_MAX_US = 50        # INIT_CONFIG.time_read_cost_us the core accepts (real us; UGT_READ_US)
CARD_OF = {'ESP': 'ESP', 'RTL': 'RTL', '509': 'EL3'}
DLL_OF = {('ESP', 'T'): 'gtcpesp', ('ESP', 'U'): 'gudpesp', ('RTL', 'T'): 'gtcprtl',
          ('RTL', 'U'): 'gudprtl', ('509', 'T'): 'gtcp509b', ('509', 'U'): 'gudp509b'}
PROBE_CARD = {'E': 'ESP', 'R': 'RTL', '3': 'EL3'}
STATUS = {v: k for k, v in json.loads((ROOT / 'tools' / 'harness' / 'abi.json').read_text())['consts']['status'].items()}


def identify(name, lines):
    """(prog, dll, scen) from the file name, checked against the report's
    first line and its SCEN line; dll is the probe card for UGPROBE."""
    stem = pathlib.Path(name).stem.upper()
    first = lines[0].strip() if lines else ''
    scen = next((ln.split()[1] for ln in lines if ln.startswith('SCEN ') and len(ln.split()) > 1), None)
    m = re.fullmatch(r'(PROBE|STATA)([ER3])', stem)
    if m:
        return ('ugprobe' if m.group(1) == 'PROBE' else 'ugstate'), PROBE_CARD[m.group(2)], scen or m.group(2)
    m = re.fullmatch(r'([UN])(ESP|RTL|509)([TUX])([A-Z])', stem)
    if not m or (m.group(3) == 'X' and m.group(2) != 'ESP'):
        return None
    prog = 'ugtest' if m.group(1) == 'U' else 'netdemo'
    # X: GUDPESP in its transparent mode (esp_fw = 2); the evidence goes
    # to gudpespx_<prog>_<scen>, as the M stand's gudpespx_<scen>
    dll = DLL_OF[(m.group(2), 'U' if m.group(3) == 'X' else m.group(3))]
    title = f'{prog.upper()} {dll.upper()}.DLL'
    if first and first != title:
        raise ValueError(f'{name}: first line {first!r}, expected {title!r}')
    return prog, dll + ('x' if m.group(3) == 'X' else ''), scen or m.group(4)


def judge(prog, s):
    """summary -> {criterion: True / False / None (not measured)}."""
    c = {'result': s.get('result') == 'PASS'}
    st = s.get('stats', {})
    if 'stats' in s:
        c['overflow'] = all(st.get(k, 0) == 0 for k in ('uart_overrun', 'ring_overflow', 'hw_overflow'))
    if prog == 'ugtest':
        step = s.get('step')
        c['step'] = (None if not step or not step['steps'] else
                     step['max_us'] - (s.get('trivial_call_us') or 0) <= STEP_BUDGET_US)
    hw = s.get('hw', {})
    lat = hw.get('lat')
    if lat and lat['txdone']['n']:
        c['latency'] = lat['saturated'] == 0 and lat['txdone'].get('max_us', 1e9) <= LAT_MAX_US
    soak = hw.get('soak')
    if soak:
        c['soak'] = soak['frames'] >= SOAK_FRAMES_MIN and (soak['net_max_us'] or 1e9) <= SOAK_NET_MAX_US
    flow = hw.get('flow')
    if flow:
        c['flow'] = (flow['offered'] > 0 and flow['at_server'] >= FLOW_MIN_SHARE * flow['offered']
                     and flow['states_lost'] == 0)
    costs = hw.get('costs16', {})
    trivial = s.get('trivial_call_us') or 0
    if 'isr' in costs and costs['isr']['per_call_us'] is not None:
        c['isr'] = costs['isr']['per_call_us'] - trivial <= ISR_BUDGET_US
    if 'busy' in costs and costs['busy']['per_call_us'] is not None and 'info' in s:
        c['bus_busy'] = costs['busy']['per_call_us'] - trivial <= s['info']['bus_busy_us']
    slot = hw.get('slot')
    if slot:
        c['card_found'] = bool(slot['found'])
    pr = s.get('probe')
    if pr:
        if 'CTC' in pr and pr['CTC']['sample_us'] is not None:
            c['probe_ctc'] = pr['CTC']['sample_us'] <= CTC_READ_MAX_US
        trig = s.get('uart_trigger')
        key = f'UART{trig:02X}' if trig else None
        if key and key in pr:
            c['probe_uart'] = pr[key]['overruns'] == 0
    return c


# DSSENV values that are the operator's addresses: the evidence keeps only
# "set" (tools/hw/hw.env is not committed for the same reason)
ENV_PRIVATE = {'NET_MAC', 'NET_IP', 'NET_MASK', 'NET_GW'}
# ... and any other value that looks like an address or a piece of one: the
# RTL machine's DSS showed NET_LEASE_SEC=92.168.1.1 (a gateway's tail)
ENV_ADDR = re.compile(r'\d+(\.\d+){1,3}$|[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){2,5}$')


def state_of(text):
    """(text without private values, state dict or None): the CARD and
    DSSENV lines of UGPROBE (tools/measure/ugprobe.asm pr_state)."""
    out, card, env = [], None, {}
    for ln in text.splitlines(keepends=True):
        body = ln.rstrip('\r\n')
        if body.startswith('CARD ') and card is None:
            card = body.split()[1:]
        elif body.startswith('DSSENV '):
            rest = body[7:]
            if '=' in rest:
                name, value = rest.split('=', 1)
                if name in ENV_PRIVATE or ENV_ADDR.match(value):  # a tag still shows a change
                    value = '<set %s>' % hashlib.sha256(value.encode()).hexdigest()[:4]
                    ln = f'DSSENV {name}={value}' + ln[len(body):]
                env[name] = value
            else:
                env[rest.split()[0]] = None
        out.append(ln)
    return ''.join(out), ({'card_regs': card, 'env': env} if card is not None or env else None)


def parse_file(path, frame_ms, uart_trigger):
    text, state = state_of(path.read_text(errors='replace'))
    lines = text.splitlines()
    ident = identify(path.name, lines)
    if not ident:
        return None
    prog, dll, scen = ident
    probe = prog in ('ugprobe', 'ugstate')
    s = {'stand': 'Ж', 'prog': prog, 'card' if probe else 'dll': dll, 'scenario': scen,
         'file': path.name, 'frame_ms_assumed': frame_ms,
         'result': 'PASS' if 'RESULT: PASS' in text else 'FAIL' if 'RESULT:' in text else 'none'}
    s.update(ugreport.parse_report(lines, frame_ms=frame_ms))
    if state:
        s['state'] = state
    if prog == 'ugprobe':
        s['probe'] = ugreport.parse_probe(lines, frame_ms)
        s['uart_trigger'] = uart_trigger if dll == 'ESP' else None
    m = re.search(r'RESULT: FAIL (\S+)', text)
    s['fail_code'] = m.group(1) if m else None
    m = re.search(r'^INIT_CONFIG ([0-9A-Fa-f]{2})', text, re.M)
    init = int(m.group(1), 16) if m else s.get('env', {}).get('init_config')
    s['init_config'] = None if init is None else STATUS.get(init, f'0x{init:02X}')
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
        sub = (f'probe_{s["card"]}' if s['prog'] == 'ugprobe' else f'state_{s["card"]}' if s['prog'] == 'ugstate'
               else f'{s["dll"]}_{s["prog"]}_{s["scenario"]}')
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
        st = s.get('step')
        step = st['max_us'] if st and st['steps'] else '—'
        lat = s.get('hw', {}).get('lat', {})
        lat_s = ('—' if not lat or not lat['txdone']['n'] else
                 '> 40 000' if lat['saturated'] else lat['txdone'].get('max_us', '—'))
        soak = s.get('hw', {}).get('soak')
        soak_s = '—' if not soak else f'{soak["frames"]} / {soak["net_max_us"]}'
        bad = [k for k, v in s['criteria'].items() if v is False]
        res = s['result'] + (f' {s["fail_code"]}' if s['fail_code'] else '')
        if s['init_config'] not in (None, 'OK'):
            res += f' (INIT_CONFIG {s["init_config"]})'
        print(f'| {sub} | {res} | {step} | {lat_s} | {soak_s} | {", ".join(bad) or "—"} |')
    for sub, s in rows:
        slot = s.get('hw', {}).get('slot')
        if slot and slot['found'] and slot['configured'] not in slot['found']:
            print(f'\nВНИМАНИЕ {sub}: карта отвечает в слоте {slot["found"]}, а не в настроенном '
                  f'{slot["configured"]} (прогон шёл в слоте {slot["used"]}): исправьте HW_SLOT_* в tools/hw/hw.env')
    # NETDEMO T / Q: one packet at a time under the program's quota profile
    lat_rows = [(sub, s) for sub, s in rows if s.get('hw', {}).get('latms')]
    if lat_rows:
        print('\nЗадержка пакета под квотой (NETDEMO T, Q, A, B, C, G; мс от TX_COMMIT; шаг часов — тик таймера 2 мс):\n')
        print('| прогон | сумма квот, мкс | самый долгий UG_STEP, мкс | байт | TX_DONE среднее / max | эхо целиком среднее / max |')
        print('|---|---|---|---|---|---|')
        for sub, s in lat_rows:
            for r in s['hw']['latms']:
                print(f'| {sub} | {s.get("env", {}).get("quota_sum_us", "—")} | '
                      f'{s.get("timing_us", {}).get("admitted_ug_step_max", "—")} | {r["bytes"]} | '
                      f'{r["txdone_mean_ms"]} / {r["txdone_max_ms"]} | {r["echo_mean_ms"]} / {r["echo_max_ms"]} |')
    # NETDEMO F: the game flow (Headball: inputs up, states down at once)
    flow_rows = [(sub, s) for sub, s in rows if s.get('hw', {}).get('flow')]
    if flow_rows:
        print('\nПоток игры (NETDEMO F, ввод 20 байт раз в 40 мс, снимок 88 байт раз в 100 мс; мс):\n')
        print('| прогон | вводов предложено / отправлено / у сервера | снимков / потеряно | TX_DONE max | '
              'ввод вверх + снимок вниз, среднее / max | наибольший промежуток между снимками |')
        print('|---|---|---|---|---|---|')
        for sub, s in flow_rows:
            f = s['hw']['flow']
            print(f'| {sub} | {f["offered"]} / {f["sent"]} / {f["at_server"]} | {f["states"]} / {f["states_lost"]} | '
                  f'{f["txdone_max_ms"]} | {f["loop_mean_ms"]} / {f["loop_max_ms"]} | {f["state_gap_max_ms"]} |')
    # bring-up and the first ARP exchange: a run that needed several
    # requests lost seconds at OPEN (ARP repeats once a second)
    arp_rows = [(sub, s) for sub, s in rows if (s.get('stats') or {}).get('arp_requests') is not None]
    slow = [(sub, s) for sub, s in arp_rows if s['stats']['arp_requests'] > 1]
    if arp_rows and (slow or any(s.get('hw', {}).get('bring') for _, s in arp_rows)):
        print(f'\nПодъём карты и ARP: {len(arp_rows)} прогонов с каналом, '
              f'больше одного запроса ARP — в {len(slow)}:\n')
        print('| прогон | запросов ARP | подъём, мс | байт состояния (3C509B: 00 — без сброса, 01 — со сбросом) |')
        print('|---|---|---|---|')
        for sub, s in arp_rows:
            br = s.get('hw', {}).get('bring')
            if not br and s['stats']['arp_requests'] <= 1:
                continue
            print(f'| {sub} | {s["stats"]["arp_requests"]} | {br["ms"] if br else "—"} | '
                  f'{"%02X" % br["scratch"] if br else "—"} |')
    # the state the series left to the system stack: UGPROBE (before) against
    # UGPROBE <card> 1 (after, STATA<card>.TXT)
    by = dict(rows)
    for card in PROBE_CARD.values():
        before, after = by.get(f'probe_{card}', {}).get('state'), by.get(f'state_{card}', {}).get('state')
        if not after:
            continue
        print(f'\nСостояние после серии, карта {card} (STATA): регистры {" ".join(after["card_regs"] or [])}')
        if not before:
            print('  снимка «до» нет (PROBE без строк CARD / DSSENV)')
            continue
        print(f'  до серии: регистры {" ".join(before["card_regs"] or [])}')
        names = sorted(set(before['env']) | set(after['env']))
        changed = [n for n in names if before['env'].get(n) != after['env'].get(n)]
        gone = [n for n in changed if after['env'].get(n) is None]
        print('  переменные NET* окружения DSS: ' + ('без изменений' if not changed else
              'ИЗМЕНИЛИСЬ ' + ', '.join(changed) + (f' (пропали: {", ".join(gone)})' if gone else '')))
    print('\nПредлагаемые строки матрицы (графа Ж; переносить вручную из summary.json):')
    for sub, s in rows:
        if s['prog'] == 'ugstate':
            continue
        crit = '; '.join(f'{k}: {mark(v)}' for k, v in s['criteria'].items())
        print(f'- {sub}: {"пройдено" if all(v is not False for v in s["criteria"].values()) else "не пройдено"} ({crit})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
