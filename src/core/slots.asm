; slots.asm -- TX/RX slot queues and their exports (9..13).
;
; TX: fixed slots used in ring order.  TX_RESERVE hands out slot tx_next,
; TX_COMMIT publishes it to the transport and advances tx_next; the
; transport consumes committed slots from tx_send.  A slot returns to
; FREE only after its TX_DONE is in the event queue (events.asm).
;
; RX, two modes over the same application slots:
;  * ring (TCP): the slots form one contiguous byte ring of rx_total bytes;
;    RX_PEEK returns the unread bytes up to the end of the current slot,
;    so the advertised TCP window is exactly the free space;
;  * datagram (UDP): one datagram per slot, published whole or dropped.

; ---- index helpers (C = slot) -------------------------------------------
; Clobber DE, HL; preserve BC.
TX_STATE_PTR
	LD	DE,CX_TX_STATE
	JR	IDX8
RX_STATE_PTR
	LD	DE,CX_RX_STATE
IDX8
	PUSH	IY
	POP	HL
	ADD	HL,DE
	LD	E,C
	LD	D,0
	ADD	HL,DE
	RET
TX_TAG_PTR
	LD	DE,UCTX_TX_TAG - CTX_BIAS
	JR	IDX16
TX_LEN_PTR
	LD	DE,CX_TX_LEN
	JR	IDX16
RX_LEN_PTR
	LD	DE,CX_RX_LEN
IDX16
	PUSH	IY
	POP	HL
	ADD	HL,DE
	LD	E,C
	LD	D,0
	ADD	HL,DE
	ADD	HL,DE
	RET

; TX_BUF / RX_BUF: HL = slot C buffer address.  Clobbers A, DE.
TX_BUF
	LD	L,(IY+CX_TX_SLOTS_PTR)
	LD	H,(IY+CX_TX_SLOTS_PTR+1)
	LD	E,(IY+CX_TX_SLOT_SIZE)
	LD	D,(IY+CX_TX_SLOT_SIZE+1)
	JR	SLOT_MUL
RX_BUF
	LD	L,(IY+CX_RX_SLOTS_PTR)
	LD	H,(IY+CX_RX_SLOTS_PTR+1)
	LD	E,(IY+CX_RX_SLOT_SIZE)
	LD	D,(IY+CX_RX_SLOT_SIZE+1)
SLOT_MUL
	LD	A,C
	OR	A
	RET	Z
.add
	ADD	HL,DE
	DEC	A
	JR	NZ,.add
	RET

; NEXT_SLOT: A = (A + 1) mod count at (HL).  Clobbers nothing else.
	MACRO	SLOT_INC field_count
	INC	A
	CP	(IY+field_count)
	JR	C,1F
	XOR	A
1
	ENDM

; TX_ALL_FREE: Z when every TX slot is FREE.  Clobbers A, B, DE, HL.
TX_ALL_FREE
	LD	DE,CX_TX_STATE
	CALL	IY_PTR
	LD	B,(IY+CX_TX_SLOT_COUNT)
.loop
	LD	A,(HL)
	OR	A
	RET	NZ
	INC	HL
	DJNZ	.loop
	RET

; RX_IS_EMPTY: Z when no received data waits for the application.
RX_IS_EMPTY
	IFDEF	UGB_RX_DYN
	LD	A,(IY+CX_TRANSPORT)
	CP	UNETG_TRANSPORT_TCP
	JR	NZ,.dgram
	ENDIF
	IFDEF	UGB_RX_RING
	LD	A,(IY+CX_RX_USED)
	OR	(IY+CX_RX_USED+1)
	RET
	ENDIF
.dgram
	IFDEF	UGB_RX_DGRAM
	LD	DE,CX_RX_STATE
	CALL	IY_PTR
	LD	B,(IY+CX_RX_SLOT_COUNT)
.d_loop
	LD	A,(HL)
	CP	URX_READY
	JR	NC,.busy		; READY or PEEKED
	INC	HL
	DJNZ	.d_loop
	XOR	A
	RET
