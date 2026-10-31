#!/usr/bin/env python3
"""Generate UNET-GAME ABI artefacts from abi/*.toml.

  gen_abi.py gen     write include/UNETGAME.INC, include/unetg_ctx.inc, include/unetg_jt.inc,
                     tools/harness/abi.json, docs/ABI-TABLE.md
  gen_abi.py check   fail if any generated file is stale
"""
from __future__ import annotations

import json
import re
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ABI = ROOT / "abi" / "unetgame_abi.toml"
CTX = ROOT / "abi" / "ctx.toml"

OUT_INC = ROOT / "include" / "UNETGAME.INC"
OUT_CTX = ROOT / "include" / "unetg_ctx.inc"
OUT_JT = ROOT / "include" / "unetg_jt.inc"
OUT_VER = ROOT / "include" / "unetg_version.inc"
VERSION = ROOT / "VERSION"
OUT_JSON = ROOT / "tools" / "harness" / "abi.json"
OUT_MD = ROOT / "docs" / "ABI-TABLE.md"

SCALAR = {"u8": 1, "u16": 2, "u32": 4, "ip4": 4, "mac6": 6}
CONST_SECTIONS = [
    "status", "flag", "src", "src_flag", "ev", "txdone", "timeout", "stream",
    "fallback", "hw", "transport", "mode", "timing", "cfgf", "cap", "route",
    "probe", "lock", "ctxstate", "avail", "limits",
]


class AbiError(Exception):
    pass


def type_size(t: str) -> tuple[int, int, str]:
    """Return (total size, element count, element type)."""
    m = re.fullmatch(r"(u8|u16|u32)\[(\d+)\]", t)
    if m:
        return SCALAR[m.group(1)] * int(m.group(2)), int(m.group(2)), m.group(1)
    if t not in SCALAR:
        raise AbiError(f"unknown field type {t!r}")
    return SCALAR[t], 1, t


def layout(block: dict) -> dict:
    off = 0
    fields = []
    seen = set()
    for name, ftype, note in block["fields"]:
        if name in seen:
            raise AbiError(f"{block['name']}: duplicate field {name}")
        seen.add(name)
        size, count, etype = type_size(ftype)
        fields.append({"name": name, "type": ftype, "offset": off, "size": size,
                       "count": count, "elem": etype, "note": note})
        off += size
    return {"name": block["name"], "title": block.get("title", block["name"]),
            "size": off, "fields": fields}


def load() -> dict:
    abi = tomllib.loads(ABI.read_text(encoding="utf-8"))
    ctx = tomllib.loads(CTX.read_text(encoding="utf-8"))
    meta = abi["meta"]
    exports = sorted(abi["export"], key=lambda e: e["index"])
    for i, e in enumerate(exports):
        if e["index"] != i:
            raise AbiError(f"export indices must be dense from 0, got {e['index']} at {i}")
    if exports[0]["name"] != "INIT" or exports[1]["name"] != "FINI":
        raise AbiError("entries 0/1 are reserved for libman INIT/FINI")
    if abi["exports"]["reserved_from"] != len(exports):
        raise AbiError("reserved_from must follow the last export")
    consts = {}
    for sec in CONST_SECTIONS:
        values = abi[sec]
        if sec not in ("limits", "cap", "cfgf", "avail", "flag", "src_flag"):
            nums = list(values.values())
            if len(nums) != len(set(nums)):
                raise AbiError(f"[{sec}] has duplicate values")
        consts[sec] = values
    blocks = [layout(b) for b in abi["block"]]
    ctx_blocks = [layout(b) for b in ctx["block"]]
    by = {b["name"]: b for b in blocks}
    if by["EVT"]["size"] != abi["limits"]["EVENT_SIZE"]:
        raise AbiError("event block must be 8 bytes")
    stats_tail = by["STATS"]["size"] - 4
    ctxb = ctx_blocks[0]
    sf = next(f for f in ctxb["fields"] if f["name"] == "stats")
    if sf["size"] != stats_tail:
        raise AbiError(f"ctx.stats must be {stats_tail} bytes (GET_STATS size - 4), is {sf['size']}")
    for b in (by["CFG"], by["INFO"], by["STATS"]):
        if [f["name"] for f in b["fields"][:2]] != ["abi_version", "size"]:
            raise AbiError(f"{b['name']} must start with abi_version, size")
    cfgf = {f["name"]: f for f in by["CFG"]["fields"]}
    ctxf = {f["name"]: f for f in ctxb["fields"]}
    copies = []
    for c in ctx.get("copy", []):
        a, z, x = c["run"]
        length = cfgf[z]["offset"] + cfgf[z]["size"] - cfgf[a]["offset"]
        cend = ctxf[x]["offset"] + length
        names = [f["name"] for f in ctxb["fields"] if ctxf[x]["offset"] <= f["offset"] < cend]
        if not names or ctxf[names[-1]]["offset"] + ctxf[names[-1]]["size"] != cend:
            raise AbiError(f"copy run {a}..{z} -> {x} does not end on a ctx field boundary")
        if cend > 256 or cfgf[a]["offset"] > 255:
            raise AbiError(f"copy run {a}..{z} -> {x} must stay inside the first 256 bytes")
        copies.append({"cfg": cfgf[a]["offset"], "ctx": ctxf[x]["offset"], "len": length,
                       "name": f"{a}..{z}"})
    return {"meta": meta, "exports": exports, "reserved": abi["exports"],
            "consts": consts, "blocks": blocks, "ctx_meta": ctx["meta"],
            "ctx": ctxb, "copies": copies}


