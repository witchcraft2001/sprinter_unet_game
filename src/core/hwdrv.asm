; hwdrv.asm -- hardware state machine shared by every card layer
; (Ethernet engine and the SprinterESP UART layer).
;
; HW_STEP (main) moves ctx.hw_state through DOWN -> INIT -> RUN and, after
; SHUTDOWN, STOP -> STOPPED.  Every card access is one bounded PORTION
; under the shared ISA lock.  The layer provides:
;   NIC_PREPARE        main, IX = ctx.hwsm: derive HS_IO etc. from the context
;   NIC_BRINGUP    (P) one bring-up step; HS_RES = NBR_*
;   NIC_STOP       (P) one stop step; HS_RES = NBR_*
;   HW_RUN             main: the work of a running card in this STEP
; and the costs COST_PREPARE, COST_BRINGUP, COST_PORTION and BRINGUP_MS.
; (P) routines run inside PORTION with IX = ctx.hwsm and IFF = 0.

	INCLUDE	"unetg_hwsm.inc"

; IX = ctx.hwsm
	MACRO	HWSM_IX
	PUSH	DE			; preserves DE
	LD	DE,UCTX_HWSM - CTX_BIAS
	PUSH	IY
	POP	IX
	ADD	IX,DE
	POP	DE
	ENDM

; HS_FIELD: HL = address of ctx.hwsm field A.  Preserves BC, DE.
HS_FIELD
	PUSH	DE
	LD	E,A
	LD	D,0
	LD	HL,UCTX_HWSM - CTX_BIAS
	ADD	HL,DE
	PUSH	IY
	POP	DE
	ADD	HL,DE
	POP	DE
	RET

; RUN_PORTION: take the bus and run (P) routine HL.  CF=1 when the bus is
; busy (nothing was run).  Clobbers A, BC, DE, HL, IX.
RUN_PORTION
	PUSH	HL
	CALL	ISA_ACQUIRE
	POP	HL
	RET	C
	PUSH	HL
	HWSM_IX
	POP	HL
	CALL	PORTION
	CALL	ISA_RELEASE
	OR	A
	RET

; ----------------------------------------------------------------------
; HW_STEP: main-loop hardware work of one STEP.
; ----------------------------------------------------------------------
HW_STEP
	LD	A,(IY+CX_HW_STATE)
	OR	A			; UHW_DOWN
	JR	NZ,.state
	LD	A,(IY+CX_STATE)
	CP	UNETG_CTXSTATE_CONFIGURED
	RET	NZ
	LD	HL,COST_PREPARE
	CALL	TAKE
	RET	C
	HWSM_IX
	CALL	NIC_PREPARE
	LD	(IY+CX_HW_STATE),UHW_INIT
	LD	BC,UCTX_HWSM + HS_BDL - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,BC
	LD	DE,BRINGUP_MS
	CALL	DL_ARM
	LD	A,UHW_INIT
.state
	CP	UHW_INIT
	JR	Z,HW_BRINGUP
	CP	UHW_RUN
	JP	Z,HW_RUN
	CP	UHW_STOP
	RET	NZ
	; SHUTDOWN: stop the card in portions (t0/deadline are in sched.asm)
.stop
	SET	2,(IY+CX_WORK)		; UWK_MORE until the card is safe
	LD	HL,COST_PORTION
	CALL	TAKE
	RET	C
	LD	HL,NIC_STOP
	CALL	RUN_PORTION
	RET	C
	CALL	HS_RESULT
	CP	NBR_CONTINUE
	JR	Z,.stop
	CP	NBR_DONE
	RET	NZ			; WAIT / FAULT: the stop deadline decides
	LD	(IY+CX_HW_STATE),UHW_STOPPED
	RES	2,(IY+CX_WORK)
	RET

HW_BRINGUP
	SET	2,(IY+CX_WORK)		; UWK_MORE until the card runs
	LD	BC,UCTX_HWSM + HS_BDL - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,BC
	CALL	DL_LEFT
	JR	NC,.portion
.fault
	LD	(IY+CX_HW_STATE),UHW_FAULT
	RES	2,(IY+CX_WORK)
	RET
.portion
	LD	HL,COST_BRINGUP
	CALL	TAKE
	RET	C
	LD	HL,NIC_BRINGUP
	CALL	RUN_PORTION
	RET	C
	CALL	HS_RESULT
	CP	NBR_CONTINUE
	JR	Z,.portion
	CP	NBR_WAIT
	RET	Z
	CP	NBR_FAULT
	JR	Z,.fault
	LD	(IY+CX_HW_STATE),UHW_RUN
	RET

; HS_RESULT: A = HS_RES.  Clobbers BC, HL.
HS_RESULT
	LD	BC,UCTX_HWSM + HS_RES - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,BC
	LD	A,(HL)
	RET

