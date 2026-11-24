# UNET-GAME — repository instructions

Non-blocking Z80 network libraries for Sprinter games. Seven libman 1.3 L1
DLLs are built from ONE shared core: `GTCPESP`, `GUDPESP`, `GTCPRTL`,
`GUDPRTL`, `GTCP509B`, `GUDP509B` and the loopback `GLOOP`, plus the SDK
(loader, gateway, time adapters, example) and the host test stand.

## Authority

- `docs/unet-game-spec.md` (ТЗ) and `docs/unet-game-abi.md` (ABI v1) are
  normative. When code and these documents disagree, the documents win; change
  them only on explicit request from the user.
- `abi/unetgame_abi.toml` is the single source of every public number:
  export indices, statuses, sources, event types, block layouts (INIT_CONFIG,
  GET_INFO, GET_STATS, event, context). `tools/gen_abi.py` generates
  `include/UNETGAME.INC`, `include/unetg_ctx.inc`, `tools/harness/abi.json`
  and `docs/ABI-TABLE.md`. Never edit generated files; run `make gen`.
- The ABI is append-only after the M0 freeze (v1.0): never renumber or reuse
  a value, add a new field at the end of a block or take a reserved slot.
  The public include `UNETGAME.INC` uses the `UNETG_` prefix for every name.
- Language: this file and code comments are English; project documents,
  reports and the acceptance matrix are Russian.

## Layout

```
abi/        unetgame_abi.toml (source of truth)
include/    UNETGAME.INC, unetg_ctx.inc (generated), unetg_internal.inc
src/core/   ABI dispatch, config validation, scheduler, hwdrv (hw_state machine
            of every card), lock, fallback, slots, events, timers, lifecycle
src/core/eth/  frame, arp, csum, tcp, udp   (RTL + 3C509B)
src/core/esp/  AT byte parser, sequencer, TP_* of passive TCP / active UDP
src/core/loop/ loopback transport
src/hw/{esp,rtl,el3,loop}/  hardware access layer, one per card
src/dll/    seven 20-line entry files: DEFINEs + ORG + INCLUDE core/main.inc
sdk/        source-included SDK: loader/ugload.asm (over libman), gateway/
            ugate.inc + ugate.asm, time/ugtime.asm; example/netdemo.asm (the
            ТЗ §7 example, M stand), example/ugtest.asm (M4 libman tester)
third_party/libman/  git submodule (libman + sprinter-mkdll), never copied
tools/      build.sh, build_sdk.sh, size_report.py, gen_abi.py, check_names.py,
            measure/ (ugprobe.asm platform probe, parse_hw.py Ж reports),
            hw/ (Ж stand: hw.env.example, build_hw.sh, echo_hw.sh),
            harness/ (Node Z80 stand; appstand.js
            runs the SDK with interrupts, devices/ctc.js),
            mame/ (M stand: holub MAME build + card patch, ugstand.lua, run_m.py,
            net_feth.sh)
tests/      z/ (Node stand scenarios, node:test; z/sdk: ugz.asm + SDK tests),
            host/ (python unittest)
docs/       spec, ABI, ARCHITECTURE, BUILD, TESTING, MEASUREMENTS, acceptance/
```

Each DLL is selected by exactly one `UGB_HW_{ESP,RTL,EL3,LOOP}` and one
`UGB_TP_{TCP,UDP,ANY}` build define (`tools/mkentries.sh` writes the entry
files); `src/core/main.inc` asserts that. Build selectors never reuse a
`UNETG_*` name: sjasmplus `DEFINE` would textually replace the ABI constant
of the same name. Never fork the core per card: hardware differences live in
`src/hw/*` and behind `IFDEF UGB_HW_*` only where unavoidable.

## Commands

```sh
make gen          # regenerate UNETGAME.INC / ctx include / abi.json / ABI table
make all          # build the seven DLLs into build/ + build/ugz.bin (make sdk)
make sdk          # the Z application stand program (tests/z/sdk/ugz.asm)
make verify       # sprinter-mkdll verify --target 1.3 for every DLL
make size         # size report: image, reloc, sum, prefix, free bytes
make names        # delivery names: 8.3, unique, not UNET<tag>, defines match
make test-host    # python: ABI sources vs generated files, block layouts,
                  # relocated L1 == direct assembly at 4 bases, vendored SHA-256
make test-z       # Node Z80 stand: ABI vectors on all seven builds + hw scenarios
make profile-check # STEP profile of every build at STEP periods 2/10/20 ms: unit
                  # rules (500 units, min, 812, 1218) and no overrun in real
                  # time (up to 3000 us); the Ethernet builds again over
                  # streams in pieces of 1..88 bytes (tools/dev/profile_small.sh),
                  # the ESP builds in pieces of 16..64 at the fat budgets,
                  # GUDPESP's transparent mode, and three scenarios
make check        # everything above; run before every hand-off
make mame         # M stand: build holub/mame + Sprinter-WiFi card (once)
make test-m       # M stand: UGTEST + NETDEMO scenarios of all six card builds in MAME,
                  # plus GUDPESP --esp-fw 2 (not in check; Ethernet needs the
                  # feth pair, else M SKIP)
make hw-image     # Ж stand file set build/hw/ (+ UGHW.ZIP, .img) from tools/hw/hw.env
```

Single DLL by hand (what `tools/build.sh` does):

```sh
sprinter-mkdll build src/dll/gtcp509b.asm --format l1 --target 1.3 \
  --assembler sjasmplus -I include -I src --name "GTCP509B v0.1.0" \
  --version 0.1 --date YYYY-MM-DD --no-compress -o build/GTCP509B.DLL
sprinter-mkdll verify build/GTCP509B.DLL --target 1.3
sprinter-mkdll inspect build/GTCP509B.DLL
```

