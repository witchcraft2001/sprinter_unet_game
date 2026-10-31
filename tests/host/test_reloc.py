"""Relocation model check: every built L1 relocated by the libman rule
(+high byte of the base on marked bytes) must equal the same source
assembled directly at that address.  Catches address arithmetic that the
two-pass diff of sprinter-mkdll cannot express (label*2, masks, ...)."""
from __future__ import annotations

import re
import struct
import subprocess
import tempfile
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASES = (0x4000, 0x4A00, 0x8000, 0xB300)


def relocate(dll: bytes, base: int) -> bytes:
    code_size, reloc_size = struct.unpack_from("<HH", dll, 4)
    image = bytearray(dll[:code_size])
    bitmap = dll[code_size:code_size + reloc_size]
    for i in range(code_size - 32):
        if bitmap[i >> 3] & (0x80 >> (i & 7)):
            image[32 + i] = (image[32 + i] + (base >> 8)) & 0xFF
    return bytes(image[32:])


def assemble_at(src: Path, origin: int) -> bytes:
    text = src.read_text()
    text, n = re.subn(r"(?mi)^(\s*)ORG\s+\S+", rf"\g<1>ORG 0x{origin:04X}", text, count=1)
    assert n == 1
    with tempfile.TemporaryDirectory() as tmp:
        tsrc = Path(tmp) / src.name
        tsrc.write_text(text)
        out = Path(tmp) / "out.bin"
        subprocess.run(["sjasmplus", "--nologo", "--msg=err", "-I", str(ROOT / "include"), "-I", str(ROOT / "src"),
                        f"--raw={out}", str(tsrc)], check=True, capture_output=True)
        return out.read_bytes()


class RelocTests(unittest.TestCase):
    def test_relocated_equals_direct(self) -> None:
        abi = tomllib.loads((ROOT / "abi" / "unetgame_abi.toml").read_text(encoding="utf-8"))
        for d in abi["dll"]:
            dll = (ROOT / "build" / d["file"]).read_bytes()
            src = ROOT / "src" / "dll" / f"{d['src']}.asm"
            for base in BASES:
                with self.subTest(dll=d["file"], base=hex(base)):
                    self.assertEqual(relocate(dll, base), assemble_at(src, base + 0x20))


if __name__ == "__main__":
    unittest.main()
