; tp_esp.asm -- transport entry points of the SprinterESP builds.
;
; TCP (GTCPESP): ESP-AT passive receive (AT+CIPRECVMODE=1): the module
; holds the peer data and announces it with "+IPD,0,<len>" (the bytes it
; holds; renewed after each read while some remain); the core asks
; for at most the free RX space with AT+CIPRECVDATA and publishes the
; bytes only after the final OK.  The module owns MSS, retransmission and
; the segments on the wire; SEND OK is not a peer ACK.
; UDP (GUDPESP): active receive ("+IPD,0,<len>:<data>"), one datagram per
; RX slot, dropped and counted when no slot is free or it does not fit.

; TP_STEP takes no cost of its own: the pending / overrun checks and the
; sequencer and parser dispatch are base time, and every action takes its
; own cost (a parse round, a pending line action, a job start, a command
; piece, a command result), so no transport entry eats the budget of the
; item it leads to.  A job start and its first piece need not share a
; STEP: ESP_ISSUE leaves ECS_BUILD, and a refused piece is built next STEP.
	ASSERT	COST_PARSE + 8 <= PROF_MAX_ITEM_US
	ASSERT	COST_PAY + ES_PAY_MAX <= PROF_MAX_ITEM_US
	ASSERT	COST_EOL <= PROF_MAX_ITEM_US && COST_HDR <= PROF_MAX_ITEM_US
	ASSERT	COST_PROMPT <= PROF_MAX_ITEM_US && COST_OVERRUN <= PROF_MAX_ITEM_US
	ASSERT	COST_PUBLISH <= PROF_MAX_ITEM_US
	ASSERT	COST_PICK <= PROF_MAX_ITEM_US
	ASSERT	COST_PIECE <= PROF_MAX_ITEM_US && COST_RESULT <= PROF_MAX_ITEM_US

; TP_OPEN: CIPSTART is issued by the sequencer once the module is idle.
TP_OPEN
	PUSH	IX
	ET_IX
	SET	EF_REQOPEN,(IX+ET_FL)
	XOR	A
	LD	(IX+ET_AVAIL),A
	LD	(IX+ET_AVAIL+1),A
	POP	IX
	RET

; TP_CLOSE: the sequencer closes the link after the committed slots.
TP_CLOSE
; TP_DEADLINES: command deadlines are owner-polled (esp_seq.asm).
TP_DEADLINES
	RET

; TP_ABORT: forget the channel.  A command already sent still runs to its
; terminal line (its result is discarded); one not sent yet is dropped.
; A payload being received for the channel is skipped.  Keeps IX.
TP_ABORT
	PUSH	IX
	ET_IX
	RES	EF_REQOPEN,(IX+ET_FL)
	XOR	A
	LD	(IX+ET_AVAIL),A
	LD	(IX+ET_AVAIL+1),A
	LD	A,(IX+ET_JOB)
	OR	A
	JR	Z,.payload
	CP	EJ_SETUP
	JR	Z,.payload
	LD	A,(IX+ET_CST)
	CP	ECS_WAIT
	JR	Z,.discard
	CP	ECS_DONE
	JR	Z,.discard
	CALL	ESP_JOB_END		; nothing in flight (not built yet, or busy pause)
	JR	.payload
.discard
	SET	EF_DISCARD,(IX+ET_FL)
.payload
	LD	A,(IX+ET_PST)
	OR	A
	JR	Z,.out
	IFDEF	UGB_RX_DGRAM
	LD	A,(IX+ET_PKIND)
	CP	EPK_UDP
	JR	NZ,.sink
	PUSH	IX
	CALL	RXD_DROP
	POP	IX
.sink
	ENDIF
	LD	(IX+ET_PKIND),EPK_SINK
.out
	POP	IX
	RET

