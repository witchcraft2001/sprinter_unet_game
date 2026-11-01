; ugprobe.asm -- UGPROBE.EXE: platform cost probe of the Ж stand (real
; Sprinter, docs/TESTING.md "Стенд Ж"); also runs on the M stand
; (tools/mame/run_m.py --probe E|R|3), where its numbers are MAME's, not
; the board's.
;
; Command line: UGPROBE <card>, card = E (SprinterESP), R (RTL8019AS) or
; 3 (3C509B); anything else is E.  Slots and I/O bases come from
; probecfg.inc (tools/hw/build_hw.sh from tools/hw/hw.env; run_m.py
; writes the M-stand defaults).  Every section prints one
; "PROBE <name> <hex ...>" line of raw counts; tools/measure/parse_hw.py
; turns them into us with the CAL line (cal_ctc = CTC counts of 16 CPU
; clocks per video frame, cal_loop = 35-T loops per frame):
;   CPU      cal_ctc, then cal_loop three times (code and data in WIN2):
;            effective MHz = cal_loop x 35 / frame, CTC clock = cal_ctc x 16
;            / frame, DRAM wait share = 1 - effective / clock.  (No WIN0 /
;            WIN1 variant: WIN0 is the DSS system page, and remapping WIN1
;            under DSS's own IM1 handler is not something to rely on.)
;   ISA_RD   4 portions of 64 reads of a card register under the opened
;            ISA window and DI, then the same 4 on RAM (window still open):
;            (isa - ram) / 64 = the ISA read cycle's extra cost.  ESP: the
;            UART LSR (+5); RTL: CR (+0); 3C509B: the status register (+E,
;            the card is not activated -- the cycle still runs on the bus).
;   ISA_WR   the same for writes (ESP: UART SCR +7; RTL: BNRY +3 after
;            CR = 0x21, stop + page 0; 3C509B: none, the line is all zero).
;   BRACKET  256 x (open + close of the ISA window, the core's sequence:
;            #E2 saved, #1FFD | #10, #E2 = I/O page, #9FBD; back), then the
;            same loop empty: (bracket - empty) / 256 per bracket.
;   CTC      the Worms CTC2 -> CTC3 counter chain (/112 from 875 kHz, /156;
;            sdk/time/ugtime.asm) set up, UGT_CTC_SAMPLE (the APP_COUNTER
;            tick sample, INIT_CONFIG.time_read_cost_us) called from a loop
;            for one frame: loops with it, loops with a bare RET instead
;            (cost = frame x (1/with - 1/without)), counts the chain
;            advanced in that frame (875 kHz x frame when it counts,
;            0 when it does not -- the MAME model), samples without a stamp.
;            Our own timer chain (ctc_init) is restored afterwards.
;   UARTt    ESP only, after the NETUP role (AT, AT+UART_CUR), for the RX
;            FIFO trigger t = 8, 4, 14: MCR = 0, FCR = FIFO on + resets +
;            trigger, MCR = AFE + RTS (one FIFO reset before AFE), AT+GMR,
;            then a drain every ~2 ms for 1.5 s: total bytes, drains, the
;            largest drain, overruns (LSR.OE), drains of 1..16+ bytes.
;   RTSt     the auto-RTS resume point: AT+GMR, 10 ms unread (the FIFO
;            fills to t, RTS drops), then one byte per ~2 ms: reads before
;            the FIFO first ran empty and B (RTS came back below the
;            trigger: the FIFO never emptied in 40 reads), A (only after
;            empty) or S (the reply ended before the FIFO could fill).
;
; This is application code: it may call DSS and wait; it never loads a DLL.

	DEVICE	NOSLOT64K

	INCLUDE	"UNETGAME.INC"
	INCLUDE	"probecfg.inc"		; PR_SLOT_*, PR_IO_*, PR_ID_PORT

EXE_HEADER_SIZE	EQU	0x200
EXE_LOAD	EQU	0x8100
UG_BLOCK	EQU	0xA000		; the time adapter's gateway block (256-aligned)
UG_REPORT	EQU	0xA100
UG_REPORT_LEN	EQU	0x680
STACK_TOP	EQU	0xBFF0
DSS		EQU	0x10
DSS_EXIT	EQU	0x41
DSS_PCHARS	EQU	0x5C
P_SYS		EQU	0x3C		; SYS port, user mode
SH_1FFD		EQU	0x01		; DSS value: RAM in WIN0, ISA closed
SH_9FBD		EQU	0x00
UART		EQU	0xC000 + PR_IO_ESP
UART_LSR	EQU	UART + 5
PR_RX_MAX	EQU	64		; bytes per drain (a FIFO is 16 deep)
PR_RTS_READS	EQU	40

	DEFINE	UG_DLL_WIN 1
	INCLUDE	"gateway/ugate.inc"

	MACRO	UG_HWPFX
	DB	"PROBE"
	ENDM

	ORG	EXE_LOAD - EXE_HEADER_SIZE
exe_header
	DB	"EXE", 1
	DD	EXE_HEADER_SIZE
	DW	0
	DS	6, 0
	DW	start
	DW	start
	DW	STACK_TOP
	DB	0
	DS	EXE_HEADER_SIZE - ($ - exe_header), 0
	ASSERT	$ == EXE_LOAD

start
	LD	(cmdline_ptr),IX	; the DSS command line (ughw.inc)
	LD	SP,STACK_TOP
	CALL	hw_args
	CALL	pr_select
	LD	A,0x03			; turbo on (21 MHz)
	OUT	(P_SYS),A
	CALL	rep_init
	LD	HL,s_title
	CALL	rp_str
	LD	A,(scen_char)
	CALL	rp_char
	CALL	rp_nl
	LD	HL,s_scen
	CALL	rp_str
	LD	A,(scen_char)
	CALL	rp_char
	CALL	rp_nl
	CALL	tick_install
	CALL	ctc_init
	CALL	calibrate
	LD	HL,s_cal
	CALL	rp_str
	LD	HL,(cal_ctc)
	CALL	rp_hex16
	LD	A,' '
	CALL	rp_char
	LD	HL,(cal_loop)
	CALL	rp_hex16
	CALL	rp_nl
	CALL	pr_cpu
	CALL	pr_isa
	CALL	pr_bracket
	CALL	pr_ctc
	LD	A,(scen_char)
	CP	'E'
	CALL	Z,pr_uart
	LD	A,'P'
	LD	(UG_REPORT + RP_STATUS),A
	LD	HL,s_result
	CALL	rp_str
	LD	HL,s_pass
	CALL	rp_str
	CALL	ctc_stop
	CALL	hw_build_fname
	LD	HL,hw_fname
	CALL	hw_save			; before the 0xA5 marker (see ugtest.asm)
	LD	HL,UG_REPORT + RP_TEXT
	LD	C,DSS_PCHARS
	RST	DSS
	LD	A,0xA5
	LD	(UG_REPORT + RP_STATUS + 2),A	; done: ugstand.lua collects the report
	LD	B,30			; outlast ugstand.lua's 25-frame grace
.wait
	PUSH	BC
	CALL	wait_tick
	POP	BC
	DJNZ	.wait
	CALL	tick_remove
	JP	hw_exit

; pr_select: scen_char = E / R / 3 (anything else -> E); pr_e2 = the ISA
; slot's #E2 I/O page, pr_base = 0xC000 + the card's I/O base.
; Clobbers A, HL.
pr_select
	LD	A,(scen_char)
	CP	'R'
	JR	Z,.rtl
	CP	'3'
	JR	Z,.el3
	LD	A,'E'
	LD	(scen_char),A
	LD	A,0xD4 | (PR_SLOT_ESP << 1)
	LD	HL,0xC000 + PR_IO_ESP
	JR	.set
.rtl
	LD	A,0xD4 | (PR_SLOT_RTL << 1)
	LD	HL,0xC000 + PR_IO_RTL
	JR	.set
.el3
	LD	A,0xD4 | (PR_SLOT_EL3 << 1)
	LD	HL,0xC000 + PR_IO_EL3
.set
	LD	(pr_e2),A
	LD	(pr_base),HL
	RET

; ----------------------------------------------------------------------
; ISA window (the core's sequence, sdk/../src/core/lock.asm order):
; isa_map / isa_unmap under the caller's DI; isa_open / isa_close add
; DI / EI.  isa_map clobbers A, BC; isa_unmap clobbers BC (keeps A).
; ----------------------------------------------------------------------
isa_open
	DI
isa_map
	IN	A,(0xE2)
	LD	(isa_e2),A
	LD	BC,0x1FFD
	LD	A,SH_1FFD | 0x10
	OUT	(C),A
	LD	A,(pr_e2)
	LD	BC,0x00E2
	OUT	(C),A
	XOR	A
	LD	BC,0x9FBD
	OUT	(C),A
	RET
isa_close
	CALL	isa_unmap
	EI
	RET
isa_unmap
	PUSH	AF
	LD	BC,0x9FBD
	LD	A,SH_9FBD
	OUT	(C),A
	LD	BC,0x1FFD
	LD	A,SH_1FFD
	OUT	(C),A
	LD	A,(isa_e2)
	LD	BC,0x00E2
	OUT	(C),A
	POP	AF
	RET

; ----------------------------------------------------------------------
; CPU: cal_ctc, then the 35-T frame loop three more times.
; ----------------------------------------------------------------------
pr_cpu
	LD	HL,s_p_cpu
	CALL	rp_str
	LD	HL,(cal_ctc)
	CALL	rp_hex16
	LD	B,3
.rep
	PUSH	BC
	CALL	wait_tick
	LD	DE,0
	LD	HL,(ticks)
	CALL	pr_loop
	LD	A,' '
	CALL	rp_char
	EX	DE,HL
	CALL	rp_hex16
	POP	BC
	DJNZ	.rep
	JP	rp_nl

; pr_loop: DE += 1 per 35-T pass until (ticks) differs from L (calibrate's
; loop).  Out: DE.  Clobbers A.
pr_loop
	INC	DE			; 6 + 13 + 4 + 12 = 35 T
	LD	A,(ticks)
	CP	L
	JR	Z,pr_loop
	RET

; ----------------------------------------------------------------------
; ISA: reads, then writes, 4 portions of 64 on the card, 4 on RAM.
; ----------------------------------------------------------------------
pr_isa
	LD	A,(scen_char)
	LD	HL,5			; ESP: UART LSR
	LD	DE,7			; ESP: UART SCR
	CP	'E'
	JR	Z,.offs
	LD	HL,0			; RTL: CR
	LD	DE,3			; RTL: BNRY
	CP	'R'
	JR	Z,.offs
	LD	HL,0x0E			; 3C509B: status
	LD	DE,0			; no write
.offs
	LD	BC,(pr_base)
	ADD	HL,BC
	LD	(pr_rd_addr),HL
	EX	DE,HL
	ADD	HL,BC
	LD	(pr_wr_addr),HL
	LD	A,(scen_char)
	CP	'R'
	JR	NZ,.no_stop
	CALL	isa_open		; RTL: CR = STOP + page 0 + abort DMA
	LD	HL,(pr_base)
	LD	(HL),0x21
	CALL	isa_close
.no_stop
	LD	HL,s_p_isard
	CALL	rp_str
	LD	HL,(pr_rd_addr)
	CALL	pr_rd4
	LD	HL,pr_ram
	CALL	pr_rd4
	CALL	rp_nl
	LD	HL,s_p_isawr
	CALL	rp_str
	LD	A,(scen_char)
	CP	'3'
	JR	Z,.no_wr
	LD	HL,(pr_wr_addr)
	CALL	pr_wr4
	LD	HL,pr_ram
	CALL	pr_wr4
	JP	rp_nl
.no_wr
	LD	B,8
.zero
	PUSH	BC
	LD	HL,0
	CALL	rp_sp_hex16
	POP	BC
	DJNZ	.zero
	JP	rp_nl

; pr_rd4 / pr_wr4: HL = address; 4 portions, one " xxxx" each.
pr_rd4
	LD	B,4
.p
	PUSH	BC
	PUSH	HL
	CALL	isa_open
	PUSH	HL
	CALL	ctc_phase
	LD	(pr_t0),HL
	POP	HL
	LD	B,64
.r
	LD	A,(HL)
	DJNZ	.r
	CALL	ctc_phase
	CALL	isa_close
	LD	DE,(pr_t0)
	OR	A
	SBC	HL,DE
	CALL	rp_sp_hex16
	POP	HL
	POP	BC
	DJNZ	.p
	RET
pr_wr4
	LD	B,4
.p
	PUSH	BC
	PUSH	HL
	CALL	isa_open
	PUSH	HL
	CALL	ctc_phase
	LD	(pr_t0),HL
	POP	HL
	LD	A,0x46			; RTL BNRY = PSTART; the UART SCR takes anything
	LD	B,64
.w
	LD	(HL),A
	DJNZ	.w
	CALL	ctc_phase
	CALL	isa_close
	LD	DE,(pr_t0)
	OR	A
	SBC	HL,DE
	CALL	rp_sp_hex16
	POP	HL
	POP	BC
	DJNZ	.p
	RET

; ----------------------------------------------------------------------
; BRACKET: 256 x (isa_map + isa_unmap) under one DI, then the empty loop.
; ----------------------------------------------------------------------
pr_bracket
	LD	HL,s_p_bracket
	CALL	rp_str
	DI
	CALL	ctc_phase
	LD	(pr_t0),HL
	LD	D,0
.b
	CALL	isa_map
	CALL	isa_unmap
	DEC	D
	JR	NZ,.b
	CALL	ctc_phase
	LD	DE,(pr_t0)
	OR	A
	SBC	HL,DE
	LD	(pr_t1),HL
	CALL	ctc_phase
	LD	(pr_t0),HL
	LD	D,0
.e
	CALL	pr_nop
	CALL	pr_nop
	DEC	D
	JR	NZ,.e
	CALL	ctc_phase
	EI
	LD	DE,(pr_t0)
	OR	A
	SBC	HL,DE
	PUSH	HL
	LD	HL,(pr_t1)
	CALL	rp_hex16
	POP	HL
	CALL	rp_sp_hex16
	JP	rp_nl
pr_nop
	RET

; ----------------------------------------------------------------------
; CTC: the Worms chain, UGT_CTC_SAMPLE for one frame.
; ----------------------------------------------------------------------
pr_ctc
	DI
	LD	A,CTC_CHAIN		; CTC2: counter of the 875 kHz input, /112
	OUT	(P_CTC2),A
	LD	A,UGT_CTC2_N
	OUT	(P_CTC2),A
	LD	A,CTC_CHAIN		; CTC3: counter of CTC2 zero counts, /156
	OUT	(P_CTC3),A
	LD	A,UGT_CTC3_N
	OUT	(P_CTC3),A
	EI
	LD	HL,UG_BLOCK
	LD	B,0
.clr
	LD	(HL),0
	INC	HL
	DJNZ	.clr
	LD	A,UNETG_TIMING_APP_COUNTER
	LD	(UG_BLOCK + UGW_TIMING),A
	LD	HL,0
	LD	DE,0
	CALL	UGT_INIT		; reference phase
	LD	HL,0
	LD	(UG_BLOCK + UGW_T_MISS),HL
	CALL	UGT_CTC_SAMPLE		; the stamp at the frame start
	LD	HL,0
	LD	(UG_BLOCK + UGW_COUNT),HL
	LD	(UG_BLOCK + UGW_COUNT + 2),HL
	LD	IX,UGT_CTC_SAMPLE
	CALL	pr_frame_calls
	LD	(pr_t0),DE		; loops with the sample
	LD	HL,(UG_BLOCK + UGW_COUNT)
	LD	(pr_cnt),HL
	LD	HL,(UG_BLOCK + UGW_COUNT + 2)
	LD	(pr_cnt + 2),HL
	CALL	wait_tick
	LD	IX,pr_nop
	CALL	pr_frame_calls
	LD	(pr_t1),DE		; the same loop calling a bare RET
	CALL	ctc_init		; our timer chain back
	LD	HL,s_p_ctc
	CALL	rp_str
	LD	HL,(pr_t0)
	CALL	rp_hex16
	LD	HL,(pr_t1)
	CALL	rp_sp_hex16
	LD	HL,(pr_cnt + 2)
	CALL	rp_sp_hex16
	LD	HL,(pr_cnt)
	CALL	rp_hex16		; chain counts in the frame (u32)
	LD	HL,(UG_BLOCK + UGW_T_MISS)
	CALL	rp_sp_hex16		; samples without a stamp
	JP	rp_nl

; pr_frame_calls: from the next frame tick to the one after it, the 35-T
; loop plus CALL (IX) per pass (DE, HL kept around it).  Out: DE = passes.
; Clobbers everything the callee does.
pr_frame_calls
	CALL	wait_tick
	LD	DE,0
	LD	HL,(ticks)
.loop
	INC	DE
	PUSH	DE
	PUSH	HL
	CALL	.call
	POP	HL
	POP	DE
	LD	A,(ticks)
	CP	L
	JR	Z,.loop
	RET
.call
	JP	(IX)

; UGH_INC: the gateway's 16-bit counter increment (sdk/gateway/ugate.asm),
; the one gateway routine the time adapter calls.
UGH_INC
	INC	(HL)
	RET	NZ
	INC	HL
	INC	(HL)
	RET

; ----------------------------------------------------------------------
; UART (ESP): NETUP role, then the drain and RTS probes per trigger.
; ----------------------------------------------------------------------
pr_uart
	CALL	isa_open
	LD	HL,UART + 1
	LD	(HL),0			; IER
	LD	HL,UART + 3
	LD	(HL),0x83		; DLAB
	LD	HL,UART
	LD	(HL),8			; 115200 at 14.7456 MHz
	INC	HL
	LD	(HL),0
	LD	HL,UART + 3
	LD	(HL),0x03		; 8N1
	LD	HL,UART + 2
	LD	(HL),0x87		; FIFO, resets, trigger 8
	LD	HL,UART + 4
	LD	(HL),0x22		; AFE + RTS
	CALL	isa_close
	LD	HL,s_at
	CALL	at_cmd
	LD	HL,s_uartcur
	CALL	at_cmd
	LD	HL,pr_triggers
.t
	LD	A,(HL)
	OR	A
	RET	Z
	INC	HL
	LD	C,(HL)			; FCR trigger bits
	INC	HL
	PUSH	HL
	LD	(pr_trig),A
	LD	A,C
	LD	(pr_fcr),A
	CALL	pr_drain_test
	CALL	pr_rts_test
	POP	HL
	JR	.t

pr_triggers
	DB	8, 0x80, 4, 0x40, 14, 0xC0, 0

; uart_setup: MCR = 0 (RTS off), FCR = FIFO on + RX/TX reset + pr_fcr,
; MCR = AFE + RTS.  The only FIFO reset, before AFE (CLAUDE.md: a reset
; mid-session leaves auto-RTS deasserted).  Clobbers A, BC, HL.
uart_setup
	CALL	pr_quiet
	CALL	isa_open
	XOR	A
	LD	(UART + 4),A
	LD	A,(pr_fcr)
	OR	0x07
	LD	(UART + 2),A
	LD	A,0x22
	LD	(UART + 4),A
	CALL	isa_close
	RET

; pr_quiet: drain and drop until 100 ms without a byte (at most 2 s).
pr_quiet
	LD	HL,2000
	CALL	dl_set
.q
	CALL	clk_update
	LD	HL,(now_ms)
	LD	DE,100
	ADD	HL,DE
	LD	(pr_qdl),HL
.w
	CALL	isa_open
	LD	A,(UART_LSR)
	RRA
	JR	NC,.none
	LD	A,(UART)
	CALL	isa_close
	CALL	dl_due
	RET	C
	JR	.q
.none
	CALL	isa_close
	CALL	dl_due
	RET	C
	LD	HL,(pr_qdl)
	LD	DE,(now_ms)		; dl_due just refreshed now_ms
	OR	A
	SBC	HL,DE
	BIT	7,H
	RET	NZ
	LD	A,H
	OR	L
	RET	Z
	JR	.w

; uart_send: the ASCIIZ line at HL to the module (THRE wait bounded by
; 64 K polls per byte).  Clobbers A, BC, DE, HL.
uart_send
	LD	A,(HL)
	OR	A
	RET	Z
	PUSH	HL
	LD	DE,0
.thre
	CALL	isa_open
	LD	A,(UART_LSR)
	CALL	isa_close
	AND	0x20
	JR	NZ,.put
	DEC	DE
	LD	A,D
	OR	E
	JR	NZ,.thre
.put
	CALL	isa_open		; clobbers A: load the byte after it
	POP	HL
	LD	A,(HL)
	LD	(UART),A
	CALL	isa_close
	INC	HL
	JR	uart_send

; pr_delay2: ~2 ms busy wait: cal_loop / 8 passes of a 26-T loop
; = 3.25 x cal_loop T, a frame is 35 x cal_loop T (~1.9 ms of 20.5).
; Clobbers A, DE, HL.
pr_delay2
	LD	HL,(cal_loop)
	SRL	H
	RR	L
	SRL	H
	RR	L
	SRL	H
	RR	L
	EX	DE,HL
	INC	DE
.d
	DEC	DE			; 6 + 4 + 4 + 12 = 26 T
	LD	A,D
	OR	E
	JR	NZ,.d
	RET

; pr_drain: read the RX FIFO until LSR.DR = 0 (at most PR_RX_MAX bytes)
; in one ISA portion.  Out: C = bytes, B = 1 when LSR.OE was seen.
; Clobbers A, HL.
pr_drain
	CALL	isa_open
	LD	BC,0
.r
	LD	A,(UART_LSR)
	BIT	1,A
	JR	Z,.no_oe
	LD	B,1
.no_oe
	RRA
	JR	NC,.done
	LD	A,(UART)
	INC	C
	LD	A,C
	CP	PR_RX_MAX
	JR	C,.r
.done
	PUSH	BC
	CALL	isa_close
	POP	BC
	RET

; pr_drain_test: "PROBE UARTtt total drains max oe h1 .. h16" (h16 = 16+).
pr_drain_test
	CALL	uart_setup
	LD	HL,pr_stats
	LD	B,pr_stats_end - pr_stats
.clr
	LD	(HL),0
	INC	HL
	DJNZ	.clr
	LD	HL,s_gmr
	CALL	uart_send
	LD	HL,1500
	CALL	dl_set
.loop
	CALL	pr_delay2
	CALL	pr_drain
	LD	A,B
	OR	A
	JR	Z,.no_oe
	LD	HL,(pr_oe)
	INC	HL
	LD	(pr_oe),HL
.no_oe
	LD	A,C
	OR	A
	JR	Z,.next
	LD	HL,(pr_total)
	LD	B,0
	ADD	HL,BC
	LD	(pr_total),HL
	LD	HL,(pr_drains)
	INC	HL
	LD	(pr_drains),HL
	LD	A,(pr_max)
	CP	C
	JR	NC,.not_max
	LD	A,C
	LD	(pr_max),A
.not_max
	LD	A,C
	CP	16
	JR	C,.h
	LD	A,16
.h
	DEC	A			; drains of n bytes -> hist[n - 1]
	ADD	A,A
	LD	E,A
	LD	D,0
	LD	HL,pr_hist
	ADD	HL,DE
	INC	(HL)
	JR	NZ,.next
	INC	HL
	INC	(HL)
.next
	CALL	dl_due
	JR	NC,.loop
	LD	HL,s_p_uart
	CALL	rp_str
	LD	A,(pr_trig)
	CALL	rp_hex8
	LD	HL,(pr_total)
	CALL	rp_sp_hex16
	LD	HL,(pr_drains)
	CALL	rp_sp_hex16
	LD	A,(pr_max)
	LD	L,A
	LD	H,0
	CALL	rp_sp_hex16
	LD	HL,(pr_oe)
	CALL	rp_sp_hex16
	LD	HL,pr_hist
	LD	B,16
.hl
	PUSH	BC
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	INC	HL
	PUSH	HL
	EX	DE,HL
	CALL	rp_sp_hex16
	POP	HL
	POP	BC
	DJNZ	.hl
	JP	rp_nl

; pr_rts_test: "PROBE RTStt reads verdict" (B / A / S, see the header).
pr_rts_test
	CALL	uart_setup
	LD	HL,s_gmr
	CALL	uart_send
	LD	B,5			; ~10 ms unread: the FIFO fills, RTS drops
.fill
	PUSH	BC
	CALL	pr_delay2
	POP	BC
	DJNZ	.fill
	LD	C,0
.r
	PUSH	BC
	CALL	pr_delay2
	CALL	isa_open
	LD	A,(UART_LSR)
	RRA
	JR	NC,.empty
	LD	A,(UART)
	CALL	isa_close
	POP	BC
	INC	C
	LD	A,C
	CP	PR_RTS_READS
	JR	C,.r
	LD	B,'B'
	JR	.out
.empty
	CALL	isa_close
	POP	BC
	LD	B,'A'
	LD	A,(pr_trig)
	DEC	A
	CP	C			; C >= trigger: the FIFO did fill
	JR	C,.out
	LD	B,'S'
.out
	PUSH	BC
	LD	HL,s_p_rts
	CALL	rp_str
	LD	A,(pr_trig)
	CALL	rp_hex8
	POP	BC
	PUSH	BC
	LD	L,C
	LD	H,0
	CALL	rp_sp_hex16
	LD	A,' '
	CALL	rp_char
	POP	BC
	LD	A,B
	CALL	rp_char
	JP	rp_nl

; at_cmd: send the AT line at HL, collect the answer for up to 1 s into the
; report (until "OK" or the 1 s end), as UGTEST's NETUP does.
at_cmd
	PUSH	HL
	LD	A,'>'
	CALL	rp_char
	POP	HL
	PUSH	HL
	CALL	rp_str
	POP	HL
	CALL	uart_send
	LD	HL,1000
	CALL	dl_set
.rx
	CALL	isa_open
	LD	A,(UART_LSR)
	RRA
	JR	NC,.none
	LD	A,(UART)
	CALL	isa_close
	CP	10
	JR	Z,.rx
	OR	A			; a NUL would end the report text
	JR	Z,.rx
	CALL	rp_char
	CP	'K'			; "OK" (an ERROR waits for the 1 s end)
	JR	Z,.done
	JR	.rx
.none
	CALL	isa_close
	CALL	dl_due
	JR	NC,.rx
.done
	JP	rp_nl

; rp_sp_hex16: " " + HL in hex.  Clobbers A.
rp_sp_hex16
	LD	A,' '
	CALL	rp_char
	JP	rp_hex16

	INCLUDE	"ugbase.inc"
	INCLUDE	"ughw.inc"
	INCLUDE	"time/ugtime.asm"

s_title		DB	"UGPROBE ", 0
s_scen		DB	"SCEN ", 0
s_cal		DB	"CAL ", 0
s_result	DB	"RESULT: ", 0
s_pass		DB	"PASS", 13, 10, 0
s_p_cpu		DB	"PROBE CPU ", 0
s_p_isard	DB	"PROBE ISA_RD", 0
s_p_isawr	DB	"PROBE ISA_WR", 0
s_p_bracket	DB	"PROBE BRACKET ", 0
s_p_ctc		DB	"PROBE CTC ", 0
s_p_uart	DB	"PROBE UART", 0
s_p_rts		DB	"PROBE RTS", 0
s_at		DB	"AT", 13, 10, 0
s_uartcur	DB	"AT+UART_CUR=115200,8,1,0,3", 13, 10, 0
s_gmr		DB	"AT+GMR", 13, 10, 0

pr_e2		DB	0
pr_base		DW	0
pr_rd_addr	DW	0
pr_wr_addr	DW	0
pr_t0		DW	0
pr_t1		DW	0
pr_ram		DB	0
pr_trig		DB	0
pr_fcr		DB	0
pr_qdl		DW	0
pr_cnt		DD	0
isa_e2		DB	0
pr_stats
pr_total	DW	0
pr_drains	DW	0
pr_max		DB	0
pr_oe		DW	0
pr_hist		DS	32, 0
pr_stats_end

code_end
	ASSERT	code_end <= UG_BLOCK, "UGPROBE code runs into its data blocks"
	SAVEBIN	"ugprobe.exe", exe_header, code_end - exe_header
