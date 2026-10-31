; ugz.asm -- the Z application stand program (tools/harness/appstand.js).
;
; A minimal game around the real SDK modules: IM2 table, CTC1 timer tick,
; frame / key / CBL / card vectors, the gateway, the time adapters and a
; main loop.  The JS stand places the DLL in WIN1 (as the SDK loader would),
; then drives the program through a mailbox: commands run in the main loop
; with interrupts on, exactly as a game would call the SDK.
; Memory: WIN2 0xA000..0xBFFF (the core regions of stand.js below 0x9D00),
; gateway block at the stand's gw region 0x9A00, network ISR stack
; 0x9C00..0x9CFF, main stack top 0x3FF0 in WIN0.

	DEVICE	NOSLOT64K
	INCLUDE	"UNETGAME.INC"

UG_BLOCK	EQU	0x9A00
	DEFINE	UG_DLL_WIN 1
	INCLUDE	"gateway/ugate.inc"

UGZ_I		EQU	0xA0		; IM2 table at 0xA000, every byte 0xA1
MSTACK_TOP	EQU	0x3FF0
P_CTC0		EQU	0x10
P_CTC1		EQU	0x11
P_CTC2		EQU	0x12
P_CTC3		EQU	0x13
CTC1_TIMER	EQU	0xA7		; IE, timer, prescaler 256, constant follows, reset
CTC_COUNTER	EQU	0x57		; counter, constant follows, reset, no interrupt
CTC_RESET	EQU	0x03
V_TICK		EQU	0x02		; CTC1 with vector base 0
V_KEY		EQU	0x20
V_CBL		EQU	0x40
V_CARD		EQU	0x50
V_FRAME		EQU	0xFF		; FPGA frame interrupt (data bus #FF)
GAME_PAGE	EQU	20		; a page the game maps into WIN1 between SDK calls

	ORG	0xA000
im2_table
	DS	257, 0xA1

; ---- mailbox (appstand.js reads the symbols) ----------------------------
mb_cmd		DB	0		; command, 0 when done
mb_a		DB	0
mb_b		DB	0
mb_de		DW	0
mb_ix		DW	0
mb_hl		DW	0
mb_ra		DB	0		; results
mb_rde		DW	0
mb_rhl		DW	0
mb_rf		DB	0		; carry
mb_auto		DB	0		; bit 0: UG_STEP every pass, bit 1: drain events,
					; bit 2: wait for the next interrupt after a pass,
					; bit 3: the "game" keeps page GAME_PAGE in WIN1
mb_irqs		DB	0		; interrupts taken (any vector)
mb_seen		DB	0
mb_n_core	DW	0		; UG_STEP results: core called
mb_n_early	DW	0
mb_n_ref	DW	0
mb_n_off	DW	0
mb_unknown	DW	0		; interrupts without a handler
mb_evhead	DB	0		; event log write index (0..31)
	DS	0xA1A1 - $, 0
	ASSERT	$ == 0xA1A1
isr_default				; every unused vector lands here
	JP	isr_unknown

ugz_start
	DI
	LD	SP,MSTACK_TOP
	IM	1
UGZ_LOOP
	LD	A,(mb_auto)
	BIT	3,A
	JR	Z,.own
	LD	A,GAME_PAGE
	OUT	(0xA2),A		; the game's own page in the DLL window
.own
	LD	A,(mb_cmd)
	OR	A
	CALL	NZ,do_cmd
	LD	A,(mb_auto)
	RRA
	CALL	C,auto_step
	LD	A,(mb_auto)
	BIT	1,A
	CALL	NZ,auto_events
	LD	A,(mb_auto)
	BIT	2,A
	JR	Z,UGZ_LOOP
UGZ_WAIT				; the stand skips the clock to the next interrupt here
	LD	A,(mb_cmd)
	OR	A
	JR	NZ,UGZ_LOOP
	LD	A,(mb_irqs)
	LD	HL,mb_seen
	CP	(HL)
	JR	Z,UGZ_WAIT
	LD	(HL),A
	JR	UGZ_LOOP

auto_step
	CALL	UG_STEP
	LD	HL,mb_n_core
	CP	UG_ST_EARLY
	JR	C,.count
	LD	HL,mb_n_early
	JR	Z,.count
	LD	HL,mb_n_ref
	CP	UG_ST_REFUSED
	JR	Z,.count
	LD	HL,mb_n_off
.count
	JP	UGH_INC

; up to 4 events into the log (8 bytes each, 32 entries at ev_log)
auto_events
	LD	B,4
.next
	PUSH	BC
	LD	A,(mb_evhead)
	LD	L,A
	LD	H,0
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,HL
	LD	DE,ev_log
	ADD	HL,DE
	PUSH	HL
	POP	IX
	LD	B,UNETG_NEXT_EVENT
	CALL	UG_CALL
	POP	BC
	OR	A
	RET	NZ
	LD	HL,mb_evhead
	LD	A,(HL)
	INC	A
	AND	31
	LD	(HL),A
	DJNZ	.next
	RET

; ---- commands -------------------------------------------------------------
do_cmd
	CP	1
	JR	Z,cmd_call
	CP	2
	JR	Z,cmd_env
	CP	3
	JP	Z,cmd_start
	CP	4
	JP	Z,cmd_stop
	CP	5
	JR	Z,cmd_shutdown
	CP	6
	JR	Z,cmd_step
	CP	7
	JR	Z,cmd_gwinit
	CP	8
	JR	Z,cmd_now
	LD	A,0xFF
	JR	cmd_done

; 1: export mb_b with A = mb_a, DE = mb_de, IX = mb_ix
cmd_call
	LD	A,(mb_b)
	LD	B,A
	LD	DE,(mb_de)
	LD	IX,(mb_ix)
	LD	A,(mb_a)
	CALL	UG_CALL
	JR	cmd_done

; 2: UG_INIT_ENV, IX = configuration, HL = profile
cmd_env
	LD	IX,(mb_ix)
	LD	HL,(mb_hl)
	CALL	UG_INIT_ENV
	JR	cmd_done

; 5: UG_SHUTDOWN, DE = timeout ms
cmd_shutdown
	LD	DE,(mb_de)
	CALL	UG_SHUTDOWN
	JR	cmd_done

; 6: one UG_STEP
cmd_step
	CALL	UG_STEP
	JR	cmd_done

; 7: UG_GW_INIT (A = #1FFD, mb_b = #9FBD), UG_ATTACH (mb_de: page, base high)
cmd_gwinit
	LD	A,(mb_b)
	LD	E,A
	LD	A,(mb_a)
	CALL	UG_GW_INIT
	LD	HL,(mb_de)
	LD	A,L
	CALL	UG_ATTACH
	XOR	A
	JR	cmd_done

; 8: UG_NOW
cmd_now
	CALL	UG_NOW
	XOR	A
	; fall through
cmd_done
	LD	(mb_ra),A
	LD	(mb_rde),DE
	LD	(mb_rhl),HL
	LD	A,0
	ADC	A,A
	LD	(mb_rf),A
	XOR	A
	LD	(mb_cmd),A
	RET

; 3: interrupts on: IM2 vectors, CTC1 tick (constant mb_a), CTC2/CTC3
; chain when mb_b bit 0, now_ms = mb_de:mb_hl, UG_START
cmd_start
	DI
	LD	HL,isr_tick
	LD	(im2_table + V_TICK),HL
	LD	HL,isr_key
	LD	(im2_table + V_KEY),HL
	LD	HL,isr_cbl
	LD	(im2_table + V_CBL),HL
	LD	HL,isr_card
	LD	(im2_table + V_CARD),HL
	LD	HL,isr_frame
	LD	(im2_table + V_FRAME),HL
	LD	A,UGZ_I
	LD	I,A
	IM	2
	XOR	A
	OUT	(P_CTC0),A		; vector base 0 (bit 0 = 0: not a control word)
	LD	A,(mb_b)
	RRA
	JR	NC,.clock
	LD	A,CTC_COUNTER
	OUT	(P_CTC2),A
	LD	A,112
	OUT	(P_CTC2),A
	LD	A,CTC_COUNTER
	OUT	(P_CTC3),A
	LD	A,156
	OUT	(P_CTC3),A
.clock
	LD	HL,(mb_hl)
	LD	DE,(mb_de)
	CALL	UGT_INIT
	LD	A,CTC1_TIMER
	OUT	(P_CTC1),A
	LD	A,(mb_a)
	OUT	(P_CTC1),A
	CALL	UG_START
	EI
	XOR	A
	JR	cmd_done

; 4: interrupts off: CTC channels reset, UG_EXIT (A = lock byte), IM 1
cmd_stop
	DI
	XOR	A
	LD	(mb_auto),A		; no more passes that wait for an interrupt
	LD	A,CTC_RESET
	OUT	(P_CTC1),A
	OUT	(P_CTC2),A
	OUT	(P_CTC3),A
	CALL	UG_EXIT
	IM	1
	JP	cmd_done

; ---- interrupt handlers (IFF = 0; EI; RETI only here) ----------------------
isr_tick
	PUSH	AF
	PUSH	BC
	PUSH	DE
	PUSH	HL
	CALL	UG_TICK
	LD	A,UNETG_SRC_TIMER
	CALL	UG_ISR_NET
	CALL	UGT_TICK
	JR	isr_out
isr_frame
	PUSH	AF
	PUSH	BC
	PUSH	DE
	PUSH	HL
	CALL	UG_ISR_FRAME
	JR	isr_out
isr_key
	PUSH	AF
	PUSH	BC
	PUSH	DE
	PUSH	HL
	CALL	UG_ISR_KEY
	JR	isr_out
isr_cbl
	PUSH	AF
	PUSH	BC
	PUSH	DE
	PUSH	HL
	CALL	UG_ISR_CBL
	JR	isr_out
isr_card
	PUSH	AF
	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD	A,UNETG_SRC_CARD_IRQ
	CALL	UG_ISR_NET
isr_out
	LD	HL,mb_irqs
	INC	(HL)
	POP	HL
	POP	DE
	POP	BC
	POP	AF
	EI
UGZ_RETI
	RETI
isr_unknown
	PUSH	AF
	PUSH	HL
	LD	HL,mb_unknown
	CALL	UGH_INC
	POP	HL
	POP	AF
	EI
	RETI

	INCLUDE	"gateway/ugate.asm"
	INCLUDE	"time/ugtime.asm"

	ALIGN	256
ev_log
	DS	256, 0
ugz_end
	ASSERT	ugz_end <= 0xC000
	SAVEBIN	"ugz.bin", 0xA000, ugz_end - 0xA000
