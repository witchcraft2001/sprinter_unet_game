; events.asm -- event queue (main context only) and NEXT_EVENT (export 14).
;
; Every event goes through a pending state (UCTX.ev_flags, DONE_* TX
; slots) and is published by EV_FLUSH when the queue has room, so a full
; queue never loses an outcome: TX slots stay DONE_* (not reusable) until
; their TX_DONE is in the queue.  Publication order of one flush:
;   CONNECTED, terminal reason, TX_DONE (ring order), RX_READY,
;   MODE_CHANGED, CONFIG_EXPIRED, CLOSED (only when TX/RX are drained).
; The queue is a power-of-two ring with one sentinel slot; the producer
; writes the 8 bytes first and then publishes ev_head with one store.

; EV_MAKE: ev_tmp = {type A, channel by type, tag FFFF, status 0, slot FF,
; detail 0}.  Clobbers A, B.
EV_MAKE
	LD	(IY+CX_EV_TMP+UNETG_EVT_TYPE),A
	LD	B,0
	CP	UNETG_EV_LINK_LOST
	JR	Z,.global
	CP	UNETG_EV_CONFIG_EXPIRED
	JR	Z,.global
	CP	UNETG_EV_MODE_CHANGED
	JR	NZ,.chan
.global
	DEC	B
.chan
	LD	(IY+CX_EV_TMP+UNETG_EVT_CHANNEL),B
	LD	A,0xFF
	LD	(IY+CX_EV_TMP+UNETG_EVT_TAG),A
	LD	(IY+CX_EV_TMP+UNETG_EVT_TAG+1),A
	LD	(IY+CX_EV_TMP+UNETG_EVT_SLOT),A
	XOR	A
	LD	(IY+CX_EV_TMP+UNETG_EVT_STATUS),A
	LD	(IY+CX_EV_TMP+UNETG_EVT_DETAIL),A
	LD	(IY+CX_EV_TMP+UNETG_EVT_DETAIL+1),A
	RET

	IFDEF	UGB_HW_ESP
COST_EVENT	EQU	110		; one publication incl. EV_MAKE and the rest of the TX scan (units; stand 94 us)
	ELSE
COST_EVENT	EQU	70		; one publication incl. EV_MAKE (units; stand 51 us)
	ENDIF
COST_TXSCAN	EQU	65	; walking the TX slots for outcomes (units; stand 48 us)

; EV_AFFORD: in a budgeted call (STEP) take the cost of one publication
; BEFORE the event is built.  Out: CF=1 when it does not fit (the
; notification stays pending for a later call).  Clobbers A, DE, HL.
EV_AFFORD
	BIT	3,(IY+CX_CALL_FLAGS)	; UCF_BUDGET
	RET	Z			; CF=0 (BIT leaves CF alone; callers clear it)
	LD	HL,COST_EVENT
	CALL	TAKE
	RET	NC
EV_STARVED				; refused: the next STEP flushes first (CF=1 kept)
	SET	6,(IY+CX_CLK_FLAGS)	; UCLK_EV_FIRST
	RET

; EV_PUT: append ev_tmp.  Out: CF=1 when the queue is full (nothing
; written).  Clobbers A, BC, DE, HL.
EV_PUT
	LD	A,(IY+CX_EV_HEAD)
	LD	B,A
	INC	A
	AND	(IY+CX_EVENT_MASK)
	CP	(IY+CX_EV_TAIL)
	SCF
	RET	Z
	LD	C,A			; next head
	LD	L,B
	LD	H,0
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,HL
	LD	E,(IY+CX_EVENT_PTR)
	LD	D,(IY+CX_EVENT_PTR+1)
	ADD	HL,DE
	EX	DE,HL			; DE -> queue entry
	PUSH	BC
	LD	HL,CX_EV_TMP
	PUSH	IY
	POP	BC
	ADD	HL,BC
	LD	BC,UNETG_EVT_BYTES
	LDIR
	POP	BC
	LD	(IY+CX_EV_HEAD),C	; publish after the content
	OR	A
	RET

; EV_PUT_TYPE: afford + EV_MAKE + EV_PUT.  CF=1 when full or unaffordable.
EV_PUT_TYPE
	PUSH	AF
	OR	A
	CALL	EV_AFFORD
	JR	C,.no
	POP	AF
	CALL	EV_MAKE
	JR	EV_PUT
