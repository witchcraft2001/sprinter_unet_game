; sched.asm -- STEP (export 4) and STEP_ISR (export 5).
;
; STEP(now_ms, budget) runs in the main loop: protocol clock, hardware
; portions, transport, event publication.  STEP_ISR(source, budget) runs
; inside the gateway's ISR with IFF=0: only bounded hardware I/O and
; pending bits, never events, RX publication or protocol time.
; Both report through A (status), L (flags byte, also ctx.flags_out) and
; STEP also DE (next protocol deadline).


; ----------------------------------------------------------------------
; STEP.  In: DE = budget_us, IX = now_ms[15:0], IY = now_ms[31:16],
;        A bit 0 = the gateway pre-acquired the ISA lock for this call.
; Out: A = WORK / YIELD / IDLE / BUS_BUSY (STATE without a context),
;      DE = 0 (deadline due), 1..0xFFFE ms, 0xFFFF (no protocol deadline),
;      L = flags.  Stack: <= 256.
; ----------------------------------------------------------------------
EXP_STEP
	PUSH	IX
	PUSH	IY
	PUSH	IY			; now_ms high word
	PUSH	IX			; now_ms low word
	LD	C,A
	CALL	CTX_LOAD
	JR	NZ,.have
	POP	HL
	POP	HL
	JP	RET_STATE
.have
	LD	A,C
	AND	UCF_PREACQ
	OR	UCF_BUDGET
	LD	(IY+CX_CALL_FLAGS),A
	PUSH	DE
	LD	DE,CX_NOW_MS
	CALL	IY_PTR
	POP	DE
	POP	BC
	LD	(HL),C
	INC	HL
	LD	(HL),B
	INC	HL
	POP	BC
	LD	(HL),C
	INC	HL
	LD	(HL),B
	CALL	UNITS_FROM_BUDGET
	XOR	A
	LD	(IY+CX_WORK),A
	LD	(IY+CX_FLAGS_OUT),A
	DEC	A
	LD	(IY+CX_DL_NEXT),A
	LD	(IY+CX_DL_NEXT+1),A
	STAT_INC UNETG_STATS_STEPS_TOTAL
	LD	HL,PROF_STEP_BASE_US
	CALL	TAKE
	JR	NC,.useful
	; Not even the clock fits: no protocol step (ABI §4: no new reference
	; point for max_observed_step_gap_ms).
	STAT_INC UNETG_STATS_BUDGET_YIELDS
	LD	DE,0
	LD	A,UNETG_STATUS_YIELD
	JR	.out
.useful
	CALL	CLOCK_STEP
	; Alternate who is served first, so that neither the hardware nor the
	; transport is starved when a portion of the other does not fit.
	LD	BC,UCTX_STATS - 4 + UNETG_STATS_STEPS_TOTAL - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,BC
	BIT	0,(HL)
	JR	Z,.tp_first
	CALL	HW_STEP
	CALL	TP_IF_RUNNING
	JR	.served
.tp_first
	CALL	TP_IF_RUNNING
	CALL	HW_STEP
.served
	CALL	EV_FLUSH
	CALL	DEADLINES
	LD	E,(IY+CX_DL_NEXT)
	LD	D,(IY+CX_DL_NEXT+1)
	CALL	WORK_STATUS
.out
	LD	L,(IY+CX_FLAGS_OUT)
	LD	H,0
	LD	(IY+CX_CALL_FLAGS),H
	POP	IY
	POP	IX
	RET

TP_IF_RUNNING
	LD	A,(IY+CX_STATE)
	CP	UNETG_CTXSTATE_CONFIGURED
	RET	NZ
	JP	TP_STEP

; WORK_STATUS: A = status from ctx.work.  Counts budget yields.
WORK_STATUS
	LD	A,(IY+CX_WORK)
	BIT	4,A			; UWK_YIELD
	JR	Z,.busy
	PUSH	DE
	STAT_INC UNETG_STATS_BUDGET_YIELDS
	POP	DE
	LD	A,UNETG_STATUS_YIELD
	RET
