; profile.inc -- per-card constants published by GET_INFO and enforced by
; INIT_CONFIG.  All timing values are design upper bounds for the turbo
; (21 MHz) profile; they are requirements for the prototype, not
; measurements, until docs/MEASUREMENTS.md says otherwise.

	IFDEF	UGB_HW_ESP
PROF_HW			EQU	UNETG_HW_ESP
; The 16-byte FIFO of the UART stops the module by itself (auto-RTS) and
; the module waits: a late poll loses nothing, it only delays the AT
; exchange.  The flow stop is confirmed on the board (the user,
; 2026-11-22), so the application may poll once per 20 ms period, as with
; the Ethernet cards (2500 / 5000 / 5000 before: a poll every 2 ms tick,
; ten per frame, about 2.1 ms of every frame by themselves).  What a
; rarer poll costs is frames per packet (docs/MEASUREMENTS.md).
PROF_POLL_GAP_US	EQU	25000
PROF_AUTO_GAP_US	EQU	25000
PROF_IRQ_DELIVERY_US	EQU	2000
PROF_MAX_SERVICE_US	EQU	25000	; relies on the RTS/CTS flow stop
PROF_CAPS_HW		EQU	UNETG_CAP_POLL | UNETG_CAP_AUTO | UNETG_CAP_FLOW_CONTROL_REQUIRED
PROF_HW_RING_MIN	EQU	UNETG_UART_RING_MIN
PROF_UART_PROFILES	EQU	0x01
PROF_IO_MASK		EQU	0x0007	; 16550 occupies 8 ports
PROF_POLL_EXTRA_US	EQU	0
PROF_DMA_EXTRA_US	EQU	0
	ENDIF
	IFDEF	UGB_HW_RTL
PROF_HW			EQU	UNETG_HW_RTL
; An Ethernet card keeps received frames by itself (RTL8019AS: a 6.6 KB
; ring, 3C509B: its RX FIFO): one poll per 20 ms period is enough for the
; traffic of a game, so the application may leave the timer ticks to
; itself and poll from STEP only (2026-11-22; 2500 before, a number taken
; from the UART profile).  25 ms = ten 2 ms ticks + the DI margin + a
; handler of the application.
PROF_POLL_GAP_US	EQU	25000
PROF_AUTO_GAP_US	EQU	25000
PROF_IRQ_DELIVERY_US	EQU	2000
PROF_MAX_SERVICE_US	EQU	25000
PROF_CAPS_HW		EQU	UNETG_CAP_POLL | UNETG_CAP_AUTO | UNETG_CAP_CHECKSUM_VERIFY
PROF_HW_RING_MIN	EQU	0
PROF_UART_PROFILES	EQU	0
PROF_IO_MASK		EQU	0x001F	; NE2000 block of 32 ports
PROF_POLL_EXTRA_US	EQU	40	; CURR on page 1 + 4-byte header by remote DMA
PROF_DMA_EXTRA_US	EQU	15	; remote DMA programmed for every portion (64-byte header: 231 us)
	ENDIF
	IFDEF	UGB_HW_EL3
PROF_HW			EQU	UNETG_HW_EL3
PROF_POLL_GAP_US	EQU	25000	; as the RTL8019AS above
PROF_AUTO_GAP_US	EQU	25000
PROF_IRQ_DELIVERY_US	EQU	2000
PROF_MAX_SERVICE_US	EQU	25000
PROF_CAPS_HW		EQU	UNETG_CAP_POLL | UNETG_CAP_AUTO | UNETG_CAP_CHECKSUM_VERIFY
PROF_HW_RING_MIN	EQU	0
PROF_UART_PROFILES	EQU	0
PROF_IO_MASK		EQU	0x000F	; 3C509B block of 16 ports
PROF_POLL_EXTRA_US	EQU	0
PROF_DMA_EXTRA_US	EQU	0
	ENDIF
	IFDEF	UGB_HW_LOOP
PROF_HW			EQU	UNETG_HW_LOOP
PROF_POLL_GAP_US	EQU	20000
PROF_AUTO_GAP_US	EQU	20000
PROF_IRQ_DELIVERY_US	EQU	0
PROF_MAX_SERVICE_US	EQU	20000
PROF_CAPS_HW		EQU	UNETG_CAP_POLL | UNETG_CAP_LOOPBACK
PROF_HW_RING_MIN	EQU	0
PROF_UART_PROFILES	EQU	0
PROF_IO_MASK		EQU	0
PROF_POLL_EXTRA_US	EQU	0
PROF_DMA_EXTRA_US	EQU	0
	ENDIF

	IFDEF	UGB_TP_TCP
