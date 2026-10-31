; time.asm -- protocol clock (now_ms u32, wrap-safe) and the call budget.
;
; Only STEP advances protocol time.  Deadlines are absolute u32 values;
; "due" means (deadline - now) <= 0 as a signed 32-bit number, so every
; comparison survives the wrap of now_ms as long as intervals are < 2^31.

; DL_SET: deadline at HL = now_ms + DE (ms).  Invalidates the timer
; cache.  Clobbers A, HL.
; DL_ARM: the same for a deadline that is polled by its owner and never
; merged into the STEP deadline (card waits, TX completion): the timer
; cache stays valid.
DL_SET
	TMR_INVALIDATE
DL_ARM
	LD	A,(IY+CX_NOW_MS)
	ADD	A,E
	LD	(HL),A
	INC	HL
	LD	A,(IY+CX_NOW_MS+1)
	ADC	A,D
	LD	(HL),A
	INC	HL
	LD	A,(IY+CX_NOW_MS+2)
	ADC	A,0
	LD	(HL),A
	INC	HL
	LD	A,(IY+CX_NOW_MS+3)
	ADC	A,0
	LD	(HL),A
	RET

; DL_LEFT: HL -> u32 deadline.
; Out: CF=1 when due; otherwise DE = min(deadline - now, 0xFFFE) ms.
; Clobbers A, C, DE, HL.
DL_LEFT
	LD	A,(HL)
	SUB	(IY+CX_NOW_MS)
	LD	E,A
	INC	HL
	LD	A,(HL)
	SBC	A,(IY+CX_NOW_MS+1)
	LD	D,A
	INC	HL
	LD	A,(HL)
	SBC	A,(IY+CX_NOW_MS+2)
	LD	C,A
	INC	HL
	LD	A,(HL)
	SBC	A,(IY+CX_NOW_MS+3)
	JP	M,.due
	OR	C
	JR	NZ,.far
	LD	A,D
	OR	E
	JR	Z,.due
	LD	A,D
	AND	E
	INC	A
	JR	NZ,.ok
	DEC	DE			; 0xFFFF is reserved for "no deadline"
.ok
	OR	A
	RET
.far
	LD	DE,UNETG_DEADLINE_MAX
	OR	A
	RET
.due
	SCF
	RET

; DL_MERGE: fold the deadline at HL into dl_next (0 when due).
; Out: CF=1 when due.  Clobbers A, C, DE, HL.
DL_MERGE
	CALL	DL_LEFT
	JR	NC,DL_MERGE_DE
	LD	DE,0
	CALL	DL_MERGE_DE
	SCF
	RET
; DL_MERGE_DE: dl_next = min(dl_next, DE).  Clobbers A, HL.  CF=0.
DL_MERGE_DE
	LD	L,(IY+CX_DL_NEXT)
	LD	H,(IY+CX_DL_NEXT+1)
	OR	A
	SBC	HL,DE
	RET	C
	LD	(IY+CX_DL_NEXT),E
	LD	(IY+CX_DL_NEXT+1),D
	OR	A
	RET

; ----------------------------------------------------------------------
; Budget.  ctx.units holds the remaining body budget of the running call
; in microseconds of a 21 MHz CPU (the unit of every cost constant); the
; caller's budget is converted once by UNITS_FROM_BUDGET.  Costs are
; qualified upper bounds measured on the stand (docs/MEASUREMENTS.md).
; ----------------------------------------------------------------------

; UNITS_FROM_BUDGET: units = (DE * cpu_f16) / 16 - PROF_MIN_RETURN_US,
; at least 0: the return reserve is set aside once here, so TAKE and
; BUDGET_BYTES compare against the units directly.  Clobbers A, B, DE, HL.
UNITS_FROM_BUDGET
	LD	A,(IY+CX_CPU_F16)
	CALL	MUL_F16
	LD	DE,-PROF_MIN_RETURN_US
	ADD	HL,DE
	JR	C,.store
	LD	HL,0
.store
	LD	(IY+CX_UNITS),L
	LD	(IY+CX_UNITS+1),H
	RET

; MUL_F16: HL = (DE * A) / 16 for 0 <= A <= 31; A == 16 is the fast path.
; Clobbers A, B.
MUL_F16
	CP	16
	JR	NZ,.scale
	EX	DE,HL
	LD	D,H
	LD	E,L
	RET
.scale
	RLCA
	RLCA
	RLCA				; multiplier bit 4 -> bit 7
	LD	HL,0
	LD	B,5
.mul
	ADD	HL,HL
	RLA				; next multiplier bit (MSB first) -> CF
	JR	NC,.no_add
	ADD	HL,DE
.no_add
	DJNZ	.mul
	LD	B,4
