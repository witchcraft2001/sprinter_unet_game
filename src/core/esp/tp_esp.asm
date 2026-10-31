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

COST_ESP_STEP	EQU	90	; TP_STEP entry, pending / overrun checks, sequencer dispatch and job checks
; Chains one STEP must afford after the transport entry (min_useful_budget):
; a parse round, a pending line action, a job start, a command piece, a
; command result.  A job start and its first piece need not share a STEP:
; ESP_ISSUE leaves ECS_BUILD, and a refused piece is built next STEP.
	ASSERT	COST_ESP_STEP + COST_PARSE + 8 <= PROF_MAX_ITEM_US
	ASSERT	COST_ESP_STEP + COST_PARSE + COST_PAY + 1 <= PROF_MAX_ITEM_US
	ASSERT	COST_ESP_STEP + COST_LINE <= PROF_MAX_ITEM_US
	ASSERT	COST_ESP_STEP + COST_PICK <= PROF_MAX_ITEM_US
	ASSERT	COST_ESP_STEP + COST_PIECE <= PROF_MAX_ITEM_US
	ASSERT	COST_ESP_STEP + COST_RESULT <= PROF_MAX_ITEM_US

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
	LD	HL,COST_ESP_STEP
	CALL	TAKE
	RET	C
	BIT	ESF_OVERRUN,(IY+EX_FLAGS)
	JR	Z,.parse
	LD	HL,COST_LINE
	CALL	TAKE
	RET	C			; the realignment comes first: next STEP
	HWSM_IX
	CALL	ESP_OVERRUN
.parse
	; a pending parser action goes first (bytes are taken in order); then
	; the parser and the sequencer take turns to go first (bit 1 of the
	; STEP counter; bit 0 alternates hardware and transport), so neither a
	; long reply nor a busy sequencer starves the other
	CALL	ESP_PEND
	LD	BC,UCTX_STATS - 4 + UNETG_STATS_STEPS_TOTAL - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,BC
	BIT	1,(HL)
	JR	Z,.seq_first
	CALL	ESP_PARSE
	CALL	ESP_PEND
	JP	ESP_SEQ
.seq_first
	CALL	ESP_SEQ
	CALL	ESP_PARSE
	JP	ESP_PEND

; ESP_OVERRUN: the pump saw LSR.OE: bytes of the AT stream are lost.
; Counted; the parser drops the current payload and realigns on the next
; LF; a live channel fails with STREAM_ERROR(UART_OVERRUN) -- no partly
; lost block becomes RX.  The command in flight runs to its terminal line
; or deadline (a lost reply re-runs the set-up).
ESP_OVERRUN
	RES	ESF_OVERRUN,(IX+ES_FLAGS)
	STAT_INC UNETG_STATS_UART_OVERRUN
	ET_IX
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
