; ugate.asm -- UNET-GAME SDK gateway (ТЗ §2, §4-§5, §7; ABI §1).
;
; Direct calls of the relocated DLL, the INIT_CONFIG preparation from the
; application profile and GET_INFO, fixed per-period quotas with the debit
; taken before every entry, the ISA try-lock with pre-acquire for the ISR
; entries, the network ISR stack, the budget period clock and the exit.
;
; v1 boards wire no ISA IRQ to the PIO: the gateway never writes the PIO or
; the CTC (the application owns both); MASK_ROUTE and an exhausted card
; quota set a software route mask only.  Requires ugate.inc (UG_BLOCK,
; UG_DLL_WIN) and UNETGAME.INC.  Costs are T-states at 21 MHz; see
; docs/SDK.md for the measured bounds.

; ----------------------------------------------------------------------
; UG_GW_INIT: zero the gateway block, free lock, shadows.  Before any
; interrupt handler that enters the gateway is installed.
; In: A = current #1FFD value, E = current #9FBD value.
; Clobbers AF, BC, DE, HL.
; ----------------------------------------------------------------------
UG_GW_INIT
	LD	B,A
	LD	C,E
	PUSH	BC
	LD	HL,UG_BLOCK
	LD	DE,UG_BLOCK + 1
	LD	BC,UGW_BYTES - 1
	LD	(HL),0
	LDIR
	POP	BC
	LD	A,B
	LD	(UG_BLOCK + UGW_SH1FFD),A
	LD	A,C
	LD	(UG_BLOCK + UGW_SH9FBD),A
	LD	A,0xFF
	LD	(UG_BLOCK + UGW_HANDLE),A
	LD	A,1 << UGF2_NOISR
	LD	(UG_BLOCK + UGW_FLAGS2),A	; no ISR entries before UG_START
	RET

; UG_ATTACH: the DLL is relocated for window UG_DLL_WIN at base H*256 in
; physical page A (the SDK loader or a program that placed it itself).
; Clobbers AF, HL.
UG_ATTACH
	LD	(UG_BLOCK + UGW_PAGE),A
	LD	A,H
	LD	(UG_BLOCK + UGW_BASEH),A
	LD	L,UNETG_STEP_ISR_OFS
	LD	(UG_BLOCK + UGW_EP_ISR),HL
	LD	HL,UG_BLOCK + UGW_FLAGS
	SET	UGF_ATTACHED,(HL)
	RET

; ----------------------------------------------------------------------
; UG_CALL: direct call of DLL export B (ABI: entry = base + 0x20 + 3*B),
; without DSS.  The DLL page is mapped into UG_DLL_WIN when the window
; holds another page (a timer ISR may come while the game uses it) and the
; previous page is restored after the call.
; In: B = export index; A, DE, IX, IY as the export expects.
; Out: A, DE, HL, F as the export returns them; IX, IY as the export
;      leaves them (preserved by every game export).
; Clobbers BC.  Stack: 4 + the export.  Cost: ~120 T besides the export.
; ----------------------------------------------------------------------
UG_CALL
	PUSH	AF
	LD	A,B
	ADD	A,A
	ADD	A,B
	ADD	A,0x20
	LD	L,A
	LD	A,(UG_BLOCK + UGW_BASEH)
	LD	H,A			; HL = jump table entry
	IN	A,(UG_WINPORT)
	LD	C,A			; page in the window now
	LD	A,(UG_BLOCK + UGW_PAGE)
	CP	C
	JR	NZ,.switch
	POP	AF
	JP	(HL)			; mapped already: the export returns to our caller
.switch
	OUT	(UG_WINPORT),A
	POP	AF
	PUSH	BC			; C = the page to restore
	CALL	.jp
	EX	(SP),HL			; HL = saved BC, the export's HL on the stack
	PUSH	AF
	LD	A,L
	OUT	(UG_WINPORT),A
	POP	AF
	POP	HL
	RET
.jp
	JP	(HL)

; ----------------------------------------------------------------------
; UG_INIT_ENV: GET_INFO, budgets and quotas from the profile, the gateway
; fields of INIT_CONFIG, then INIT_CONFIG (ТЗ §2 INIT_ENV, §5.1).
; In: IX = INIT_CONFIG block filled by the application (card, addresses,
;     regions, timeouts, ISR stack); HL = profile (UGP_*).
; The gateway fills: mode, timing_mode, worst_poll_gap_us,
; worst_step_gap_ms, step_budget_us, isr_budget_us, time_read_cost_us,
; isa_lock_ptr and the two shadow pointers.
; Out: A = INIT_CONFIG status, or UNSUPPORTED_TIMING / BAD_CONFIG when the
;      gateway refuses first; UGW_ENV = UG_ENV_*; UGW_SUM = quota sum.
; Main loop, before UG_START.  Preserves IX, IY.  Clobbers BC, DE, HL.
; ----------------------------------------------------------------------
UG_INFO		EQU	UG_BLOCK + UGW_SCRATCH
UG_INIT_ENV
	PUSH	IY
	PUSH	HL
	POP	IY			; IY = profile
	LD	A,(IY+UGP_PERIOD_TICKS)
	OR	A
	JR	Z,.bad_profile
	LD	A,(IY+UGP_POLL_TICKS)
	OR	A
	JR	Z,.bad_profile
	LD	A,(IY+UGP_STEPS)
	OR	A
	JR	Z,.bad_profile
	CALL	UGH_ISR_TOP
	LD	A,D
	OR	E
	JR	NZ,.info