PROF_TRANSPORTS		EQU	0x01
PROF_CAPS_TP		EQU	UNETG_CAP_TCP
PROF_CFGF_TP		EQU	0
PROF_MAX_PAYLOAD	EQU	UNETG_TCP_MSS
	ENDIF
	IFDEF	UGB_TP_UDP
PROF_TRANSPORTS		EQU	0x02
	IFDEF	UGB_HW_ESP
; GUDPESP: the transparent mode of the module (esp_fw = 2, esp/esp_x.asm)
	DEFINE	UGB_XMODE
; UDP records (UNETG_CFGF_UDP_RECORDS) are the transparent mode's own
; format: the flag is accepted with esp_fw = 2 only (config.asm)
PROF_CAPS_TP		EQU	UNETG_CAP_UDP | UNETG_CAP_ESP_TRANSPARENT | UNETG_CAP_UDP_RECORDS
PROF_CFGF_TP		EQU	UNETG_CFGF_UDP_RECORDS
	ELSE
; UDP records on the wire (UNETG_CFGF_UDP_RECORDS, core/rec.asm): the same
; datagram bytes from every card and mode
	DEFINE	UGB_RECORDS
PROF_CAPS_TP		EQU	UNETG_CAP_UDP | UNETG_CAP_UDP_RECORDS
PROF_CFGF_TP		EQU	UNETG_CFGF_UDP_RECORDS
	ENDIF
PROF_MAX_PAYLOAD	EQU	UNETG_UDP_MAX
	ENDIF
	IFDEF	UGB_TP_ANY
PROF_TRANSPORTS		EQU	0x03
PROF_CAPS_TP		EQU	UNETG_CAP_TCP | UNETG_CAP_UDP
PROF_CFGF_TP		EQU	0
PROF_MAX_PAYLOAD	EQU	UNETG_TCP_MSS	; UDP datagrams stay <= 512
	ENDIF

