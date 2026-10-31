#!/usr/bin/env python3
"""Turn out-of-range JR into JP, guided by sjasmplus errors.

  tools/fix_jr.py src/dll/gtcp509b.asm [...]

Assembles each entry file, rewrites the reported `JR` lines (same
condition) in the source they come from, and repeats until clean.  JP is
one byte longer: run make size afterwards.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ERR = re.compile(r"^(?P<file>[^(\s]+)\((?P<line>\d+)\): error: \[JR\] Target out of range")


def find(name: str) -> Path:
    hits = [p for p in (ROOT / "src").rglob(name)]
    if len(hits) != 1:
        raise SystemExit(f"cannot resolve {name}: {hits}")
    return hits[0]


def main(entries: list[str]) -> int:
    for _ in range(20):
        fixes: dict[Path, set[int]] = {}
        for e in entries:
            out = subprocess.run(["sjasmplus", "--nologo", "--msg=err", "-I", str(ROOT / "include"), "-I", str(ROOT / "src"),
                                  "--raw=/dev/null", e], capture_output=True, text=True, cwd=ROOT)
            for line in (out.stdout + out.stderr).splitlines():
                m = ERR.match(line)
                if m:
                    fixes.setdefault(find(Path(m["file"]).name), set()).add(int(m["line"]))
        if not fixes:
            return 0
        for path, lines in fixes.items():
            text = path.read_text().split("\n")
            for n in lines:
                old = text[n - 1]
                new = re.sub(r"\bJR\b", "JP", old, count=1)
                if new == old:
                    raise SystemExit(f"{path}:{n}: no JR to rewrite: {old!r}")
                text[n - 1] = new
                print(f"{path.relative_to(ROOT)}:{n}: JR -> JP")
            path.write_text("\n".join(text))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or [str(p) for p in sorted((ROOT / "src" / "dll").glob("*.asm"))]))