.bad_profile
	LD	C,UG_ENV_PROFILE
	LD	A,UNETG_STATUS_BAD_CONFIG
	JP	.fail
.info
	PUSH	IX
	LD	IX,UG_INFO
	LD	DE,UNETG_INFO_BYTES
	LD	B,UNETG_GET_INFO
	CALL	UG_CALL
	POP	IX
	OR	A
	LD	C,UG_ENV_INFO
	JP	NZ,.fail
	; STEP body budget: profile or min_useful; min_useful <= b <= body max
	LD	L,(IY+UGP_STEP_BUDGET)
	LD	H,(IY+UGP_STEP_BUDGET+1)
	LD	A,H
	OR	L
	JR	NZ,.sb
	LD	HL,(UG_INFO + UNETG_INFO_MIN_USEFUL_BUDGET_US)
.sb
	LD	(UG_BLOCK + UGW_STEP_BUDGET),HL
	EX	DE,HL
	LD	HL,(UG_INFO + UNETG_INFO_MIN_USEFUL_BUDGET_US)
	OR	A
	SBC	HL,DE
	JR	Z,.sb_min
	JR	NC,.bad_budget		; budget below min_useful
.sb_min
	LD	HL,(UG_INFO + UNETG_INFO_STEP_BODY_MAX_US)
	OR	A
	SBC	HL,DE
	JR	C,.bad_budget
	; STEP_ISR body budget: profile or empty poll + minimum return
	LD	L,(IY+UGP_ISR_BUDGET)
	LD	H,(IY+UGP_ISR_BUDGET+1)
	LD	A,H
	OR	L
	JR	NZ,.ib
	LD	HL,(UG_INFO + UNETG_INFO_EMPTY_POLL_US)
	LD	DE,(UG_INFO + UNETG_INFO_MIN_RETURN_US)
	ADD	HL,DE
.ib
	LD	(UG_BLOCK + UGW_ISR_BUDGET),HL
	EX	DE,HL
	LD	HL,(UG_INFO + UNETG_INFO_ISR_BODY_MAX_US)
	OR	A
	SBC	HL,DE
	JR	NC,.costs
.bad_budget
	LD	C,UG_ENV_BUDGET
	LD	A,UNETG_STATUS_UNSUPPORTED_TIMING
	JP	.fail
.costs
	; full upper costs = body budget + the gateway's own path
	LD	HL,(UG_BLOCK + UGW_ISR_BUDGET)
	LD	DE,UG_OVH_ISR_US
	ADD	HL,DE
	LD	(UG_BLOCK + UGW_COST_POLL),HL
	LD	HL,(UG_BLOCK + UGW_STEP_BUDGET)
	LD	DE,UG_OVH_STEP_US
	ADD	HL,DE
	LD	(UG_BLOCK + UGW_COST_STEP),HL
	LD	HL,UG_BUSY_PATH_US
	LD	(UG_BLOCK + UGW_COST_BUSY),HL
	LD	HL,UG_REFUSE_US
	LD	(UG_BLOCK + UGW_COST_REFUSE),HL
	; schedule
	LD	A,(IY+UGP_PERIOD_TICKS)
	LD	(UG_BLOCK + UGW_PERIOD_TICKS),A
	LD	(UG_BLOCK + UGW_TICK_CNT),A
	LD	A,(IY+UGP_POLL_TICKS)
	LD	(UG_BLOCK + UGW_POLL_TICKS),A
	LD	(UG_BLOCK + UGW_POLL_CNT),A
	LD	A,(IY+UGP_PERIOD_TICKS)
	LD	C,(IY+UGP_STEPS)
	CALL	UGH_DIV			; B = ticks between STEPs
	LD	A,B
	OR	A
	JR	NZ,.spacing
	INC	A
.spacing
	LD	(UG_BLOCK + UGW_SPACING),A
	LD	A,0xFF
	LD	(UG_BLOCK + UGW_STEP_AGE),A	; the first STEP is admitted
	LD	L,(IY+UGP_TICK_US)
	LD	H,(IY+UGP_TICK_US+1)
	LD	(UG_BLOCK + UGW_TICK_US),HL
	LD	DE,1000			; tick = TICK_MS ms + TICK_REM us
	LD	B,0