.busy
	OR	A			; NZ (A >= 2)
	RET
	ENDIF

; RX_DISCARD_ALL: ABORT semantics -- drop every received byte/datagram.
RX_DISCARD_ALL
	XOR	A
	LD	(IY+CX_RX_USED),A
	LD	(IY+CX_RX_USED+1),A
	LD	(IY+CX_RX_FILL),A
	LD	(IY+CX_RX_READ),A
	LD	(IY+CX_RX_WR_OFF),A
	LD	(IY+CX_RX_WR_OFF+1),A
	LD	(IY+CX_RX_RD_OFF),A
	LD	(IY+CX_RX_RD_OFF+1),A
	LD	DE,CX_RX_STATE
	CALL	IY_PTR
	LD	B,UCTX_MAX_SLOTS
.clr
	LD	(HL),A
	INC	HL
	DJNZ	.clr
	DEC	A
	LD	(IY+CX_RX_PEEK_SLOT),A
	LD	A,(IY+CX_EV_FLAGS)
	AND	~(UEVF_RXR_PEND) & 0xFF
	LD	(IY+CX_EV_FLAGS),A
	RET

; ----------------------------------------------------------------------
; TX_RESERVE.  In: DE = n (1 .. payload limit).
; Out: A = OK, HL = buffer (also ctx.out_hl), E = slot, D = 0;
;      WOULD_BLOCK (next slot busy), STATE (no open channel or a
;      reservation is pending), BAD_ARGUMENT (n).
; ----------------------------------------------------------------------
EXP_TX_RESERVE
	PUSH	IX
	PUSH	IY
	CALL	CTX_LOAD
	JP	Z,RET_STATE
	CALL	TX_ALLOWED
	JP	NZ,RET_STATE
	LD	A,(IY+CX_TX_RES_SLOT)
	INC	A
	JP	NZ,RET_STATE		; one reservation at a time
	LD	A,D
	OR	E
	JP	Z,RET_BADARG
	PUSH	DE
	CALL	CFG_LIMIT		; HL = payload limit of this channel
	OR	A
	SBC	HL,DE
	POP	DE
	JP	C,RET_BADARG
	LD	C,(IY+CX_TX_NEXT)
	PUSH	DE
	CALL	TX_STATE_PTR
	POP	DE
	LD	A,(HL)
	OR	A
	LD	A,UNETG_STATUS_WOULD_BLOCK
	JP	NZ,RET_A
	LD	(HL),UTX_RESERVED
	LD	(IY+CX_TX_RES_SLOT),C
	LD	(IY+CX_TX_RES_LEN),E
	LD	(IY+CX_TX_RES_LEN+1),D
	CALL	TX_TAG_PTR
	LD	(HL),0xFF
	INC	HL
	LD	(HL),0xFF
	CALL	TX_BUF
	LD	(IY+CX_OUT_HL),L
	LD	(IY+CX_OUT_HL+1),H
	LD	E,C
	LD	D,0
	JP	RET_OK

; TX_ALLOWED: Z when new TX operations are accepted (configured context,
; open channel, not finishing, configuration not expired).
TX_ALLOWED
	LD	A,(IY+CX_STATE)
	CP	UNETG_CTXSTATE_CONFIGURED
	RET	NZ
	LD	A,(IY+CX_CHAN)
	CP	UCH_OPEN
	RET	NZ
	LD	A,(IY+CX_CHAN_FLAGS)
	AND	UCHF_FINISHED | UCHF_ABORTED
	RET	NZ
	BIT	2,(IY+CX_CLK_FLAGS)	; UCLK_EXPIRED
	RET

; CFG_LIMIT: HL = payload limit of the configured transport.
CFG_LIMIT
	LD	HL,UNETG_TCP_MSS
	LD	A,(IY+CX_TRANSPORT)
	CP	UNETG_TRANSPORT_UDP
	RET	NZ
	LD	HL,UNETG_UDP_MAX
	RET