; Common design bounds (ТЗ §3, §5.1). Revised after the M0 measurements.
PROF_CPU_KHZ		EQU	21000
; Units and real time.  Every cost below and the budget counter are in
; UNITS: one unit is a microsecond of a 21 MHz Z80 WITHOUT memory waits
; (the Z stand without `waits`, where all costs were measured).  On the
; board every memory cycle in turbo waits for the 3.5 MHz memory grid
; (tools/harness/dramwait.js; UGPROBE CPU: 9.37 effective MHz of 21), and
; a STEP lasts 2.12..2.40 times its unit count on all six card builds
; (tools/dev/real_ratio.js), 3 % more on the board than in the model
; (ISRTIME16 - BUSYTIME16 of the eighth 3C509B series).  Budgets of the
; ABI are REAL microseconds: units = us * 13 / 32 (one unit = 2.46 us,
; time.asm US_UNITS), and every published number is units * 32 / 13
; rounded up (the PROF_*_RT constants).  PROF_*_US and COST_* stay units.
PROF_UNIT_MUL		EQU	13
PROF_UNIT_DIV		EQU	32
; PROF_STEP_BASE_US covers the "needed base reserve" of the build: the
; STEP time not bought by budget items (prologue, clock, timer cache,
; scheduler, dispatch, refused attempts, flush, deadlines) -- the largest
; over the 8 KiB stream at STEP periods of 2/10/20 ms and the budgets 500
; and min (tools/dev/profile_step.js; make profile-check fails above it).
; Stand: GTCPRTL 199, GTCP509B 190, GUDPRTL 178, GUDP509B 174, GTCPESP
; 189 (ESP 2 KiB/s stage, WP1: HW_RUN's joint RX/TX sizing), GUDPESP 172,
; GLOOP 57 us.  PROF_MIN_RETURN_US stays on top of it.
	IFDEF	UGB_HW_LOOP
PROF_STEP_BASE_US	EQU	140
	ELSE
	IFDEF	UGB_HW_ESP
	; 200 since the fat STEP (below): its one test in the scheduler and
	; the by-kind costs of the sequencer lengthen the plain path too
	; (stand: GTCPESP 196 at the minimum budget, 189 before)
PROF_STEP_BASE_US	EQU	200
	ELSE
	IFDEF	UGB_TP_TCP
	; +6 units since 2026-11-22: US_UNITS in the STEP prologue (stand:
	; GTCPRTL 204, GTCP509B 196 at the minimum budget)
	; Measured with streams in pieces of 1..64 bytes and foreign
	; broadcast traffic too (stand: 210 on either card with pieces of 23
	; bytes at the minimum budget, GTCP509B 211 under broadcast traffic
	; at a base of 210; it had 200 from the 8 KiB stream alone).  212 is
	; no round number on purpose: 215 costs a STEP per small packet at
	; 2000 us (TX_DONE of 64 bytes in the game profile 169 ms against 120).
	IFDEF	UGB_HW_RTL
PROF_STEP_BASE_US	EQU	210	; the RTL8019AS poll (140) leaves less to the transport
	ELSE
PROF_STEP_BASE_US	EQU	212
	ENDIF
	ELSE
	IFDEF	UGB_HW_EL3
	; GUDP509B, with the short path (below): its checks in the dispatch
	; and no fat discard items any more (stand: 202 at the minimum
	; budget with pieces of 22 bytes, 207 under broadcast traffic; 208
	; with the further passes' test, UGB_CONT)
PROF_STEP_BASE_US	EQU	210
	ELSE
	; GUDPRTL: 205 under foreign broadcast traffic (204.3, tools/dev/
	; scenario_budget.js; 190 until the check could fail, 195 until the
	; USCH_BIG decision, its tests in the dispatchers and the poll's
	; HS_BEHIND, 2026-11-23)
PROF_STEP_BASE_US	EQU	205
	ENDIF
	ENDIF
	ENDIF
	ENDIF
; Short path (UGB_SHORT; eth/engine.asm, eth/udp.asm): the card portions
; of a small frame fused and a small UDP datagram as one software item
; each way.  Its items are sized with nothing to spare and its decisions
; lengthen the fixed path, so it is on only in a STEP whose units, after
; the base, reach PROF_SHORT_MIN_US (a budget of about 1800 us) and that
; starts with no frame in progress; such a STEP sets PROF_SHORT_DEC_US
; more aside for the fixed path (stand: the needed base reserve with
; pieces of 1..64 bytes at 730 and 812 units reaches 266,
; tools/dev/profile_step.js --piece).
; Only GUDP509B has it.  Measured with the same accounting, it gains
; nothing within the 2000 us STEP elsewhere: the RTL8019AS pays a remote
; DMA set-up per portion and cannot read the header in the poll's portion
; (DI limit), so its fused items do not fit beside the share; a TCP
; segment's cost is in its transport items.  At 3000 us (2026-11-22) it
; was measured on GUDPRTL again: a real-time game's input 22.5 packets/s
; instead of 20 (tools/dev/game_load.js, two in flight), for a base of
; 225 instead of 198 (the minimum budget 1096 us instead of 1029): left
; off.
	IFDEF	UGB_HW_EL3
	IFDEF	UGB_TP_UDP
	DEFINE	UGB_SHORT
	DEFINE	UGB_SHORT_EL3
	DEFINE	UGB_FIT			; UNITS_FIT / SHORT_TAKE (time.asm)
PROF_SHORT_MIN_US	EQU	512
PROF_SHORT_DEC_US	EQU	65	; (60 before UDP records: need 273 / 275 with 23-byte datagrams at 812 units)
	ASSERT	LOW PROF_SHORT_MIN_US == 0
	ENDIF
	ENDIF
; Further passes of the Ethernet scheduler (UGB_CONT; eth/engine.asm
; ETH_SCHED): a STEP whose frames ended before its budget did runs the
; whole order again (poll, frames, transport, new TX) while a pipeline
; was or is busy and a pass fee plus the TX completion check still fit:
; the TX completion, the next frame and a second poll come in the same
; STEP instead of the next one.  GUDP509B only: measured on GUDPRTL too
; (a real-time game's input 20 packets/s with or without them, the base
; 195 -> 198), so that build stays the plain code.  On in
; a STEP whose units reach PROF_CONT_MIN_US when the scheduler starts
; (after the base and the short path's share), with PROF_CONT_DEC_US set
; aside at once for the loop's own path (stand: 19 units of needed base
; reserve with pieces of 1 byte at 812 units).
	IFDEF	UGB_HW_EL3
	IFDEF	UGB_TP_UDP
	DEFINE	UGB_CONT
	IFNDEF	UGB_FIT
	DEFINE	UGB_FIT
	ENDIF
PROF_CONT_MIN_US	EQU	768	; a budget of about 2580 us (off at 2000: its share cost the short receive a STEP)
PROF_CONT_DEC_US	EQU	20
	ASSERT	LOW PROF_CONT_MIN_US == 0
	ENDIF
	ENDIF
; GUDPRTL (2026-11-23; eth/engine.asm): a real-time game's flow (an input
; of 20 bytes every 40 ms up, a state of 88 bytes every 100 ms down) at
; one STEP per frame.  The plain order continued a frame being received
; before the transport and a new TX: an input that met a state waited a
; STEP and, with one input in flight, the next one was skipped (15 of 25
; per second).
;   UGB_NODW     no discard wait item: the RTL8019AS drops a frame with
;                one BNRY write (NIC_RX_DISC_DONE is immediate); the short
;                path has none either;
;   UGB_TXFIRST  ETH_SCHED: TX in progress, transport and a new TX before
;                the RX frame in progress (one new frame per STEP: TX
;                stops when it is on the wire, RX still gets the rest);
;   UGB_BYTECOST card portions priced by their bytes (TX DATA, RX copy)
;                and TX END by its padding, not at the full portion.
; Both are on only in a STEP whose units, after the base, reach
; PROF_FIRST_MIN_US (USCH_BIG, sched.asm); smaller STEPs run the plain
; order and table costs.  Their decisions are base time: the base covers
; them (stand: need 174 at 1218 units with pieces of 88 bytes), no share
; is set aside.  Below that budget the flow does not fit one STEP anyway, and
; either rule gives TX the leftovers RX needed: the card ring overflowed
; and states were lost instead of inputs being skipped.
	IFDEF	UGB_HW_RTL
	IFDEF	UGB_TP_UDP
	DEFINE	UGB_NODW
	DEFINE	UGB_TXFIRST
	DEFINE	UGB_BYTECOST
PROF_FIRST_MIN_US	EQU	850	; a budget of about 2600 us (at 2000 / 2500 either rule lost states)
	ENDIF
	ENDIF
	IFDEF	UGB_TXFIRST
	IFDEF	UGB_SHORT
	ASSERT	0			; USCH_BIG is USCH_SHORT's bit
	ENDIF
	ENDIF
	IFDEF	UGB_SHORT
	DEFINE	UGB_NODW
	ENDIF
; Fat STEP of the SprinterESP builds (UGB_FAT; sched.asm, esp/tp_esp.asm,
; esp/esp_parse.asm).  The plain ESP STEP is one UART portion and one
; parser / sequencer visit: sized for many small STEPs, it leaves half of
; a 2000 us budget unused and takes 12 STEPs for one small packet.  A STEP
; whose units, after the base, reach PROF_FAT_MIN_US (a budget of about
; 1800 us) runs rounds of pump -> parser -> sequencer while they bring
; something (ESP_FAT), with whole lines of the module as one lean item
; each (ESP_LEAN); it sets PROF_FAT_DEC_US aside for the dispatch of its
; extra rounds.  Smaller budgets run the plain code unchanged.
	IFDEF	UGB_HW_ESP
	DEFINE	UGB_FAT
	DEFINE	UGB_FIT
PROF_FAT_MIN_US		EQU	512
	IFDEF	UGB_XMODE
; GUDPESP: the data mode of its transparent UDP (esp_x.asm) visits the
; record parser and the held / streaming record every round; a STEP that
; takes a record and holds it for the module's silence (an idle pump, no
; TX share to cover the dispatch) needed a base of 281 units with 65
PROF_FAT_DEC_US		EQU	85
	ELSE
