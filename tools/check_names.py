#!/usr/bin/env python3
"""Check UNET-GAME delivery names (ТЗ §9.1).

- seven DOS 8.3 names, uppercase ASCII letters/digits, one dot, .DLL;
- unique without regard to case, and different from the legacy UNET<tag>.DLL;
- every entry has src/dll/<src>.asm with matching UGB_HW_/UGB_TP_ defines;
- built files (when present) carry the same name in the L1 header.
"""
from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LEGACY = {"UNETESP", "UNETRTL", "UNET509B"}


def main() -> int:
    abi = tomllib.loads((ROOT / "abi" / "unetgame_abi.toml").read_text(encoding="utf-8"))
    dlls = abi["dll"]
    errors = []
    if len(dlls) != 7:
        errors.append(f"expected 7 DLLs, found {len(dlls)}")
    seen = set()
    for d in dlls:
        name = d["file"]
        if not re.fullmatch(r"[A-Z0-9]{1,8}\.DLL", name):
            errors.append(f"{name}: not an uppercase DOS 8.3 .DLL name")
        base = name.split(".")[0]
        if base.upper() in seen:
            errors.append(f"{name}: duplicate base name")
        seen.add(base.upper())
        if base.upper() in LEGACY or base.upper().startswith("UNET"):
            errors.append(f"{name}: collides with the legacy UNET<tag>.DLL naming")
        if base.upper() != d["src"].upper():
            errors.append(f"{name}: source {d['src']} does not match")
        src = ROOT / "src" / "dll" / f"{d['src']}.asm"
        if not src.exists():
            errors.append(f"{src.relative_to(ROOT)} missing")
            continue
        text = src.read_text()
        for define in (f"UGB_HW_{d['hw']}", f"UGB_TP_{d['transport']}"):
            if not re.search(rf"^\s*DEFINE\s+{define}\s*$", text, re.M):
                errors.append(f"{src.name}: missing DEFINE {define}")
        built = ROOT / "build" / name
        if built.exists():
            hdr_name = built.read_bytes()[16:32].split(b"\0", 1)[0].decode("ascii")
            if not hdr_name.startswith(base):
                errors.append(f"{name}: L1 name field is {hdr_name!r}")
    if not any(d["hw"] == "LOOP" for d in dlls):
        errors.append("GLOOP missing")
    for e in errors:
        print(f"names: {e}", file=sys.stderr)
    if not errors:
        print(f"names: {len(dlls)} delivery names OK")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