def hexv(v: int) -> str:
    return f"0x{v:02X}" if v < 0x100 else f"0x{v:04X}"


def gen_inc(d: dict) -> str:
    p = d["meta"]["prefix"]
    major, minor = d["meta"]["abi_major"], d["meta"]["abi_minor"]
    o = [
        "; UNETGAME.INC -- UNET-GAME ABI v%d.%d for sjasmplus." % (major, minor),
        "; GENERATED by tools/gen_abi.py from abi/unetgame_abi.toml -- do not edit.",
        "; Normative description: docs/unet-game-abi.md, register table: docs/ABI-TABLE.md.",
        "",
        "\tIFNDEF\t_UNETGAME_INC",
        "\tDEFINE\t_UNETGAME_INC",
        "",
        f"{p}ABI_MAJOR\tEQU\t{major}",
        f"{p}ABI_MINOR\tEQU\t{minor}",
        f"{p}ABI_VERSION\tEQU\t0x{(major << 8) | minor:04X}",
        f"{p}IMAGE_MAX_BODY\tEQU\t0x{d['meta']['image_max_body']:04X}",
        f"{p}IMAGE_MAX_TOTAL\tEQU\t{d['meta']['image_max_total']}",
        "",
        "; Export indices. Jump address = image_base + 0x20 + 3*index",
        "; (image_base = address of the L1 header, GET_INFO.image_base).",
    ]
    for e in d["exports"]:
        o.append(f"{p}{e['name']}\tEQU\t{e['index']}\t; in: {e['regs_in']}")
        o.append(f"{p}{e['name']}_OFS\tEQU\t0x{0x20 + 3 * e['index']:02X}\t; out: {e['regs_out']}")
    o.append(f"{p}EXPORT_COUNT\tEQU\t{d['reserved']['reserved_to'] + 1}")
    o.append("")
    for sec, values in d["consts"].items():
        o.append(f"; [{sec}]")
        for k, v in values.items():
            name = f"{p}{sec.upper()}_{k}" if sec != "limits" else f"{p}{k}"
            o.append(f"{name}\tEQU\t{hexv(v)}")
        o.append("")
    for b in d["blocks"]:
        o.append(f"; {b['title']} -- {b['size']} bytes")
        for f in b["fields"]:
            note = f"\t; {f['type']} {f['note']}".rstrip()
            o.append(f"{p}{b['name']}_{f['name'].upper()}\tEQU\t{f['offset']}{note}")
        o.append(f"{p}{b['name']}_BYTES\tEQU\t{b['size']}")
        o.append("")
    o.append("\tENDIF")
    return "\n".join(o) + "\n"


def gen_ctx(d: dict) -> str:
    b = d["ctx"]
    o = [
        "; unetg_ctx.inc -- internal context layout (NOT public ABI).",
        "; GENERATED by tools/gen_abi.py from abi/ctx.toml -- do not edit.",
        "",
        "\tIFNDEF\t_UNETG_CTX_INC",
        "\tDEFINE\t_UNETG_CTX_INC",
        "",
        f"UCTX_VERSION\tEQU\t0x{d['ctx_meta']['ctx_version']:04X}",
        f"UCTX_MAX_SLOTS\tEQU\t{d['ctx_meta']['max_slots']}",
    ]
    for f in b["fields"]:
        o.append(f"UCTX_{f['name'].upper()}\tEQU\t{f['offset']}\t; {f['type']} {f['note']}".rstrip())
    o.append(f"UCTX_BYTES\tEQU\t{b['size']}")
    o += ["", "; IY-relative offsets: the core keeps IY = context + 128, so fields",
          "; inside the first 256 bytes are reached as (IY+CX_<FIELD>).",
          "CTX_BIAS\tEQU\t128"]
    for f in b["fields"]:
        if f["offset"] + f["size"] <= 256:
            o.append(f"CX_{f['name'].upper()}\tEQU\t{f['offset'] - 128}")
    o += ["", "; INIT_CONFIG -> context copy runs: DB cfg_offset, ctx_offset, length"]
    o.append(f"CFG_COPY_COUNT\tEQU\t{len(d['copies'])}")
    o.append("\tMACRO\tCFG_COPY_TABLE")
    for c in d["copies"]:
        o.append(f"\tDB\t{c['cfg']}, {c['ctx']}, {c['len']}\t; {c['name']}")
    o.append("\tENDM")
    o += ["", "\tENDIF"]
    return "\n".join(o) + "\n"


