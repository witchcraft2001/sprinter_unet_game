#!/usr/bin/env python3
"""run_m.py -- one M stand run: a test program + a card build in MAME.

  tools/mame/run_m.py gtcpesp E                    # UGTEST.EXE (libman l_call, M4)
  tools/mame/run_m.py --prog netdemo gtcpesp E     # NETDEMO.EXE (the SDK, M5)
  tools/mame/run_m.py --prog netdemo gtcprtl E     # RTL8019AS over pcap (M3)

Scenarios: E echo, S 8 KiB stream, P peer closes (TCP), D SHUTDOWN while
open; NETDEMO also W pause, L load / check / free and H card bring-up and
SHUTDOWN without a channel (Ethernet: needs no network).

Cards:
  ESP  holub MAME, -isa1 sprinter_esp with the ESP-AT model (at22); the
       model opens host sockets: echo server on 127.0.0.1:7000.
  RTL  holub MAME, -isa1 rtl8019as (I/O 0x300).
  EL3  the user's MAME build (MAME_3C509B, default ../../../mame/mame; run
       read-only with our own cfg/nvram/diff directories), -isa1 3c509b.
  Ethernet cards use -networkprovider pcap on MAME_NET_IF (default feth0,
  the pair made by tools/mame/net_feth.sh); the host side feth1 carries
  MAME_NET_HOST (default 192.168.7.1), where the echo server listens.  The
  pcap interface index is looked up at every run (it is not stable) and
  written into cfg/sprinter.cfg.  Without the interface a network scenario
  exits 77 (SKIP); H runs with -networkprovider none (never pcap on a real
  host adapter).  Ethernet runs are throttled (the peer answers in real
  time) unless --nothrottle.

Steps: config include (mkcfg.js) -> the EXE (sjasmplus) -> FAT12 floppy
with the EXE and the DLL -> echo server -> MAME with the card and
ugstand.lua -> report.  Exit status 0 only for "RESULT: PASS".

Evidence (report, decoded statistics, server log, the command line) goes
to build/mame/<prog>_<dll>_<scen>/; with --evidence the report and the
statistics (not the timestamped server log nor the machine-specific
command line) are copied to docs/evidence/m4_esp/<dll>_<scen>/ (ESP,
ugtest), docs/evidence/m5_sdk/<dll>_<scen>/ (ESP, netdemo) or
docs/evidence/m3_eth/<prog>_<dll>_<scen>/.

Environment: MAME_HOLUB (binary, default ../../../mame-holub/sprinter),
MAME_3C509B, MAME_NET_IF, MAME_NET_HOST, MAME_ASSETS (roms + IMG, default
.../mame_images/mame_release_v306_25.05.2025), LIBMAN_DIR (default
third_party/libman/libman, the git submodule).
"""
import argparse
import json
import os
import pathlib
import random
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPRINTER = ROOT.parents[1]
MAME = pathlib.Path(os.environ.get('MAME_HOLUB', SPRINTER / 'mame-holub' / 'sprinter'))
MAME_3C509B = pathlib.Path(os.environ.get('MAME_3C509B', SPRINTER / 'mame' / 'mame'))
NET_IF = os.environ.get('MAME_NET_IF', 'feth0')
NET_HOST = os.environ.get('MAME_NET_HOST', '192.168.7.1')
ASSETS = pathlib.Path(os.environ.get('MAME_ASSETS', SPRINTER / 'mame_images' / 'mame_release_v306_25.05.2025'))
LIBMAN = pathlib.Path(os.environ.get('LIBMAN_DIR', ROOT / 'third_party' / 'libman' / 'libman'))
SCENARIOS = {'E': 'echo 300 bytes', 'S': '8 KiB stream', 'P': 'peer closes', 'D': 'SHUTDOWN while open',
             'W': 'pause 2 s between two echoes', 'L': 'load, check and free the DLL',
             'H': 'card bring-up and SHUTDOWN, no channel'}