.no
	POP	AF
	SCF
	RET

; ----------------------------------------------------------------------
; EV_FLUSH: publish pending notifications while there is room.
; Clobbers A, BC, DE, HL; preserves IX.  Stack: 10.
; ----------------------------------------------------------------------
EV_FLUSH
	LD	A,(IY+CX_EV_FLAGS)
	AND	~UEVF_RXR_QUEUED & 0xFF
	RET	Z				; fast path: nothing pending
	BIT	0,(IY+CX_EV_FLAGS)		; UEVF_CONNECTED
	JR	Z,.reason
	LD	A,UNETG_EV_CONNECTED
	CALL	EV_PUT_TYPE
	RET	C
	RES	0,(IY+CX_EV_FLAGS)
.reason
	BIT	1,(IY+CX_EV_FLAGS)		; UEVF_REASON
	JR	Z,.tx
	OR	A
	CALL	EV_AFFORD
	RET	C
	LD	A,(IY+CX_EV_REASON)
	CALL	EV_MAKE
	LD	A,(IY+CX_EV_REASON_DETAIL)
	LD	(IY+CX_EV_TMP+UNETG_EVT_DETAIL),A
	LD	A,(IY+CX_EV_REASON_DETAIL+1)
	LD	(IY+CX_EV_TMP+UNETG_EVT_DETAIL+1),A
	CALL	EV_PUT
	RET	C
	RES	1,(IY+CX_EV_FLAGS)
.tx
	; TX outcomes in ring order: the oldest committed slot follows tx_next.
	BIT	7,(IY+CX_EV_FLAGS)		; UEVF_TXDONE
	JR	Z,.rx_ready
	IFDEF	UGB_HW_ETH
	CALL	ETH_TX_COPYING			; a slot is still being read by the card
	JR	C,.rx_ready			; pipeline: outcomes stay held
	ENDIF
	IFDEF	UGB_HW_ESP
	CALL	ESP_TX_COPYING			; a CIPSEND may still read its slot
	JR	C,.rx_ready
	ENDIF
	BIT	3,(IY+CX_CALL_FLAGS)		; UCF_BUDGET: the scan itself costs
	JR	Z,.tx_scan
	LD	HL,COST_TXSCAN
	CALL	TAKE
	JP	C,EV_STARVED
.tx_scan
	LD	C,(IY+CX_TX_NEXT)
	LD	B,(IY+CX_TX_SLOT_COUNT)
.tx_loop
	PUSH	BC
	CALL	TX_STATE_PTR
	LD	A,(HL)
	SUB	UTX_DONE_FIRST
	JR	C,.tx_next
	PUSH	HL
	PUSH	AF			; A = TX_DONE status
	OR	A
	CALL	EV_AFFORD
	JP	C,.tx_poor
	LD	A,UNETG_EV_TX_DONE
	CALL	EV_MAKE
	POP	AF
	LD	(IY+CX_EV_TMP+UNETG_EVT_STATUS),A
	POP	HL
	POP	BC
	PUSH	BC
	PUSH	HL
	LD	(IY+CX_EV_TMP+UNETG_EVT_SLOT),C
	CALL	TX_TAG_PTR
	LD	A,(HL)
	LD	(IY+CX_EV_TMP+UNETG_EVT_TAG),A
	INC	HL
	LD	A,(HL)
	LD	(IY+CX_EV_TMP+UNETG_EVT_TAG+1),A
	CALL	EV_PUT
	POP	HL
	JP	C,.tx_full
	LD	(HL),UTX_FREE
.tx_next
	POP	BC
	INC	C
	LD	A,C
	CP	(IY+CX_TX_SLOT_COUNT)
	JR	C,.tx_wrap
	LD	C,0
.tx_wrap
	DJNZ	.tx_loop
	RES	7,(IY+CX_EV_FLAGS)		; every outcome is in the queue
.rx_ready
	; RX_READY: one notification per empty -> non-empty transition,
	; merged with a not yet read RX_READY.
	BIT	2,(IY+CX_EV_FLAGS)		; UEVF_RXR_PEND
	JR	Z,.mode
	BIT	3,(IY+CX_EV_FLAGS)		; UEVF_RXR_QUEUED
	JR	NZ,.rx_merged
	LD	A,UNETG_EV_RX_READY
	CALL	EV_PUT_TYPE
	RET	C
	SET	3,(IY+CX_EV_FLAGS)