PROF_FAT_DEC_US		EQU	65
	ENDIF
	ASSERT	LOW PROF_FAT_MIN_US == 0
	ENDIF
; A useful STEP must afford the fixed path plus the most expensive
; indivisible item, otherwise a pipeline waiting for that item never moves
; (every cost is asserted against PROF_MAX_ITEM_US; no item chains two
; costs).  At 7 MHz this exceeds the 500 us STEP body limit: v1 needs
; turbo.
	IFDEF	UGB_HW_ETH
	IFDEF	UGB_TP_TCP
PROF_MAX_ITEM_US	EQU	215	; COST_TP_ACK (TCP_ACKED, stand 193 us)
	ELSE
PROF_MAX_ITEM_US	EQU	210	; COST_RX_CHUNK of the RTL8019AS (stand 181 us)
	ENDIF
	ELSE
	IFDEF	UGB_HW_LOOP
PROF_MAX_ITEM_US	EQU	230	; COST_LOOP_ITER + COST_LOOP_FIXED + a 16-byte portion (60 + 150 + 16)
	ELSE
PROF_MAX_ITEM_US	EQU	220	; ESP: COST_BRINGUP / a full line round (COST_PARSE + bytes)
	ENDIF
	ENDIF
PROF_MIN_USEFUL_US	EQU	PROF_STEP_BASE_US + PROF_MAX_ITEM_US + PROF_MIN_RETURN_US
PROF_MIN_USEFUL_RT	EQU	(PROF_MIN_USEFUL_US * PROF_UNIT_DIV + PROF_UNIT_MUL - 1) / PROF_UNIT_MUL
; STEP_ISR (stand, 21 MHz, tools/dev/isr_profile.js): fixed path (entry,
; checks, budget, counters) 23 us; the card sample (lock.asm ISR_PORTION:
; polls_total, try-lock, map, status, unmap, release; no per-call field)
; 26 us (RTL: one ISR read); empty poll RTL 49.0, 3C509B 49.0, ESP 48.0
; (pre-acquired -4.3), loopback 20 us; BUS_BUSY 24.5 us (decided before
; any write but the counters); budget refusal 13.4 us.  Published empty
; poll = worst + 5, rounded up to 5.
	IFDEF	UGB_HW_LOOP
