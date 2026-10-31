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
	LD	C,A
	LD	HL,(IMG_CTX_PTR)	; ctx + CTX_BIAS (CTX_LOAD inline)
	LD	A,H
	OR	L
	JP	Z,RET_STATE
	PUSH	HL
	POP	IY
	LD	A,C
	AND	UCF_PREACQ
	OR	UCF_BUDGET
	LD	(IY+CX_CALL_FLAGS),A
	; now_ms from the caller's IX (low) / IY (high) words on the stack
	POP	HL
	POP	BC
	PUSH	BC
	PUSH	HL
	LD	(IY+CX_NOW_MS),C
	LD	(IY+CX_NOW_MS+1),B
	LD	(IY+CX_NOW_MS+2),L
	LD	(IY+CX_NOW_MS+3),H
	; units = budget * f16 / 16 - return (UNITS_FROM_BUDGET), and the
	; fixed STEP path taken from them at once (TAKE PROF_STEP_BASE_US)
	LD	A,(IY+CX_CPU_F16)
	EX	DE,HL			; HL = budget
	CP	16
	JR	Z,.turbo		; 21 MHz: one unit per microsecond
	EX	DE,HL
	CALL	MUL_F16
.turbo
	XOR	A
	LD	(IY+CX_WORK),A
	LD	(IY+CX_FLAGS_OUT),A
	DEC	A
	LD	(IY+CX_DL_NEXT),A
	LD	(IY+CX_DL_NEXT+1),A
	LD	DE,-PROF_MIN_RETURN_US
	ADD	HL,DE
	JR	C,.units
	LD	HL,0
.units
	LD	(IY+CX_UNITS),L		; kept for the refusal (no budget taken)
	LD	(IY+CX_UNITS+1),H
	LD	DE,-PROF_STEP_BASE_US
	ADD	HL,DE
	JR	NC,.no_base
	LD	(IY+CX_UNITS),L
	LD	(IY+CX_UNITS+1),H
	STAT_INC UNETG_STATS_STEPS_TOTAL
	JR	.useful