.tick_ms
	OR	A
	SBC	HL,DE
	JR	C,.tick_rem
	INC	B
	JR	.tick_ms
.tick_rem
	ADD	HL,DE
	LD	(UG_BLOCK + UGW_TICK_REM),HL
	LD	A,B
	LD	(UG_BLOCK + UGW_TICK_MS),A
	LD	A,(IY+UGP_TICK_FRAC)
	LD	(UG_BLOCK + UGW_TICK_FRAC),A
	LD	A,(IY+UGP_TIMING)
	LD	(UG_BLOCK + UGW_TIMING),A
	; quotas per period
	LD	A,(IY+UGP_PERIOD_TICKS)
	LD	C,(IY+UGP_POLL_TICKS)
	CALL	UGH_DIV			; B = guaranteed polls per period
	LD	DE,(UG_BLOCK + UGW_COST_POLL)
	CALL	UGH_MUL
	LD	(UG_BLOCK + UGW_QFULL + UGQ_POLL),HL
	LD	B,(IY+UGP_CARD_N)
	CALL	UGH_MUL
	LD	(UG_BLOCK + UGW_QFULL + UGQ_CARD),HL
	LD	B,(IY+UGP_STEPS)
	LD	DE,(UG_BLOCK + UGW_COST_STEP)
	CALL	UGH_MUL
	LD	(UG_BLOCK + UGW_QFULL + UGQ_MAIN),HL
	LD	L,(IY+UGP_Q_SERVICE)
	LD	H,(IY+UGP_Q_SERVICE+1)
	LD	(UG_BLOCK + UGW_QFULL + UGQ_SERVICE),HL
	; sum of the quotas against the target
	LD	DE,(UG_BLOCK + UGW_QFULL + UGQ_POLL)
	ADD	HL,DE
	JR	C,.sat
	LD	DE,(UG_BLOCK + UGW_QFULL + UGQ_CARD)
	ADD	HL,DE
	JR	C,.sat
	LD	DE,(UG_BLOCK + UGW_QFULL + UGQ_MAIN)
	ADD	HL,DE
	JR	NC,.sum
.sat
	LD	HL,0xFFFF
.sum
	LD	(UG_BLOCK + UGW_SUM),HL
	EX	DE,HL
	LD	L,(IY+UGP_TARGET)
	LD	H,(IY+UGP_TARGET+1)
	OR	A
	SBC	HL,DE
	LD	C,UG_ENV_OK
	JR	NC,.within
	LD	C,UG_ENV_OVER
	BIT	0,(IY+UGP_FLAGS)	; UGPF_RELAXED
	JR	NZ,.over_ok
	LD	C,UG_ENV_REFUSED
	LD	A,UNETG_STATUS_UNSUPPORTED_TIMING
	JP	.fail
.over_ok
	LD	HL,UG_BLOCK + UGW_FLAGS
	SET	UGF_OVER,(HL)
.within
	PUSH	BC			; [env code]
	; worst poll gap: poll ticks (rounded up) + the longest DI section of
	; the network + the longest other handler; within GET_INFO.poll_gap_us
	LD	B,(IY+UGP_POLL_TICKS)
	LD	DE,(UG_BLOCK + UGW_TICK_US)
	INC	DE
	CALL	UGH_MUL
	LD	DE,UG_DI_MARGIN_US
	ADD	HL,DE
	LD	E,(IY+UGP_OTHER_ISR)
	LD	D,(IY+UGP_OTHER_ISR+1)
	ADD	HL,DE
	PUSH	HL
	EX	DE,HL
	LD	HL,(UG_INFO + UNETG_INFO_POLL_GAP_US)
	OR	A
	SBC	HL,DE
	POP	HL
	JR	NC,.gap_ok
	POP	BC
	LD	C,UG_ENV_GAP
	LD	A,UNETG_STATUS_UNSUPPORTED_TIMING
	JP	.fail