PROF_ISR_BASE_US	EQU	25	; no card: checks, budget, counters
PROF_ISR_POLL_US	EQU	0	; nothing to poll
	ELSE
PROF_ISR_BASE_US	EQU	25	; entry, checks, budget, counters, return
PROF_ISR_POLL_US	EQU	30	; ISR_PORTION: lock + map + status + unmap + release
	ENDIF
PROF_MIN_RETURN_US	EQU	10
PROF_ISR_MIN_US		EQU	PROF_ISR_BASE_US + PROF_ISR_POLL_US + PROF_MIN_RETURN_US
; STEP_ISR compares its budget in real microseconds (no conversion on the
; interrupt path): the same sums, units * 32 / 13 rounded up.
PROF_ISR_MIN_RT		EQU	(PROF_ISR_MIN_US * PROF_UNIT_DIV + PROF_UNIT_MUL - 1) / PROF_UNIT_MUL
PROF_ISR_IDLE_RT	EQU	((PROF_ISR_BASE_US + PROF_MIN_RETURN_US) * PROF_UNIT_DIV + PROF_UNIT_MUL - 1) / PROF_UNIT_MUL
PROF_MIN_RETURN_RT	EQU	(PROF_MIN_RETURN_US * PROF_UNIT_DIV + PROF_UNIT_MUL - 1) / PROF_UNIT_MUL
; max_atomic_us: the longest indivisible (DI) section any export may start
; (ТЗ §5.1: an indivisible operation is refused if it and its return do not
; fit).  Stale at 60 since before this stage; the stand's hard DI <= 200 us
; rule was passing regardless, so nothing enforced this number against
; reality.  Stand worst DI over the 8 KiB stream (all budgets/DT, all
; cards): GTCPRTL 160, GUDPRTL 159, GTCP509B 151, GUDP509B 150, GUDPESP
; 152, GTCPESP 121 us (tools/dev/profile_step.js).  Published = worst * 1.1
; rounded up to 5 (ESP 2 KiB/s stage, WP5).
PROF_MAX_ATOMIC_US	EQU	180
PROF_MAX_ATOMIC_RT	EQU	(PROF_MAX_ATOMIC_US * PROF_UNIT_DIV + PROF_UNIT_MUL - 1) / PROF_UNIT_MUL
PROF_EMPTY_POLL_US	EQU	PROF_ISR_BASE_US + PROF_ISR_POLL_US
PROF_EMPTY_POLL_RT	EQU	(PROF_EMPTY_POLL_US * PROF_UNIT_DIV + PROF_UNIT_MUL - 1) / PROF_UNIT_MUL
PROF_BUS_BUSY_US	EQU	25	; stand 24.8 us: lock byte read before any per-call write
PROF_BUS_BUSY_RT	EQU	(PROF_BUS_BUSY_US * PROF_UNIT_DIV + PROF_UNIT_MUL - 1) / PROF_UNIT_MUL
PROF_MAX_STEP_GAP_MS	EQU	20
PROF_TIME_READ_MAX_RT	EQU	50	; real us (20 units; the board's CTC sample is 31 us, UGPROBE CTC)
	ASSERT	PROF_EMPTY_POLL_RT + PROF_MIN_RETURN_RT >= PROF_ISR_MIN_RT
PROF_TIMING_MODES	EQU	0x03
PROF_MUTABLE_BYTES	EQU	2
