#!/usr/bin/env python3
"""Size report for UNET-GAME DLLs (ТЗ §2): image, relocations, sum, prefix.

Reads the L1 header directly, so it does not depend on mkdll's text output.
Fails (exit 1) when code_size + reloc_size or the prefix exceeds 16384 bytes,
or when the code body exceeds 0x38C7.  Writes build/size-report.json.
"""
from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIMIT = 16384
MAX_BODY = 0x38C7
ALL = ["gtcpesp", "gudpesp", "gtcprtl", "gudprtl", "gtcp509b", "gudp509b", "gloop"]


def header(path: Path) -> dict:
    data = path.read_bytes()
    if len(data) < 32 or data[:2] != b"L1":
        raise SystemExit(f"{path}: not an L1 DLL")
    prefix, code_size, reloc_size, checksum = struct.unpack_from("<HHHH", data, 2)
    day, month, year, version = data[10], data[11], *struct.unpack_from("<HH", data, 12)
    name = data[16:32].split(b"\0", 1)[0].decode("ascii")
    return {"file": path.name, "file_size": len(data), "prefix": prefix,
            "image": code_size, "body": code_size - 32, "reloc": reloc_size,
            "sum": code_size + reloc_size, "free": MAX_BODY - (code_size - 32),
            "name": name, "version": f"{version >> 8}.{version & 0xFF}",
            "date": f"{year:04d}-{month:02d}-{day:02d}", "trailing": len(data) - prefix}


def main(argv: list[str]) -> int:
    names = argv[1:] or ALL
    rows, bad = [], []
    for n in names:
        p = ROOT / "build" / f"{n.upper()}.DLL"
        if not p.exists():
            bad.append(f"{p.name}: missing")
            continue
        h = header(p)
        rows.append(h)
        if h["sum"] > LIMIT:
            bad.append(f"{h['file']}: image+reloc {h['sum']} > {LIMIT}")
        if h["prefix"] > LIMIT:
            bad.append(f"{h['file']}: prefix {h['prefix']} > {LIMIT}")
        if h["body"] > MAX_BODY:
            bad.append(f"{h['file']}: body {h['body']} > {MAX_BODY}")
        if h["trailing"]:
            bad.append(f"{h['file']}: {h['trailing']} trailing bytes (overlays are forbidden)")
    print(f"{'DLL':<13}{'image':>7}{'reloc':>7}{'sum':>7}{'prefix':>8}{'limit':>7}{'free':>7}  name")
    for h in rows:
        print(f"{h['file']:<13}{h['image']:>7}{h['reloc']:>7}{h['sum']:>7}{h['prefix']:>8}{LIMIT:>7}{h['free']:>7}  {h['name']}")
    out = ROOT / "build" / "size-report.json"
    out.write_text(json.dumps(rows, indent=1) + "\n")
    for b in bad:
        print(f"SIZE FAIL: {b}", file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