.gap_ok
	; the gateway's fields of INIT_CONFIG
	LD	(IX+UNETG_CFG_WORST_POLL_GAP_US),L
	LD	(IX+UNETG_CFG_WORST_POLL_GAP_US+1),H
	LD	A,(IY+UGP_STEP_GAP_MS)
	LD	(IX+UNETG_CFG_WORST_STEP_GAP_MS),A
	LD	(IX+UNETG_CFG_WORST_STEP_GAP_MS+1),0
	LD	HL,(UG_BLOCK + UGW_STEP_BUDGET)
	LD	(IX+UNETG_CFG_STEP_BUDGET_US),L
	LD	(IX+UNETG_CFG_STEP_BUDGET_US+1),H
	LD	HL,(UG_BLOCK + UGW_ISR_BUDGET)
	LD	(IX+UNETG_CFG_ISR_BUDGET_US),L
	LD	(IX+UNETG_CFG_ISR_BUDGET_US+1),H
	LD	A,(IY+UGP_MODE)
	LD	(IX+UNETG_CFG_MODE),A
	LD	A,(IY+UGP_TIMING)
	LD	(IX+UNETG_CFG_TIMING_MODE),A
	LD	(IX+UNETG_CFG_TIME_READ_COST_US),UGT_READ_US
	LD	(IX+UNETG_CFG_TIME_READ_COST_US+1),0
	LD	HL,UG_BLOCK + UGW_LOCK
	LD	(IX+UNETG_CFG_ISA_LOCK_PTR),L
	LD	(IX+UNETG_CFG_ISA_LOCK_PTR+1),H
	INC	HL
	LD	(IX+UNETG_CFG_SHADOW_1FFD_PTR),L
	LD	(IX+UNETG_CFG_SHADOW_1FFD_PTR+1),H
	INC	HL
	LD	(IX+UNETG_CFG_SHADOW_9FBD_PTR),L
	LD	(IX+UNETG_CFG_SHADOW_9FBD_PTR+1),H
	CALL	UGH_ISR_TOP
	LD	(UG_BLOCK + UGW_ISR_TOP),HL
	BIT	1,(IY+UGP_FLAGS)	; UGPF_FRAME_PER
	JR	Z,.first
	LD	HL,UG_BLOCK + UGW_FLAGS
	SET	UGF_FRAME_PER,(HL)
.first
	LD	HL,UG_BLOCK + UGW_QFULL
	LD	DE,UG_BLOCK + UGW_Q
	LD	BC,8
	LDIR
	LD	B,UNETG_INIT_CONFIG
	CALL	UG_CALL
	POP	BC			; C = env code
	OR	A
	JR	Z,.configured
	LD	C,UG_ENV_CONFIG
	JR	.fail
.configured
	LD	HL,UG_BLOCK + UGW_FLAGS
	SET	UGF_CONFIGURED,(HL)
.fail
	LD	B,A
	LD	A,C
	LD	(UG_BLOCK + UGW_ENV),A
	LD	A,B
	POP	IY
	RET

; UGH_ISR_TOP: HL = INIT_CONFIG(IX).isr_stack_ptr + isr_stack_len, DE =
; the length (offsets above +127: through HL).  Clobbers A.
UGH_ISR_TOP
	PUSH	IX
	POP	HL
	LD	DE,UNETG_CFG_ISR_STACK_PTR
	ADD	HL,DE
	LD	A,(HL)
	INC	HL
	LD	D,(HL)
	INC	HL
	LD	E,A			; DE = pointer
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A			; HL = length
	EX	DE,HL
	ADD	HL,DE
	RET

; UGH_DIV: B = A / C (C >= 1, by subtraction: INIT only).  Clobbers A.
UGH_DIV
	LD	B,0
.loop
	SUB	C
	RET	C
	INC	B
	JR	.loop

; UGH_MUL: HL = DE * B, saturating at 0xFFFF.  Preserves DE.  Clobbers B.
UGH_MUL
	LD	HL,0
	INC	B
	JR	.next
.add
	ADD	HL,DE
	JR	C,.sat
.next
	DJNZ	.add
	RET
.sat
	LD	HL,0xFFFF
	RET

; UGH_QSUB: u16 at HL -= DE, saturating at 0.  Preserves HL, DE.
; Clobbers A.
UGH_QSUB
	LD	A,(HL)
	SUB	E
	LD	(HL),A
	INC	HL
	LD	A,(HL)
	SBC	A,D
	LD	(HL),A
	DEC	HL
	RET	NC
	XOR	A
	LD	(HL),A
	INC	HL
	LD	(HL),A
	DEC	HL
	RET

; UGH_DEBIT: debit of the period += DE, saturating.  Preserves DE.
; Clobbers HL, F.
UGH_DEBIT
	LD	HL,(UG_BLOCK + UGW_DEBIT)
	ADD	HL,DE
	JR	NC,.store
	LD	HL,0xFFFF
.store
	LD	(UG_BLOCK + UGW_DEBIT),HL
	RET

; UGH_INC: u16 counter at HL += 1.  Clobbers HL, F.
UGH_INC
	INC	(HL)
	RET	NZ
	INC	HL
	INC	(HL)
	RET

; ----------------------------------------------------------------------
; UG_START / UG_STOP: budget periods, admission and ISR entries on / off.
; UG_START after UG_INIT_ENV, with the tick handler installed.
; ----------------------------------------------------------------------
UG_START
	XOR	A
	LD	(UG_BLOCK + UGW_FLAGS2),A
	LD	HL,UG_BLOCK + UGW_FLAGS
	SET	UGF_RUN,(HL)
	RET
UG_STOP
	LD	HL,UG_BLOCK + UGW_FLAGS2
	SET	UGF2_NOISR,(HL)
	LD	HL,UG_BLOCK + UGW_FLAGS
	RES	UGF_RUN,(HL)
	RET

