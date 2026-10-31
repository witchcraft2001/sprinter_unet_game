; lifecycle.asm -- OPEN (6), CLOSE (7), ABORT (8), SHUTDOWN (3) and the
; channel termination rules of ABI §3.
;
; Channel: CLOSED -> OPENING -> OPEN -> CLOSING -> CLOSED.  CLOSED is
; entered only when the CLOSED event is published (events.asm), so a new
; OPEN after an accepted one always follows its CLOSED.
; Transport hooks (one set per build): TP_OPEN, TP_CLOSE, TP_ABORT,
; TP_STEP, TP_DEADLINES, TP_RESET.

; ----------------------------------------------------------------------
; OPEN.  In: IX = 0 (peer from INIT_CONFIG) or IX -> {ip[4], port u16}.
; Out: OK (queued; CONNECTED or a reason + CLOSED follow), STATE,
;      BAD_ARGUMENT (peer 0.0.0.0, port 0, bad pointer).
; ----------------------------------------------------------------------
EXP_OPEN
	PUSH	IX
	PUSH	IY
	CALL	CTX_LOAD
	JP	Z,RET_STATE
	LD	A,(IY+CX_STATE)
	CP	UNETG_CTXSTATE_CONFIGURED
	JP	NZ,RET_STATE
	BIT	2,(IY+CX_CLK_FLAGS)	; UCLK_EXPIRED: new INIT_CONFIG needed
	JP	NZ,RET_STATE
	LD	A,(IY+CX_CHAN)
	OR	A			; UCH_CLOSED
	JP	NZ,RET_STATE
	PUSH	IX
	POP	HL
	LD	A,H
	OR	L
	JR	Z,.peer_ok
	LD	DE,UNETG_PEER_BYTES
	CALL	RANGE
	JP	C,RET_BADARG
	LD	A,(IX+UNETG_PEER_IP)
	OR	(IX+UNETG_PEER_IP+1)
	OR	(IX+UNETG_PEER_IP+2)
	OR	(IX+UNETG_PEER_IP+3)
	JP	Z,RET_BADARG
	LD	A,(IX+UNETG_PEER_PORT)
	OR	(IX+UNETG_PEER_PORT+1)
	JP	Z,RET_BADARG
	PUSH	IX
	POP	HL
	LD	DE,CX_PEER_IP
	PUSH	HL
	CALL	IY_PTR
	EX	DE,HL
	POP	HL
	LD	BC,UNETG_PEER_BYTES	; peer_ip + peer_port are adjacent in ctx
	LDIR
.peer_ok
	LD	A,(IY+CX_PEER_IP)
	OR	(IY+CX_PEER_IP+1)
	OR	(IY+CX_PEER_IP+2)
	OR	(IY+CX_PEER_IP+3)
	JP	Z,RET_BADARG
	LD	A,(IY+CX_PEER_PORT)
	OR	(IY+CX_PEER_PORT+1)
	JP	Z,RET_BADARG
	LD	(IY+CX_CHAN),UCH_OPENING
	XOR	A
	LD	(IY+CX_CHAN_FLAGS),A
	LD	(IY+CX_TX_OFF),A
	LD	(IY+CX_TX_OFF+1),A
	LD	A,(IY+CX_TX_NEXT)
	LD	(IY+CX_TX_SEND),A
	LD	A,(IY+CX_CLK_FLAGS)
	AND	~UCLK_OP_ARMED & 0xFF
	OR	UCLK_OP_ARM		; connect deadline from the next STEP
	LD	(IY+CX_CLK_FLAGS),A
	TMR_INVALIDATE
	CALL	TP_OPEN
	JP	RET_OK

; ----------------------------------------------------------------------
; CLOSE.  Graceful: no new TX, committed TX finish within close_timeout,
; then CLOSED.  Idempotent in CLOSING/CLOSED.
; ----------------------------------------------------------------------
EXP_CLOSE
	PUSH	IX
	PUSH	IY
	CALL	CTX_LOAD
	JP	Z,RET_STATE
	LD	A,(IY+CX_CHAN)
	CP	UCH_OPENING
	JR	Z,.opening
	CP	UCH_OPEN
	JP	NZ,RET_OK		; CLOSING / CLOSED: nothing to do
	LD	(IY+CX_CHAN),UCH_CLOSING
	LD	A,(IY+CX_CLK_FLAGS)
	AND	~UCLK_OP_ARMED & 0xFF
	OR	UCLK_OP_ARM		; close deadline from the next STEP
	LD	(IY+CX_CLK_FLAGS),A
	TMR_INVALIDATE
	CALL	TP_CLOSE
	CALL	EV_FLUSH
	JP	RET_OK
.opening
	; Withdraw the attempt: no CONNECTED, no reason, just CLOSED.
	CALL	TP_ABORT
	LD	A,UTX_DONE_CANCEL
	CALL	CH_TERMINATE
	CALL	EV_FLUSH
	JP	RET_OK

; ----------------------------------------------------------------------
; ABORT.  Drops pending RX, every unfinished TX (reservations included)
; gets one TX_DONE/CANCEL, then CLOSED.  A repeated ABORT adds nothing.
; ----------------------------------------------------------------------
EXP_ABORT
	PUSH	IX
	PUSH	IY
	CALL	CTX_LOAD
	JP	Z,RET_STATE
	CALL	CH_ABORT
	CALL	EV_FLUSH
	JP	RET_OK