; TP_RESET: after CLOSED.  The module state (set-up, command in flight)
; is kept.  Keeps IX (called from EV_FLUSH).
TP_RESET
	PUSH	IX
	ET_IX
	LD	A,(IX+ET_FL)
	AND	~((1 << EF_REQOPEN) | (1 << EF_CFAIL)) & 0xFF
	LD	(IX+ET_FL),A
	XOR	A
	LD	(IX+ET_AVAIL),A
	LD	(IX+ET_AVAIL+1),A
	LD	(IX+ET_PFAIL),A
	POP	IX
	RET

; ----------------------------------------------------------------------
; TP_STEP: parser and sequencer, while the UART is programmed (bring-up
; phase EUP_AT and RUN).
; ----------------------------------------------------------------------
TP_STEP
	LD	A,(IY+CX_HW_STATE)
	CP	UHW_INIT
	JR	Z,.hw
	CP	UHW_RUN
	RET	NZ
.hw
	BIT	ESF_UP,(IY+EX_FLAGS)
	RET	Z
	BIT	ESF_OVERRUN,(IY+EX_FLAGS)
	JR	Z,.parse
	LD	HL,COST_OVERRUN
	CALL	TAKE
	RET	C			; the realignment comes first: next STEP
	HWSM_IX
	CALL	ESP_OVERRUN
.parse
	; a pending parser action goes first (bytes are taken in order); then
	; the parser and the sequencer take turns to go first (bit 1 of the
	; STEP counter; bit 0 alternates hardware and transport), so neither a
	; long reply nor a busy sequencer starves the other.  Each visit pays
	; only its own item (no item chains two costs): WP2 priced the pending
	; action by kind (COST_EOL / COST_HDR / COST_PROMPT) instead of one
	; flat COST_LINE, freeing budget for the rest of the STEP, but a
	; second parse/pend visit the same STEP was measured to find nothing
	; new (HW_RUN delivers at most ES_RX_MAX bytes once per STEP; a round
	; sized ES_PARSE_MAX/ES_PAY_MAX already drains all of it) while still
	; taxing every STEP for the dispatch overhead of trying -- so TP_STEP
	; stays at one parse/pend visit per call; see WP4 (a second UART
	; drain, in STEP_ISR) before revisiting this.
	CALL	ESP_PEND
	BIT	USCH_ODD2,(IY+CX_SCHED_FLAGS)
	JR	Z,.seq_first
	CALL	ESP_PARSE
	CALL	ESP_PEND
	JP	ESP_SEQ
.seq_first
	CALL	ESP_SEQ
	CALL	ESP_PARSE
	JP	ESP_PEND

	IFDEF	UGB_FAT
; ----------------------------------------------------------------------
; Fat STEP (profile.inc PROF_FAT_MIN_US): a budget of about 1800 us and
; more is spent in rounds instead of one portion and one visit.
;
; TP_FAT: the transport's visit of a round.  The parser works while it
; has something whole to act on: ESP_LEAN's passes first, the generic
; round and its pending action for what is not theirs (up to
; TP_FAT_LINES actions).  A command that has just ended gets its result
; at once, before the lines after it (the stream order is the order of
; events).  The sequencer is visited last, and only when it can have
; work: in the first visit of the STEP (its deadline, a slot the
; application committed) and after a visit that acted (a result taken,
; a notice of held bytes, a failure line) -- its checks without work are
; base time, and the rounds are paid by COST_FAT_ROUND alone.
; Every action takes its own cost; a refusal ends the visit.
; ----------------------------------------------------------------------
TP_FAT_LINES	EQU	6
USCH_SEQD	EQU	6	; sched_flags: the sequencer was visited in this STEP
; TP_FAT_VISIT: TP_FAT with what TP_STEP checks first (the card runs:
; ESP_FAT is called for a running card only).
TP_FAT_VISIT
	LD	A,(IY+CX_STATE)
	CP	UNETG_CTXSTATE_CONFIGURED
	RET	NZ
	BIT	ESF_UP,(IY+EX_FLAGS)
	RET	Z
	BIT	ESF_OVERRUN,(IY+EX_FLAGS)
	JR	Z,TP_FAT
	LD	HL,COST_OVERRUN
	CALL	TAKE
	RET	C			; the realignment comes first: next STEP
	HWSM_IX
	CALL	ESP_OVERRUN