.rx_merged
	RES	2,(IY+CX_EV_FLAGS)
.mode
	BIT	4,(IY+CX_EV_FLAGS)		; UEVF_MODE
	JR	Z,.expired
	OR	A
	CALL	EV_AFFORD
	RET	C
	LD	A,UNETG_EV_MODE_CHANGED
	CALL	EV_MAKE
	LD	A,(IY+CX_FALLBACK_REASON)
	LD	(IY+CX_EV_TMP+UNETG_EVT_DETAIL),A
	CALL	EV_PUT
	RET	C
	RES	4,(IY+CX_EV_FLAGS)
.expired
	BIT	5,(IY+CX_EV_FLAGS)		; UEVF_EXPIRED
	JR	Z,.closed
	LD	A,UNETG_EV_CONFIG_EXPIRED
	CALL	EV_PUT_TYPE
	RET	C
	RES	5,(IY+CX_EV_FLAGS)
.closed
	BIT	6,(IY+CX_EV_FLAGS)		; UEVF_CLOSED
	RET	Z
	CALL	TX_ALL_FREE
	RET	NZ
	CALL	RX_IS_EMPTY
	RET	NZ
	LD	A,UNETG_EV_CLOSED
	CALL	EV_PUT_TYPE
	RET	C
	RES	6,(IY+CX_EV_FLAGS)
	XOR	A
	LD	(IY+CX_CHAN),UCH_CLOSED
	LD	(IY+CX_CHAN_FLAGS),A
	LD	A,(IY+CX_CLK_FLAGS)
	AND	~(UCLK_OP_ARMED | UCLK_OP_ARM) & 0xFF
	LD	(IY+CX_CLK_FLAGS),A
	PUSH	IX			; callers (NEXT_EVENT) keep their IX buffer
	CALL	TP_RESET
	POP	IX
	RET
.tx_poor
	POP	AF
	POP	HL
.tx_full
	POP	BC
	SCF
	RET

; ----------------------------------------------------------------------
; NEXT_EVENT.  In: IX = 8-byte buffer.  Out: A = OK or EMPTY (STATE
; without a context).  Taking an entry immediately lets held
; notifications into the freed space.
; ----------------------------------------------------------------------
EXP_NEXT_EVENT
	PUSH	IX
	PUSH	IY
	CALL	CTX_LOAD
	JP	Z,RET_STATE
	PUSH	IX
	POP	HL
	LD	DE,UNETG_EVT_BYTES
	CALL	RANGE
	JP	C,RET_BADARG
	LD	A,(IY+CX_EV_TAIL)
	CP	(IY+CX_EV_HEAD)
	JR	NZ,.take
	CALL	EV_FLUSH		; a held event may be waiting for room
	LD	A,(IY+CX_EV_TAIL)
	CP	(IY+CX_EV_HEAD)
	LD	A,UNETG_STATUS_EMPTY
	JP	Z,RET_A
	LD	A,(IY+CX_EV_TAIL)
.take
	LD	L,A
	LD	H,0
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,HL
	LD	E,(IY+CX_EVENT_PTR)
	LD	D,(IY+CX_EVENT_PTR+1)
	ADD	HL,DE
	PUSH	IX
	POP	DE
	LD	A,(HL)
	CP	UNETG_EV_RX_READY
	JR	NZ,.copy
	RES	3,(IY+CX_EV_FLAGS)		; the queued RX_READY is read
.copy
	LD	BC,UNETG_EVT_BYTES
	LDIR
	LD	A,(IY+CX_EV_TAIL)
	INC	A
	AND	(IY+CX_EVENT_MASK)
	LD	(IY+CX_EV_TAIL),A
	CALL	EV_FLUSH
	JP	RET_OK

; EV_EMPTY: Z when the queue is empty and nothing is pending.
EV_EMPTY
	LD	A,(IY+CX_EV_TAIL)
	CP	(IY+CX_EV_HEAD)
	RET	NZ
	LD	A,(IY+CX_EV_FLAGS)
	AND	~(UEVF_RXR_QUEUED) & 0xFF
	RET	NZ
	CALL	TX_ALL_FREE
	RET
