; netdemo.asm -- NETDEMO.EXE: the SDK example of mixed service (ТЗ §7) and
; the M stand program of milestone M5 (tools/mame/run_m.py).
;
; The order of ТЗ §7:
;  1. before the game: the SDK loader (libman) loads the DLL, the gateway
;     prepares INIT_CONFIG from the profile and GET_INFO (UG_INIT_ENV), the
;     timer and IM2 are set up, the gateway starts (UG_START);
;  2. the CTC1 timer tick (2 ms): the time adapter (FIXED_SCHEDULE), the
;     gateway tick (budget periods of 10 ticks) and the guaranteed poll
;     (UG_ISR_NET -> STEP_ISR); the frame interrupt (#FF) is counted and
;     gives an extra poll opportunity; no keyboard in this program; no
;     CBL either, except the UG_HW build, where every frame interrupt also
;     raises UG_ISR_CBL and the CBL line times flag -> admitted poll;
;  3. the main loop: UG_STEP from the main quota, events, RX / TX;
;  4. pause (scenario W): no game work for 2 s, the clocks, periods, polls
;     and STEP go on;
;     A stopwatch on CTC2 (timer, /16) -> CTC3 (FIXED_SCHEDULE leaves both
;     free; the 875 kHz counter chain does not count in this MAME) times
;     the tick ISR, the admitted UG_STEP and the gaps between ticks
;     (TIMING line, counts of 16 CPU clocks);
;  5. exit: UG_SHUTDOWN until OK, CTC and IM restored, UG_EXIT, UG_FREE
;     (FINI), report, back to DSS (the report is printed; ugstand.lua
;     collects it from memory).
; Scenarios (-DSCEN): E echo 300 bytes, S 8 KiB stream, P the peer
; closes, D SHUTDOWN with the channel open, W pause, L load / check / free,
; H card bring-up and SHUTDOWN without a channel.
; ESP builds play NETUP first (AT, AT+UART_CUR=115200,8,1,0,3).
; Memory: tools/mame/mkcfg.js --prog netdemo (WIN2, nothing at >= 0xC000).

	DEVICE	NOSLOT64K

	INCLUDE	"UNETGAME.INC"
	INCLUDE	"unetg_ctx.inc"		; ctx.hw_state during the bring-up (this repository's example)
	INCLUDE	"ugcfg.inc"

	DEFINE	LIBMAN_MAX_LIBS 1
	DEFINE	LIBMAN_NO_LEGACY_API
	DEFINE	LIBMAN_L0_L1_ONLY

UG_BLOCK	EQU	UG_GW
	DEFINE	UG_DLL_WIN 1
	INCLUDE	"gateway/ugate.inc"

EXE_HEADER_SIZE	EQU	0x200
EXE_LOAD	EQU	0x8100
STACK_TOP	EQU	UG_MSTK + UG_MSTK_LEN
DSS		EQU	0x10
DSS_PCHARS	EQU	0x5C
P_SYS		EQU	0x3C
P_CTC0		EQU	0x10
P_CTC1		EQU	0x11
P_CTC2		EQU	0x12
P_CTC3		EQU	0x13
SW_TIMER	EQU	0x07		; stopwatch: CTC2 timer, prescaler 16, constant follows, reset
SW_CHAIN	EQU	0x57		; CTC3 counts the CTC2 zero counts
TICK_COUNTS	EQU	2624		; one tick in stopwatch counts (41 984 / 16)
CTC1_TIMER	EQU	0xA7		; IE, timer, prescaler 256, constant follows, reset
CTC1_CONST	EQU	164		; 41 984 T at 21 MHz = 1999.238 us
CTC_RESET	EQU	0x03
IM2_TABLE	EQU	UG_GW + 0x100	; 257 bytes of IM2_FILL, I = HIGH IM2_TABLE
IM2_FILL	EQU	HIGH IM2_TABLE + 1
IM2_DEFAULT	EQU	IM2_FILL * 0x101	; every unused vector lands here
V_TICK		EQU	0x02		; CTC1, vector base 0
V_FRAME		EQU	0xFF
SH_1FFD		EQU	0x01		; DSS values when the program starts
SH_9FBD		EQU	0x00
UART		EQU	0xC000 + UG_IO_BASE	; the card's io_base in the ISA window
RP_STATUS	EQU	8
RP_TEXT		EQU	16
UHW_RUN		EQU	2
DSS_EXIT	EQU	0x41		; B = exit code (ughw.inc hw_exit)
	ASSERT	IM2_DEFAULT + 3 <= UG_ISTK, "default IM2 handler below the ISR stack"
	ASSERT	(IM2_TABLE & 0xFF) == 0

	; UG_HW (the Ж / real-hardware stand): a file replaces .spin at exit.
	; Default off, so a plain build (no -DUG_HW) is the M-stand program
	; unchanged.  See ugtest.asm for why ughw.inc is included further
	; down (inside the ORG'd EXE image), never here before ORG.
	IFNDEF	UG_HW
	DEFINE	UG_HW 0
	ENDIF

; ugstand.lua samples these (CLOCK_RATE line): now_ms of the time adapter,
; timer ticks, admitted STEPs
now_ms		EQU	UG_BLOCK + UGW_NOW
ticks		EQU	UG_BLOCK + UGW_STATS + UGS_TICKS
st_n		EQU	UG_BLOCK + UGW_STATS + UGS_STEP

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
	IF	UG_HW
	LD	A,SCEN			; hw_build_fname's file name needs it;
	LD	(scen_char),A		; NETDEMO keeps -DSCEN even under UG_HW
	ENDIF
	LD	SP,STACK_TOP
	LD	A,0x03			; turbo on (21 MHz, the v1 profile)
	OUT	(P_SYS),A
	CALL	rep_init
	LD	HL,s_title
	CALL	rp_str
	LD	HL,dll_name
	CALL	rp_str
	CALL	rp_nl
	IF	UG_HW
	LD	HL,s_scen
	CALL	rp_str
	LD	A,SCEN
	CALL	rp_char
	CALL	rp_nl
	ENDIF
	; 1. before the game -----------------------------------------------
	LD	A,SH_1FFD
	LD	E,SH_9FBD
	CALL	UG_GW_INIT
	LD	HL,dll_name
	CALL	UG_LOAD
	PUSH	AF
	PUSH	BC
	LD	HL,s_load
	CALL	rp_str
	POP	BC
	POP	AF
	PUSH	AF
	CALL	rp_hex8			; UG_LD_*
	LD	A,' '
	CALL	rp_char
	LD	A,B
	CALL	rp_hex8			; libman reason
	LD	A,' '
	CALL	rp_char
	LD	A,(UG_BLOCK + UGW_HANDLE)
	CALL	rp_hex8
	LD	A,' '
	CALL	rp_char
	LD	A,(UG_BLOCK + UGW_PAGE)
	CALL	rp_hex8
	LD	A,' '
	CALL	rp_char
	LD	A,(UG_BLOCK + UGW_BASEH)
	CALL	rp_hex8
	CALL	rp_nl
	POP	AF
	LD	A,'L'
	JP	C,fail
	LD	A,1
	LD	(loaded),A
	IF	SCEN == 'L'
	LD	A,'P'
	JP	finish
	ENDIF
	; the application zeroes its context region
	LD	HL,UG_CTX
	LD	DE,UG_CTX + 1
	LD	BC,UG_CTX_LEN - 1
	LD	(HL),0
	LDIR
	LD	IX,cfg_block
	LD	HL,profile
	CALL	UG_INIT_ENV
	PUSH	AF
	LD	HL,s_env
	CALL	rp_str
	POP	AF
	PUSH	AF
	CALL	rp_hex8
	LD	A,' '
	CALL	rp_char
	LD	A,(UG_BLOCK + UGW_ENV)
	CALL	rp_hex8
	LD	A,' '
	CALL	rp_char
	LD	HL,(UG_BLOCK + UGW_SUM)
	CALL	rp_hex16
	CALL	rp_nl
	LD	HL,s_info
	LD	DE,UG_BLOCK + UGW_SCRATCH
	LD	B,UNETG_INFO_BYTES
	CALL	rp_dump
	POP	AF
	OR	A
	LD	A,'C'
	JP	NZ,fail
	; the timer and IM2; the time adapter starts at now_ms = 0
	CALL	irq_start
	; NETUP (ESP): the module UART, with the ticks running for its deadlines
	IF	UG_ESP
	CALL	netup
	ENDIF
	; bring-up through the gateway, at most 10 s
	LD	HL,10000
	CALL	dl_set
.hw
	CALL	pump
	LD	A,(UG_CTX + UCTX_HW_STATE)
	CP	UHW_RUN
	JR	Z,.hw_ok
	CALL	dl_due
	JR	NC,.hw
	LD	A,'H'
	JP	fail
.hw_ok
	LD	HL,s_hw
	CALL	rp_str
	CALL	scenario
	; 5. exit ------------------------------------------------------------
	CALL	report_gw
	LD	HL,s_shut
	CALL	rp_str
	LD	DE,3000
	CALL	UG_SHUTDOWN
	PUSH	AF
	CALL	rp_hex8
	CALL	rp_nl
	POP	AF
	OR	A
	LD	A,'X'
	JP	NZ,fail
	CALL	irq_stop
	LD	A,(fail_code)
	OR	A
	JP	NZ,fail
	LD	A,'P'
	JR	finish

fail
	LD	(fail_code),A
	LD	A,(irq_on)
	OR	A
	JR	Z,.quiet
	CALL	report_gw
	LD	DE,3000
	CALL	UG_SHUTDOWN
	CALL	irq_stop
.quiet
	LD	A,'F'
finish
	LD	(UG_REPORT + RP_STATUS),A
	LD	A,(fail_code)
	LD	(UG_REPORT + RP_STATUS + 1),A
	CALL	rp_result
	LD	A,(loaded)
	OR	A
	CALL	NZ,UG_FREE		; FINI through libman, in IM1
	IF	UG_HW
	; the report is already fully composed (rp_result just ran): save
	; it BEFORE the 0xA5 completion marker below, so a harness polling
	; once per video frame (M stand, ugstand.lua) can never observe
	; 0xA5 while hw_save is still running.
	CALL	hw_build_fname
	LD	HL,hw_fname
	CALL	hw_save
	ENDIF
	LD	HL,UG_REPORT + RP_TEXT
	LD	C,DSS_PCHARS
	RST	DSS
	LD	A,0xA5
	LD	(UG_REPORT + RP_STATUS + 2),A	; done: ugstand.lua collects the report
	IF	UG_HW
	; ugstand.lua waits 25 frames after it SEES 0xA5 before it actually
	; reads the report text ("let the DSS print finish"); outlast that
	; grace period before hw_exit's DSS EXIT can disturb anything the
	; harness has not captured yet (irq_stop already ran above: no tick
	; source left to wait on, hence the plain CPU busy-wait).
	CALL	hw_delay
	CALL	hw_exit			; does not return
	ENDIF
.spin
	JR	.spin

rp_result
	LD	HL,s_result
	CALL	rp_str
	LD	A,(UG_REPORT + RP_STATUS)
	CP	'P'
	LD	HL,s_pass
	JR	Z,.r
	LD	HL,s_failr
	CALL	rp_str
	LD	A,(fail_code)
	CALL	rp_char
	LD	HL,s_crlf
.r
	JP	rp_str

; ----------------------------------------------------------------------
; Interrupts: IM2 table in the gateway region, CTC1 tick, frame vector.
; ----------------------------------------------------------------------
irq_start
	DI
	LD	A,I
	LD	(saved_i),A
	LD	HL,IM2_TABLE
	LD	DE,IM2_TABLE + 1
	LD	BC,256
	LD	(HL),IM2_FILL
	LDIR
	LD	HL,isr_tick
	LD	(IM2_TABLE + V_TICK),HL
	LD	HL,isr_frame
	LD	(IM2_TABLE + V_FRAME),HL
	LD	A,0xC3
	LD	(IM2_DEFAULT),A
	LD	HL,isr_unknown
	LD	(IM2_DEFAULT + 1),HL
	LD	A,HIGH IM2_TABLE
	LD	I,A
	IM	2
	XOR	A
	OUT	(P_CTC0),A		; vector base 0 (a byte with bit 0 = 0)
	LD	HL,0
	LD	DE,0
	CALL	UGT_INIT
	LD	A,SW_TIMER
	OUT	(P_CTC2),A
	XOR	A
	OUT	(P_CTC2),A
	LD	A,SW_CHAIN
	OUT	(P_CTC3),A
	XOR	A
	OUT	(P_CTC3),A
	LD	A,CTC1_TIMER
	OUT	(P_CTC1),A
	LD	A,CTC1_CONST
	OUT	(P_CTC1),A
	CALL	UG_START
	LD	A,1
	LD	(irq_on),A
	EI
	RET

irq_stop
	DI
	LD	A,CTC_RESET
	OUT	(P_CTC1),A
	OUT	(P_CTC2),A
	OUT	(P_CTC3),A
	CALL	UG_EXIT
	LD	(exit_lock),A
	LD	A,(saved_i)
	LD	I,A
	IM	1
	XOR	A
	LD	(irq_on),A
	EI
	RET

isr_tick
	PUSH	AF
	PUSH	BC
	PUSH	DE
	PUSH	HL
	CALL	sw_now
	LD	(sw_isr0),HL
	LD	DE,(sw_tick)		; gap since the previous tick
	LD	(sw_tick),HL
	OR	A
	SBC	HL,DE
	LD	DE,(sw_gap_max)
	CALL	sw_max
	LD	(sw_gap_max),DE
	LD	DE,TICK_COUNTS * 3 / 2	; a gap above 1.5 ticks: ticks were lost
	OR	A
	SBC	HL,DE
	JR	C,.on_time
	LD	HL,(sw_late)
	INC	HL
	LD	(sw_late),HL
.on_time
	CALL	UG_TICK
	LD	A,UNETG_SRC_TIMER
	CALL	UG_ISR_NET
	IF	UG_HW
	CALL	cbl_check
	ENDIF
	CALL	UGT_TICK
	CALL	sw_now
	LD	DE,(sw_isr0)
	OR	A
	SBC	HL,DE
	LD	DE,(sw_isr_max)
	CALL	sw_max
	LD	(sw_isr_max),DE
	POP	HL
	POP	DE
	POP	BC
	POP	AF
	EI
	RETI
isr_frame
	PUSH	AF
	PUSH	BC
	PUSH	DE
	PUSH	HL
	IF	UG_HW
	CALL	cbl_raise
	ENDIF
	CALL	UG_ISR_FRAME
	POP	HL
	POP	DE
	POP	BC
	POP	AF
	EI
	RETI
; sw_now: HL = stopwatch counts (16 CPU clocks), modulo 65536 (50 ms).
; Clobbers A, BC.
sw_now
	IN	A,(P_CTC3)
	LD	B,A
	IN	A,(P_CTC2)
	LD	C,A
	IN	A,(P_CTC3)
	CP	B
	JR	Z,.ok
	LD	B,A
	IN	A,(P_CTC2)
	LD	C,A
.ok
	XOR	A
	SUB	B
	LD	H,A
	XOR	A
	SUB	C
	LD	L,A
	RET
; sw_max: DE = max(DE, HL).  Preserves HL.
sw_max
	PUSH	HL
	OR	A
	SBC	HL,DE
	POP	HL
	RET	C
	LD	D,H
	LD	E,L
	RET

isr_unknown
	PUSH	HL
	LD	HL,(n_unknown)
	INC	HL
	LD	(n_unknown),HL
	POP	HL
	EI
	RETI

; ----------------------------------------------------------------------
; Scenarios
; ----------------------------------------------------------------------
scenario
	IF	SCEN == 'H'
	RET				; bring-up and SHUTDOWN only, no channel
	ENDIF
	CALL	open_wait
	IF	SCEN == 'E'
	LD	HL,300
	LD	(tx_total),HL
	CALL	send_all
	CALL	close_wait
	ENDIF
	IF	SCEN == 'S'
	LD	HL,8192
	LD	(tx_total),HL
	CALL	send_all
	CALL	close_wait
	ENDIF
	IF	SCEN == 'W'
	LD	HL,300
	LD	(tx_total),HL
	CALL	send_all
	; the game pauses: 2 s of service only
	LD	HL,s_pause
	CALL	rp_str
	LD	HL,2000
	CALL	dl_set
.pause
	CALL	pump
	CALL	dl_due
	JR	NC,.pause
	LD	HL,600
	LD	(tx_total),HL
	CALL	send_all
	CALL	close_wait
	ENDIF
	IF	SCEN == 'P'
	LD	HL,64
	LD	(tx_total),HL
	CALL	send_all
	LD	HL,5000
	CALL	dl_set
.pc
	CALL	pump
	LD	A,(ev_closed)
	OR	A
	JR	NZ,.pc_done
	CALL	dl_due
	JR	NC,.pc
	LD	A,'p'
	JP	fail
.pc_done
	LD	A,(ev_peer)
	OR	A
	RET	NZ
	LD	A,'q'
	LD	(fail_code),A
	ENDIF
	IF	SCEN == 'D'
	LD	HL,100
	LD	(tx_total),HL
	CALL	send_one
	LD	HL,200
	CALL	dl_set
.d
	CALL	pump
	CALL	dl_due
	JR	NC,.d
	ENDIF
	RET

open_wait
	LD	HL,s_open
	CALL	rp_str
	LD	IX,0
	LD	B,UNETG_OPEN
	CALL	UG_CALL
	OR	A
	LD	A,'O'
	JP	NZ,fail
	LD	HL,15000
	CALL	dl_set
.w
	CALL	pump
	LD	A,(ev_connected)
	OR	A
	RET	NZ
	LD	A,(ev_closed)
	OR	A
	LD	A,'R'
	JP	NZ,fail
	CALL	dl_due
	JR	NC,.w
	LD	A,'T'
	JP	fail

; send_all: tx_total more bytes (on top of what was sent), the echo checked
send_all
	LD	HL,(tx_total)
	LD	DE,(tx_sent)
	ADD	HL,DE
	LD	(tx_total),HL
	LD	HL,30000
	CALL	dl_set
.loop
	CALL	send_one
	CALL	pump
	LD	HL,(rx_count)
	LD	DE,(tx_total)
	OR	A
	SBC	HL,DE
	JR	NC,.done
	CALL	dl_due
	JR	NC,.loop
	LD	A,'E'
	JP	fail
.done
	LD	A,(rx_bad)
	OR	A
	LD	A,'B'
	JP	NZ,fail
	LD	HL,s_echo
	CALL	rp_str
	LD	HL,(rx_count)
	CALL	rp_hex16
	JP	rp_nl

send_one
	LD	HL,(tx_total)
	LD	DE,(tx_sent)
	OR	A
	SBC	HL,DE
	RET	Z
	LD	DE,UG_SLOT
	CALL	min_de_hl		; DE = this piece
	PUSH	DE
	LD	B,UNETG_TX_RESERVE
	CALL	UG_CALL			; HL = slot buffer, E = slot
	POP	BC
	OR	A
	RET	NZ			; no free slot yet
	LD	A,E
	LD	(tx_slot),A
	PUSH	BC
	LD	A,(tx_gen)
.fill
	LD	(HL),A
	ADD	A,31
	INC	HL
	DEC	BC
	LD	E,A
	LD	A,B
	OR	C
	LD	A,E
	JR	NZ,.fill
	LD	(tx_gen),A
	POP	DE
	PUSH	DE
	LD	A,(tx_slot)
	LD	IX,(tx_tag)
	LD	B,UNETG_TX_COMMIT
	CALL	UG_CALL
	POP	DE
	OR	A
	LD	A,'K'
	JP	NZ,fail
	LD	HL,(tx_sent)
	ADD	HL,DE
	LD	(tx_sent),HL
	LD	HL,(tx_tag)
	INC	HL
	LD	(tx_tag),HL
	RET

close_wait
	LD	B,UNETG_CLOSE
	CALL	UG_CALL
	OR	A
	LD	A,'c'
	JP	NZ,fail
	LD	HL,5000
	CALL	dl_set
.w
	CALL	pump
	LD	A,(ev_closed)
	OR	A
	RET	NZ
	CALL	dl_due
	JR	NC,.w
	LD	A,'d'
	JP	fail

; ----------------------------------------------------------------------
; pump: one admission attempt (UG_STEP), the events and the RX data; with
; nothing done it sleeps until the next interrupt (HALT: application code)
; ----------------------------------------------------------------------
pump
	DI
	CALL	sw_now
	EI
	LD	(sw_step0),HL
	CALL	UG_STEP
	LD	(last_step),A
	CP	UG_ST_EARLY
	JR	NC,.events
	PUSH	AF
	DI
	CALL	sw_now
	EI
	LD	DE,(sw_step0)
	OR	A
	SBC	HL,DE
	LD	DE,(sw_step_max)
	CALL	sw_max
	LD	(sw_step_max),DE
	POP	AF
.events
	LD	B,8
.ev
	PUSH	BC
	LD	IX,evbuf
	LD	B,UNETG_NEXT_EVENT
	CALL	UG_CALL
	POP	BC
	OR	A
	JR	NZ,.rx
	CALL	event
	DJNZ	.ev
.rx
	LD	B,4
.peek
	PUSH	BC
	LD	B,UNETG_RX_PEEK
	CALL	UG_CALL			; HL = data, DE = length
	OR	A
	JR	NZ,.rx_end
	LD	A,(rx_gen)
	LD	C,A
.cmp
	LD	A,D
	OR	E
	JR	Z,.cmp_end
	LD	A,(HL)
	CP	C
	JR	Z,.same
	LD	A,1
	LD	(rx_bad),A
.same
	LD	A,C
	ADD	A,31
	LD	C,A
	INC	HL
	DEC	DE
	PUSH	HL
	LD	HL,(rx_count)
	INC	HL
	LD	(rx_count),HL
	POP	HL
	JR	.cmp
.cmp_end
	LD	A,C
	LD	(rx_gen),A
	LD	B,UNETG_RX_RELEASE
	CALL	UG_CALL
	POP	BC
	DJNZ	.peek
	RET
.rx_end
	POP	BC
	LD	A,(last_step)
	CP	UG_ST_EARLY
	RET	C			; the core ran: no sleep
	HALT				; until the next tick
	RET

event
	LD	A,(evbuf + UNETG_EVT_TYPE)
	CP	UNETG_EV_CONNECTED
	JR	NZ,.e1
	LD	(ev_connected),A
.e1
	CP	UNETG_EV_CLOSED
	JR	NZ,.e2
	LD	(ev_closed),A
.e2
	CP	UNETG_EV_PEER_CLOSED
	JR	NZ,.e3
	LD	(ev_peer),A
.e3
	CP	UNETG_EV_RX_READY
	RET	Z
	CP	UNETG_EV_TX_DONE
	JR	NZ,.log
	LD	A,(evbuf + UNETG_EVT_STATUS)
	OR	A
	RET	Z
	CP	UNETG_TXDONE_CANCEL	; ABI §5: CANCEL is the documented outcome
	JR	Z,.txcancel		; of ABORT/SHUTDOWN on an unfinished TX, not a failure
	LD	A,'t'
	LD	(fail_code),A
.txcancel
	LD	A,(evbuf + UNETG_EVT_TYPE)
.log
	PUSH	AF
	LD	HL,s_ev
	CALL	rp_str
	POP	AF
	CALL	rp_hex8
	LD	A,'/'
	CALL	rp_char
	LD	A,(evbuf + UNETG_EVT_DETAIL)
	CALL	rp_hex8
	JP	rp_nl

; report_gw: the gateway snapshot (quotas, debits, counters, now_ms) and
; GET_STATS, while the context is configured
report_gw
	LD	DE,gwsnap
	CALL	UG_SNAPSHOT
	LD	HL,s_gw
	LD	DE,gwsnap
	LD	B,UGW_SCRATCH
	CALL	rp_dump
	LD	IX,gstats
	LD	DE,80
	LD	B,UNETG_GET_STATS
	CALL	UG_CALL
	LD	HL,s_stats
	LD	DE,gstats
	LD	B,80
	CALL	rp_dump
	LD	HL,s_unknown
	CALL	rp_str
	LD	HL,(n_unknown)
	CALL	rp_hex16
	CALL	rp_nl
	LD	HL,s_timing		; tick ISR max, admitted UG_STEP max (with
	CALL	rp_str			; interrupts), largest tick gap, late ticks
	LD	HL,(sw_isr_max)
	CALL	rp_hex16
	LD	A,' '
	CALL	rp_char
	LD	HL,(sw_step_max)
	CALL	rp_hex16
	LD	A,' '
	CALL	rp_char
	LD	HL,(sw_gap_max)
	CALL	rp_hex16
	LD	A,' '
	CALL	rp_char
	LD	HL,(sw_late)
	CALL	rp_hex16
	IF	UG_HW
	CALL	rp_nl
	; CBL n max sum(32): CBL flag raised (frame ISR) -> the guaranteed
	; poll it turned into admitted (stopwatch counts, like TIMING)
	LD	HL,s_cbl
	CALL	rp_str
	LD	HL,(cbl_n)
	CALL	rp_hex16
	LD	A,' '
	CALL	rp_char
	LD	HL,(cbl_max)
	CALL	rp_hex16
	LD	A,' '
	CALL	rp_char
	LD	HL,(cbl_sum + 2)
	CALL	rp_hex16
	LD	HL,(cbl_sum)
	CALL	rp_hex16
	ENDIF
	JP	rp_nl

min_de_hl
	PUSH	HL
	OR	A
	SBC	HL,DE
	POP	HL
	RET	NC
	EX	DE,HL
	RET

; deadlines on the gateway's now_ms (16-bit horizon)
dl_set
	PUSH	HL
	CALL	UG_NOW
	POP	DE
	ADD	HL,DE
	LD	(deadline),HL
	RET
dl_due					; CF = 1 when due
	CALL	UG_NOW
	LD	DE,(deadline)
	OR	A
	SBC	HL,DE
	BIT	7,H
	SCF
	RET	Z
	OR	A
	RET

; ----------------------------------------------------------------------
; NETUP (ESP), with the shared ISA lock (owner: controller) and the
; gateway's shadows
; ----------------------------------------------------------------------
	IF	UG_ESP
netup
	CALL	isa_open
	LD	HL,UART + 1
	LD	(HL),0
	LD	HL,UART + 3
	LD	(HL),0x83
	LD	HL,UART
	LD	(HL),8
	INC	HL
	LD	(HL),0
	LD	HL,UART + 3
	LD	(HL),0x03
	LD	HL,UART + 2
	LD	(HL),0x87
	LD	HL,UART + 4
	LD	(HL),0x22
	CALL	isa_close
	LD	HL,s_at
	CALL	at_cmd
	LD	HL,s_uartcur
	CALL	at_cmd
	RET

at_cmd
	PUSH	HL
	LD	A,'>'
	CALL	rp_char
	POP	HL
	PUSH	HL
	CALL	rp_str
	POP	HL
.send
	LD	A,(HL)
	OR	A
	JR	Z,.sent
	PUSH	HL
	CALL	isa_open
.thre
	LD	A,(UART + 5)
	AND	0x20
	JR	Z,.thre
	POP	HL
	LD	A,(HL)
	LD	(UART),A
	CALL	isa_close
	INC	HL
	JR	.send
.sent
	LD	HL,1000
	CALL	dl_set
.rx
	CALL	isa_open
	LD	A,(UART + 5)
	RRA
	JR	NC,.none
	LD	A,(UART)
	CALL	isa_close
	CP	10
	JR	Z,.rx
	CALL	rp_char
	CP	'K'
	JR	Z,.done
	JR	.rx
.none
	CALL	isa_close
	CALL	dl_due
	JR	NC,.rx
.done
	JP	rp_nl

; isa_open: DI, the lock (the main loop holds no portion here: free), the
; window from the gateway's shadows.  isa_close: exact restore, lock, EI.
isa_open
	DI
	LD	A,UNETG_LOCK_CONTROLLER
	LD	(UG_BLOCK + UGW_LOCK),A
	IN	A,(0xE2)
	LD	(isa_e2),A
	LD	A,(UG_BLOCK + UGW_SH1FFD)
	OR	0x10
	LD	BC,0x1FFD
	OUT	(C),A
	LD	A,0xD4 | (UG_ISA_SLOT << 1)	; the card's ISA slot, I/O space (slot 1: #D6)
	LD	BC,0x00E2
	OUT	(C),A
	XOR	A
	LD	BC,0x9FBD
	OUT	(C),A
	RET
isa_close
	PUSH	AF
	LD	A,(UG_BLOCK + UGW_SH9FBD)
	LD	BC,0x9FBD
	OUT	(C),A
	LD	A,(UG_BLOCK + UGW_SH1FFD)
	LD	BC,0x1FFD
	OUT	(C),A
	LD	A,(isa_e2)
	LD	BC,0x00E2
	OUT	(C),A
	XOR	A
	LD	(UG_BLOCK + UGW_LOCK),A
	POP	AF
	EI
	RET
	ENDIF

; ----------------------------------------------------------------------
; Report
; ----------------------------------------------------------------------
rep_init
	LD	HL,UG_REPORT
	LD	DE,UG_REPORT + 1
	LD	BC,UG_REPORT_LEN - 1
	LD	(HL),0
	LDIR
	LD	HL,s_magic
	LD	DE,UG_REPORT
	LD	BC,8
	LDIR
	LD	A,'R'
	LD	(UG_REPORT + RP_STATUS),A
	LD	HL,UG_REPORT + RP_TEXT
	LD	(rp_ptr),HL
	RET
rp_char
	PUSH	HL
	PUSH	DE
	LD	HL,(rp_ptr)
	LD	DE,UG_REPORT + UG_REPORT_LEN - 2
	PUSH	HL
	OR	A
	SBC	HL,DE
	POP	HL
	JR	NC,.full
	LD	(HL),A
	INC	HL
	LD	(HL),0
	LD	(rp_ptr),HL
.full
	POP	DE
	POP	HL
	RET
rp_str
	LD	A,(HL)
	OR	A
	RET	Z
	CALL	rp_char
	INC	HL
	JR	rp_str
rp_nl
	LD	HL,s_crlf
	JR	rp_str
rp_hex16
	LD	A,H
	CALL	rp_hex8
	LD	A,L
rp_hex8
	PUSH	AF
	RRA
	RRA
	RRA
	RRA
	CALL	.nib
	POP	AF
.nib
	PUSH	AF
	AND	0x0F
	ADD	A,'0'
	CP	'9' + 1
	JR	C,.d
	ADD	A,7
.d
	CALL	rp_char
	POP	AF
	RET
rp_dump
	PUSH	DE
	PUSH	BC
	CALL	rp_str
	POP	BC
	POP	DE
.b
	LD	A,(DE)
	CALL	rp_hex8
	INC	DE
	DJNZ	.b
	JP	rp_nl

	IF	UG_HW
; UG_HW (Ж stand) only: ughw.inc's hw_save/hw_exit, plus a plain CPU
; busy-wait (no tick/IRQ dependency: by the time `finish` runs below,
; irq_stop may already have torn down CTC1/IM2) long enough to outlast
; ugstand.lua's 25-frame "let the DSS print finish" grace period before
; hw_exit's DSS EXIT.  NETDEMO keeps -DSCEN (build_hw.sh: one NETDEMO.EXE
; per scenario) -- no hw_args, no runtime dispatch.
	INCLUDE	"ughw.inc"

; ~1.3 s at 21 MHz (16 x 65536 x 26 T; ugstand.lua waits 25 frames = 0.5 s).
; DEC DE sets no flags: the loop tests D|E.
hw_delay
	LD	B,16
.l1
	LD	DE,0
.l2
	DEC	DE
	LD	A,D
	OR	E
	JR	NZ,.l2
	DJNZ	.l1
	RET

; cbl_raise: frame ISR (IFF = 0) -- stand in for a sound interrupt (ТЗ §3):
; UG_ISR_CBL every frame; the first flag not yet followed by its poll
; starts a sample (sw_now).  Clobbers AF, BC, HL.
cbl_raise
	LD	A,(cbl_armed)
	OR	A
	JR	NZ,.raise
	CALL	sw_now
	LD	(cbl_t0),HL
	LD	A,1
	LD	(cbl_armed),A
.raise
	JP	UG_ISR_CBL

; cbl_check: tick ISR (IFF = 0) after UG_TICK + UG_ISR_NET.  The sample
; ends once UG_TICK consumed the CBL flag (UGF_CBL clear) and the poll it
; armed was admitted (UGF_POLL_DUE clear); a refused poll keeps it open
; for the next tick.  Clobbers AF, BC, DE, HL.
cbl_check
	LD	A,(cbl_armed)
	OR	A
	RET	Z
	LD	A,(UG_BLOCK + UGW_FLAGS)
	AND	(1 << UGF_CBL) | (1 << UGF_POLL_DUE)
	RET	NZ
	LD	(cbl_armed),A
	CALL	sw_now
	LD	DE,(cbl_t0)
	OR	A
	SBC	HL,DE
	LD	DE,(cbl_max)
	CALL	sw_max
	LD	(cbl_max),DE
	LD	DE,(cbl_sum)
	ADD	HL,DE
	LD	(cbl_sum),HL
	JR	NC,.nc
	LD	HL,(cbl_sum + 2)
	INC	HL
	LD	(cbl_sum + 2),HL
.nc
	LD	HL,(cbl_n)
	INC	HL
	LD	(cbl_n),HL
	RET

s_scen		DB	"SCEN ", 0
s_cbl		DB	"CBL ", 0
cbl_armed	DB	0
cbl_t0		DW	0
cbl_max		DW	0
cbl_sum		DD	0
cbl_n		DW	0
	ENDIF

; ----------------------------------------------------------------------
; Profile of this program (ugate.inc UGP_*): CTC1 tick 1999.238 us,
; periods of 10 ticks (19.99 ms; no video: the timer is the period source,
; ТЗ §5), a guaranteed poll every tick, UG_STEPS STEPs per period, relaxed
; (the current core does not fit the 2000 us target, docs/SDK.md).
; ----------------------------------------------------------------------
	IFNDEF	UG_STEPS
	DEFINE	UG_STEPS 5		; -DUG_STEPS=n overrides
	ENDIF
profile
	DW	1999			; tick, whole us
	DB	61			; tick, 1/256 us
	DB	10			; ticks per period
	DB	1			; ticks between polls
	DB	UG_STEPS		; STEPs per period
	DB	20			; worst STEP gap, ms
	DB	0			; card IRQ entries (no route in v1)
	DW	0			; STEP budget: GET_INFO.min_useful
	DW	0			; STEP_ISR budget: empty poll + return
	DW	100			; service quota
	DW	2000			; target per period
	DW	0			; longest other handler: none
	DB	UGPF_RELAXED
	DB	UNETG_MODE_POLL
	DB	UNETG_TIMING_FIXED_SCHEDULE
	ASSERT	$ - profile == UGP_BYTES

s_magic		DB	"UGTREP1", 0
s_title		DB	"NETDEMO ", 0
s_load		DB	"LOAD ", 0		; UG_LD_*, l_reason, handle, page, base high
s_env		DB	"ENV ", 0		; INIT_CONFIG status, UG_ENV_*, quota sum
s_info		DB	"INFO ", 0
s_hw		DB	"HW RUN", 13, 10, 0
s_open		DB	"OPEN", 13, 10, 0
s_echo		DB	"ECHO ", 0
s_pause		DB	"PAUSE", 13, 10, 0
s_ev		DB	"EV ", 0
s_shut		DB	"SHUTDOWN ", 0
s_gw		DB	"GW ", 0
s_stats		DB	"STATS ", 0
s_unknown	DB	"UNKNOWN_IRQ ", 0
s_timing	DB	"TIMING ", 0		; stopwatch counts of 16 CPU clocks
s_result	DB	"RESULT: ", 0
s_pass		DB	"PASS", 13, 10, 0
s_failr		DB	"FAIL ", 0
s_crlf		DB	13, 10, 0
	IF	UG_ESP
s_at		DB	"AT", 13, 10, 0
s_uartcur	DB	"AT+UART_CUR=115200,8,1,0,3", 13, 10, 0
	ENDIF
dll_name	UG_DLLNAME
cfg_block	UG_CFG_BLOCK

loaded		DB	0
irq_on		DB	0
saved_i		DB	0
exit_lock	DB	0
fail_code	DB	0
last_step	DB	0
deadline	DW	0
n_unknown	DW	0
sw_isr0		DW	0
sw_tick		DW	0
sw_isr_max	DW	0
sw_gap_max	DW	0
sw_late		DW	0
sw_step0	DW	0
sw_step_max	DW	0
tx_total	DW	0
tx_sent		DW	0
tx_tag		DW	1
tx_gen		DB	7
tx_slot		DB	0
rx_count	DW	0
rx_gen		DB	7
rx_bad		DB	0
ev_connected	DB	0
ev_closed	DB	0
ev_peer		DB	0
isa_e2		DB	0
rp_ptr		DW	0
evbuf		DS	8, 0
gstats		DS	80, 0
gwsnap		DS	UGW_SCRATCH, 0

	INCLUDE	"gateway/ugate.asm"
	INCLUDE	"time/ugtime.asm"
	INCLUDE	"libman.asm"
	INCLUDE	"loader/ugload.asm"

code_end
	ASSERT	code_end <= UG_CODE_END, "NETDEMO code runs into the library regions"
	SAVEBIN	"netdemo.exe", exe_header, code_end - exe_header