; ----------------------------------------------------------------------
; UG_NOW: HL = now_ms[15:0], DE = now_ms[31:16] (main loop).
; FIXED_SCHEDULE: read in one DI section; APP_COUNTER: the published counts
; turned into ms (UGT_NOW_CTC).  Restores the caller's IFF.  Clobbers AF, B.
; ----------------------------------------------------------------------
UG_NOW
	LD	A,(UG_BLOCK + UGW_TIMING)
	CP	UNETG_TIMING_APP_COUNTER
	JP	Z,UGT_NOW_CTC
	LD	A,I
	JP	PE,.on
	LD	A,I			; LD A,I erratum: sample IFF2 twice
.on
	PUSH	AF
	DI
	LD	HL,(UG_BLOCK + UGW_NOW)
	LD	DE,(UG_BLOCK + UGW_NOW + 2)
	POP	AF
	RET	PO
	EI
	RET

; ----------------------------------------------------------------------
; UG_STEP: one STEP from the main quota (ТЗ §5.1, §7 item 3).  Under one
; short DI section: spacing (at most one STEP per UGW_SPACING ticks,
; spread over the period for max_step_gap_ms), main quota, full debit,
; the active-call record and now_ms.  The STEP runs with interrupts as
; the caller had them and without pre-acquire: the core locks the bus per
; portion, so the sound owner is not blocked for a whole STEP.
; Out: A = core status, DE = deadline, L = flags; or A = UG_ST_EARLY /
;      UG_ST_REFUSED / UG_ST_OFF (nothing called, DE = last deadline).
; Preserves IX, IY.  Clobbers BC, HL.  Restores the caller's IFF.
; ----------------------------------------------------------------------
UG_STEP
	LD	A,(UG_BLOCK + UGW_FLAGS)
	BIT	UGF_RUN,A
	LD	A,UG_ST_OFF
	RET	Z
	PUSH	IX
	PUSH	IY
	LD	A,I
	JP	PE,.on
	LD	A,I
.on
	PUSH	AF			; P/V = IFF2 of the caller
	DI
	LD	HL,(UG_BLOCK + UGW_DEBIT_LAST)	; diagnostic: largest period debit
	LD	DE,(UG_BLOCK + UGW_DEBIT_MAX)
	OR	A
	SBC	HL,DE
	JR	C,.age
	ADD	HL,DE
	LD	(UG_BLOCK + UGW_DEBIT_MAX),HL
.age
	LD	A,(UG_BLOCK + UGW_STEP_AGE)
	LD	HL,UG_BLOCK + UGW_SPACING
	CP	(HL)
	JR	C,.early
	LD	HL,(UG_BLOCK + UGW_Q + UGQ_MAIN)
	LD	DE,(UG_BLOCK + UGW_COST_STEP)
	OR	A
	SBC	HL,DE
	JR	C,.refuse
	LD	(UG_BLOCK + UGW_Q + UGQ_MAIN),HL
	LD	(UG_BLOCK + UGW_ACTIVE),DE
	CALL	UGH_DEBIT
	XOR	A
	LD	(UG_BLOCK + UGW_STEP_AGE),A
	LD	HL,UG_BLOCK + UGW_STATS + UGS_STEP
	CALL	UGH_INC
	LD	IX,(UG_BLOCK + UGW_NOW)		; FIXED_SCHEDULE: the tick ISR's now_ms
	LD	IY,(UG_BLOCK + UGW_NOW + 2)
	POP	AF
	JP	PO,.clock
	EI
.clock
	LD	A,(UG_BLOCK + UGW_TIMING)
	CP	UNETG_TIMING_APP_COUNTER
	JR	NZ,.call
	CALL	UGT_NOW_CTC			; APP_COUNTER: counts -> ms in main
	PUSH	HL
	POP	IX
	PUSH	DE
	POP	IY
.call
	LD	DE,(UG_BLOCK + UGW_STEP_BUDGET)
	XOR	A			; A bit 0 = 0: no pre-acquire
	LD	B,UNETG_STEP
	CALL	UG_CALL
	LD	(UG_BLOCK + UGW_STEP_A),A
	LD	(UG_BLOCK + UGW_STEP_DE),DE
	LD	B,A
	LD	A,L
	LD	(UG_BLOCK + UGW_STEP_L),A
	PUSH	HL
	LD	HL,0
	LD	(UG_BLOCK + UGW_ACTIVE),HL	; one store: the period sees 0 or the cost
	POP	HL
	LD	A,B
	POP	IY
	POP	IX
	RET
.early
	LD	HL,UG_BLOCK + UGW_STATS + UGS_EARLY
	CALL	UGH_INC
	LD	B,UG_ST_EARLY
	JR	.leave
.refuse
	LD	DE,(UG_BLOCK + UGW_COST_REFUSE)
	LD	HL,UG_BLOCK + UGW_Q + UGQ_SERVICE
	CALL	UGH_QSUB
	CALL	UGH_DEBIT
	LD	HL,UG_BLOCK + UGW_STATS + UGS_REFUSE
	CALL	UGH_INC
	LD	B,UG_ST_REFUSED