Tools: `sjasmplus` 1.22 and `sprinter-mkdll` in `/usr/local/bin`,
`z88dk-ticks` in `/Users/dmitry/dev/zx/sprinter/z88dk/bin`, `node`, `python3`.
Automated builds/tests are the agent's job: run `make check` yourself, do not
ask the user to run them. The M stand is automated too (`make test-m`, MAME
from https://github.com/holub/mame built in `../../../mame-holub`); never
touch the user's own MAME tree `../../../mame` -- its prebuilt binary
`../../../mame/mame` (the only one with `3c509b`) is run read-only by
`tools/mame/run_m.py` with our own cfg/nvram/diff directories. Ethernet
cards in MAME use pcap on the feth pair the user creates
(`sudo tools/mame/net_feth.sh`); never bind pcap to a real host adapter.
Ask the user only for real-Sprinter runs.
The DSS system disk is `$MAME_ASSETS/IMG/sp_hdd_sys.chd` unless
`MAME_HDD` names another (read-only, our own diff directory); since
2026-11-13 that shared image no longer boots DSS (the machine stays on
the BIOS screen, every run ends `(no report block)`): run the M stand
with `MAME_HDD=.../IMG/sp_hdd_sys_0726.chd` and never modify the images.

## Size limit (hard, checked on every build)

libman 1.3 loads at most 16 KiB. For every DLL:

- `code_size` (which INCLUDES the 32-byte L1 header) `+ reloc_size <= 16384`;
- the L1 prefix size (header field at +02h) `<= 16384`;
- hence the code body after the header is at most **0x38C7 = 14535 bytes**
  (32 + 14535 + ceil(14535/8) = 16384).

Rules:

- Every `src/dll/*.asm` ends with
  `DISPLAY "free: ", /D, IMG_ORIGIN + 0x38C7 - $` and
  `ASSERT $ <= IMG_ORIGIN + 0x38C7` (pattern:
  `sprinter-rtl8019a/src/dll/unetrtl.asm:3054-3058`). Do not weaken it to
  `$ <= 0x4000` — that ignores the relocation bitmap
  (the mistake in `sprinter_wifi/network/src/dll/unetesp.asm:2840`).
- `make size` (`tools/size_report.py`) prints image size, relocation size,
  their sum and the prefix size separately for each DLL and fails above the
  limit. Report the numbers for every DLL whose size changed.
- No cold overlays, no WIN0 blobs, no trailing payload appended after the L1
  image (ТЗ §2). The existing UNET509B/UNETRTL overlay design is NOT a model.
- The image is BSS-free: code + constant tables only. All mutable state lives
  in the application context passed to INIT_CONFIG. The only mutable image
  bytes are `IMG_CTX_PTR` (2 bytes, GET_INFO.image_mutable_bytes); the stand
  flags any other write into the image.
  This is the main size reserve versus the old DLLs (3+ KB of in-image BSS).
- Biggest risk is `GTCP509B`, then `GTCPRTL`. If a build gets close to the
  limit: table-driven automata, shared helpers, trim optional statistics down
  to the mandatory list of ТЗ §7 — never an overlay.

## L1 / sprinter-mkdll rules

- Exactly one `ORG 0x0000`, and it is the first `ORG` in the assembled text
  (mkdll rewrites only that line and assembles twice, at 0x0020 and 0x0120).
- Every byte differing between the two passes must differ by exactly +1:
  absolute addresses, `DW label` tables, `HIGH label`, `label ± constant` are
  fine; `label*2`, `label>>1`, `label/…`, masks of addresses are build errors.
- `label - label` inside the image is pass-invariant and fine; never mix an
  image label with an absolute literal address (`label - 0xA000`): one side is
  relocated, the other is not. No pass-dependent `DS`/`IF`.
- `LOW label` is not relocated: it is correct only because libman places
  images on 256-byte boundaries — rely on that, never on a full address.
- Jump table at image +0x20, 3 bytes (`JP`) per entry: 0 = INIT, 1 = FINI
  (libman), game exports from 2 (order fixed by the TOML). Reserved slots jump
  to a stub returning `STATE`.
- The relocated base comes from `LD HL,IMG_ORIGIN` (the header is at
  `IMG_ORIGIN - 0x20`, 256-aligned); INIT refuses window 3 (`SCF`), otherwise
  `XOR A`. FINI must succeed after a failed or partial INIT and
  without INIT_CONFIG. libman forwards CF only for function 0: every game
  export returns its status in A.
- Via `l_call` only A, DE, IX, IY reach the DLL and only A, DE (and IX/IY)
  come back; extra outputs (HL, flags byte) are duplicated into the context.
- The L1 name field is at most 15 bytes (`"GTCP509B v0.1.0"` is exactly 15).
- libman 1.3 does not pass the file handle to INIT and uses DSS SETWIN; do not
  depend on 1.4-only behaviour.

## Core rules (non-negotiable, ТЗ §2–§5, ABI §1)

- The core never calls DSS, BIOS or libman: no `RST #08`, `RST #10`,
  `RST #30`, no call into system pages — not even in INIT_CONFIG or errors.
- No `EXX`, no `EX AF,AF'`; preserve IX and IY in every export; never change
  SP; no self-modifying code (the sibling `isa.asm` stores state in
  instruction operands — port its logic, not that idiom).
- No `EI` inside STEP_ISR (it runs with IFF=0; RETI belongs to the gateway).
  Main-loop exports restore the caller's IFF exactly: sample IFF2 with
  `LD A,I` twice (Z80 erratum), `DI`, … , `EI` only if it was set.
- No busy waits. Every hardware/connection/close wait is a resumable state
  advanced by STEP/STEP_ISR with a byte/visit cap and a `now_ms` deadline.
  "Drain until empty" loops are forbidden; every loop has a fixed maximum.
- Time is REAL time of the board (the user's decision of 2026-11-22: the
  consumer measures nothing, picks a budget, and the core keeps it).
  Every budget and every number of the ABI is a real microsecond in turbo;
  the core counts in UNITS (a microsecond of a 21 MHz Z80 without memory
  waits: `COST_*`, `PROF_*_US`, ctx.units) and converts once per STEP:
  units = us * 13 / 32 (`US_UNITS`, src/core/profile.inc; one unit =
  2.46 us: the worst measured ratio 2.40 plus the model-to-board 3 %).
  STEP_ISR converts nothing: its constants are `PROF_*_RT`, real us.
- Budget: STEP body ≤ the passed budget, which the application chooses
  between `min_useful_budget_us` (1047..1076; the ESP builds 1059) and `STEP_BODY_MAX_US`
  (3000 since 2026-11-22, 2000 before); STEP_ISR body ≤ `ISR_BODY_MAX_US` (370).  The ТЗ §5.1 targets
  (STEP_ISR ≤ 150, empty poll ≤ 100, BUS_BUSY ≤ 25, DI ≤ 200, quota sum ≤
  2000 per period) were met in model time only; in real time v1 has 161 /
  136 / 62 / 444 / 4700 and they are `todo` tests
  (tests/z/abi/perf_targets.test.js, tests/z/sdk), never weakened asserts.
  The user's target is 2..2.5 ms of network per 20 ms frame.
  Stack: ≤ 256 bytes for main exports, ≤ 96 bytes for STEP_ISR. Do not start
  an indivisible operation that does not fit together with its return cost.
- Only STEP advances protocol time (`now_ms` u32, wrap-safe comparisons,
  intervals < 2^31). STEP_ISR never touches the event queue or RX publication;
  it only moves hardware data and sets pending bits.
- The core never touches CTC ports (#10..#13) or PIO ports (#1C..#1F). Card
  interrupt masks (UART IER, RTL IMR, 3C509B mask) only while holding ISA.
  Route masking is the gateway's job; the core returns the `MASK_ROUTE` flag.
- ISA access only while the shared try-lock byte (`isa_lock_ptr`) is held:
  0 free, 1 net/main, 2 net/ISR, 3 sound, 4 controller. Test-and-set under one
  short DI; a non-zero byte, even our own ID, is BUS_BUSY. Honour the
  gateway's pre-acquired flag; release only after restoring mapping/shadows.
- Single-producer/single-consumer queues with one-byte indices; publish the
  index after the content with one write. Multi-byte cross-context values
  (UART ring head/tail, ISR stats) need an atomic protocol.
- All application regions are validated with 17-bit interval arithmetic
  before touching the card: overflow, overlap, crossing into 0xC000..0xFFFF,
  overlap with the DLL image or gateway/stack regions → BAD_CONFIG.

## Sprinter platform rules

Trust `Estex-DSS/Shared_Includes/constants/SP2000.inc`, the BIOS/FPGA sources
and the working drivers; `sprinter_ai_doc/manual/08_peripherals/03_isa_bus.md`
and `04_port_map.md` are wrong about ISA (no `#1FFD` step, swapped bits).

- ISA lives only in WIN3 (`0xC000..0xFFFF`), memory-mapped: card I/O port N
  is address `0xC000+N`. Open: `IN A,(#E2)` (save page) → `OUT (#1FFD),sh|#10`
  → `OUT (#E2),#D4|slot<<1` (I/O mode; `#D0` memory) → `OUT (#9FBD),0`.
  Close: `OUT (#1FFD),sh` → restore `#E2`. `#1FFD` and `#9FBD` are write-only:
  use the shadow bytes passed by the gateway and restore their exact values,
  never a constant `#01`/0. `#1FFD` bit 0 must stay 1 (otherwise ROM in WIN0).
  While `#1FFD` bit 4 is set, never map page `#A0` into WIN3 (soft reset).
- Keep the window open only under DI and only for one bounded portion;
  nothing an interrupt can reach (handlers, their stack, IM2 table, gateway)
  may live in `0xC000..0xFFFF`.
- 3C509B: 16-bit registers are accessed low byte then high byte back to back.
  RTL8019AS: 8-bit mode only, `DCR = 0x48`; ring TPSR 0x40, PSTART 0x46,
  PSTOP 0x60. Never touch the reset port +0x1F (clones hang the ISA cycle;
  reset softly with CR = STOP and a 2 ms wait state). One remote DMA per
  portion, programmed in full (CR, ISR.RDC, RBCR, RSAR, CR) and completed
  inside it; a portion never crosses PSTOP; write CR.TXP exactly once per
  frame (re-issuing it duplicated frames in the field). TL16C550C (ESP) at ISA I/O 0x3E8: MCR OUT1/OUT2 are the ESP
  module RESET/PGM lines — never use them as a PC-style "IRQ enable"; never
  reset the RX FIFO through FCR mid-session (it leaves auto-RTS deasserted,
  `sprinter_wifi/network/src/lib/esp_tcp_multi.asm:139-151`).
- Z84C15 PIO port B: data `#1E`, control `#1F`, written ONLY as
  `LD BC,#001F : OUT (C),A` (the short form is redirected by the FPGA). Mode 3
  control word with "mask follows" and its mask byte go out back to back under
  one DI from the gateway's shadow. PB0/PB1 = ISA IRQ of slot 1/2, PB6/PB7 =
  printer lines (BIOS: `#CF`, mask `#3F`, data `#C0`). Gateway only.
- ISA IRQ → PIO is not wired on known boards nor in MAME. v1 hardware
  profiles are POLL-only releases: the core serves AUTO through POLL (no IRQ
  probe, no fallback machine, CAP_PROBE not published), STEP_ISR is complete
  and tested (also nested inside STEP), GET_INFO reports no qualified route,
  the SDK writes neither PIO nor the IM2 route (MASK_ROUTE / an exhausted card
  quota set a software mask), and IRQ columns of the acceptance matrix say
  «маршрут не квалифицирован».
- CTC (#10..#13) belongs to the application (CH0 = mouse). The APP_COUNTER
  adapter may only READ the game's CTC2/CTC3 chain with the owner's
  permission (`CTC3 → CTC2 → CTC3`, one retry, phase modulo 17472).
- CPU is 7 MHz or 21 MHz (turbo, default on). ISA cycles are plain memory
  cycles without IOCHRDY handling: real costs come from `tools/measure`.

## Lessons that are now rules

- `TAKE` clobbers A, DE, HL: a value in DE (ring tail, pointer) is pushed
  around it.  `ET_IX`/`HWSM_IX`/`TP_IX` before `TAKE`, never between `TAKE`
  and its `RET C` (the macros end in `ADD IX,DE`: a refusal turned into a
  success built commands without budget in M4).
- ESP parse rounds never contain an action: a line end, `>` or a payload
  header byte leaves `ET_PEND`, performed by `ESP_PEND` as its own budget
  item before the next round. Heavy actions (CH_FAIL) are deferred to the
  sequencer (`ET_PFAIL`). Otherwise the round pays for bytes and refuses the
  action that needs them, every STEP.
- Passive TCP: the held count is lowered at the `+CIPRECVDATA:<n>,` header,
  not at the `OK`: the module's next `+IPD` notice comes after the answer and
  carries the new total (lowering at the OK zeroed it and stalled the read).
  An empty answer zeroes it: no immediate retry (ABI §5).
- SprinterESP: MCR is only ever 0x22 (AFE+RTS), 0x20 (explicit pause while
  the parser is 64 bytes behind) or 0 (stop); OUT1/OUT2 are the module
  RESET/PGM lines. The FIFO is reset once, before AFE is on. The RTS
  pause/resume decision and the write itself stay main-only, never
  STEP_ISR's (ESP 2 KiB/s stage).
- SprinterESP: a UART portion checks LSR once at its start (OE cannot
  reappear mid-drain, the FIFO only shrinks) and bails out before any
  ring/RTS arithmetic when there is no byte and no TX stream -- an idle
  portion must not cost the same as a working one. A full RX drain
  (ES_RX_MAX) and a TX write do not fit the same PROF_MAX_ITEM_US item
  together: when both are pending in one portion, RX is capped at
  ES_RX_JOINT_MAX, never the full depth; TX stays main-only. The pump
  reserve stays flat: refunding the unmoved RX share bought nothing on Z
  and made the MAME ESP-AT model time out a CIPSEND (GUDPESP UGTEST S).
- SprinterESP: STEP_ISR may run a second UART RX drain, but only from the
  leftover budget EXP_STEP_ISR already computes and would otherwise
  discard (sched.asm), stashed in the hwsm byte ES_ISRCAP (IY window,
  write-once by STEP_ISR, read-only by ISRP_POLL). ISRP_POLL never writes
  ES_RXMAX, ESF_RTSOFF/MCR or TX -- only the ring head, under the same
  "only one of {ISR at IFF=0, main under DI} runs at a time" guarantee
  that makes the write race-free without an atomic protocol. Every
  main-context read of the ring head goes through ER_HEAD under DI, even
  where it used to be safe to skip (HW_RUN's own tail) before ISRP_POLL
  could write it too. Its sizing is in real microseconds since
  2026-11-22 (STEP_ISR converts nothing): the whole STEP_ISR with n bytes
  takes 197.1 + 8.3 n us on the stand, the budget that moves n bytes is
  PROF_ISR_MIN_RT (161) + ISRP_ENTRY_RESERVE (85) + 8 n (341 for 12), and
  ISR_BODY_MAX_US (370) bounds the body at any budget.
- SprinterESP parser: a payload round's cost (COST_PAY) never chains on
  top of a line round's cost (COST_PARSE) -- the old single COST_LINE for
  every deferred line action hid this and other fixed costs; each kind of
  deferred action (end of line, header, prompt, overrun, a completed UDP
  datagram's publish) has its own measured item.
- Memory waits: in turbo every memory cycle (RAM and ISA) starts on the
  3.5 MHz grid and takes 3 wait T-states, an I/O cycle 2
  (tools/harness/dramwait.js, the rule of MAME's sprinter.cpp
  `do_mem_wait`): an opcode fetch costs 12 T, a register-only instruction
  is 3x slower, a memory read 2x.  The Z stand runs with them by default
  (`waits`, `UG_WAITS=0` switches them off) and so shows what M and the
  board show: the 35-T calibration loop is 78.0 T on Z, 78.4 on the board
  and in MAME; ISRTIME16 - BUSYTIME16 is 58.3 us on Z, 60.2 on the board.
  The board is not exactly MAME on single loops (UGPROBE: CALL/RET loop
  +3.6 %, `LD A,(HL)`/`DJNZ` -6 %, an ISA read 3 T cheaper than RAM, the
  ISA bracket 30.4 against 26.3 us): keep the 3 % in the unit factor and
  judge by whole paths.
- Tests pass real budgets; `US(n)` (tools/harness/stand.js) is the real
  budget that buys n units, for vectors that mean units.  The calibration
  tools of tools/dev account in units: they `require('./units.js')` first
  (the stand without waits, where a microsecond is a unit) and pass
  `US(budget)`; `profile_step.js --real`, pkt_steps.js, pkt_profile.js,
  real_costs.js, real_ratio.js, gw_costs.js and the tests run in real
  time.  A new cost is measured in units (cost rule below) and the
  whole STEP is then checked in real time (`make profile-check`).
- M stand program: turbo on through the SYS port (`OUT (#3C),3`); time from
  an IM1 frame-tick hook (vector at `#0039`), durations from CTC2 in timer
  mode chained into CTC3 and calibrated per frame. The Worms CTC counter
  chain does not count at 875 kHz in this MAME. Scenario state lives in
  WIN2 below `#C000`; at least `UNETG_SLOTS_MIN` (4) slots per direction.
  MAME loses most IM1 frame pulses (~9 us, under DI); the latched CTC1 tick
  of NETDEMO loses none. `CLOCK_RATE` is meaningful only on long runs.

- STEP_ISR may interrupt STEP between two portions (ABI §1) and writes no
  per-call field (`call_flags`, `work`, `units`, `flags_out`): its card
  sample is `ISR_PORTION` (lock.asm), not RUN_PORTION, and `ISRP_POLL` of
  the card layer works through IY only (no IX), answers in CF, clobbers A
  and HL and writes only its own hwsm flags; `isr_pending` bits are set by
  ISR_PORTION. Hwsm bytes it reads (`EX_IO`, RTL `EX_RFLAGS`, ESP
  `EX_ESFLAGS`) stay inside the IY window. The budget check comes before
  the first write (the counters).
- A card that is not running copies nothing: holds keyed on a TX pipeline
  state (`ETH_TX_COPYING`, `ESP_TX_COPYING`) check `hw_state == UHW_RUN`
  first, or SHUTDOWN in the middle of a frame never reaches OK.
- The SDK spreads STEPs (10 ms with 2 per period) and GET_INFO allows 20 ms:
  stream scenarios and `make profile-check` run at 2, 10 and 20 ms, and
  every build must hold the 8 KiB stream at each (a long STEP gap is where
  timer deadlines, retransmission and command deadlines meet a slow pipe).
- SDK (docs/SDK.md): no DSS call after `IM 2` (load before, free after IM1 is
  back); the SDK never writes PIO or CTC (the game programs its timer, the
  time adapter only reads CTC2/CTC3); ISR entries pre-acquire the lock (owner
  2) and run STEP_ISR on the INIT_CONFIG ISR stack, refusing a held bus
  before the core; main `UG_STEP` passes no pre-acquire (the core locks per
  portion); the budget period comes from the timer tick, not the frame pulse;
  `UG_BLOCK` is 256-aligned; `UG_OVH_*`, `UG_BUSY_PATH_US` and `UGT_READ_US`
  are measured on the application stand and checked by tests/z/sdk; libman
  is the submodule only, its `lib_table` layout pinned by `LIBMAN.VERSION`.

- IX-base macros (`TP_IX`, `HWSM_IX`, `ARP_IX`, `TXH_IX`, `TP_IX_HL`) preserve
  DE; helpers that clobber DE (`TX_BUF`, `RX_BUF`, `TX_*_PTR`, `IY_PTR`,
  `STAT_INC`) must be bracketed when DE/HL carry a value.
- The same macros end in `ADD IX,DE` and destroy CF: never put one between a
  routine that answers in CF (`DL_LEFT`, `TAKE`, ...) and the branch on it
  (this silently disabled TCP retransmission until M2).
- `EV_FLUSH` preserves IX (it can call `TP_RESET`); any routine that runs
  inside an export with an IX argument and calls into the transport must too.
- Charge the budget BEFORE the work (`TAKE`, `BUDGET_BYTES`, `EV_AFFORD`), with
  costs measured on the stand, never estimated, and measured under load:
  single-shot scenarios miss the heavy cases (ACK processing,
  retransmissions). A validated frame must not be dropped for lack of
  budget: keep the state and continue next STEP. Cost rule:
  `COST = max(real * 1.1, real + 15)` rounded up to 5, real = the worst
  item time of `tools/dev/profile_step.js --items` (`tools/dev/items_max.sh`)
  over STEP periods 2/10/20 ms, the budgets 500 units and min and both cards of
  the family; `make profile-check` (part of `check`) fails on any STEP over
  its budget and on any broken publication rule (below).
- `min_useful_budget_us` = `PROF_STEP_BASE_US` + `PROF_MAX_ITEM_US` +
  `PROF_MIN_RETURN_US`. Every cost is `ASSERT`ed against `PROF_MAX_ITEM_US`,
  and no item chains two costs: an entry that only dispatches (TP_STEP of
  TCP and ESP, the RX/TX dispatchers) takes nothing, its checks are base
  time, and every action takes exactly its own cost (an "idle step" that
  pays first eats the budget of the item it leads to -- a livelock at the
  minimum budget). `PROF_STEP_BASE_US` covers the "needed base reserve" of
  the build (profile_step.js `need` <= base at budgets 500 units and min); the
  minimum-budget tests and `tools/dev/sweep_loop.js` must keep moving data
  at the published minimum. Refusals cost base time: check the units of a
  known cost before the work that leads to its TAKE (dispatcher tables,
  TCP data segment, ESP parse round and pump).
- The needed base reserve and the item costs are checked beyond the stream:
  smaller pieces and foreign traffic make some items dearer (FINISH over
  RX slots) and a minimum STEP leaves room for one item only, so a
  publication refused after the card poll and the TX scan was refused in
  every STEP (`UCLK_EV_FIRST`: the next STEP flushes the events first;
  NEXT_EVENT publishes without a budget and hid it).
- An item's window in `budget_calls.js` runs from its TAKE / PARSE_BUDGET
  to the next call, refund or phase boundary (`BOUNDS`: also `HW_STEP` and
  `ESP_PARSE`, the dispatch points of the alternating card/transport
  order): the sizing before a round's PARSE_BUDGET and the tail after its
  refund are base time, invisible in the item's ratio. Never lower a fixed
  cost from the item window alone -- the needed base reserve and the STEP
  time (`over`) are the judges (a payload round costs ~75 us in its window
  but ~150 us in all; COST_PAY 90 overran the STEP). A change that passes
  Z can still break M: run `make test-m` for ESP after any pump/parser
  timing change.
- Budget tools account for refunds: a reserve given back (`UNITS_REFUND`)
  is no item (tools/dev/budget_calls.js, shared by profile_step.js and
  overrun.js); a TAKE reached by JP from a dispatch table is named by its
  state routine (`ETH_RX_STEP.copy`).
- The SDK quota sum of the default profile is
  `10 x (empty_poll + 10 + UG_OVH_ISR_US) + 2 x (min_useful + UG_OVH_STEP_US)
  + 100` <= 2000 (ТЗ §5.1): one microsecond of the STEP_ISR or gateway ISR
  path is worth ten of the STEP; published constants are measured + margin
  (core: worst + 5 rounded up to 5; gateway: tools/dev/gw_costs.js).
- Livelocks come from two items that each refuse the other's budget (timer
  recomputation vs the transport step, TCP idle + template). Deadlines that
  only their owner polls are armed with `DL_ARM` (no timer-cache reset);
  a merged deadline re-armed while running goes through `DL_SET_MIN` (the
  cache becomes min(cache, new): early or exact, never late) or, when it
  only moves later, `DL_ARM`; `DL_SET` (full invalidation) is for changes
  of the deadline set. A full recomputation per partial ACK eats the STEP.
  While the transport owes a timer evaluation (`UTMR_TPDUE`) no new full
  recomputation starts. Check with `tools/dev/trace.js` under load.
- A TX slot is handed back (TX_DONE) only when no pipeline still reads it;
  a prepared TCP segment overtaken by an ACK is dropped (`TCP_REWIND`).
  `tools/dev/tcpcheck.js` compares every transmitted payload with the data.
- Stand scenarios run at the STEP period the configuration promises
  (`worst_poll_gap_us`, 2 ms by default); the peer retransmits with the
  RFC 6298 minimum RTO (1 s). Unmet ТЗ targets stay visible as `todo`
  tests (`tests/z/abi/perf_targets.test.js`), never as weakened asserts.
- Placing a new global label inside a routine cuts off its dotted locals.
- `RUN_PORTION` (lock.asm) takes the try-lock, maps, runs, unmaps and
  releases inside ONE DI section: the core never holds the ISA lock with
  interrupts enabled. `IMG_CTX_PTR` holds ctx + `CTX_BIAS` (the IY value).
- STEP_ISR decides source, state, budget (base + poll + return in one
  check) and BUS_BUSY before any write; it takes `hw_state == UHW_RUN` as
  "configured": SHUTDOWN moves `hw_state` off RUN before `state` leaves
  CONFIGURED.
- RTL8019AS: STEP_ISR reads only ISR (page 0). The main poll acknowledges
  PRX/RXE before it reads CURR, and `RF_MORE` keeps STEP_ISR answering WORK
  from a found frame until a poll sees the ring empty: without it the
  second of two waiting frames loses its notice (a STEP skips its own poll
  after an empty ISR sample).
- The IY window is ctx bytes 0..255. Fields reached only through `IY_PTR`
  (arrays like `tx_tag`) live past it, so hot bytes stay inside: hwsm
  `EX_RXS`/`EX_TXS`/`EX_TXKIND` (Ethernet) and the ESP `EX_*` are read as
  `(IY+d)`; an `ASSERT` guards each.
- Ethernet STEP order is `ETH_SCHED` (engine.asm): on odd STEPs the poll
  first (its own item), on even ones a poll reserve while the largest item
  still fits besides it; frames in progress (bounded, stop at the frame
  end), transport, TX start, poll, rest. The RX/TX pipelines dispatch by
  state tables (`RX_TAB`/`TX_TAB`: TAKE returns into the state routine,
  which starts with `RET C`), check the state's cost before the TAKE, and
  a stopped pipeline is not retried in the same STEP unless the poll
  reserve was refunded; the TX completion is checked the STEP after the
  start. A frame header is written as DATA portions (one remote DMA per
  portion: header and payload never share one); a TCP segment's ACK is its
  own item (`ERX_TCPACK`) after the payload/FIN commit.
- TCP reports CLOSED only after its last segment (the ACK of the peer's
  FIN) has left the TX pipeline: a game calls SHUTDOWN on CLOSED, and a
  card stopped under that frame leaves the host in LAST_ACK, dropping the
  next SYN on the same 4-tuple (found in MAME over pcap).
- MAME Ethernet runs are deterministic (same ISS from `now_ms`, same
  ports); `run_m.py` gives every run its own local port, otherwise a SYN
  meets the host's previous connection (TIME_WAIT after P, ESTABLISHED
  after D: v1 sends no RST) and the OPEN times out.
- The vendored Z80 core applies DI one instruction late (`do_delayed_di`):
  stand code that injects interrupts must skip that state, as a real Z80
  takes none after DI.

- STEP limit 3000 us (2026-11-22; ABI `STEP_BODY_MAX_US`, 1218 units).
  Every gate runs at 1218 units and at 3000 us real too; NETDEMO
  profile `R` = 1 STEP of 3000 us + one poll per period (run_m.py
  LAT_PROFILE, build_hw.sh).  NETDEMO `F` (UDP builds) is Headball's
  flow at R's profile (ESP: two polls) against `echo_server.py --game`,
  which sends a state every 100 ms by the host clock: run_m.py throttles
  MAME for F on ESP too (unthrottled, 10 emulated s took 5 real and 11
  states came).  Its state handler sits in front of the SDK on ESP and
  behind it on Ethernet (`FL_STATE_CODE`): the page-aligned tables of
  ugtime.asm decide which build crosses a page.
  A MAME run is deterministic, so a flow meets the STEPs at one phase
  only: GUDPRTL F passed on M (248 of 251) and failed on the board (225);
  the first input shifted by 18..34 ms gave 221..225 on M too.  F now
  sweeps the phase itself (every 12th input interval 2 ms longer).  The
  cause was a stale flag: `RF_TXPRI` ("TX had the front last STEP, RX's
  turn") was cleared only on the busy-RX path of `ETH_FIRST`, so a STEP
  with RX idle kept it and the next state, STEPs later, took the front
  from an input committed before it (TX_DONE three STEPs, the next input
  skipped).  A "last STEP" flag is cleared on every path of the STEP.
  Z did not show it with game_load.js (offers right before the STEP); the
  application stand does (`tools/dev/sdk_flow.js`: the gateway, ticks,
  offers at any phase; tests/z/sdk), and a per-STEP ring of TXS / RXS /
  units in NETDEMO (temporary) found the STEP in MAME.
- `IFUSED` only around a routine whose callers come before it in the
  text: `IFUSED send_one` (the latency scenarios call it only from
  further down) assembled a `CALL l_call` of libman 256 bytes off, with
  a symbol table identical to the good build's and no error.  A plain
  `IF SCEN != 'F'` fixed it.  Compare the old scenarios' binaries byte
  for byte after any NETDEMO / UGTEST edit.
- Further passes (GUDP509B only, `UGB_CONT`, profile.inc, eth/engine.asm
  `ETH_SCHED`): with `PROF_CONT_MIN_US` (768) units left, up to 4 passes
  of poll / frames / transport / TX per STEP, each `COST_PASS` taken only
  when it fits together with `COST_TX_WAIT`; an ETX_WAIT transmitter is
  checked before the pass polls; the loop sets `PROF_CONT_DEC_US` aside.
  At 2000 us the passes' share cost the short receive a whole STEP (echo
  16 B 58 -> 76 ms): hence the threshold.  On GUDPRTL neither the passes
  nor the short path paid off (a remote-DMA set-up per portion): it stays
  byte-identical.
- `UDP_RX_MID` (GUDP509B, eth/udp.asm): a 23..96-byte datagram whose
  headers lie in scratch is one item (COST_UDP_RX_MID + 2 per byte +
  COST_UDP_RX_MIDP per extra RX portion): checks (`UDP_RX_CHK`, shared
  with the fast path), slot, 22 bytes from scratch, the rest by
  `RXP_COPY` portions with the sum, then `ETH_RX_VERDICT`.  The fast
  path's TAKE comes first and the checks refund it: checks before a
  TAKE are base time (the header item's ratio fell to 0.96).
- Transparent UDP of GUDPESP (`esp_fw` = 2, `UGB_XMODE`, esp/esp_x.asm):
  records of a 2-byte header (tools/harness/net/xrec.js) through
  `AT+CIPMODE=1`.  Its hwsm deadline is `ES_XDL`: `HS_DL` aliases
  `ES_RT` / `ES_TXN` on ESP (a shared "generic" deadline silently
  clobbered the TX stream).  `ESP_LEAN` is off in data mode (its
  reserves are sized for AT lines).  "+++" has no answer: its command
  deadline is the pause behind it (ESP_TIMEOUT).  The module (MAME's
  esp8266_at, very likely ESP-AT) cuts a packet only after 20 ms of UART
  silence: a 22-byte record takes two STEPs at one STEP a frame (one TX
  FIFO load per STEP, THRE = FIFO empty), inputs every 40 ms never left
  20 ms of silence and one packet grew to 1460 bytes (inputs 2.7 s
  late).  `ESP_XGATE` holds a record (`ET_XHOLD`) when the packet being
  gathered is older than `ESP_XAGE_MS`, until `ESP_XCUT_MS` of silence
  after `ES_XLAST` (stamped by the pumps at every TX write); the hold is
  decided inside ESP_XSEND's item and released by `ESP_XWAIT` -- a
  refusal before the TAKE was base time on every visit (need 334).
  The held STEP has an idle pump and no TX slack: GUDPESP's fat STEP
  sets 85 units aside (`PROF_FAT_DEC_US`, 65 elsewhere).
- UART FIFO trigger 14 overruns in MAME (auto-RTS only at the 16th
  character, the module sends one more): ESP game profiles use trigger
  8 with two byte-moving polls per period.  A slack in one item's
  reserve can hide base time: a structural change that removes the
  slack (a held record: idle pump) shows the real base.

## Ж stand (real Sprinter)

- The Ж programs are UGTEST/NETDEMO built with `-DUG_HW=1` plus
  `tools/measure/ugprobe.asm`; everything Ж-only stays under `IF UG_HW` /
  inside `sdk/example/ughw.inc`, so the M-stand programs and their reports
  are unchanged (`make test-m` never sets `UG_HW`). Shared stand-program
  code (frame hook, CTC durations, deadlines, report) lives in
  `sdk/example/ugbase.inc`. Check every Ж change on M with
  `run_m.py --hw` / `--probe` (the saved file must equal the report).
- Ж results enter the repository only through
  `tools/measure/parse_hw.py` into `docs/evidence/hw/`; the acceptance
  matrix Ж column is filled only from those `summary.json` files, never
  from M numbers. Until then every Ж cell says «не проверено».
- `tools/hw/hw.env` holds the user's LAN addresses: never commit it (it is
  git-ignored; `hw.env.example` is the template).
- A stand program's own ISA accesses (NETUP's UART) use `UG_ISA_SLOT` /
  `UG_IO_BASE` from mkcfg.js (through the `isa_page` byte), never a
  literal slot 1 / 0x3E8.
- ISA slots are 0 and 1 (`#E2 = #D4 | slot << 1`), never 1 and 2: the
  first Ж runs (3C509B) all died with INIT_CONFIG BAD_CONFIG on
  `HW_SLOT_EL3=2` from our own template, and the probe "passed" on page
  `#D8`. `build_hw.sh` and `mkcfg.js` reject other values; every Ж
  program runs `hw_slot` (ughw.inc) before its first ISA access and
  INIT_CONFIG, prints `SLOT c mm u` and uses the slot that answers;
  UGPROBE fails (`FAIL S`) when none does. A probe section that cannot
  tell "measured the card" from "measured nothing" is not a pass.
- A card wait must guarantee real time, not "now_ms + n": the
  application's now_ms moves in ticks of any length (UGTEST: 20 ms frames,
  NETDEMO: 2 ms CTC), so a single DL_ARM(2) is due at the next tick edge,
  microseconds later. The second Ж series of the 3C509B failed so (early
  ID EEPROM reads, the card never activated; Z and M answer EEPROM reads
  at once). Card waits are two-stage (el3.asm EL3_WAIT1_MS, then
  EL3_WAIT_MS after the first observed tick: >= one tick and >= 4 ms);
  the 3C509B bring-up selects window 0 itself. The EL3 model is strict
  about both (eepromBusyMs, resetBusyMs) and `ethStand` `clockMs` gives
  STEP a coarse now_ms: keep such hazards modelled.
- Never reset a card that answers. The 3C509B ID-port global reset (C0)
  switches the transceiver off and on: the link drops and the switch
  forwards nothing for 2..6 s. With a reset in every INIT_CONFIG each Ж
  run lost its first 3..5 ARP requests and one OPEN timed out (fourth
  series, NETDEMO GUDP509B W). Bring-up attaches as UNET509B DISCOVER
  does (ID sequence, tag, EEPROM word 7 = 0x6D50, MAC words, activation,
  window 0, manufacturer ID, init table); the reset is a recovery, once
  per bring-up, when word 7 or the manufacturer ID is wrong. The EL3
  model loses frames for `linkDownMs` after a reset (`lostRx`/`lostTx`);
  tests assert `resets === 0` on a card that answers. MAME's 3C509B
  answers the 4th ARP request with or without the reset (it did before
  the reset existed; RTL answers the 1st): `arp_requests` on M is no
  evidence either way.
- SHUTDOWN leaves the 3C509B as the system driver leaves it: RX/TX off,
  mask 0, window 0. UNET509B's attach reads the manufacturer ID without
  selecting window 0; the table runner's `OP_END` selected window 1 for
  the stop table too, so the first system-stack command after every Ж
  series failed (found only by the fifth series' STATA3.TXT: `CARD 00 20`
  after, `00 00 50 6D ...` before). Each table now ends in its own
  window; the Z session test asserts the card state after SHUTDOWN. Model
  what the NEXT user of the hardware expects, not only our own restart.
- A stand program stops the card on every exit path: `fail` runs SHUTDOWN
  too (UGTEST did not: a failed run left RX/TX on in window 1, and the
  system driver's attach reads the manufacturer ID without selecting
  window 0). The status goes into the report (`SHUTDOWN xx`).
- What a series leaves to the system network stack is evidence, not a
  guess: UGPROBE prints `CARD` (read-only card registers) and `DSSENV`
  (the DSS NET* variables) before its first card access, and
  `UGPROBE <c> 1` at the end of every UGRUN*.BAT saves the same as
  `STATA<c>.TXT`; parse_hw.py prints the difference and keeps addresses
  out of `docs/evidence/hw` (`<set xxxx>` tags). A report line name is
  unique across programs (`ENV` is NETDEMO's gateway line; ugreport.py
  parses by name).
- A report must let a later reader tell the causes apart: the seventh
  3C509B series had 4 runs of 28 with 4..5 ARP requests (OPEN took 3..4 s
  of the 5 s timeout) and nothing to tell a bring-up that fell into the
  reset recovery from an ARP answer lost on the LAN. Ж programs print
  `BRING <ms> <byte>` at RUN (hw_bring: bring-up time and hwsm[43], the
  3C509B HS_PASS until the first frame; 01 = reset used); parse_hw.py
  lists every run with more than one ARP request. The eighth series
  answered it: byte 00 and the usual bring-up time in the slow runs too,
  so the card was fine and the answers were lost on the way from the
  stand host, which is on Wi-Fi (broadcast ARP requests reach a
  power-saving Wi-Fi client only at DTIM). Several ARP requests with
  `BRING .. 00` are the stand's network, not the core.
- The core's ephemeral port is `now_ms` at OPEN (tcp.asm / udp.asm) and v1
  sends no RST: a program whose now_ms starts at 0 reuses its port every
  run, and after a connection left open (scenario D) the host answers
  the next SYN from that port with no SYN-ACK (NETDEMO W after D failed
  so on Ж; on M run_m.py passes a port per run). Ж programs call
  `hw_lport` (DSS clock; line `LPORT`) when local_port is 0, and
  echo_hw.sh runs the echo server with `--idle-close 10`. The Ж echo
  ports are 7710/7712: 7000 belongs to macOS AirPlay.
- A Ж program shows the operator what is running: `hw_show` prints the
  report head at start (never between the first STEP and SHUTDOWN, never
  after IM 2); the soak prints a dot a minute and polls Esc once a second
  between frames (`KEYSTOP`). A silent 10-minute run was reported as a hang.
- Check an assembly by its exit code, not by grepping "error": sjasmplus
  prints "Pass 1 complete (0 errors)" (a JR out of range slipped through).
- NETDEMO's UG_HW build is tight against `UG_CODE_END` (0x9D00; the line
  `netdemo free:` of every assembly says how tight): ughw.inc assembles
  `hw_args` only when called (`IFUSED`) and only the build's own card
  test (`UG_CARD` from mkcfg.js; UGPROBE sets 0 = all three); `send_all`
  is `IFUSED`. sdk/time/ugtime.asm holds two `ALIGN 256` tables in the
  middle of the image: code added in front of them can cross a page and
  cost 256 bytes at once, so scenario-only routines (the latency
  scenario) live behind the SDK includes, right before `code_end`.