; ----------------------------------------------------------------------
; TX_COMMIT.  In: A = slot, DE = used (1..n), IX = tag (not 0xFFFF,
; unique among outstanding operations and unread TX_DONE).
; Out: OK; BAD_ARGUMENT (slot/length/tag; the reservation is kept);
;      STATE (no reservation or the channel is no longer open).
; ----------------------------------------------------------------------
EXP_TX_COMMIT
	PUSH	IX
	PUSH	IY
	PUSH	AF
	CALL	CTX_LOAD
	POP	BC			; B = slot
	JP	Z,RET_STATE
	LD	A,(IY+CX_TX_RES_SLOT)
	CP	0xFF
	JP	Z,RET_STATE
	CP	B
	JP	NZ,RET_BADARG
	LD	C,A
	LD	A,D
	OR	E
	JP	Z,RET_BADARG
	LD	L,(IY+CX_TX_RES_LEN)
	LD	H,(IY+CX_TX_RES_LEN+1)
	OR	A
	SBC	HL,DE
	JP	C,RET_BADARG		; used > n
	PUSH	IX
	POP	HL
	LD	A,H
	AND	L
	INC	A
	JP	Z,RET_BADARG		; 0xFFFF is reserved
	PUSH	DE
	CALL	TAG_IN_USE
	POP	DE
	JP	Z,RET_BADARG
	CALL	TX_ALLOWED
	JP	NZ,RET_STATE
	PUSH	DE
	CALL	TX_LEN_PTR
	POP	DE
	LD	(HL),E
	INC	HL
	LD	(HL),D
	CALL	TX_TAG_PTR
	PUSH	IX
	POP	DE
	LD	(HL),E
	INC	HL
	LD	(HL),D
	CALL	TX_STATE_PTR
	LD	(HL),UTX_COMMITTED
	LD	(IY+CX_TX_RES_SLOT),0xFF
	LD	A,C
	SLOT_INC CX_TX_SLOT_COUNT
	LD	(IY+CX_TX_NEXT),A
	JP	RET_OK

; TAG_IN_USE: Z when tag IX belongs to another non-free slot.
; In: C = the slot being committed (skipped).  Clobbers A, B, DE, HL.
TAG_IN_USE
	PUSH	BC
	LD	B,(IY+CX_TX_SLOT_COUNT)
.loop
	DEC	B
	LD	A,B
	CP	C
	JR	Z,.next
	PUSH	BC
	LD	C,B
	CALL	TX_STATE_PTR
	LD	A,(HL)
	OR	A
	JR	Z,.skip
	CALL	TX_TAG_PTR
	PUSH	IX
	POP	DE
	LD	A,(HL)
	CP	E
	JR	NZ,.skip
	INC	HL
	LD	A,(HL)
	CP	D
	JR	NZ,.skip
	POP	BC
	POP	BC
	XOR	A			; Z: in use
	RET
.skip
	POP	BC
.next
	LD	A,B
	OR	A
	JR	NZ,.loop
	POP	BC
	; published but unread TX_DONE events keep their tag reserved
	LD	B,(IY+CX_EV_TAIL)
.queue
	LD	A,B
	CP	(IY+CX_EV_HEAD)
	JR	Z,.unique
	LD	L,A
	LD	H,0
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,HL
	LD	E,(IY+CX_EVENT_PTR)
	LD	D,(IY+CX_EVENT_PTR+1)
	ADD	HL,DE
	LD	A,(HL)
	CP	UNETG_EV_TX_DONE
	JR	NZ,.q_next
	INC	HL
	INC	HL
	PUSH	IX
	POP	DE
	LD	A,(HL)
	CP	E
	JR	NZ,.q_next
	INC	HL
	LD	A,(HL)
	CP	D
	RET	Z			; Z: in use
.q_next
	LD	A,B
	INC	A
	AND	(IY+CX_EVENT_MASK)
	LD	B,A
	JR	.queue
.unique
	OR	1			; NZ
	RET