TP_FAT
	LD	BC,TP_FAT_LINES * 256	; C = 0: nothing acted yet
.line
	PUSH	BC
	CALL	ESP_PEND
	POP	BC
	JR	C,.seq			; refused: the action waits for the next STEP
	PUSH	BC
	CALL	ESP_LEAN
	POP	BC
	OR	A
	JR	Z,.acted		; an answer, a line, the prompt or a datagram
	DEC	A
	JR	NZ,.seq			; its end has not arrived yet
	LD	C,1
	PUSH	BC
	CALL	ESP_PARSE
	ET_IX
	POP	BC
	LD	A,(IX+ET_PEND)
	OR	A
	JR	Z,.seq			; nothing left to act on: the ring is read
	DJNZ	.line
	JR	.seq
.acted
	LD	C,1
	ET_IX
	LD	A,(IX+ET_CST)
	CP	ECS_DONE
	JR	NZ,.next
	PUSH	BC
	CALL	ESP_SEQ			; the result of the command
	ET_IX
	POP	BC
	LD	A,(IX+ET_CST)
	CP	ECS_DONE
	RET	Z			; no budget for it in this STEP
.next
	DJNZ	.line
.seq
	; a command that ended before this visit: its result, then (below)
	; the next job at once
	ET_IX
	LD	A,(IX+ET_CST)
	CP	ECS_DONE
	JR	NZ,.gate
	CALL	ESP_SEQ
	LD	C,1
.gate
	BIT	USCH_SEQD,(IY+CX_SCHED_FLAGS)
	JR	Z,.seq_go		; the first visit of the STEP: always
	; later visits: only a sequencer with nothing in flight after a
	; visit that acted, or a failure to raise (a command in flight has
	; only its deadline, looked at once per STEP)
	IFDEF	UGB_XMODE
	; a record being streamed: its next part or its result as soon as
	; the pump has sent what was there
	BIT	EXF_DATA,(IY+EX_XFL)
	JR	Z,.g_cmd
	ET_IX
	LD	A,(IX+ET_JOB)
	CP	EJ_SEND
	JR	Z,.seq_go
.g_cmd
	ENDIF
	LD	A,C
	OR	A
	RET	Z
	ET_IX
	LD	A,(IX+ET_PFAIL)
	OR	A
	JR	NZ,.seq_go
	LD	A,(IX+ET_JOB)
	OR	(IX+ET_CST)
	RET	NZ
.seq_go
	SET	USCH_SEQD,(IY+CX_SCHED_FLAGS)
	JP	ESP_SEQ

; ----------------------------------------------------------------------
; ESP_FAT: card and transport work of a fat STEP of a running card.
; A round is one pump (HW_STEP) and one transport visit (TP_FAT).  A
; further round runs only while it can bring something: the round made a
; TX stream (a command text or a payload) that its own pump has not seen,
; or the pump has just moved bytes of the module (more of the answer is
; on the line).  A stream the pump has already written from waits for
; the UART (THRE comes 1.4 ms later): no round for it.  A further round
; pays COST_FAT_ROUND for its dispatch (taken only when it fits: no
; refusal flag); at most ESP_FAT_ROUNDS rounds, and every item takes its
; cost, so the STEP is bounded by its budget as before.
; Clobbers all but IY.
; ----------------------------------------------------------------------
ESP_FAT_ROUNDS	EQU	3
COST_FAT_ROUND	EQU	75
COST_FAT_TXROUND EQU	30	; a further portion alone (the stream just made)
ESP_FAT
	; the transport first: what STEP_ISR has moved into the ring is
	; parsed and a command the sequencer issues goes out with the first
	; portion (no round of its own for it)
	CALL	TP_FAT_VISIT
	LD	B,ESP_FAT_ROUNDS