.busy
	BIT	3,A			; UWK_BUSY
	JR	Z,.more
	LD	A,UNETG_STATUS_BUS_BUSY
	RET
.more
	BIT	2,A			; UWK_MORE
	LD	A,UNETG_STATUS_WORK
	RET	NZ
	LD	A,UNETG_STATUS_IDLE
	RET

; ----------------------------------------------------------------------
; CLOCK_STEP: everything driven by protocol time.
; ----------------------------------------------------------------------
	ASSERT	UCTX_LAST_USEFUL_MS == UCTX_NOW_MS + 4
STATS_GAP	EQU	UCTX_STATS - 4 + UNETG_STATS_MAX_STEP_GAP_MS - CTX_BIAS
COST_TMR_FULL	EQU	120	; timer evaluation + full deadline recomputation (stand: 86 us)
STATS_AVAIL	EQU	UCTX_STATS - 4 + UNETG_STATS_AVAIL - CTX_BIAS
CLOCK_STEP
	; max_observed_step_gap_ms between useful STEPs (saturating u16)
	BIT	0,(IY+CX_CLK_FLAGS)	; UCLK_HAVE_LAST
	JR	Z,.first
	LD	L,(IY+CX_NOW_MS)
	LD	H,(IY+CX_NOW_MS+1)
	LD	E,(IY+CX_LAST_USEFUL_MS)
	LD	D,(IY+CX_LAST_USEFUL_MS+1)
	OR	A
	SBC	HL,DE
	PUSH	HL
	LD	L,(IY+CX_NOW_MS+2)
	LD	H,(IY+CX_NOW_MS+3)
	LD	E,(IY+CX_LAST_USEFUL_MS+2)
	LD	D,(IY+CX_LAST_USEFUL_MS+3)
	SBC	HL,DE
	LD	A,H
	OR	L
	POP	DE			; DE = gap (low word)
	JR	Z,.gap16
	LD	DE,0xFFFF
.gap16
	LD	BC,STATS_GAP
	PUSH	IY
	POP	HL
	ADD	HL,BC			; HL -> max_step_gap_ms
	LD	A,E
	SUB	(HL)
	INC	HL
	LD	A,D
	SBC	A,(HL)
	JR	C,.gap_kept		; gap < max
	LD	(HL),D
	DEC	HL
	LD	(HL),E
	LD	BC,STATS_AVAIL - STATS_GAP
	ADD	HL,BC
	SET	0,(HL)			; UNETG_AVAIL_MAX_STEP_GAP
.gap_kept
.first
	LD	DE,CX_LAST_USEFUL_MS
	CALL	IY_PTR
	EX	DE,HL
	LD	HL,-4
	ADD	HL,DE			; HL -> now_ms, DE -> last_useful_ms
	LDI
	LDI
	LDI
	LDI
	SET	0,(IY+CX_CLK_FLAGS)
	STAT_INC UNETG_STATS_STEPS_USEFUL

	; Timer cache: protocol timers are evaluated only when the earliest
	; armed deadline is reached or a deadline was (re)armed.
	RES	2,(IY+CX_TMR_FLAGS)	; UTMR_DUE
	; While the transport still owes the evaluation started by an earlier
	; STEP (its step did not fit), a new full evaluation would only eat the
	; budget it needs: the cached due deadline is explained by that debt.
	; (Ethernet transports only: they clear UTMR_TPDUE in every TP_STEP.)
	IFDEF	UGB_HW_ETH
	BIT	4,(IY+CX_TMR_FLAGS)	; UTMR_TPDUE
	JR	Z,.tmr_cache
	LD	A,(IY+CX_STATE)
	CP	UNETG_CTXSTATE_CONFIGURED
	JR	Z,.tmr_done
	RES	4,(IY+CX_TMR_FLAGS)	; no transport step will pay it any more
