#!/usr/bin/env python3
"""run_esp.py -- one M stand run: a test program + an ESP build in MAME (holub).

  tools/mame/run_esp.py gtcpesp E                  # UGTEST.EXE (libman l_call, M4)
  tools/mame/run_esp.py --prog netdemo gtcpesp E   # NETDEMO.EXE (the SDK, M5)

Scenarios: E echo, S 8 KiB stream, P peer closes (TCP), D SHUTDOWN while
open; NETDEMO also W pause and L load / check / free.

Steps: config include (mkcfg.js) -> UGTEST.EXE (sjasmplus) -> FAT12 floppy
with the EXE and the DLL -> echo server on 127.0.0.1:7000 -> MAME with
-isa1 sprinter_esp -isa1:sprinter_esp:esp esp8266_at,bios=at22 and
ugstand.lua -> report.  Exit status 0 only for "RESULT: PASS".

Evidence (report, decoded statistics, server log, the command line) goes
to build/mame/<prog>_<dll>_<scen>/ and, with --evidence, to
docs/evidence/m4_esp/<dll>_<scen>/ (ugtest) or docs/evidence/m5_sdk/
<dll>_<scen>/ (netdemo).

Environment: MAME_HOLUB (binary, default ../../../mame-holub/sprinter),
MAME_ASSETS (roms + IMG, default .../mame_images/mame_release_v306_25.05.2025),
LIBMAN_DIR (default third_party/libman/libman, the git submodule).
"""
import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPRINTER = ROOT.parents[1]
MAME = pathlib.Path(os.environ.get('MAME_HOLUB', SPRINTER / 'mame-holub' / 'sprinter'))
ASSETS = pathlib.Path(os.environ.get('MAME_ASSETS', SPRINTER / 'mame_images' / 'mame_release_v306_25.05.2025'))
LIBMAN = pathlib.Path(os.environ.get('LIBMAN_DIR', ROOT / 'third_party' / 'libman' / 'libman'))
SCENARIOS = {'E': 'echo 300 bytes', 'S': '8 KiB stream', 'P': 'peer closes', 'D': 'SHUTDOWN while open',
             'W': 'pause 2 s between two echoes', 'L': 'load, check and free the DLL'}
NETDEMO_ONLY = ('W', 'L')