; ----------------------------------------------------------------------
; TX_UNRESERVE.  In: A = slot.  Cancels a reservation without an event.
; ----------------------------------------------------------------------
EXP_TX_UNRESERVE
	PUSH	IX
	PUSH	IY
	PUSH	AF
	CALL	CTX_LOAD
	POP	BC
	JP	Z,RET_STATE
	LD	A,(IY+CX_TX_RES_SLOT)
	CP	0xFF
	JP	Z,RET_STATE
	CP	B
	JP	NZ,RET_BADARG
	LD	C,A
	CALL	TX_STATE_PTR
	LD	(HL),UTX_FREE
	LD	(IY+CX_TX_RES_SLOT),0xFF
	CALL	EV_FLUSH		; CLOSED may have waited for this slot
	JP	RET_OK

; ----------------------------------------------------------------------
; RX_PEEK.  Out: A = OK, HL = data, DE = length (both also in ctx), the
; slot in ctx.rx_peek_slot; EMPTY when nothing is waiting.  Repeating it
; before RX_RELEASE returns the same region.
; ----------------------------------------------------------------------
EXP_RX_PEEK
	PUSH	IX
	PUSH	IY
	CALL	CTX_LOAD
	JP	Z,RET_STATE
	LD	A,(IY+CX_RX_PEEK_SLOT)
	INC	A
	JR	NZ,.again
	IFDEF	UGB_RX_DYN
	LD	A,(IY+CX_TRANSPORT)
	CP	UNETG_TRANSPORT_TCP
	JR	NZ,.dgram
	ENDIF
	IFDEF	UGB_RX_RING
	LD	E,(IY+CX_RX_USED)
	LD	D,(IY+CX_RX_USED+1)
	LD	A,D
	OR	E
	JR	Z,.empty
	LD	L,(IY+CX_RX_SLOT_SIZE)
	LD	H,(IY+CX_RX_SLOT_SIZE+1)
	LD	C,(IY+CX_RX_RD_OFF)
	LD	B,(IY+CX_RX_RD_OFF+1)
	OR	A
	SBC	HL,BC			; bytes left in this slot
	CALL	MIN_DE_HL
	LD	A,(IY+CX_RX_READ)
	JR	.set
	ENDIF
.dgram
	IFDEF	UGB_RX_DGRAM
	LD	C,(IY+CX_RX_READ)
	CALL	RX_STATE_PTR
	LD	A,(HL)
	CP	URX_READY
	JR	NZ,.empty
	LD	(HL),URX_PEEKED
	CALL	RX_LEN_PTR
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	LD	A,C
	ENDIF
.set
	LD	(IY+CX_RX_PEEK_SLOT),A
	LD	(IY+CX_RX_PEEK_LEN),E
	LD	(IY+CX_RX_PEEK_LEN+1),D
.again
	LD	C,(IY+CX_RX_PEEK_SLOT)
	CALL	RX_BUF
	IFDEF	UGB_RX_RING
	IFDEF	UGB_RX_DYN
	LD	A,(IY+CX_TRANSPORT)
	CP	UNETG_TRANSPORT_TCP
	JR	NZ,.no_off
	ENDIF
	LD	E,(IY+CX_RX_RD_OFF)
	LD	D,(IY+CX_RX_RD_OFF+1)
	ADD	HL,DE
.no_off
	ENDIF
	LD	E,(IY+CX_RX_PEEK_LEN)
	LD	D,(IY+CX_RX_PEEK_LEN+1)
	LD	(IY+CX_OUT_HL),L
	LD	(IY+CX_OUT_HL+1),H
	LD	(IY+CX_OUT_DE),E
	LD	(IY+CX_OUT_DE+1),D
	XOR	A
	POP	IY
	POP	IX
	RET
.empty
	LD	A,UNETG_STATUS_EMPTY
	JP	RET_A

; MIN_DE_HL: DE = min(DE, HL).  Clobbers HL.
MIN_DE_HL
	OR	A
	SBC	HL,DE
	RET	NC
	ADD	HL,DE
	EX	DE,HL
	RET