def gen_jt(d: dict) -> str:
    o = ["; unetg_jt.inc -- libman/L1 jump table (image +0x20, 3 bytes per entry).",
         "; GENERATED by tools/gen_abi.py from abi/unetgame_abi.toml -- do not edit.",
         "; Every core defines EXP_<NAME> for each export and EXP_RESERVED."]
    for e in d["exports"]:
        o.append(f"\tJP\tEXP_{e['name']}\t\t; {e['index']}")
    r = d["reserved"]
    for i in range(r["reserved_from"], r["reserved_to"] + 1):
        o.append(f"\tJP\tEXP_RESERVED\t\t; {i}")
    return "\n".join(o) + "\n"


def gen_version() -> str:
    text = VERSION.read_text(encoding="ascii").strip()
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", text)
    if not m:
        raise AbiError("VERSION must be major.minor.revision")
    major, minor, rev = (int(x) for x in m.groups())
    return "\n".join([
        "; unetg_version.inc -- GENERATED by tools/gen_abi.py from VERSION -- do not edit.",
        "\tIFNDEF\t_UNETG_VERSION_INC",
        "\tDEFINE\t_UNETG_VERSION_INC",
        f"UNETG_IMAGE_VERSION\tEQU\t0x{(major << 8) | minor:04X}\t; {text}",
        f"UNETG_IMAGE_REVISION\tEQU\t{rev}",
        "\tENDIF", ""])


def gen_json(d: dict) -> str:
    out = {
        "abi_version": (d["meta"]["abi_major"] << 8) | d["meta"]["abi_minor"],
        "image_max_body": d["meta"]["image_max_body"],
        "image_max_total": d["meta"]["image_max_total"],
        "exports": {e["name"]: e["index"] for e in d["exports"]},
        "export_count": d["reserved"]["reserved_to"] + 1,
        "consts": d["consts"],
        "blocks": {b["name"]: {"size": b["size"], "fields": {f["name"]: {k: f[k] for k in ("offset", "size", "count", "elem", "type")} for f in b["fields"]}} for b in d["blocks"]},
        "ctx": {"version": d["ctx_meta"]["ctx_version"], "size": d["ctx"]["size"],
                "fields": {f["name"]: {k: f[k] for k in ("offset", "size", "count", "elem", "type")} for f in d["ctx"]["fields"]}},
    }
    return json.dumps(out, indent=1, sort_keys=False) + "\n"


def gen_md(d: dict) -> str:
    major, minor = d["meta"]["abi_major"], d["meta"]["abi_minor"]
    o = [f"# Таблица ABI UNET-GAME v{major}.{minor}", "",
         "Файл сгенерирован `tools/gen_abi.py` из `abi/unetgame_abi.toml`; не редактировать.",
         "Нормативный текст — [unet-game-abi.md](unet-game-abi.md).", "",
         "## Экспорты", "",
         "Адрес входа = `image_base + 0x20 + 3 × N`, где `image_base` — адрес заголовка L1.",
         "Через `l_call` гарантированно передаются только A, DE, IX, IY; дополнительные",
         "выходы (HL, байт флагов) дублируются в контексте.", "",
         "| N | Экспорт | Вход | Выход |", "|---:|---|---|---|"]
    for e in d["exports"]:
        o.append(f"| {e['index']} | `{e['name']}` | {e['regs_in']} | {e['regs_out']} |")
    r = d["reserved"]
    o.append(f"| {r['reserved_from']}–{r['reserved_to']} | резерв | — | A = STATE |")
    o += ["", "## Константы", ""]
    for sec, values in d["consts"].items():
        o.append(f"**{sec}:** " + ", ".join(f"`{k}`={hexv(v)}" for k, v in values.items()))
        o.append("")
    for b in d["blocks"]:
        o += [f"## {b['title']} ({b['size']} байт)", "", "| Смещение | Поле | Тип | Примечание |", "|---:|---|---|---|"]
        for f in b["fields"]:
            o.append(f"| {f['offset']} | `{f['name']}` | {f['type']} | {f['note']} |")
        o.append("")
    o.append(f"Размер внутреннего контекста v{d['ctx_meta']['ctx_version']:#06x}: {d['ctx']['size']} байт (публикуется в GET_INFO.ctx_size).")
    return "\n".join(o) + "\n"


def outputs() -> dict[Path, str]:
    d = load()
    return {OUT_INC: gen_inc(d), OUT_CTX: gen_ctx(d), OUT_JT: gen_jt(d), OUT_VER: gen_version(),
            OUT_JSON: gen_json(d), OUT_MD: gen_md(d)}


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "gen"
    try:
        outs = outputs()
    except AbiError as exc:
        print(f"gen_abi: {exc}", file=sys.stderr)
        return 1
    if cmd == "gen":
        for path, text in outs.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                path.write_text(text, encoding="utf-8")
                print(f"wrote {path.relative_to(ROOT)}")
        return 0
    if cmd == "check":
        stale = [p for p, t in outs.items() if not p.exists() or p.read_text(encoding="utf-8") != t]
        for p in stale:
            print(f"stale: {p.relative_to(ROOT)} (run make gen)", file=sys.stderr)
        return 1 if stale else 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