- Every budget check and stand limit comes from the ABI constants
  (`ABI.consts.limits`), never a literal 500 / 150: both stands had the
  old STEP limit hard-coded. `make profile-check` ran at 500, the
  minimum, 1000 and 2000 model us (since 2026-11-22: 500 units, the
  minimum and 812 units = 2000 us, plus the real-time runs): a larger budget reaches paths the small ones
  never do (the RX_READY published by the STEP that finished the frame
  cost 95 us against a reserve of 70; COST_EVENT is 110 on every card).
- Work that cannot succeed takes no budget: EV_FLUSH returns at once on a
  full event queue. With COST_EVENT at 110 a STEP paid for a publication
  whose EV_PUT failed, the second one was refused for budget and the STEP
  answered YIELD for as long as the application read nothing
  (tests/z/abi/m1_queues "full event queue"). Run the whole `make check`
  after a cost change, not only the tests of the card being worked on.
- A packet's latency under a quota is (STEPs per packet) x (time between
  STEPs), and its cost is mostly the per-STEP base, not the work:
  `tools/dev/pkt_steps.js` (STEPs and model time per packet at the
  minimum budget and 500), NETDEMO scenarios T / Q (`LATMS`, T at the
  program's UG_STEPS, Q at 2 STEPs per period = the SDK default quota;
  A / B / C with a STEP budget of 1000 / 1500 us: 2 x 1000, 2 x 1500,
  1 x 1000 per period -- tools/mame/run_m.py LAT_PROFILE and
  tools/hw/build_hw.sh hold the same table).  Judge a scheduling change
  by both.