; ----------------------------------------------------------------------
; RX_RELEASE.  Releases the region of the outstanding RX_PEEK.
; Out: OK, or STATE when there is no outstanding RX_PEEK.
; ----------------------------------------------------------------------
EXP_RX_RELEASE
	PUSH	IX
	PUSH	IY
	CALL	CTX_LOAD
	JP	Z,RET_STATE
	LD	A,(IY+CX_RX_PEEK_SLOT)
	CP	0xFF
	JP	Z,RET_STATE
	LD	C,A
	IFDEF	UGB_RX_DYN
	LD	A,(IY+CX_TRANSPORT)
	CP	UNETG_TRANSPORT_TCP
	JR	NZ,.dgram
	ENDIF
	IFDEF	UGB_RX_RING
	LD	E,(IY+CX_RX_PEEK_LEN)
	LD	D,(IY+CX_RX_PEEK_LEN+1)
	LD	L,(IY+CX_RX_USED)
	LD	H,(IY+CX_RX_USED+1)
	OR	A
	SBC	HL,DE
	LD	(IY+CX_RX_USED),L
	LD	(IY+CX_RX_USED+1),H
	LD	L,(IY+CX_RX_RD_OFF)
	LD	H,(IY+CX_RX_RD_OFF+1)
	ADD	HL,DE
	LD	E,(IY+CX_RX_SLOT_SIZE)
	LD	D,(IY+CX_RX_SLOT_SIZE+1)
	OR	A
	SBC	HL,DE
	JR	Z,.next_slot
	ADD	HL,DE
	JR	.store
.next_slot
	LD	A,C
	SLOT_INC CX_RX_SLOT_COUNT
	LD	(IY+CX_RX_READ),A
.store
	LD	(IY+CX_RX_RD_OFF),L
	LD	(IY+CX_RX_RD_OFF+1),H
	SET	2,(IY+CX_CHAN_FLAGS)	; UCHF_WINUPD
	JR	.done
	ENDIF
.dgram
	IFDEF	UGB_RX_DGRAM
	CALL	RX_STATE_PTR
	LD	(HL),URX_FREE
	LD	A,C
	SLOT_INC CX_RX_SLOT_COUNT
	LD	(IY+CX_RX_READ),A
	ENDIF
.done
	LD	(IY+CX_RX_PEEK_SLOT),0xFF
	CALL	EV_FLUSH
	JP	RET_OK

; ======================================================================
; Writers used by the transports (main context only).
; ======================================================================
	IFDEF	UGB_RX_RING
; RXR_FREE: HL = free bytes of the ring.  Clobbers DE.
RXR_FREE
	LD	L,(IY+CX_RX_TOTAL)
	LD	H,(IY+CX_RX_TOTAL+1)
	LD	E,(IY+CX_RX_USED)
	LD	D,(IY+CX_RX_USED+1)
	OR	A
	SBC	HL,DE
	RET

; RXR_DEST: DE = address of the write cursor, BC = contiguous bytes up to
; the end of its slot.  Clobbers A, HL.
RXR_DEST
	PUSH	BC
	LD	C,(IY+CX_RX_FILL)
	CALL	RX_BUF
	POP	BC
	LD	E,(IY+CX_RX_WR_OFF)
	LD	D,(IY+CX_RX_WR_OFF+1)
	ADD	HL,DE
	PUSH	HL
	LD	L,(IY+CX_RX_SLOT_SIZE)
	LD	H,(IY+CX_RX_SLOT_SIZE+1)
	OR	A
	SBC	HL,DE
	LD	B,H
	LD	C,L
	POP	DE
	RET

; RXR_ADVANCE: move the write cursor by BC bytes (BC <= RXR_DEST span)
; and publish them.  Raises RX_READY on an empty -> non-empty transition.
; Clobbers A, DE, HL.
RXR_ADVANCE
	LD	L,(IY+CX_RX_WR_OFF)
	LD	H,(IY+CX_RX_WR_OFF+1)
	ADD	HL,BC
	LD	E,(IY+CX_RX_SLOT_SIZE)
	LD	D,(IY+CX_RX_SLOT_SIZE+1)
	OR	A
	SBC	HL,DE
	JR	NZ,.same
	LD	A,(IY+CX_RX_FILL)
	SLOT_INC CX_RX_SLOT_COUNT
	LD	(IY+CX_RX_FILL),A
	JR	.cursor