.round
	LD	A,(IY+EX_TXN)
	OR	(IY+EX_TXN+1)
	LD	C,A			; a stream waited before this round's pump
	PUSH	BC
	CALL	HW_FAT
	CALL	TP_FAT_VISIT
	POP	BC
	DEC	B
	RET	Z
	LD	A,C
	OR	A
	JR	NZ,.rx			; that stream waits for the UART
	LD	A,(IY+EX_TXN)
	OR	(IY+EX_TXN+1)
	JR	Z,.rx
	; the stream this visit made (the payload after the prompt, a
	; command after a result): a portion for it and nothing else -- what
	; it reads besides is parsed by the next STEP
	LD	HL,COST_FAT_TXROUND + COST_FPUMP + COST_FPUMP_ACT + 2 * (ES_TX_MAX + 1)
	CALL	UNITS_FIT
	RET	C
	LD	HL,COST_FAT_TXROUND
	CALL	TAKE
	JP	HW_FAT
.rx
	BIT	ESF_GOT,(IY+EX_FLAGS)
	RET	Z
	; the round and at least an active portion must fit
	LD	HL,COST_FAT_ROUND + COST_FPUMP + COST_FPUMP_ACT + 4 * 4
	CALL	UNITS_FIT
	RET	C
	PUSH	BC
	LD	HL,COST_FAT_ROUND
	CALL	TAKE
	POP	BC
	JR	.round
	ENDIF

; ESP_OVERRUN: the pump saw LSR.OE: bytes of the AT stream are lost.
; Counted; the parser drops the current payload and realigns on the next
; LF; a live channel fails with STREAM_ERROR(UART_OVERRUN) -- no partly
; lost block becomes RX.  The command in flight runs to its terminal line
; or deadline (a lost reply re-runs the set-up).
ESP_OVERRUN
	RES	ESF_OVERRUN,(IX+ES_FLAGS)
	IFDEF	UGB_FAT
	RES	ESF_LWAIT,(IX+ES_FLAGS)	; the stream is realigned: look again
	ENDIF
	STAT_INC UNETG_STATS_UART_OVERRUN
	ET_IX
	IFDEF	UGB_XMODE
	BIT	EXF_DATA,(IY+EX_XFL)
	JP	NZ,ESP_XOVERRUN		; data mode: the record is lost, the channel stays
	ENDIF
	LD	A,(IX+ET_PST)
	OR	A
	JR	Z,.line
	IFDEF	UGB_RX_DGRAM
	LD	A,(IX+ET_PKIND)
	CP	EPK_UDP
	JR	NZ,.drop
	PUSH	IX
	CALL	RXD_DROP
	POP	IX
.drop
	ENDIF
	LD	(IX+ET_PST),EPS_LINE
	LD	(IX+ET_PKIND),0
	; a CIPRECVDATA answer cut short: its OK must not publish anything
	LD	A,(IX+ET_JOB)
	CP	EJ_RECV
	JR	NZ,.line
	SET	EF_DISCARD,(IX+ET_FL)
.line
	SET	EF_RESYNC,(IX+ET_FL)
	LD	(IX+ET_LLEN),0
	LD	(IX+ET_PEND),EPD_NONE
	LD	A,UNETG_STREAM_UART_OVERRUN
	JP	ESP_STREAM_ERROR

; ESP_TX_COPYING: CF=1 while a CIPSEND job runs: the pump may still read
; its slot, so EV_FLUSH holds the TX_DONE outcomes until the job ends.
; Clobbers A, DE, HL.
ESP_TX_COPYING
	LD	A,(IY+CX_HW_STATE)	; a stopped UART sends nothing any more
	CP	UHW_RUN
	JR	NZ,.no
	LD	DE,UCTX_TP + ET_JOB - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,DE
	LD	A,(HL)
	CP	EJ_SEND
	SCF
	RET	Z
.no
	OR	A
	RET
