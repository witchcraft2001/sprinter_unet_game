; loop.asm -- loopback transport (GLOOP): what the application sends comes
; back to it, with the same ABI, slot rules and event order as the
; network builds.  TCP semantics: a byte stream into the RX ring, flow
; controlled by free RX space.  UDP semantics: one datagram per RX slot,
; dropped (and counted) when no slot is free.

LOOP_CHUNK	EQU	128		; largest copy portion (bytes)
COST_LOOP_ITER	EQU	80		; one pass over the TX cursor, taken before it
COST_LOOP_FIXED	EQU	110		; copy portion besides LDIR, incl. slot completion

TP_OPEN
TP_CLOSE
TP_DEADLINES
	RET

TP_ABORT
TP_RESET
	XOR	A
	LD	(IY+CX_TX_OFF),A
	LD	(IY+CX_TX_OFF+1),A
	RET

TP_STEP
	LD	A,(IY+CX_CHAN)
	CP	UCH_OPENING
	JR	NZ,.data
	; A loopback partner is always there: connected at the first step.
	LD	(IY+CX_CHAN),UCH_OPEN
	SET	0,(IY+CX_EV_FLAGS)	; UEVF_CONNECTED
	RES	3,(IY+CX_CLK_FLAGS)	; connect deadline no longer armed
	SET	1,(IY+CX_WORK)		; UWK_PROTO
.data
	LD	A,(IY+CX_CHAN)
	CP	UCH_OPEN
	JR	Z,.move
	CP	UCH_CLOSING
	RET	NZ
	BIT	1,(IY+CX_CHAN_FLAGS)	; UCHF_FINISHED
	RET	NZ
.move
	LD	HL,COST_LOOP_ITER
	CALL	TAKE
	RET	C
	LD	C,(IY+CX_TX_SEND)
	CALL	TX_STATE_PTR
	LD	A,(HL)
	CP	UTX_COMMITTED
	JR	Z,.start
	CP	UTX_SENDING
	JR	Z,.chunk
	; nothing committed: a closing channel is finished
	LD	A,(IY+CX_CHAN)
	CP	UCH_CLOSING
	RET	NZ
	LD	A,UTX_DONE_FAILED
	JP	CH_TERMINATE
.start
	LD	(HL),UTX_SENDING
	XOR	A
	LD	(IY+CX_TX_OFF),A
	LD	(IY+CX_TX_OFF+1),A
.chunk
	; remaining = len - off, n = min(remaining, CHUNK [, free RX])
	CALL	TX_LEN_PTR
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	LD	L,(IY+CX_TX_OFF)
	LD	H,(IY+CX_TX_OFF+1)
	EX	DE,HL
	OR	A
	SBC	HL,DE
	EX	DE,HL			; DE = remaining
	LD	HL,LOOP_CHUNK
	CALL	MIN_DE_HL
	IFDEF	UGB_RX_DYN
	LD	A,(IY+CX_TRANSPORT)
	CP	UNETG_TRANSPORT_TCP
	JR	NZ,.dgram
	ENDIF
	IFDEF	UGB_RX_RING
	PUSH	DE
	CALL	RXR_FREE
	POP	DE
	CALL	MIN_DE_HL
	LD	A,D
	OR	E
	JR	NZ,.copy_ring
	SET	2,(IY+CX_WORK)		; blocked by a full RX ring: retry later
	RET
.copy_ring
	LD	HL,COST_LOOP_FIXED
	XOR	A			; LDIR: one unit per byte
	CALL	BUDGET_BYTES		; BC = portion
	RET	C
	PUSH	BC
	CALL	LOOP_SRC		; HL = source
	POP	BC
	PUSH	BC
	CALL	RXR_PUT
	POP	DE
	JR	.advance
	ENDIF
.dgram
	IFDEF	UGB_RX_DGRAM
	LD	HL,COST_LOOP_FIXED
	XOR	A
	CALL	BUDGET_BYTES
	RET	C
	LD	D,B
	LD	E,C			; DE = portion
	LD	A,(IY+CX_TX_OFF)
	OR	(IY+CX_TX_OFF+1)
	JR	NZ,.d_copy
	; first chunk: a datagram needs a free RX slot, else it is lost whole
	PUSH	DE
	CALL	RXD_TAKE
	POP	DE
	JR	NC,.d_copy
	STAT_INC UNETG_STATS_RING_OVERFLOW
	LD	C,(IY+CX_TX_SEND)
	JR	.sent
.d_copy
	PUSH	DE
	LD	C,(IY+CX_RX_FILL)
	CALL	RX_BUF
	LD	E,(IY+CX_TX_OFF)
	LD	D,(IY+CX_TX_OFF+1)
	ADD	HL,DE
	PUSH	HL
	CALL	LOOP_SRC
	POP	DE
	POP	BC
	PUSH	BC
	LDIR
	POP	DE
	ENDIF
.advance
	PUSH	DE
	STAT_ADD32 UNETG_STATS_RX_BYTES
	POP	DE
	PUSH	DE
	STAT_ADD32 UNETG_STATS_TX_BYTES
	POP	DE
	LD	L,(IY+CX_TX_OFF)
	LD	H,(IY+CX_TX_OFF+1)
	ADD	HL,DE
	LD	(IY+CX_TX_OFF),L
	LD	(IY+CX_TX_OFF+1),H
	SET	1,(IY+CX_WORK)		; UWK_PROTO
	LD	C,(IY+CX_TX_SEND)
	PUSH	HL			; new offset
	CALL	TX_LEN_PTR		; clobbers DE
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A
	POP	DE
	OR	A
	SBC	HL,DE
	JR	Z,.complete
	SET	2,(IY+CX_WORK)		; UWK_MORE: the slot is not finished
	RET
.complete
	IFDEF	UGB_RX_DGRAM
	IFDEF	UGB_RX_DYN
	LD	A,(IY+CX_TRANSPORT)
	CP	UNETG_TRANSPORT_TCP
	JR	Z,.sent
	ENDIF
	LD	B,D
	LD	C,E
	CALL	RXD_PUBLISH
	STAT_INC UNETG_STATS_RX_FRAMES
	LD	C,(IY+CX_TX_SEND)
	ENDIF
.sent
	CALL	TX_STATE_PTR
	LD	A,UTX_DONE_OK
	TX_SET_DONE
	STAT_INC UNETG_STATS_TX_FRAMES
	XOR	A
	LD	(IY+CX_TX_OFF),A
	LD	(IY+CX_TX_OFF+1),A
	LD	A,(IY+CX_TX_SEND)
	SLOT_INC CX_TX_SLOT_COUNT
	LD	(IY+CX_TX_SEND),A
	JP	.move

; LOOP_SRC: HL = tx_send buffer + tx_off.  Clobbers A, C, DE.
LOOP_SRC
	LD	C,(IY+CX_TX_SEND)
	CALL	TX_BUF
	LD	E,(IY+CX_TX_OFF)
	LD	D,(IY+CX_TX_OFF+1)
	ADD	HL,DE
	RET