- Short path (2026-11-22, `UGB_SHORT`, GUDP509B only; profile.inc,
  eth/engine.asm, eth/udp.asm): in a STEP with a budget of about 1800 us
  or more (`PROF_SHORT_MIN_US` units after the base) that starts with no
  frame in progress, a small frame's card portions are fused (BEGIN +
  header, payload <= `TX_FUSE_END` + END, poll + header + drop of a frame
  whole in scratch), a frame is dropped by the card in the portion that
  reads its last byte (no DISCARD / DISC_WAIT items: the poll checks CIP),
  and a small datagram is one software item each way (send <=
  `UDP_FAST_MAX` 64 bytes: sum + header; receive with the IPv4 packet whole
  in scratch, payload <= 22: `UDP_RX_FAST` verifies everything before it
  writes anything and leaves every doubt to the generic states, which
  count the drop).  Its items are taken only when they fit (`SHORT_TAKE`:
  no refusal flag, the plain item is the fallback) and are not bound by
  `PROF_MAX_ITEM_US`; the STEP sets `PROF_SHORT_DEC_US` aside for its
  decisions.  Result at 2000 us, one STEP per frame: a datagram of up to
  16 bytes is on the wire after 2 STEPs and its echo readable after 3
  (plain items: 3 and 5); larger packets and the bulk stream are a little
  slower (base 210 instead of 190).  The other three Ethernet builds are
  the plain code, byte for byte: measured with honest accounting the
  short path gains nothing there within 2000 us (RTL8019AS: a remote DMA
  set-up per portion, no header in the poll's portion; TCP: the cost is in
  the transport items).