CH_ABORT
	LD	A,(IY+CX_CHAN)
	OR	A
	RET	Z			; CLOSED
	BIT	0,(IY+CX_CHAN_FLAGS)	; UCHF_ABORTED
	RET	NZ
	CALL	TP_ABORT
	CALL	RX_DISCARD_ALL
	SET	0,(IY+CX_CHAN_FLAGS)
	LD	A,UTX_DONE_CANCEL
	; fall through

; ----------------------------------------------------------------------
; CH_TERMINATE: the transport is finished with the channel.
; In: A = outcome for slots already handed to the transport
;     (UTX_DONE_FAILED, or UTX_DONE_CANCEL for ABORT).
; Reservations and committed-but-unsent slots are cancelled; outcomes
; already decided (DONE_*) are kept; CLOSED follows once TX outcomes are
; published and RX is drained.  Clobbers A, BC, DE, HL.
; ----------------------------------------------------------------------
CH_TERMINATE
	LD	(IY+CX_CHAN),UCH_CLOSING
	SET	1,(IY+CX_CHAN_FLAGS)	; UCHF_FINISHED
	SET	6,(IY+CX_EV_FLAGS)	; UEVF_CLOSED
	LD	E,A
	LD	C,0
.slot
	LD	A,C
	CP	(IY+CX_TX_SLOT_COUNT)
	JR	NC,.done
	PUSH	DE
	CALL	TX_STATE_PTR
	POP	DE
	LD	A,(HL)
	CP	UTX_SENDING
	JR	Z,.sending
	JR	NC,.next		; DONE_*: outcome already decided
	OR	A
	JR	Z,.next			; FREE
	LD	(HL),UTX_DONE_CANCEL	; RESERVED / COMMITTED
	JR	.next
.sending
	LD	(HL),E
.next
	INC	C
	JR	.slot
.done
	SET	7,(IY+CX_EV_FLAGS)	; UEVF_TXDONE: outcomes to publish
	LD	(IY+CX_TX_RES_SLOT),0xFF
	LD	A,(IY+CX_TX_NEXT)
	LD	(IY+CX_TX_SEND),A
	RET

; CH_REASON: queue terminal reason A with detail DE.
CH_REASON
	LD	(IY+CX_EV_REASON),A
	LD	(IY+CX_EV_REASON_DETAIL),E
	LD	(IY+CX_EV_REASON_DETAIL+1),D
	SET	1,(IY+CX_EV_FLAGS)	; UEVF_REASON
	RET

; CH_FAIL: reason A / detail DE, stop the transport, fail in-flight TX.
CH_FAIL
	CALL	CH_REASON
	CALL	TP_ABORT
	LD	A,UTX_DONE_FAILED
	JP	CH_TERMINATE

; ----------------------------------------------------------------------
; SHUTDOWN (export 3).  Idempotent; usable after a partial INIT_CONFIG or
; a fatal error.  The first call moves the context to STOPPING (ABORT
; rules for an active channel); STEP then stops the card in portions.
; Out: WORK while stopping or while events remain; OK once the card is
; safe and the queue is read (the context is released); DEVICE_FAULT when
; the stop missed t0 + close_timeout (call again for a new attempt).
; ----------------------------------------------------------------------
EXP_SHUTDOWN
	PUSH	IX
	PUSH	IY
	CALL	CTX_LOAD
	JP	Z,RET_OK		; zeroed context: OK without I/O
	LD	A,(IY+CX_STATE)
	CP	UNETG_CTXSTATE_STOPPING
	JR	Z,.check
	CP	UNETG_CTXSTATE_FAULT
	JR	Z,.retry
	; CONFIGURED -> STOPPING
	LD	(IY+CX_STATE),UNETG_CTXSTATE_STOPPING
	CALL	CH_ABORT
	LD	A,(IY+CX_HW_STATE)
	OR	A			; UHW_DOWN: the card was never touched
	JR	NZ,.stop_hw
	LD	(IY+CX_HW_STATE),UHW_STOPPED
	JR	.check
.retry
	; The first call after a missed stop deadline reports it; the next
	; one starts a new attempt with a new t0 (no repeated cancel events).
	BIT	5,(IY+CX_CLK_FLAGS)	; UCLK_FAULT_SEEN
	JR	NZ,.again
	SET	5,(IY+CX_CLK_FLAGS)
	LD	A,UNETG_STATUS_DEVICE_FAULT
	JP	RET_A
.again
	RES	5,(IY+CX_CLK_FLAGS)
	LD	(IY+CX_STATE),UNETG_CTXSTATE_STOPPING
.stop_hw
	LD	(IY+CX_HW_STATE),UHW_STOP
	RES	1,(IY+CX_CLK_FLAGS)	; UCLK_T0_SET: next STEP records t0
	TMR_INVALIDATE
.check
	CALL	EV_FLUSH
	LD	A,(IY+CX_HW_STATE)
	CP	UHW_STOPPED
	LD	A,UNETG_STATUS_WORK
	JP	NZ,RET_A
	CALL	EV_EMPTY
	LD	A,UNETG_STATUS_WORK
	JP	NZ,RET_A
	LD	(IY+CX_STATE),UNETG_CTXSTATE_STOPPED
	LD	HL,0
	LD	(IMG_CTX_PTR),HL
	JP	RET_OK