.leave
	POP	AF
	JP	PO,.quiet
	EI
.quiet
	LD	DE,(UG_BLOCK + UGW_STEP_DE)
	LD	A,B
	POP	IY
	POP	IX
	RET

; ----------------------------------------------------------------------
; UG_TICK: the timer tick (application timer ISR, IFF = 0, before
; UG_ISR_NET): tick count, STEP spacing age, the guaranteed poll schedule,
; the CBL pending flag and, unless the frame drives it, the budget period.
; Clobbers AF, DE, HL.  Cost: ~170 T, ~500 T with a period boundary.
; ----------------------------------------------------------------------
UG_TICK
	LD	HL,UG_BLOCK + UGW_FLAGS
	BIT	UGF_RUN,(HL)
	RET	Z
	LD	DE,(UG_BLOCK + UGW_STATS + UGS_TICKS)
	INC	DE
	LD	(UG_BLOCK + UGW_STATS + UGS_TICKS),DE
	LD	A,(UG_BLOCK + UGW_STEP_AGE)
	INC	A
	JR	Z,.age			; saturate at 255
	LD	(UG_BLOCK + UGW_STEP_AGE),A
.age
	BIT	UGF_CBL,(HL)
	JR	NZ,.cbl
	LD	A,(UG_BLOCK + UGW_POLL_CNT)
	DEC	A
	JR	NZ,.count
	BIT	UGF_POLL_DUE,(HL)
	SET	UGF_POLL_DUE,(HL)
	CALL	NZ,.late
	LD	A,(UG_BLOCK + UGW_POLL_TICKS)
.count
	LD	(UG_BLOCK + UGW_POLL_CNT),A
.period
	BIT	UGF_FRAME_PER,(HL)
	RET	NZ
	LD	HL,UG_BLOCK + UGW_TICK_CNT
	DEC	(HL)
	RET	NZ
	LD	A,(UG_BLOCK + UGW_PERIOD_TICKS)
	LD	(HL),A
	JR	UG_PERIOD
.late
	PUSH	HL
	LD	HL,UG_BLOCK + UGW_STATS + UGS_LATE
	CALL	UGH_INC
	POP	HL
	RET
.cbl
	; a CBL flag: poll now instead of at the next scheduled tick (the
	; number of guaranteed polls per period does not grow)
	RES	UGF_CBL,(HL)
	SET	UGF_POLL_DUE,(HL)
	LD	A,(UG_BLOCK + UGW_POLL_TICKS)
	LD	(UG_BLOCK + UGW_POLL_CNT),A
	LD	DE,UG_FLAG_US
	LD	HL,UG_BLOCK + UGW_Q + UGQ_SERVICE
	CALL	UGH_QSUB
	CALL	UGH_DEBIT
	LD	HL,UG_BLOCK + UGW_FLAGS
	JR	.period

; UG_PERIOD: budget period boundary (IFF = 0).  Every quota starts full,
; the main one minus the full cost of a STEP still running (it is paid in
; both periods); unused quota is not carried over.  Clobbers AF, DE, HL.
; Cost: ~270 T.
UG_PERIOD
	LD	HL,(UG_BLOCK + UGW_PERIOD_NO)
	INC	HL
	LD	(UG_BLOCK + UGW_PERIOD_NO),HL
	LD	HL,(UG_BLOCK + UGW_DEBIT)
	LD	(UG_BLOCK + UGW_DEBIT_LAST),HL
	LD	HL,(UG_BLOCK + UGW_QFULL + UGQ_POLL)
	LD	(UG_BLOCK + UGW_Q + UGQ_POLL),HL
	LD	HL,(UG_BLOCK + UGW_QFULL + UGQ_CARD)
	LD	(UG_BLOCK + UGW_Q + UGQ_CARD),HL
	LD	HL,(UG_BLOCK + UGW_QFULL + UGQ_SERVICE)
	LD	(UG_BLOCK + UGW_Q + UGQ_SERVICE),HL
	LD	DE,(UG_BLOCK + UGW_ACTIVE)
	LD	HL,(UG_BLOCK + UGW_QFULL + UGQ_MAIN)
	OR	A
	SBC	HL,DE
	JR	NC,.main
	LD	HL,0
.main
	LD	(UG_BLOCK + UGW_Q + UGQ_MAIN),HL
	LD	(UG_BLOCK + UGW_DEBIT),DE
UG_PERIOD_RET				; (stand probe: quotas of the new period)
	RET