.tmr_cache
	ENDIF
	BIT	0,(IY+CX_TMR_FLAGS)	; UTMR_VALID
	JR	Z,.tmr_due
	BIT	1,(IY+CX_TMR_FLAGS)	; UTMR_NONE
	JR	NZ,.tmr_done
	LD	DE,CX_TMR_DUE
	CALL	IY_PTR
	CALL	DL_LEFT
	JR	NC,.tmr_done
.tmr_due
	; evaluating the timers and recomputing every deadline has its price
	LD	HL,COST_TMR_FULL
	CALL	TAKE
	JR	NC,.tmr_take
	RES	4,(IY+CX_WORK)		; not a budget yield: the step still counts
	TMR_INVALIDATE			; evaluate at the next STEP
	JR	.tmr_done
.tmr_take
	LD	A,(IY+CX_TMR_FLAGS)
	OR	UTMR_DUE | UTMR_TPDUE	; the transport evaluates its timers too
	LD	(IY+CX_TMR_FLAGS),A
.tmr_done

	LD	A,(IY+CX_STATE)
	CP	UNETG_CTXSTATE_STOPPING
	JR	NZ,.running
	; SHUTDOWN hardware phase: t0 = now of the first STEP in STOPPING,
	; recorded before any ISA access; deadline t0 + close_timeout_ms.
	LD	A,(IY+CX_HW_STATE)
	CP	UHW_STOP
	RET	NZ
	BIT	1,(IY+CX_CLK_FLAGS)	; UCLK_T0_SET
	JR	NZ,.stop_due
	SET	1,(IY+CX_CLK_FLAGS)
	LD	A,(IY+CX_NOW_MS)
	LD	(IY+CX_T0_MS),A
	LD	A,(IY+CX_NOW_MS+1)
	LD	(IY+CX_T0_MS+1),A
	LD	A,(IY+CX_NOW_MS+2)
	LD	(IY+CX_T0_MS+2),A
	LD	A,(IY+CX_NOW_MS+3)
	LD	(IY+CX_T0_MS+3),A
	LD	E,(IY+CX_CLOSE_TIMEOUT_MS)
	LD	D,(IY+CX_CLOSE_TIMEOUT_MS+1)
	LD	BC,CX_OP_DEADLINE_MS
	PUSH	IY
	POP	HL
	ADD	HL,BC
	CALL	DL_SET
	RET
.stop_due
	LD	BC,CX_OP_DEADLINE_MS
	PUSH	IY
	POP	HL
	ADD	HL,BC
	CALL	DL_LEFT
	RET	NC
	LD	(IY+CX_HW_STATE),UHW_FAULT
	LD	(IY+CX_STATE),UNETG_CTXSTATE_FAULT
	RES	5,(IY+CX_CLK_FLAGS)	; report DEVICE_FAULT at the next SHUTDOWN
	RET

.running
	BIT	2,(IY+CX_TMR_FLAGS)	; nothing is due: skip the timer checks
	RET	Z
	; CONFIG_EXPIRED: the first STEP that reaches the deadline.
	BIT	0,(IY+CX_CFG_FLAGS)	; UNETG_CFGF_HAS_EXPIRY
	JR	Z,.op
	BIT	2,(IY+CX_CLK_FLAGS)	; UCLK_EXPIRED
	JR	NZ,.op
	LD	BC,CX_EXPIRES_MS
	PUSH	IY
	POP	HL
	ADD	HL,BC
	CALL	DL_LEFT
	JR	NC,.op
	SET	2,(IY+CX_CLK_FLAGS)
	SET	5,(IY+CX_EV_FLAGS)	; UEVF_EXPIRED
	LD	A,(IY+CX_CHAN)
	OR	A
	JR	Z,.op			; no channel: no CLOSED is synthesised
	BIT	1,(IY+CX_CHAN_FLAGS)	; already finishing
	JR	NZ,.op
	CALL	TP_ABORT		; nothing more is sent to an expired peer
	LD	A,UTX_DONE_CANCEL
	CALL	CH_TERMINATE