.no_base
	SET	4,(IY+CX_WORK)		; UWK_YIELD (TAKE's refusal)
	STAT_INC UNETG_STATS_STEPS_TOTAL
	; Not even the clock fits: no protocol step (ABI §4: no new reference
	; point for max_observed_step_gap_ms).
	STAT_INC UNETG_STATS_BUDGET_YIELDS
	LD	DE,0
	LD	A,UNETG_STATUS_YIELD
	JR	.out
.useful
	CALL	CLOCK_STEP
	IFDEF	UGB_HW_ETH
	; A running Ethernet card: the engine orders card and transport work
	; (ETH_SCHED: poll reserve, frames in progress, transport, new TX, poll).
	LD	A,(IY+CX_HW_STATE)
	CP	UHW_RUN
	JR	NZ,.alternate
	CALL	ETH_SCHED
	JR	.served
.alternate
	ENDIF
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
ISR_STATS_OFF	EQU	UCTX_STATS - 4 + UNETG_STATS_IRQ_COUNT - CTX_BIAS
	ASSERT	UNETG_STATS_ISR_CALLS == UNETG_STATS_IRQ_COUNT + 2
; early exits of STEP_ISR (only IY pushed), within JR range of the checks
ISR_STATE
	LD	A,UNETG_STATUS_STATE
	POP	IY
	RET
ISR_BADARG
	LD	A,UNETG_STATUS_BAD_ARGUMENT
	POP	IY
	RET
ISR_YIELD
	LD	HL,0			; flags byte 0
	LD	A,UNETG_STATUS_YIELD
	POP	IY
	RET
EXP_STEP_ISR
	PUSH	IY			; IX is pushed only on the full path
	LD	C,A
	LD	HL,(IMG_CTX_PTR)	; ctx + CTX_BIAS (CTX_LOAD inline)
	LD	A,H
	OR	L
	JR	Z,ISR_STATE
	PUSH	HL
	POP	IY
	LD	A,C
	AND	0x7F
	DEC	A
	CP	UNETG_SRC_OTHER_IRQ	; source 1..6 -> 0..5
	JR	NC,ISR_BADARG
	LD	B,A			; B = source - 1
	IFNDEF	UGB_HW_LOOP
	; A running card implies a CONFIGURED context (SHUTDOWN moves the
	; hardware state first): the BUS_BUSY path skips the state check.
	LD	A,(IY+CX_HW_STATE)
	CP	UHW_RUN
	JP	NZ,.idle_card
	LD	A,B
	CP	UNETG_SRC_CBL - 1
	JP	Z,.cbl_run
.run_ok
	; Budget first, without touching the context: a call that cannot pay
	; even the fixed path returns YIELD at once and leaves the fields of an
	; interrupted main call alone.  units = budget * f16 / 16 - return.
	LD	A,(IY+CX_CPU_F16)
	EX	DE,HL			; HL = budget
	CP	16
	JR	NZ,.scale_r		; 21 MHz: one unit per microsecond
.units_r
	LD	DE,-(PROF_MIN_RETURN_US + PROF_ISR_BASE_US)
	ADD	HL,DE
	JR	NC,ISR_YIELD
	EX	DE,HL			; DE = units left after the fixed path
	; isr_calls[source] and irq_count through ctx.isr_stats_ptr (INC (HL)
	; is atomic per byte, see STAT_INC); HL = that pointer afterwards
	LD	L,(IY+CX_ISR_STATS_PTR)
	LD	H,(IY+CX_ISR_STATS_PTR+1)
	PUSH	HL
	LD	A,B
	OR	A
	CALL	Z,ISR_COUNT_IRQ		; source 1 = CARD_IRQ
	INC	A
	ADD	A,A
	ADD	A,L
	LD	L,A
	JR	C,.carry_r
.calls_r
	INC	(HL)			; isr_calls[source]
	JR	Z,.wrap_r
.counted_r
	POP	HL
	; BUS_BUSY before any write of a per-call field: another owner holds
	; the bus (the gateway did not pre-acquire it for us) -- answer at once
	; (ТЗ §5.1: <= 25 us).  The lock byte is only read here; RUN_PORTION
	; does the test-and-set.  B, C are free on this path (C bit 7 = 0).
	BIT	7,C
	JR	NZ,.full		; pre-acquired by the gateway
	LD	C,(IY+CX_ISA_LOCK_PTR)
	LD	B,(IY+CX_ISA_LOCK_PTR+1)
	LD	A,(BC)
	LD	C,0			; not pre-acquired
	OR	A
	JR	Z,.full
	LD	BC,UNETG_STATS_BUS_BUSY - UNETG_STATS_IRQ_COUNT
	ADD	HL,BC
	INC	(HL)			; bus_busy
	JR	Z,.busy_wrap
.busy
	LD	HL,0			; flags byte 0
	LD	A,UNETG_STATUS_BUS_BUSY
	POP	IY
	RET
.wrap_r
	INC	HL
	INC	(HL)
	JR	.counted_r
.carry_r
	INC	H
	JR	.calls_r
.scale_r
	EX	DE,HL
	PUSH	BC
	CALL	MUL_F16
	POP	BC
	JR	.units_r
.full
	; the card status portion (ISRP_POLL of the card layer)
	LD	HL,-PROF_ISR_POLL_US
	ADD	HL,DE
	JR	NC,.no_poll
	PUSH	IX
	; The network ISR may interrupt a main STEP between two portions (ABI
	; §1): its call flags and work bits belong to that call -- saved here
	; and restored on the way out (call_flags = 0 outside STEP).  The budget
	; units of the interrupted call are never touched (the portion cost was
	; checked above).  Nothing in STEP_ISR sets a flags byte bit (v1: no
	; route to mask), so ctx.flags_out stays the main call's.  Stack: +4.
	LD	H,(IY+CX_CALL_FLAGS)
	LD	L,(IY+CX_WORK)
	PUSH	HL
	LD	A,C
	RLCA				; bit 7 (pre-acquired) -> bit 0
	AND	UCF_PREACQ
	OR	UCF_ISR
	LD	(IY+CX_CALL_FLAGS),A
	LD	(IY+CX_WORK),0
	LD	HL,ISRP_POLL
	CALL	RUN_PORTION
	; status from the work bits (WORK_STATUS without the yield case)
	LD	A,(IY+CX_WORK)
	LD	B,UNETG_STATUS_BUS_BUSY
	BIT	3,A			; UWK_BUSY: RUN_PORTION refused
	JR	NZ,.status
	LD	B,UNETG_STATUS_WORK
	BIT	2,A			; UWK_MORE: a frame / bytes for the next STEP
	JR	NZ,.status
	LD	B,UNETG_STATUS_IDLE
.status
	POP	HL
	LD	(IY+CX_WORK),L
	LD	(IY+CX_CALL_FLAGS),H
	LD	A,B
	LD	HL,0			; flags byte 0
	POP	IX
	POP	IY
	RET
.no_poll
	STAT_INC UNETG_STATS_BUDGET_YIELDS
	JP	ISR_YIELD
	ELSE
	JR	.idle_card
	ENDIF

	IFNDEF	UGB_HW_LOOP
.busy_wrap
	INC	HL
	INC	(HL)
	JR	.busy
.cbl_run
	BIT	2,(IY+CX_CFG_FLAGS)	; UNETG_CFGF_CBL_QUALIFIED
	JP	NZ,.run_ok
	JP	ISR_STATE
	ENDIF
.idle_card
	; no card poll in this call: the full checks
	LD	A,(IY+CX_STATE)
	CP	UNETG_CTXSTATE_CONFIGURED
	JP	NZ,ISR_STATE
	LD	A,B
	CP	UNETG_SRC_CBL - 1
	JR	NZ,.idle_ok
	; Budget first (YIELD when not even the fixed path fits), then the
	; counters; a card that is not running is not polled: IDLE, no writes.
	BIT	2,(IY+CX_CFG_FLAGS)	; UNETG_CFGF_CBL_QUALIFIED
	JP	Z,ISR_STATE
.idle_ok
	; Budget first, without touching the context: a call that cannot pay
	; even the fixed path returns YIELD at once and leaves the fields of an
	; interrupted main call alone.  units = budget * f16 / 16 - return.
	LD	A,(IY+CX_CPU_F16)
	EX	DE,HL			; HL = budget
	CP	16
	JR	NZ,.scale_i		; 21 MHz: one unit per microsecond
.units_i
	LD	DE,-(PROF_MIN_RETURN_US + PROF_ISR_BASE_US)
	ADD	HL,DE
	JP	NC,ISR_YIELD
	EX	DE,HL			; DE = units left after the fixed path
	; isr_calls[source] and irq_count through ctx.isr_stats_ptr (INC (HL)
	; is atomic per byte, see STAT_INC); HL = that pointer afterwards
	LD	L,(IY+CX_ISR_STATS_PTR)
	LD	H,(IY+CX_ISR_STATS_PTR+1)
	PUSH	HL
	LD	A,B
	OR	A
	CALL	Z,ISR_COUNT_IRQ		; source 1 = CARD_IRQ
	INC	A
	ADD	A,A
	ADD	A,L
	LD	L,A
	JR	C,.carry_i
.calls_i
	INC	(HL)			; isr_calls[source]
	JR	Z,.wrap_i
.counted_i
	POP	HL
	LD	HL,0			; flags byte 0
	LD	A,UNETG_STATUS_IDLE
	POP	IY
	RET
.wrap_i
	INC	HL
	INC	(HL)
	JR	.counted_i
.carry_i
	INC	H
	JR	.calls_i
.scale_i
	EX	DE,HL
	PUSH	BC
	CALL	MUL_F16
	POP	BC
	JR	.units_i

; ISR_COUNT_IRQ: irq_count += 1 at (HL) (u16).  Preserves A, HL.
; STEP_ISR only (source CARD_IRQ).
ISR_COUNT_IRQ
	INC	(HL)
	RET	NZ
	INC	HL
	INC	(HL)
	DEC	HL
	RET