def run(*cmd, **kw):
    return subprocess.run([str(c) for c in cmd], check=True, **kw)


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--prog', choices=['ugtest', 'netdemo'], default='ugtest')
    ap.add_argument('--steps', type=int, default=5, help='NETDEMO: STEPs per 20 ms budget period')
    ap.add_argument('dll', choices=['gtcpesp', 'gudpesp'])
    ap.add_argument('scen', choices=list(SCENARIOS))
    ap.add_argument('--timeout', type=int, default=240, help='MAME -seconds_to_run')
    ap.add_argument('--evidence', action='store_true', help='copy the evidence to docs/evidence/m4_esp')
    ap.add_argument('--window', action='store_true', help='show the MAME window (debugging)')
    a = ap.parse_args()
    if a.dll == 'gudpesp' and a.scen == 'P':
        sys.exit('P (peer closes) is a TCP scenario')
    if a.prog == 'ugtest' and a.scen in NETDEMO_ONLY:
        sys.exit(f'{a.scen} is a NETDEMO scenario')
    prog = a.prog
    work = ROOT / 'build' / 'mame' / (f'{a.dll}_{a.scen}' if prog == 'ugtest' else f'{prog}_{a.dll}_{a.scen}')
    if work.exists():
        shutil.rmtree(work)
    for d in ('cfg', 'nvram', 'diff', 'snap'):
        (work / d).mkdir(parents=True, exist_ok=True)
    dll = ROOT / 'build' / f'{a.dll.upper()}.DLL'
    if not dll.exists():
        sys.exit(f'{dll} missing: run make dlls')
    if not MAME.exists():
        sys.exit(f'{MAME} missing: run tools/mame/build_holub.sh')

    run('node', ROOT / 'tools/mame/mkcfg.js', '--prog', prog, a.dll, work / 'ugcfg.inc')
    run('sjasmplus', '--nologo', '-I', ROOT / 'include', '-I', ROOT / 'sdk', '-I', work, '-I', LIBMAN,
        f'-DSCEN={ord(a.scen)}', f'-DUG_STEPS={a.steps}', f'--sym={work / (prog + ".sym")}',
        ROOT / 'sdk/example' / f'{prog}.asm', cwd=work, stdout=subprocess.DEVNULL)
    img = work / f'{prog}.img'
    run('mformat', '-C', '-i', img, '-f', '1440', '::')
    run('mcopy', '-i', img, work / f'{prog}.exe', f'::{prog.upper()}.EXE')
    run('mcopy', '-i', img, dll, f'::{dll.name}')

    srv_log = work / 'server.log'
    srv_args = [sys.executable, ROOT / 'tools/mame/echo_server.py', '--log', srv_log]
    if a.scen == 'P':
        srv_args += ['--close-after', '64']
    srv = subprocess.Popen([str(x) for x in srv_args], stdout=subprocess.PIPE, text=True)
    srv.stdout.readline()                      # "ready"
    report = work / 'report.txt'
    cmd = [MAME, 'sprinter', '-bios', 'v3.06', '-rompath', ASSETS / 'roms',
           '-hard1', ASSETS / 'IMG' / 'sp_hdd_sys.chd',
           '-cfg_directory', work / 'cfg', '-nvram_directory', work / 'nvram',
           '-diff_directory', work / 'diff', '-snapshot_directory', work / 'snap',
           '-beta:wd179x:1', '35hd', '-flop2', img,
           '-isa0', 'zxbus_adapter', '-isa0:zxbus_adapter:card', 'neogs',
           '-isa1', 'sprinter_esp', '-isa1:sprinter_esp:esp', 'esp8266_at,bios=at22',
           '-skip_gameinfo', '-nothrottle', '-autoboot_script', ROOT / 'tools/mame/ugstand.lua',
           '-seconds_to_run', str(a.timeout)]
    if not a.window:
        cmd += ['-video', 'none', '-sound', 'none']
    env = dict(os.environ, UG_SYM=str(work / f'{prog}.sym'), UG_REPORT_FILE=str(report),
               UG_CMD='b:\\' + prog + '.exe')
    (work / 'command.txt').write_text(' '.join(str(c) for c in cmd) + '\n')
    t0 = time.time()
    try:
        with (work / 'mame.log').open('w') as log:
            subprocess.run([str(c) for c in cmd], cwd=ASSETS, env=env, stdout=log, stderr=subprocess.STDOUT,
                           timeout=a.timeout + 120)
    finally:
        srv.terminate()
        srv.wait(timeout=5)
    wall = time.time() - t0
    text = report.read_text(errors='replace') if report.exists() else 'RESULT: FAIL (no report)\n'
    lines = text.splitlines()
    summary = {'prog': prog, 'dll': a.dll, 'scenario': f'{a.scen} {SCENARIOS[a.scen]}', 'wall_s': round(wall, 1)}
    if prog == 'netdemo':
        summary['steps_per_period'] = a.steps
    for ln in lines:
        if ln.startswith('LOAD '):
            f = ln[5:].split()
            summary['load'] = {'status': int(f[0], 16), 'libman_reason': int(f[1], 16), 'handle': int(f[2], 16),
                               'page': int(f[3], 16), 'base': hex(int(f[4], 16) << 8)}
        if ln.startswith('ENV '):
            f = ln[4:].split()
            summary['env'] = {'init_config': int(f[0], 16), 'env': int(f[1], 16), 'quota_sum_us': int(f[2], 16)}
        if ln.startswith('GW '):
            summary['gateway'] = gateway(bytes.fromhex(ln[3:].strip()))
        if ln.startswith('CLOCK_RATE '):
            summary['clock'] = ln.strip()
        if ln.startswith('TIMING '):
            # stopwatch counts of 16 CPU clocks at 21 MHz (turbo, confirmed by UGTEST's calibration)
            isr, step, gap, late = (int(x, 16) for x in ln[7:].split())
            us = 16 / 21.0
            summary['timing_us'] = {'tick_isr_max': round(isr * us), 'admitted_ug_step_max': round(step * us),
                                    'largest_tick_gap': round(gap * us), 'late_ticks': late}
        if ln.startswith('STATS '):
            summary['stats'] = {k: v for k, v in decode('STATS', ln[6:].strip()).items() if v}
        if ln.startswith('INFO '):
            info = decode('INFO', ln[5:].strip())
            summary['info'] = {k: info[k] for k in ('min_useful_budget_us', 'empty_poll_us', 'bus_busy_us') if k in info}
        if ln.startswith('CAL '):
            cal_ctc, cal_loop = (int(x, 16) for x in ln[4:].split())
        if ln.startswith('CLOCK_RATE '):
            frame_ms = float(ln.split('FRAME_MS ')[1].split(',')[0])   # video frame = IM1 tick during the calibration
            tick_ms = float(ln.split('TICK_MS ')[1].split(',')[0])     # ticks seen while the library runs
        if ln.startswith('STEPTIME '):
            steptime = [int(x, 16) for x in ln[9:].split()]
        if ln.startswith('CALLTIME16 '):
            calltime = int(ln[11:].strip(), 16)
    try:
        # CTC timer counts (16 CTC clocks) -> real us via the video frame
        # (= the IM1 tick while nothing holds DI); the CTC clock = the CPU clock
        us_per_count = frame_ms * 1000 / cal_ctc
        mx, n, total, over = steptime
        summary['cpu_mhz'] = round(cal_ctc * 16 / (frame_ms * 1000), 2)
        summary['frame_ms'] = frame_ms
        summary['ticks_missed_ratio'] = round(1 - frame_ms / tick_ms, 3) if tick_ms else None
        summary['step'] = {
            'max_us': round(mx * us_per_count), 'mean_us': round(total * us_per_count / max(n, 1)),
            'steps': n, 'over_budget': over}
        summary['trivial_call_us'] = round(calltime * us_per_count / 16)
    except NameError:
        pass
    (work / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(text)
    print(json.dumps(summary, indent=2))
    ok = 'RESULT: PASS' in text
    if a.evidence:
        ev = ROOT / 'docs' / 'evidence' / ('m4_esp' if prog == 'ugtest' else 'm5_sdk') / f'{a.dll}_{a.scen}'
        if ev.exists():
            shutil.rmtree(ev)
        ev.mkdir(parents=True)
        for f in ('report.txt', 'summary.json', 'server.log', 'command.txt'):
            if (work / f).exists():
                shutil.copy2(work / f, ev / f)
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