; ----------------------------------------------------------------------
; UG_ISR_NET: network entry from an application ISR (IFF = 0, after the
; handler's own device; never EI).  A = UNETG_SRC_TIMER / KEY / FRAME (the
; guaranteed poll when it is due, poll quota) or UNETG_SRC_CARD_IRQ (card
; quota, not while the route is masked).  Before the core: quota, then the
; try-lock (owner 2); a held bus pays UG_BUSY_PATH_US from the source
; quota and the core is not entered; a short quota pays UG_REFUSE_US from
; the service quota (a card source is masked).  Admitted: full debit, the
; network ISR stack, STEP_ISR(source | PREACQ, body budget), lock release
; after the core restored mapping and shadows.
; Any STEP_ISR entry samples the card, so it also counts as the guaranteed
; poll of the tick.  Clobbers AF, BC, DE, HL.  Preserves IX, IY.
; Stack: 2 on the interrupted stack, 4 + STEP_ISR on the ISR stack.
; ----------------------------------------------------------------------
UG_ISR_NET
	LD	C,A
	LD	A,(UG_BLOCK + UGW_FLAGS2)
	OR	A
	RET	NZ			; not started, SHUTDOWN or exit
	LD	HL,UG_BLOCK + UGW_FLAGS
	LD	A,C
	CP	UNETG_SRC_CARD_IRQ
	JR	Z,.card
	BIT	UGF_POLL_DUE,(HL)
	RET	Z
	LD	HL,UG_BLOCK + UGW_Q + UGQ_POLL
	JR	.quota
.card
	BIT	UGF_MASKED,(HL)
	RET	NZ
	LD	HL,UG_BLOCK + UGW_Q + UGQ_CARD
.quota
	LD	DE,(UG_BLOCK + UGW_COST_POLL)
	LD	A,(HL)
	SUB	E
	LD	B,A
	INC	HL
	LD	A,(HL)
	SBC	A,D
	JP	C,.refuse
	LD	E,A			; the new quota, kept until the lock is ours
	LD	A,(UG_BLOCK + UGW_LOCK)
	OR	A
	JP	NZ,.busy
	LD	A,UNETG_LOCK_NET_ISR	; IFF = 0: test-and-set is indivisible
	LD	(UG_BLOCK + UGW_LOCK),A
	LD	(HL),E
	DEC	HL
	LD	(HL),B
	LD	HL,(UG_BLOCK + UGW_DEBIT)	; a period's debits stay far below 64 K
	LD	DE,(UG_BLOCK + UGW_COST_POLL)
	ADD	HL,DE
	LD	(UG_BLOCK + UGW_DEBIT),HL
	LD	HL,UG_BLOCK + UGW_FLAGS
	RES	UGF_POLL_DUE,(HL)	; every STEP_ISR samples the card: the poll is done
	; STEP_ISR on the network ISR stack with the DLL page in its window
	LD	(UG_BLOCK + UGW_ISR_SP),SP
	LD	SP,(UG_BLOCK + UGW_ISR_TOP)
	IN	A,(UG_WINPORT)
	LD	B,A
	PUSH	BC			; B = page to restore, C = source
	LD	A,(UG_BLOCK + UGW_PAGE)
	CP	B
	JR	Z,.mapped
	OUT	(UG_WINPORT),A
.mapped
	LD	HL,.back
	PUSH	HL
	LD	HL,(UG_BLOCK + UGW_EP_ISR)
	LD	DE,(UG_BLOCK + UGW_ISR_BUDGET)
	LD	A,C
	OR	UNETG_SRC_FLAG_PREACQ
	JP	(HL)
.back
	POP	BC
	LD	E,A
	LD	A,B
	OUT	(UG_WINPORT),A
	LD	SP,(UG_BLOCK + UGW_ISR_SP)
	LD	A,E
	LD	(UG_BLOCK + UGW_ISR_A),A
	XOR	A
	LD	(UG_BLOCK + UGW_LOCK),A	; after the core restored mapping and shadows
	BIT	0,L			; UNETG_FLAG_MASK_ROUTE
	JR	NZ,.mask
	LD	HL,UG_BLOCK + UGW_FLAGS
	BIT	UGF_MASKED,(HL)
	RET	Z
	; a successful poll in a later period lifts the software route mask
	; (ТЗ §5.1: the card is checked by a poll before IRQs are allowed)
	LD	A,C
	CP	UNETG_SRC_CARD_IRQ
	RET	Z
	LD	A,(UG_BLOCK + UGW_PERIOD_NO)
	LD	HL,UG_BLOCK + UGW_MASK_PER
	CP	(HL)
	RET	Z
	LD	HL,UG_BLOCK + UGW_FLAGS
	RES	UGF_MASKED,(HL)
	RET
.mask
	LD	HL,UG_BLOCK + UGW_FLAGS
	SET	UGF_MASKED,(HL)
	LD	A,(UG_BLOCK + UGW_PERIOD_NO)
	LD	(UG_BLOCK + UGW_MASK_PER),A
	LD	HL,UG_BLOCK + UGW_STATS + UGS_MASK
	JP	UGH_INC