- GUDPRTL game flow (2026-11-23, `UGB_TXFIRST` / `UGB_BYTECOST` /
  `UGB_NODW`; profile.inc, eth/engine.asm `ETH_FIRST`, `RX_BYTECOST`,
  `TX_BYTECOST`, rtl8019.asm `HS_BEHIND`).  Headball's flow lost inputs
  on GUDPRTL not to the STEP limit but to order and over-reserved
  items: an input that met a state waited a STEP behind the RX frame in
  progress, and items reserved ~1.4x their real time (FINISH at TCP's
  175 for 64 real, an empty ERX_DISC_WAIT item, every DATA portion at
  56 bytes).  In a `USCH_BIG` STEP (units after the base >=
  `PROF_FIRST_MIN_US`, decided in EXP_STEP's `.base` -- on step 2 the
  units depend on whether RX is busy, no poll reserve: 140 more) TX
  goes before a short RX frame and card portions are priced by their
  bytes.  Either rule alone at 2000 / 2500 us gave TX the leftovers RX
  needed and the card ring overflowed (states lost instead of inputs
  skipped); and at 3000 us an overloaded flow did the same until TX
  first yields to a ring that holds more than the frame being read
  (`HS_BEHIND`, CURR vs the frame's next page at the poll).  Judge a
  priority change by an overloaded flow too (`hw_overflow` 0), not
  only by the flow it was made for.  Every flag test in a dispatcher
  is base time of every STEP: GUDPRTL's base 195 -> 205.
- A speed-up measured with under-reserved costs is no speed-up.  The fat
  items of the plain path (discard 100 for 56 real, FINISH 175 for 73,
  idle + summing + pull) silently paid for the dispatch between items and
  for part of the fixed path; every lean item that replaced one showed up
  as "needed base reserve" (140 -> 300 units at the largest budget before
  the costs were honest).  Before believing STEPs-per-packet numbers:
  `profile_step.js --piece` (tools/dev/profile_small.sh, part of
  profile-check) at the minimum, 500, 730 and 812 units must show need <=
  base and over 0, and the item table ratio >= 1 with the dispatch that
  follows an item inside its window.  What a decision costs belongs to
  the item it leads to (COST_UDP_FAST includes TP_STEP's choice); what a
  refused attempt costs is base time, so refusals check the units first.
- A cost of 256 or more does not fit `CP n`: sjasmplus truncates it
  silently and the "does it fit" check passes on anything (the fast
  receive item ran without budget: STEPs of 2200 us at a budget of 2000,
  found by the stand).  Units against a 16-bit cost: `UNITS_FIT`.
- 3C509B: RX_DISCARD takes time; the RX status is valid only after a
  status read has seen CIP clear -- CIP first, then the RX status (the
  other order is shorter and passed everything but the model's
  `cipReads`: the model keeps showing the dropped frame's status until
  CIP clears and throws on a FIFO read).  A model option that makes a
  race visible is worth a test on every build that touches the path.
- ESP (TCP): the sequencer takes a completed command's result before a
  failure line that came after it -- the stream order is the order of
  events.  A CIPRECVDATA answer right before "0,CLOSED" (a peer that
  answers and closes at once) lost the peer's last data when one parse
  turn brought both lines: M scenario P failed in half of the runs after
  an unrelated timing change, 54 of 192 phases on Z
  (tools/dev/esp_close_race.js, tests/z/hw/esp).  A flaky M scenario is a
  core race until proven otherwise: reproduce it on Z with a phase sweep.
- `make` 3.81 (macOS) has no `.SHELLFLAGS`: a recipe line `check | tail
  -1` returns tail's status.  Until 2026-11-22 every piped line of
  profile-check could not fail; with `set -o pipefail` (Makefile `PF`)
  the broadcast scenario turned out to need a base of 195 (GUDPRTL) and
  211 (GTCP509B) against 190 / 200, and small pieces 210 on GTCP509B
  (bases now 195 and 212).  A gate that prints FAIL and exits 0 is no
  gate: check the exit status of a new gate with a deliberate failure.
- A base is not rounded up "to be safe": GTCP509B at 215 instead of 212
  took one more STEP per small packet at 2000 us (TX_DONE of 64 bytes in
  the game profile 169 ms against 120; MAME 188 against 120), and five
  units on COST_FINISH did the same to both TCP builds.  After any change
  of a base or a shared cost: `pkt_steps.js` and `sdk_lat.js --polls 10`
  against the numbers of docs/MEASUREMENTS.md, not only the rules.
- Fat STEP of the SprinterESP builds (2026-11-22, `UGB_FAT`; profile.inc,
  sched.asm, esp/tp_esp.asm `ESP_FAT` / `TP_FAT`, esp/esp_parse.asm
  `ESP_LEAN`, hw/esp/uart.asm `HW_RUN_FAT` / `UART_PUMP_FAT`).  The plain
  ESP STEP is one UART portion and one parser / sequencer visit: sized for
  many small STEPs, it used half of a 2000 us budget and took 12 STEPs for
  a 16-byte packet (the game calls STEP once a frame).  A STEP of a
  running card with `PROF_FAT_MIN_US` units left (about 1800 us) runs the
  transport first, then rounds of pump -> parser -> sequencer while they
  bring something; the pump charges inside its portion for what it really
  moved (`COST_FPUMP*`), whole answers of the module are recognised in the
  ring in one pass (`ESP_LEAN`: "OK", "Recv n bytes", "SEND OK", the
  prompt, a whole UDP datagram, the TCP notice; a line or datagram seen in
  part is waited for, `ESF_LWAIT` / `ET_LNEED`), a CIPSEND command is one
  item and one portion of 17 bytes (first byte into the idle shift
  register).  Every fat item has its own entry or copy (`UART_PUMP_FAT` is
  a copy, not a mode): a mode test on the plain path is time of the plain
  STEP -- eight `BIT USCH_FAT` cost its base 7 units (GTCPESP 189 -> 196;
  base 200 now, minimum budget 1059 us).  Result at one 2000 us STEP per
  frame (Z, frames per 16-byte packet, send / send + echo): 12.0 / 14.1 ->
  6.1 / 9.9; with one byte-moving STEP_ISR(341) per frame 10.0 / 11.9 ->
  4.1 / 5.3; with two 3.2 / 4.3.  What is left is the UART itself: 9
  bytes per portion at trigger 8, about 0.5 ms of budget each, and the AT
  exchange of one small packet is ~100 bytes.
- Game profile on every card (2026-11-22): `poll_gap_us` is 25000 on the
  ESP builds too (2500 before; `auto_fallback_gap_us` /
  `max_service_gap_us` with it).  The UART FIFO stops the module by
  auto-RTS and a late poll loses nothing; the user confirmed that the RTS
  flow stop works on the board (our ESP builds themselves have not run
  there yet).  A poll every tick was ten polls a frame, about 2.1 ms by
  themselves.  The ESP game profile is one STEP of 2000 us and one
  byte-moving poll per period (`UGP_POLL_TICKS` 10, `UGP_ISR_BUDGET` 341;
  NETDEMO scenario `G`, `-DUG_ISR_BUDGET=341` on ESP): quota sum 2631 us,
  1.7 ms of network per frame (2.2 at most), GUDPESP 16 bytes 74 ms to
  TX_DONE and 119 to the echo; two polls (`UGP_POLL_TICKS` 5): 52 / 98 at
  1.9 ms (2.5 at most).  What a game gets on every card at one STEP per
  frame is the table of docs/MEASUREMENTS.md («Что получает игра при
  одном STEP за кадр»): `tools/dev/esp_frames.js` on all six builds,
  `tools/dev/oneway.js`, `tools/dev/sdk_lat.js --polls 10`.
- An optimisation is judged after its costs are honest, three times over
  in this stage: with under-reserved items the same code showed 4.1
  frames per packet and STEPs of 2400 us at a budget of 2000; the dispatch
  of every extra round / visit is real time (a round fee, `COST_FAT_ROUND`,
  and `PROF_FAT_DEC_US`); the TAKEs of one visit are one item for the
  tools (budget_calls.js `FOLD`: ESP_LEAN, UART_PUMP_FAT), calibrated by
  `tools/dev/items_fat.sh`.  And when two items must share a STEP to save
  a frame, 30 units decide: check the pair's sum against the units a STEP
  has (812 - 10 - base - share), not each item alone.
- MAME's NS16550 kept 15 characters in its transmit FIFO (a ring of 16
  with head == tail for "empty"): 16 written while the shift register was
  busy wrapped it to "empty", the characters were lost and THRE never came
  back.  That was the "lost CIPSEND" of GUDPESP UGTEST S in MAME, flaky
  with every timing change for months (the pump refund, the general
  "result before failure" fix, a 5-unit base change) and each time left
  as "not understood"; the fat STEP's 17-byte command hit it every time.
  Fixed in the M stand (tools/mame/patches/ns16550_txfifo.patch,
  build_holub.sh).  A flaky scenario that depends on nothing but timing
  can be the model: read the model's code path of the operation that
  stalled before changing the core around it.
- A test that waits for CLOSED reads its RX while it waits (ABI: an
  unread RX holds CLOSED back): the ESP "CLOSE during a CIPSEND" test read
  events only and passed while the echo came after the close; 5 units
  less per STEP and it hung -- a test artefact that looked like a livelock.
- DSS: the command line is IX at entry (load - #80: length, text), not
  APPINFO #47; `#0A` creates or truncates a file. A UG_HW program saves
  its report before the 0xA5 marker and waits out ugstand.lua's grace
  frames before DSS EXIT (`wait_tick` clobbers B: push it around DJNZ).

## Testing policy

- Every code iteration ends with `make check` green. ABI vectors in
  `tests/z/abi` run on all seven builds; hardware scenarios run per card.
- The Node stand (`tools/harness`, `node:test`) executes the real relocated
  DLLs (`stand.js` places them in WIN1/WIN2 at any 256-byte offset) and
  enforces: T-state budgets at 7/21 MHz, DI-section length, stack high-water
  (guard bytes), no RST/EXX/EX AF/SMC writes into the image (except the 4
  mutable bytes), no CTC/PIO port access from the image, exact restore of
  `#1FFD/#9FBD/#E2`, ISA access only with the window open and IFF=0.
- `tools/harness/z80core.js` is vendored (MIT, see THIRD_PARTY.md) and pinned
  by SHA-256; never edit it in place.
- The application stand (`tools/harness/appstand.js`, tests/z/sdk) runs the
  real SDK around a DLL with IM2 interrupts (CTC model, frame pulse, injected
  vectors, a sound owner holding the lock) and applies the Stand.call checks
  to every direct export call, plus DI sections, ISR paths, gateway costs
  and PIO writes.
- Calibration and debugging: `tools/dev/profile_step.js` (per-build STEP
  profile: items reserved vs real, needed base reserve, overruns, rates at
  DT 2/10/20, STEP_ISR paths, STEPs per segment; `--json`/`--base` deltas),
  `tools/dev/isr_profile.js` and `tools/dev/step_profile.js` (per-label time
  of the STEP_ISR paths and of an idle STEP), `tools/dev/audit.js` (budget audit),
  `tools/dev/overrun.js` (overruns, needed base reserve, per-item worst case,
  per-STEP profile), `tools/dev/trace.js` (per-STEP states and budget calls),
  `tools/dev/e2e.js` (end-to-end smoke), `tools/dev/sweep_loop.js` (GLOOP
  budget sweep), `tools/dev/portions.js` (card portion times),
  `tools/dev/di_find.js` (long DI sections), `tools/dev/throughput.js`,
  `tools/dev/tcpcheck.js`, `tools/dev/watch.js` (write watch on context fields),
  `tools/dev/esp_costs.js` (ESP layer routine costs), `tools/dev/sdk_rate.js`
  (throughput through the SDK gateway by STEPs per period),
  `tools/dev/gw_costs.js` (gateway path overheads, quota sum),
  `tools/dev/items_max.sh` (worst time per budget item over builds),
  `tools/dev/stream_stats.js` (stream with retransmissions and yields),
  `tools/dev/scenario_budget.js` (budget accounting over foreign broadcast
  traffic, SHUTDOWN in a send, a lone send; part of profile-check),
  `tools/dev/pkt_steps.js` (STEPs from TX_COMMIT to the wire, to TX_DONE
  and to the echo, by packet size and budget), `tools/dev/pkt_profile.js`
  (per-label time of one packet), `tools/dev/items_small.sh` and
  `tools/dev/profile_small.sh` (item costs and publication rules over
  streams in pieces of 1..64 bytes), `tools/dev/sdk_flow.js` (NETDEMO F
  through the SDK gateway on the application stand, swept over the input
  and state phases; `--trace` prints the budget calls of slow inputs),
  `tools/dev/sdk_lat.js` (latency and
  time per period through the SDK gateway), `tools/dev/esp_close_race.js`
  (GTCPESP: echo then close, phase sweep), `tools/dev/esp_frames.js`
  (frames per packet at one STEP per frame, with STEP_ISR polls, baud and
  FIFO trigger), `tools/dev/oneway.js` (one-way send / receive rates at
  one STEP per period), `tools/dev/game_load.js` (a real-time game's
  traffic on a UDP build: small inputs up and larger states down at once,
  what arrives and how late; `--phase in,st[,poll]` places the offer, the
  state and the poll inside the frame), `tools/dev/items_fat.sh` (the fat STEP's items:
  reserved against worst real time);
  `tools/dev/budget_calls.js` is the shared budget-call accounting. Keep debug scripts in `tools/dev/`, not in the session
  scratchpad.
- Results are kept separate per stand: Z (model), M (MAME), Ж (real
  Sprinter). A scenario that was not run is «не проверено», never «пройдено».
  Model passes do not prove hardware IRQ routing or real ISA timing.

## Reference sources (port logic, re-implement non-blocking)

The existing drivers block, call DSS and each has its own stack. Reuse
register sequences and protocol knowledge, never their control flow.

- libman / L1: the submodule `third_party/libman` (same as
  `/Users/dmitry/dev/zx/sprinter/sources/libman`): `README.md`
  (formats L0/L1/L2, lines 64-180), `libman/README.md` (API, 179-267),
  `src/sprinter_mkdll/format.py` and `assembler.py` (exact checks),
  `examples/libmantst/testdll_l1.asm` (minimal L1).
- L1 production skeleton and build script:
  `/Users/dmitry/dev/zx/sprinter/sprinter-rtl8019a/src/dll/unetrtl.asm`
  (rules 22-73, jump table 141-174, INIT/FINI 339-367, size assert 3054-3058),
  `sprinter-rtl8019a/tools/build.sh:59-158`.
- Existing UNET L1 binaries: `/Users/dmitry/dev/zx/sprinter/sources/unet_libs/unet_libs_core/dll/`
  (`sprinter-mkdll inspect` for size comparison).
- DLL test pattern with z88dk-ticks: `/Users/dmitry/dev/zx/sprinter/sources/libs/gfx320/Makefile`,
  `tools/run_z80_tests.sh`, `tools/prepare_runtime_image.py` (relocation).
- ISA window: `/Users/dmitry/dev/zx/sprinter/sprinter-rtl8019a/src/lib/isa.asm`
  (IFF2 sampling; uses SMC — do not copy the idiom).
- SprinterESP / TL16C550C / ESP-AT:
  `/Users/dmitry/dev/zx/sprinter/sprinter_wifi/network/src/lib/esplib.asm`
  (registers 15-71, UART_INIT 171-233, RTS pause 292-344, FIFO trigger 351-387,
  module reset 684-703), `src/lib/esp_tcp.asm` (+IPD header/len 2545-2665),
  `src/lib/esp_tcp_multi.asm:284-715` (CIPRECVMODE/CIPRECVDATA),
  `src/lib/tput_lib.asm:561-616` (AFE burst problems), `docs/UNETAPI.md:715-738`,
  `docs/UNETRTL-GAMES-FR.md` (earlier analysis of game needs),
  `sprinter_wifi/network/CLAUDE.md` (ESP-AT 2.2.1/2.2.2 differences, jesperl).
- RTL8019AS: `/Users/dmitry/dev/zx/sprinter/sprinter-rtl8019a/src/include/rtl8019.inc`,
  `src/lib/rtl8019.asm` (DMA_READ 1211-1312, INIT_NORMAL 1619-1678,
  SEND_FRAME_SG 1829-1974, RING_HAS_PACKET 2293-2387, RECOVER_OVERFLOW
  2423-2471, READ_PACKET 2484-2703), `sprinter_rtl8019_soft.md:369-516`,
  driver constraints in `sprinter-rtl8019a/CLAUDE.md` ("Driver / Stack
  Constraints", "ISA window discipline").
- 3C509B: `/Users/dmitry/dev/zx/sprinter/sprinter-3C509B/src/include/el3.inc`,
  `src/lib/el3.asm` (DISCOVER 63-127, ACTIVATE 133-172, ID_SEQUENCE 214-249),
  `el3_regs.asm` (CMD 51, WAIT_CIP 63-94, SELECT_WINDOW 227-252, INIT 293-424),
  `el3_fifo.asm` (SEND_FRAME 19-112, RX_PENDING 117-141, READ_FRAME 148-229),
  `el3_io.asm` (FIFO_READ 190-254; RX_COPY_SUM 364-482 uses EXX — rewrite),
  `specs.md:128-260`. Its GPL clean-room rule applies to us as well: never
  copy Linux/Nestor packet-driver code.
- Host stand models: `/Users/dmitry/dev/zx/sprinter/sprinter-rtl8019a/tools/exe-harness/`
  (`harness.js` MMU/ISA/IFF2, `rtl8019-model.js`, `net-builders.js`,
  `docs/HARNESS.md`), `/Users/dmitry/dev/zx/sprinter/sprinter-3C509B/tools/exe-harness/harness.js`
  (class `EtherLinkIII`, lines 406-1618).
- Platform: `/Users/dmitry/dev/zx/sprinter/Estex-DSS/Shared_Includes/constants/SP2000.inc`
  (cp866; windows 527-534, ISA 566-601, CTC 2113-2117, PIO 2125-2130),
  `/Users/dmitry/dev/zx/sprinter/sprinter_bios/src/bios/exp/EXP.asm:1040-1091`
  (PIO and `#1FFD` init), `/Users/dmitry/dev/zx/sprinter/sprinter_ai_doc/manual`
  (architecture overview), `/Users/dmitry/dev/zx/sprinter/Estex-DSS` (DSS,
  IM1 handler `DSS/DSS-MAIN.ASM:143-167`), `/Users/dmitry/dev/zx/sprinter/sprinter_bios`.
- Worms (first consumer): `https://github.com/witchcraft2001/worms`
  (`src/platform/ctcnow.inc` CTC phase read, `src/input.asm` PIO B / Sega,
  `src/video_boot.asm` silent CBL); local copy may exist under
  `/Users/dmitry/dev/zx/sprinter/sources/games/worms`.
- MAME: `/Users/dmitry/dev/zx/sprinter/mame` (`src/mame/sinclair/sprinter.cpp`:
  ISA IRQs are not connected to PIO), ESP emulator
  `/Users/dmitry/dev/zx/sprinter/mame_esp/jesperl`.

Treat sibling repositories as read-only references; this repository is the
source of truth for UNET-GAME.

## Style

sjasmplus only. Uppercase mnemonics, tabs, unique per-unit label prefixes
(exports are `EXP_<NAME>`, no `MODULE` around them), dotted local labels, `EQU` constants from the generated includes instead of literals,
English comments for hardware ordering, timing and invariants. Every public
routine documents inputs, outputs, clobbers, stack depth and worst-case cost.

## Commits and hygiene

- Short imperative subjects (`Add 3C509B RX chunk state`); mention milestone
  and verification in the body when useful.
- Never add `Co-Authored-By: Claude …` or any other AI attribution trailer.
- Do not commit `build/`, `distr/`, listings, captures with private traffic or
  credentials. Commit release DLLs only when a release is requested.