.op
	; OPEN / CLOSE deadline: armed by the first STEP after the request.
	BIT	4,(IY+CX_CLK_FLAGS)	; UCLK_OP_ARM
	JR	Z,.op_check
	RES	4,(IY+CX_CLK_FLAGS)
	SET	3,(IY+CX_CLK_FLAGS)	; UCLK_OP_ARMED
	LD	E,(IY+CX_CONNECT_TIMEOUT_MS)
	LD	D,(IY+CX_CONNECT_TIMEOUT_MS+1)
	LD	A,(IY+CX_CHAN)
	CP	UCH_OPENING
	JR	Z,.arm
	LD	E,(IY+CX_CLOSE_TIMEOUT_MS)
	LD	D,(IY+CX_CLOSE_TIMEOUT_MS+1)
.arm
	LD	BC,CX_OP_DEADLINE_MS
	PUSH	IY
	POP	HL
	ADD	HL,BC
	JP	DL_SET
.op_check
	BIT	3,(IY+CX_CLK_FLAGS)
	RET	Z
	BIT	1,(IY+CX_CHAN_FLAGS)	; UCHF_FINISHED: nothing to time out
	RET	NZ
	LD	A,(IY+CX_CHAN)
	CP	UCH_OPENING
	JR	Z,.op_due
	CP	UCH_CLOSING
	RET	NZ
.op_due
	LD	BC,CX_OP_DEADLINE_MS
	PUSH	IY
	POP	HL
	ADD	HL,BC
	CALL	DL_LEFT
	RET	NC
	RES	3,(IY+CX_CLK_FLAGS)
	LD	DE,UNETG_TIMEOUT_OPEN
	LD	A,(IY+CX_CHAN)
	CP	UCH_OPENING
	JR	Z,.timeout
	LD	DE,UNETG_TIMEOUT_CLOSE
.timeout
	LD	A,UNETG_EV_TIMEOUT
	JP	CH_FAIL

; DEADLINES: dl_next = earliest armed protocol deadline.  Recomputed from
; every timer when they were evaluated in this STEP, otherwise taken from
; the cache.
DEADLINES
	BIT	2,(IY+CX_TMR_FLAGS)	; UTMR_DUE: full recomputation
	JR	NZ,.full
	BIT	1,(IY+CX_TMR_FLAGS)	; UTMR_NONE
	RET	NZ
	LD	DE,CX_TMR_DUE
	CALL	IY_PTR
	JP	DL_MERGE
.full
	CALL	DEADLINES_ALL
	BIT	3,(IY+CX_TMR_FLAGS)	; UTMR_AGAIN: something changed or was
	JR	Z,.cache		; refused during this STEP: no cache
	LD	A,(IY+CX_TMR_FLAGS)
	AND	UTMR_TPDUE
	LD	(IY+CX_TMR_FLAGS),A
	RET
.cache
	; cache = now + dl_next (0xFFFF: nothing armed)
	LD	E,(IY+CX_DL_NEXT)
	LD	D,(IY+CX_DL_NEXT+1)
	LD	A,D
	AND	E
	INC	A
	LD	B,UTMR_VALID | UTMR_NONE
	JR	Z,.store
	LD	A,(IY+CX_NOW_MS)
	ADD	A,E
	LD	(IY+CX_TMR_DUE),A
	LD	A,(IY+CX_NOW_MS+1)
	ADC	A,D
	LD	(IY+CX_TMR_DUE+1),A
	LD	A,(IY+CX_NOW_MS+2)
	ADC	A,0
	LD	(IY+CX_TMR_DUE+2),A
	LD	A,(IY+CX_NOW_MS+3)
	ADC	A,0
	LD	(IY+CX_TMR_DUE+3),A
	LD	B,UTMR_VALID
.store
	LD	A,(IY+CX_TMR_FLAGS)
	AND	UTMR_TPDUE
	OR	B
	LD	(IY+CX_TMR_FLAGS),A
	RET