.div
	SRL	H
	RR	L
	DJNZ	.div
	RET

; TAKE: reserve HL units.  Refused (CF=1, UWK_YIELD, units unchanged)
; when the cost plus the cheapest return path does not fit.
; Clobbers A, DE, HL.
TAKE
	EX	DE,HL
	LD	L,(IY+CX_UNITS)
	LD	H,(IY+CX_UNITS+1)
	OR	A
	SBC	HL,DE
	JR	C,.refuse
	LD	(IY+CX_UNITS),L
	LD	(IY+CX_UNITS+1),H
	RET				; CF=0
.refuse
	SET	4,(IY+CX_WORK)		; UWK_YIELD
	SCF
	RET

; UNITS_REFUND: give HL units back (a reserve taken with BUDGET_BYTES that
; the caller spends with its own TAKE).  Preserves BC, DE.  Clobbers A, HL.
UNITS_REFUND
	LD	A,(IY+CX_UNITS)
	ADD	A,L
	LD	(IY+CX_UNITS),A
	LD	A,(IY+CX_UNITS+1)
	ADC	A,H
	LD	(IY+CX_UNITS+1),A
	RET

; BUDGET_BYTES: size a copy portion from the remaining budget.
; In:  HL = fixed cost of the portion (units), A = log2 of the cost of one
;      byte (0: 1 unit/byte, 1: 2, 2: 4), DE = bytes wanted (> 0).
; Out: CF=0, BC = bytes (1..DE); units -= fixed + (BC << A).
;      CF=1 (UWK_YIELD) when not even one byte fits; units unchanged.
; Clobbers A, DE, HL.
BUDGET_BYTES
	PUSH	AF			; [shift]
	PUSH	DE			; [shift][wanted]
	EX	DE,HL
	LD	L,(IY+CX_UNITS)
	LD	H,(IY+CX_UNITS+1)
	OR	A
	SBC	HL,DE			; avail = units - fixed - return
	JR	C,.none
	EX	DE,HL			; DE = avail
	POP	HL			; HL = wanted   [shift]
	POP	AF
	PUSH	AF			; A = shift     [shift]
	PUSH	DE			; [shift][avail]
	LD	B,D
	LD	C,E
	OR	A
	JR	Z,.affordable
.shr
	SRL	B
	RR	C
	DEC	A
	JR	NZ,.shr
.affordable				; BC = avail >> shift
	PUSH	HL
	OR	A
	SBC	HL,BC
	POP	HL
	JR	NC,.min_ok		; wanted >= affordable: take affordable
	LD	B,H
	LD	C,L
.min_ok
	LD	A,B
	OR	C
	JR	Z,.none
	POP	HL			; HL = avail    [shift]
	POP	AF			; A = shift     []
	LD	D,B
	LD	E,C
	OR	A
	JR	Z,.spend
.shl
	SLA	E
	RL	D
	DEC	A
	JR	NZ,.shl
.spend
	OR	A
	SBC	HL,DE
	LD	(IY+CX_UNITS),L
	LD	(IY+CX_UNITS+1),H
	OR	A
	RET
.none
	POP	DE
	POP	AF
	SET	4,(IY+CX_WORK)		; UWK_YIELD
	SCF
	RET

; ----------------------------------------------------------------------
; Statistics: u16 counters in ctx.stats (GET_STATS image).  INC (HL) is
; atomic per byte and the carry belongs to whoever wrapped the low byte,
; so main and STEP_ISR may both increment without DI.
; ----------------------------------------------------------------------
	MACRO	STAT_INC field
	LD	BC,UCTX_STATS - 4 + field - CTX_BIAS
	CALL	STAT_INC_BC
	ENDM
STAT_INC_BC
	PUSH	IY
	POP	HL
	ADD	HL,BC
	INC	(HL)
	RET	NZ
	INC	HL
	INC	(HL)
	RET

; STAT_ADD32: u32 counter at offset BC += DE (main only).  Clobbers A, HL.
	MACRO	STAT_ADD32 field
	LD	BC,UCTX_STATS - 4 + field - CTX_BIAS
	CALL	STAT_ADD32_BC
	ENDM
STAT_ADD32_BC
	PUSH	IY
	POP	HL
	ADD	HL,BC
	LD	A,(HL)
	ADD	A,E
	LD	(HL),A
	INC	HL
	LD	A,(HL)
	ADC	A,D
	LD	(HL),A
	INC	HL
	LD	A,(HL)
	ADC	A,0
	LD	(HL),A
	INC	HL
	LD	A,(HL)
	ADC	A,0
	LD	(HL),A
	RET

; IY_PTR: HL = IY + DE (DE = a CX_* offset, possibly negative).
IY_PTR
	PUSH	IY
	POP	HL
	ADD	HL,DE
	RET