.same
	ADD	HL,DE
.cursor
	LD	(IY+CX_RX_WR_OFF),L
	LD	(IY+CX_RX_WR_OFF+1),H
	LD	L,(IY+CX_RX_USED)
	LD	H,(IY+CX_RX_USED+1)
	LD	A,H
	OR	L
	JR	NZ,.was_busy
	SET	2,(IY+CX_EV_FLAGS)	; UEVF_RXR_PEND
.was_busy
	ADD	HL,BC
	LD	(IY+CX_RX_USED),L
	LD	(IY+CX_RX_USED+1),H
	RET

; RXR_COMMIT: publish BC bytes already written at the ring cursor, slot
; piece by slot piece (the writer filled RXR_DEST spans).  Clobbers A, BC,
; DE, HL.
RXR_COMMIT
.loop
	LD	A,B
	OR	C
	RET	Z
	PUSH	BC
	CALL	RXR_DEST		; BC = bytes to the end of the slot
	POP	HL			; HL = remaining
	PUSH	HL
	OR	A
	SBC	HL,BC
	JR	NC,.piece		; remaining >= span: publish the span
	POP	BC
	PUSH	BC
.piece
	POP	HL
	OR	A
	SBC	HL,BC
	PUSH	HL
	CALL	RXR_ADVANCE
	POP	BC
	JR	.loop

; RXR_PUT: copy BC bytes from HL into the ring (BC <= RXR_FREE) and
; publish them.  Clobbers A, BC, DE, HL.
RXR_PUT
.piece
	LD	A,B
	OR	C
	RET	Z
	PUSH	HL			; source
	PUSH	BC			; remaining
	CALL	RXR_DEST		; DE = dest, BC = span
	POP	HL			; HL = remaining
	PUSH	HL
	OR	A
	SBC	HL,BC
	JR	NC,.span_ok		; remaining >= span: copy the span
	POP	BC
	PUSH	BC			; remaining < span: copy the rest
.span_ok
	POP	HL			; remaining
	OR	A
	SBC	HL,BC
	EX	(SP),HL			; (SP) = remaining after, HL = source
	PUSH	BC
	LDIR
	POP	BC
	PUSH	HL
	CALL	RXR_ADVANCE
	POP	HL
	POP	BC
	JR	.piece
	ENDIF

	IFDEF	UGB_RX_DGRAM
; RXD_TAKE: start filling slot rx_fill.  Out: CF=1 when it is not free;
; otherwise HL = buffer, C = slot.  Clobbers A, DE.
RXD_TAKE
	LD	C,(IY+CX_RX_FILL)
	CALL	RX_STATE_PTR
	LD	A,(HL)
	OR	A
	SCF
	RET	NZ
	LD	(HL),URX_FILLING
	CALL	RX_BUF
	OR	A
	RET

; RXD_PUBLISH: the filled slot gets length BC and becomes READY.
; Clobbers A, C, DE, HL.
RXD_PUBLISH
	PUSH	BC
	LD	C,(IY+CX_RX_FILL)
	CALL	RX_LEN_PTR
	POP	DE
	LD	(HL),E
	INC	HL
	LD	(HL),D
	CALL	RX_STATE_PTR
	LD	(HL),URX_READY
	LD	A,C
	CP	(IY+CX_RX_READ)
	JR	NZ,.not_first		; older datagrams are still unread
	SET	2,(IY+CX_EV_FLAGS)	; UEVF_RXR_PEND
.not_first
	SLOT_INC CX_RX_SLOT_COUNT
	LD	(IY+CX_RX_FILL),A
	RET

; RXD_DROP: abandon the slot being filled.
RXD_DROP
	LD	C,(IY+CX_RX_FILL)
	CALL	RX_STATE_PTR
	LD	(HL),URX_FREE
	RET
	ENDIF