DEADLINES_ALL
	LD	A,(IY+CX_STATE)
	CP	UNETG_CTXSTATE_STOPPING
	JR	NZ,.cfg
	BIT	1,(IY+CX_CLK_FLAGS)
	RET	Z
	LD	A,(IY+CX_HW_STATE)
	CP	UHW_STOP
	RET	NZ
	JR	.op_dl
.cfg
	BIT	0,(IY+CX_CFG_FLAGS)
	JR	Z,.op
	BIT	2,(IY+CX_CLK_FLAGS)
	JR	NZ,.op
	LD	BC,CX_EXPIRES_MS
	PUSH	IY
	POP	HL
	ADD	HL,BC
	CALL	DL_MERGE
.op
	BIT	3,(IY+CX_CLK_FLAGS)
	JR	Z,.tp
	BIT	1,(IY+CX_CHAN_FLAGS)
	JR	NZ,.tp
.op_dl
	LD	BC,CX_OP_DEADLINE_MS
	PUSH	IY
	POP	HL
	ADD	HL,BC
	CALL	DL_MERGE
	LD	A,(IY+CX_STATE)
	CP	UNETG_CTXSTATE_STOPPING
	RET	Z
.tp
	JP	TP_DEADLINES

; ----------------------------------------------------------------------
; STEP_ISR.  In: A = source (UNETG_SRC_*) | 0x80 when the gateway holds
; the ISA lock for this portion, DE = body budget (us).  IFF = 0.
; Out: A = status (BAD_ARGUMENT for an unknown source, STATE without an
; active context or for CBL without a qualified portion), L = flags.
; Stack: <= 96.  Never touches events, RX publication or protocol time.
; ----------------------------------------------------------------------
EXP_STEP_ISR
	PUSH	IX
	PUSH	IY
	LD	C,A
	PUSH	BC
	CALL	CTX_LOAD
	POP	BC
	JP	Z,RET_STATE
	LD	A,C
	AND	0x7F
	JP	Z,RET_BADARG
	CP	UNETG_SRC_OTHER_IRQ + 1
	JP	NC,RET_BADARG
	LD	B,A			; B = source
	LD	A,(IY+CX_STATE)
	CP	UNETG_CTXSTATE_CONFIGURED
	JP	NZ,RET_STATE
	LD	A,B
	CP	UNETG_SRC_CBL
	JR	NZ,.src_ok
	BIT	2,(IY+CX_CFG_FLAGS)	; UNETG_CFGF_CBL_QUALIFIED
	JP	Z,RET_STATE
.src_ok
	LD	A,C
	RLCA				; bit 7 (pre-acquired) -> bit 0
	AND	UCF_PREACQ
	OR	UCF_ISR
	LD	(IY+CX_CALL_FLAGS),A
	XOR	A
	LD	(IY+CX_WORK),A
	LD	(IY+CX_FLAGS_OUT),A
	PUSH	BC
	CALL	UNITS_FROM_BUDGET
	LD	HL,PROF_ISR_BASE_US
	CALL	TAKE
	POP	BC
	LD	A,UNETG_STATUS_YIELD
	JR	C,.out			; not even the fixed path fits
	PUSH	BC
	LD	A,B
	DEC	A
	ADD	A,A
	LD	C,A
	LD	B,0
	LD	HL,UCTX_STATS - 4 + UNETG_STATS_ISR_CALLS - CTX_BIAS
	ADD	HL,BC
	LD	B,H
	LD	C,L
	CALL	STAT_INC_BC
	POP	BC
	LD	A,B
	CP	UNETG_SRC_CARD_IRQ
	JR	NZ,.hw
	STAT_INC UNETG_STATS_IRQ_COUNT
.hw
	CALL	HW_ISR
	CALL	WORK_STATUS
.out
	LD	L,(IY+CX_FLAGS_OUT)
	LD	H,0
	LD	(IY+CX_CALL_FLAGS),H
	POP	IY
	POP	IX
	RET