NETDEMO_ONLY = ('W', 'L', 'H')
DLLS = ('gtcpesp', 'gudpesp', 'gtcprtl', 'gudprtl', 'gtcp509b', 'gudp509b')
SKIP = 77
NET_CFG = '''<?xml version="1.0"?>
<mameconfig version="10">
    <system name="sprinter">
        <network>
            <device tag="{tag}" interface="{index}" mac="{mac}" />
        </network>
    </system>
</mameconfig>
'''


def card_of(dll):
    return 'ESP' if dll.endswith('esp') else 'RTL' if dll.endswith('rtl') else 'EL3'


def pcap_index(mame, name):
    """Ordinal of interface `name` in `mame -listnetwork`, None when absent."""
    out = subprocess.run([str(mame), '-networkprovider', 'pcap', '-listnetwork'],
                         capture_output=True, text=True).stdout
    listed, n = False, 0
    for ln in out.splitlines():
        if ln.startswith('Available network interfaces:'):
            listed = True
        elif listed and ln.strip():
            if ln.strip() == name:
                return n
            n += 1
    return None


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
    ap.add_argument('dll', choices=DLLS)
    ap.add_argument('scen', choices=list(SCENARIOS))
    ap.add_argument('--timeout', type=int, default=240, help='MAME -seconds_to_run')
    ap.add_argument('--evidence', action='store_true', help='copy the evidence to docs/evidence')
    ap.add_argument('--nothrottle', action='store_true', help='Ethernet: run unthrottled')
    ap.add_argument('--window', action='store_true', help='show the MAME window (debugging)')
    a = ap.parse_args()
    if a.dll.startswith('gudp') and a.scen == 'P':
        sys.exit('P (peer closes) is a TCP scenario')
    if a.prog == 'ugtest' and a.scen in NETDEMO_ONLY:
        sys.exit(f'{a.scen} is a NETDEMO scenario')
    prog = a.prog
    card = card_of(a.dll)
    mame = MAME_3C509B if card == 'EL3' else MAME
    if not mame.exists():
        sys.exit(f'{mame} missing' + (': run tools/mame/build_holub.sh' if card != 'EL3' else ' (set MAME_3C509B)'))
    net = card != 'ESP' and a.scen not in ('L', 'H')
    index = pcap_index(mame, NET_IF) if card != 'ESP' and a.scen != 'L' else None
    if net and index is None:
        print(f'SKIP: pcap interface {NET_IF} not found (create the pair: tools/mame/net_feth.sh)')
        sys.exit(SKIP)
    work = ROOT / 'build' / 'mame' / (f'{a.dll}_{a.scen}' if prog == 'ugtest' else f'{prog}_{a.dll}_{a.scen}')
    if work.exists():
        shutil.rmtree(work)
    for d in ('cfg', 'nvram', 'diff', 'snap'):
        (work / d).mkdir(parents=True, exist_ok=True)
    dll = ROOT / 'build' / f'{a.dll.upper()}.DLL'
    if not dll.exists():
        sys.exit(f'{dll} missing: run make dlls')
    peer = '127.0.0.1' if card == 'ESP' else NET_HOST
    # An emulated run is deterministic: the same local port and the same
    # clock-based ISS every time.  The host still holds the previous
    # connection on that 4-tuple (TIME_WAIT after P, ESTABLISHED after D:
    # v1 sends no RST) and drops the new SYN, so every Ethernet run gets
    # its own local port.
    lport = '7001' if card == 'ESP' else str(random.randint(20000, 48999))
    run('node', ROOT / 'tools/mame/mkcfg.js', '--prog', prog, a.dll, work / 'ugcfg.inc', peer, '7000', lport)
    run('sjasmplus', '--nologo', '-I', ROOT / 'include', '-I', ROOT / 'sdk', '-I', work, '-I', LIBMAN,
        f'-DSCEN={ord(a.scen)}', f'-DUG_STEPS={a.steps}', f'--sym={work / (prog + ".sym")}',
        ROOT / 'sdk/example' / f'{prog}.asm', cwd=work, stdout=subprocess.DEVNULL)
    img = work / f'{prog}.img'
    run('mformat', '-C', '-i', img, '-f', '1440', '::')
    run('mcopy', '-i', img, work / f'{prog}.exe', f'::{prog.upper()}.EXE')
    run('mcopy', '-i', img, dll, f'::{dll.name}')

    srv_log = work / 'server.log'
    srv_args = [sys.executable, ROOT / 'tools/mame/echo_server.py', '--log', srv_log, '--host', peer]
    if a.scen == 'P':
        srv_args += ['--close-after', '64']
    srv = None
    if card == 'ESP' or net:
        srv = subprocess.Popen([str(x) for x in srv_args], stdout=subprocess.PIPE, text=True)
        if srv.stdout.readline().strip() != 'ready':
            sys.exit(f'echo server did not start on {peer} (is {NET_IF} paired and feth1 at that address?)')
    if card == 'ESP':
        card_args = ['-isa1', 'sprinter_esp', '-isa1:sprinter_esp:esp', 'esp8266_at,bios=at22', '-nothrottle']
    else:
        tag, mac = ((':isa1:rtl8019as:rtl8019a', '02:80:19:12:34:56') if card == 'RTL'
                    else (':isa1:3c509b', '02:60:8c:12:34:56'))
        card_args = ['-isa1', 'rtl8019as' if card == 'RTL' else '3c509b']
        if index is not None:
            (work / 'cfg' / 'sprinter.cfg').write_text(NET_CFG.format(tag=tag, index=index, mac=mac))
            card_args += ['-networkprovider', 'pcap']
        else:
            card_args += ['-networkprovider', 'none']
        if a.nothrottle or not net:
            card_args.append('-nothrottle')
    report = work / 'report.txt'
    cmd = [mame, 'sprinter', '-bios', 'v3.06', '-rompath', ASSETS / 'roms',
           '-hard1', ASSETS / 'IMG' / 'sp_hdd_sys.chd',
           '-cfg_directory', work / 'cfg', '-nvram_directory', work / 'nvram',
           '-diff_directory', work / 'diff', '-snapshot_directory', work / 'snap',
           '-beta:wd179x:1', '35hd', '-flop2', img,
           '-isa0', 'zxbus_adapter', '-isa0:zxbus_adapter:card', 'neogs',
           *card_args, '-skip_gameinfo', '-autoboot_script', ROOT / 'tools/mame/ugstand.lua',
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
        if srv:
            srv.terminate()
            srv.wait(timeout=5)
    wall = time.time() - t0
    text = report.read_text(errors='replace') if report.exists() else 'RESULT: FAIL (no report)\n'
    lines = text.splitlines()
    summary = {'prog': prog, 'dll': a.dll, 'card': card, 'mame': str(mame),
               'scenario': f'{a.scen} {SCENARIOS[a.scen]}', 'wall_s': round(wall, 1)}
    if card != 'ESP':
        summary['network'] = 'none' if index is None else f'pcap {NET_IF} (index {index}), peer {NET_HOST}, local port {lport}'
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
        if card == 'ESP':
            ev = ROOT / 'docs' / 'evidence' / ('m4_esp' if prog == 'ugtest' else 'm5_sdk') / f'{a.dll}_{a.scen}'
        else:
            ev = ROOT / 'docs' / 'evidence' / 'm3_eth' / f'{prog}_{a.dll}_{a.scen}'
        if ev.exists():
            shutil.rmtree(ev)
        ev.mkdir(parents=True)
        for f in ('report.txt', 'summary.json'):
            if (work / f).exists():
                shutil.copy2(work / f, ev / f)
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