.busy
	DEC	HL			; HL -> the source quota
	LD	DE,(UG_BLOCK + UGW_COST_BUSY)
	CALL	UGH_QSUB
	CALL	UGH_DEBIT
	LD	HL,UG_BLOCK + UGW_STATS + UGS_BUSY
	JP	UGH_INC
.refuse
	LD	A,C
	CP	UNETG_SRC_CARD_IRQ
	CALL	Z,.mask
	LD	DE,(UG_BLOCK + UGW_COST_REFUSE)
	LD	HL,UG_BLOCK + UGW_Q + UGQ_SERVICE
	CALL	UGH_QSUB
	CALL	UGH_DEBIT
	LD	HL,UG_BLOCK + UGW_STATS + UGS_REFUSE
	JP	UGH_INC

; UG_ISR_FRAME: frame interrupt (IFF = 0): count, the budget period when
; the profile puts it on the frame, then an extra poll opportunity.
; Clobbers AF, BC, DE, HL.
UG_ISR_FRAME
	LD	HL,UG_BLOCK + UGW_STATS + UGS_FRAMES
	CALL	UGH_INC
	LD	HL,UG_BLOCK + UGW_FLAGS
	BIT	UGF_RUN,(HL)
	RET	Z
	BIT	UGF_FRAME_PER,(HL)
	CALL	NZ,UG_PERIOD
	LD	A,UNETG_SRC_FRAME
	JP	UG_ISR_NET

; UG_ISR_KEY: keyboard interrupt (IFF = 0): an extra poll opportunity when
; the guaranteed poll is still due (busy bus at the tick).
UG_ISR_KEY
	LD	HL,UG_BLOCK + UGW_STATS + UGS_KEY
	CALL	UGH_INC
	LD	A,UNETG_SRC_KEY
	JP	UG_ISR_NET

; UG_ISR_CBL: sound interrupt (IFF = 0): only the pending flag (ТЗ §3);
; the next tick turns it into the guaranteed poll.  Clobbers F, HL.
UG_ISR_CBL
	LD	HL,UG_BLOCK + UGW_FLAGS
	SET	UGF_CBL,(HL)
	LD	HL,UG_BLOCK + UGW_STATS + UGS_CBL
	JP	UGH_INC

; ----------------------------------------------------------------------
; UG_SHUTDOWN: stop new ISR entries, then SHUTDOWN until OK (ТЗ §7 item 5):
; on WORK keep STEP from the main quota and drain the events, at most DE
; ms.  Main loop, interrupts on (the ticks move now_ms and the periods).
; Out: A = OK, or the last SHUTDOWN status on timeout.
; Preserves IX, IY.  Clobbers BC, DE, HL.
; ----------------------------------------------------------------------
UG_SHUTDOWN
	LD	HL,UG_BLOCK + UGW_FLAGS2
	SET	UGF2_NOISR,(HL)
	PUSH	IX
	PUSH	DE
	CALL	UG_NOW
	POP	DE
	ADD	HL,DE
	PUSH	HL			; [deadline, low 16 bits]
.again
	LD	B,UNETG_SHUTDOWN
	CALL	UG_CALL
	OR	A
	JR	Z,.done
	LD	C,A
	PUSH	BC
	CALL	UG_STEP
	CALL	UG_DRAIN
	CALL	UG_NOW
	POP	BC
	POP	DE
	PUSH	DE
	OR	A
	SBC	HL,DE
	BIT	7,H			; now - deadline < 0: keep going
	JR	NZ,.again
	LD	A,C
.done
	POP	HL
	POP	IX
	RET

; UG_DRAIN: discard up to 8 waiting events (exit path).  Clobbers AF, BC,
; DE, HL, IX.
UG_DRAIN
	LD	B,8
.next
	PUSH	BC
	LD	IX,UG_BLOCK + UGW_SCRATCH
	LD	B,UNETG_NEXT_EVENT
	CALL	UG_CALL
	POP	BC
	OR	A
	RET	NZ
	DJNZ	.next
	RET

; UG_EXIT: after SHUTDOWN returned OK and before the application restores
; its interrupt mode: no more admission or ISR entries.  The core restored
; #1FFD / #9FBD / pages itself; the gateway never changed them.
; Out: A = lock byte (0 expected).  Clobbers HL.
UG_EXIT
	CALL	UG_STOP
	LD	A,(UG_BLOCK + UGW_LOCK)
	RET

; UG_SNAPSHOT: copy block bytes 0..UGW_SCRATCH-1 to DE in one DI section
; (~130 us): quotas, debits and counters without torn values.
; Clobbers AF, BC, DE, HL.  Restores the caller's IFF.
UG_SNAPSHOT
	LD	A,I
	JP	PE,.on
	LD	A,I
.on
	PUSH	AF
	DI
	LD	HL,UG_BLOCK
	LD	BC,UGW_SCRATCH
	LDIR
	POP	AF
	RET	PO
	EI
	RET
