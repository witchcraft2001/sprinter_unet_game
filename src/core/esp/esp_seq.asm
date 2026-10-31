; esp_seq.asm -- AT command sequencer of the SprinterESP builds (main only).
;
; One command is in flight at a time.  A job (set-up, OPEN, CIPSEND,
; CIPRECVDATA, CLOSE) issues its commands in order; each
; command is built in budgeted pieces, sent by the UART pump, and ends with
; a terminal line (OK, ERROR, FAIL, SEND OK, SEND FAIL) or its deadline.
; "busy p..." means the module ignored the command: it is sent again after
; a pause.  Asynchronous lines (CONNECT, CLOSED, ready, WIFI DISCONNECT,
; +IPD notices) are handled whenever they arrive.
;
; When the channel of a command in flight is aborted (TP_ABORT), its
; result is discarded (EF_DISCARD) but the command still runs to its end,
; so the AT stream stays aligned.  A lost reply (deadline) re-runs the
; module set-up, which starts with "AT" and so absorbs a late reply.
; Command deadlines are polled by their owner and kept out of the STEP
; deadline (DL_ARM): STEP is called every worst_poll_gap_us anyway.

COST_PICK	EQU	70	; choice of the next job (TX slot, RX space, ring cursor)
COST_PIECE	EQU	140	; one literal run (<= 16 bytes) + one substitution of a command
COST_RESULT	EQU	150	; a finished command: slot outcome, RX commit (stand: <= 136 us)

ESP_AT_TRIES	EQU	5	; "AT" until the module answers (boot <= 2 s)
ESP_AT_MS	EQU	500
ESP_CMD_MS	EQU	1000
ESP_IO_MS	EQU	2000	; CIPRECVDATA, CIPCLOSE
ESP_START_MS	EQU	15000	; CIPSTART: the module gives up after 10 s
ESP_BUSY_MS	EQU	100
ESP_RECV_MAX	EQU	512	; bytes per CIPRECVDATA

; ----------------------------------------------------------------------
; Small helpers (IX = tp unless stated)
; ----------------------------------------------------------------------

; ET_ARM_CDL: ET_CDL = now + DE.  Clobbers A, BC, HL.
ET_ARM_CDL
	PUSH	IX
	POP	HL
	LD	BC,ET_CDL
	ADD	HL,BC
	JP	DL_ARM

; ET_CDL_DUE: CF=1 when ET_CDL is reached.  Clobbers A, BC, DE, HL.
ET_CDL_DUE
	PUSH	IX
	POP	HL
	LD	BC,ET_CDL
	ADD	HL,BC
	JP	DL_LEFT

; ES_TX_IDLE: Z when the UART pump has no stream to send.  Clobbers A.
ES_TX_IDLE
	LD	A,(IY+EX_TXN)
	OR	(IY+EX_TXN+1)
	RET

; ES_TX_STOP: drop the rest of the TX stream (the module restarted or the
; command ended without taking it).  Clobbers A.
ES_TX_STOP
	XOR	A
	LD	(IY+EX_TXN),A
	LD	(IY+EX_TXN+1),A
	RET

; ESP_LIVE: CF=0 when the channel exists and the transport is not done
; with it.  Clobbers A.
ESP_LIVE
	LD	A,(IY+CX_CHAN)
	OR	A
	SCF
	RET	Z
	BIT	1,(IY+CX_CHAN_FLAGS)	; UCHF_FINISHED
	SCF
	RET	NZ
	OR	A
	RET

; ESP_FAIL_LIVE: fail the live channel with reason A, detail E.  The
; failure (CH_FAIL: events, slot outcomes) is raised by the sequencer in
; its own budget item (ESP_SEQ), so a line action stays cheap; the first
; reason wins.  Sets IX = tp.  Clobbers A, C.
ESP_FAIL_LIVE
	LD	C,A
	CALL	ESP_LIVE
	RET	C
	ET_IX
	LD	A,(IX+ET_PFAIL)
	OR	A
	RET	NZ
	LD	(IX+ET_PFAIL),C
	LD	(IX+ET_PFDET),E
	RET

; ESP_STREAM_ERROR: STREAM_ERROR with detail A for a live channel, counted
; in stream_errors.  IX kept.
ESP_STREAM_ERROR
	LD	E,A
	CALL	ESP_LIVE
	RET	C
	ET_IX
	LD	A,(IX+ET_PFAIL)
	OR	A
	RET	NZ			; the channel already fails (first reason)
	PUSH	DE
	STAT_INC UNETG_STATS_STREAM_ERRORS
	POP	DE
	LD	D,0
	LD	A,UNETG_EV_STREAM_ERROR
	JP	ESP_FAIL_LIVE

; ESP_JOB_END: back to idle; a discarded result is forgotten.  IX = tp.
ESP_JOB_END
	XOR	A
	LD	(IX+ET_JOB),A
	LD	(IX+ET_IDX),A
	LD	(IX+ET_TRY),A
	LD	(IX+ET_CST),A
	RES	EF_DISCARD,(IX+ET_FL)
	RES	EF_PROMPT,(IX+ET_FL)
	RET

; ESP_JOB: start job A at its first command.  IX = tp.
ESP_JOB
	LD	(IX+ET_JOB),A
	XOR	A
	LD	(IX+ET_IDX),A
	LD	(IX+ET_TRY),A
	LD	(IX+ET_CST),A
	RET

; ----------------------------------------------------------------------
; ESP_TOKEN: a classified line.  In: A = TK_*, ET_LINK / ET_N1 / ET_N2.
; Clobbers A, BC, DE, HL, IX.
; ----------------------------------------------------------------------
ESP_TOKEN
	ET_IX
	CP	TK_ASYNC
	JR	NC,.async
	LD	C,A
	LD	A,(IX+ET_CST)
	CP	ECS_WAIT
	RET	NZ			; no command in flight: stray line
	LD	A,C
	CP	TK_BUSY
	JR	Z,.busy
	CP	TK_OK
	JR	NZ,.term
	LD	A,(IX+ET_JOB)
	CP	EJ_SEND
	RET	Z			; CIPSEND: OK comes before the prompt
.term
	LD	(IX+ET_TERM),C
	LD	(IX+ET_CST),ECS_DONE
	RET
.busy
	LD	(IX+ET_CST),ECS_PAUSE
	LD	DE,ESP_BUSY_MS
	JP	ET_ARM_CDL
.async
	CP	TK_CONNECT
	JR	NZ,.a_cfail
	CALL	.link0
	RET	NZ
	SET	EF_CONN,(IX+ET_FL)
	RET
.a_cfail
	CP	TK_CONNFAIL
	JR	NZ,.a_closed
	SET	EF_CFAIL,(IX+ET_FL)
	RET
.a_closed
	CP	TK_CLOSED
	JR	NZ,.a_ready
	CALL	.link0
	RET	NZ
	BIT	EF_CONN,(IX+ET_FL)
	RES	EF_CONN,(IX+ET_FL)
	RET	Z			; our link was not up (e.g. CIPCLOSE=5)
	; the peer (or the module) closed an open channel; while opening the
	; CIPSTART result decides, while closing our CIPCLOSE does
	LD	A,(IY+CX_CHAN)
	CP	UCH_OPEN
	RET	NZ
	LD	A,UNETG_EV_PEER_CLOSED
	LD	DE,0
	JP	ESP_FAIL_LIVE
.a_ready
	CP	TK_READY
	JR	NZ,.a_wifi
	; the module restarted: its links, modes and our command are gone
	LD	A,(IX+ET_FL)
	AND	~((1 << EF_READY) | (1 << EF_CONN) | (1 << EF_REQOPEN)) & 0xFF
	LD	(IX+ET_FL),A
	CALL	ES_TX_STOP
	CALL	ESP_JOB_END
	XOR	A
	LD	(IX+ET_AVAIL),A
	LD	(IX+ET_AVAIL+1),A
	LD	A,UNETG_EV_LINK_LOST
	LD	DE,0
	JP	ESP_FAIL_LIVE
.a_wifi
	CP	TK_WIFIOFF
	JR	NZ,.a_ipd
	RES	EF_CONN,(IX+ET_FL)
	LD	A,UNETG_EV_LINK_LOST
	LD	DE,0
	JP	ESP_FAIL_LIVE
.a_ipd
	IFDEF	UGB_RX_RING
	CP	TK_IPD
	RET	NZ
	; passive notice "+IPD,<link>,<len>": the module holds <len> bytes
	LD	A,(IX+ET_N1)
	OR	(IX+ET_N1+1)
	RET	NZ
	LD	A,(IX+ET_N2)
	LD	(IX+ET_AVAIL),A
	LD	A,(IX+ET_N2+1)
	LD	(IX+ET_AVAIL+1),A
	ENDIF
	RET
; .link0: Z when the line is for link 0 (or has no link prefix).
.link0
	LD	A,(IX+ET_LINK)
	OR	A
	RET	Z
	INC	A
	RET

; ----------------------------------------------------------------------
; ESP_PROMPT: '>' of CIPSEND: stream the slot payload.  Clobbers A, BC,
; DE, HL, IX.  The slot outcome is held while the job runs
; (ESP_TX_COPYING), so the bytes are still the application's.
; ----------------------------------------------------------------------
ESP_PROMPT
	ET_IX
	LD	A,(IX+ET_JOB)
	CP	EJ_SEND
	RET	NZ
	LD	A,(IX+ET_CST)
	CP	ECS_WAIT
	RET	NZ
	BIT	EF_PROMPT,(IX+ET_FL)
	RET	NZ
	SET	EF_PROMPT,(IX+ET_FL)
	LD	C,(IX+ET_TXSLOT)
	CALL	TX_LEN_PTR
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	PUSH	DE
	CALL	TX_BUF			; HL = payload
	POP	DE
	HWSM_IX
	LD	(IX+ES_TXP),L
	LD	(IX+ES_TXP+1),H
	LD	(IX+ES_TXN),E
	LD	(IX+ES_TXN+1),D
	LD	(IX+ES_TXKIND),ETXK_DATA
	RET

; ----------------------------------------------------------------------
; ESP_SEQ: advance the sequencer by one decision.  Clobbers all but IY.
; ----------------------------------------------------------------------
ESP_SEQ
	ET_IX
	LD	A,(IX+ET_PFAIL)
	OR	A
	JR	Z,.state
	; a channel failure found by the parser or a deadline
	LD	HL,COST_RESULT
	CALL	TAKE
	RET	C
	ET_IX
	LD	A,(IX+ET_PFAIL)
	LD	E,(IX+ET_PFDET)
	LD	D,0
	LD	(IX+ET_PFAIL),0
	LD	C,A
	CALL	ESP_LIVE
	RET	C
	LD	A,C
	JP	CH_FAIL
.state
	LD	A,(IX+ET_CST)
	CP	ECS_WAIT
	JR	Z,.wait
	CP	ECS_PAUSE
	JR	Z,.pause
	CP	ECS_BUILD
	JP	Z,ESP_BUILD
	CP	ECS_DONE
	JP	Z,ESP_DONE
	LD	A,(IX+ET_JOB)
	OR	A
	JP	Z,ESP_PICK
	JP	ESP_ISSUE
.wait
	CALL	ET_CDL_DUE
	RET	NC
	JP	ESP_TIMEOUT
.pause
	CALL	ET_CDL_DUE
	RET	NC
	LD	(IX+ET_CST),ECS_NONE
	JP	ESP_ISSUE

; ----------------------------------------------------------------------
; ESP_PICK: choose the next job.  IX = tp.
; ----------------------------------------------------------------------
; The checks are cheap (inside COST_ESP_STEP); COST_PICK is taken only
; when a job is about to start, so an idle channel costs no budget.
ESP_PICK
	CALL	ES_TX_IDLE
	RET	NZ			; the previous command is still going out
	BIT	EF_READY,(IX+ET_FL)
	JR	NZ,.ready
	BIT	ESF_SETUP_BAD,(IY+EX_FLAGS)
	RET	NZ			; module not qualified: nothing more to try
	CALL	.afford
	RET	C
	LD	A,EJ_SETUP
	CALL	ESP_JOB
	JP	ESP_ISSUE
.ready
	LD	A,(IY+CX_HW_STATE)
	CP	UHW_RUN
	RET	NZ
	LD	A,(IY+CX_CHAN)
	CP	UCH_OPENING
	JR	NZ,.not_opening
	BIT	EF_REQOPEN,(IX+ET_FL)
	RET	Z			; CIPSTART answered or in flight
	CALL	.afford
	RET	C
	RES	EF_REQOPEN,(IX+ET_FL)
	LD	A,EJ_OPEN
	CALL	ESP_JOB
	JP	ESP_ISSUE
.not_opening
	OR	A
	RET	Z			; CLOSED
	BIT	1,(IY+CX_CHAN_FLAGS)	; UCHF_FINISHED
	RET	NZ
	; OPEN or CLOSING: TX and RX take turns to go first
	LD	BC,UCTX_STATS - 4 + UNETG_STATS_STEPS_TOTAL - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,BC
	BIT	1,(HL)
	JR	Z,.rx_first
	CALL	.try_tx
	RET	NC
	CALL	.try_rx
	RET	NC
	JR	.rest
.rx_first
	CALL	.try_rx
	RET	NC
	CALL	.try_tx
	RET	NC
.rest
	LD	A,(IY+CX_CHAN)
	CP	UCH_CLOSING
	RET	NZ
	; closing and nothing more to send: close the link
	CALL	.afford
	RET	C
	LD	A,EJ_CLOSE
	CALL	ESP_JOB
	JP	ESP_ISSUE
; .afford: COST_PICK before a job starts.  CF=1: refused.  IX = tp after.
.afford
	ET_IX				; before TAKE: ET_IX ends in ADD IX,DE (CF)
	LD	HL,COST_PICK
	JP	TAKE			; TAKE keeps IX

; .try_tx: CF=1 when there is nothing to send (CF=0: a job started, or
; the budget refused it: stop either way).
.try_tx
	BIT	EF_CONN,(IX+ET_FL)
	SCF
	RET	Z
	LD	C,(IY+CX_TX_SEND)
	CALL	TX_STATE_PTR
	LD	A,(HL)
	CP	UTX_COMMITTED
	SCF
	RET	NZ
	CALL	.afford
	CCF
	RET	NC			; refused: next STEP
	LD	C,(IY+CX_TX_SEND)
	CALL	TX_STATE_PTR
	LD	(HL),UTX_SENDING
	LD	(IX+ET_TXSLOT),C
	CALL	TX_LEN_PTR
	LD	A,(HL)
	INC	HL
	OR	(HL)
	JR	NZ,.tx_go
	; empty slot: nothing to tell the module
	CALL	TX_STATE_PTR
	LD	A,UTX_DONE_OK
	TX_SET_DONE
	LD	A,C
	SLOT_INC CX_TX_SLOT_COUNT
	LD	(IY+CX_TX_SEND),A
	OR	A
	RET
.tx_go
	LD	A,EJ_SEND
	CALL	ESP_JOB
	CALL	ESP_ISSUE
	OR	A
	RET

; .try_rx: CF=1 when there is nothing to fetch.
.try_rx
	IFDEF	UGB_RX_RING
	BIT	EF_CONN,(IX+ET_FL)
	SCF
	RET	Z
	LD	A,(IX+ET_AVAIL)
	OR	(IX+ET_AVAIL+1)
	SCF
	RET	Z
	CALL	RXR_FREE		; HL = free RX bytes
	LD	A,H
	OR	L
	SCF
	RET	Z			; the application must read first
	PUSH	HL
	CALL	.afford
	POP	HL
	CCF
	RET	NC			; refused: next STEP
	LD	E,(IX+ET_AVAIL)
	LD	D,(IX+ET_AVAIL+1)
	CALL	MIN_DE_HL
	LD	HL,ESP_RECV_MAX
	CALL	MIN_DE_HL
	LD	(IX+ET_REQ),E
	LD	(IX+ET_REQ+1),D
	; the payload goes to the ring cursor, published by the final OK
	CALL	RXR_DEST		; DE = cursor
	LD	L,(IY+CX_RX_SLOTS_PTR)
	LD	H,(IY+CX_RX_SLOTS_PTR+1)
	EX	DE,HL
	LD	(IX+ET_RXDST),L
	LD	(IX+ET_RXDST+1),H
	OR	A
	SBC	HL,DE			; linear offset of the cursor
	EX	DE,HL
	LD	L,(IY+CX_RX_TOTAL)
	LD	H,(IY+CX_RX_TOTAL+1)
	OR	A
	SBC	HL,DE			; bytes before the ring wraps
	LD	(IX+ET_RXSPAN),L
	LD	(IX+ET_RXSPAN+1),H
	XOR	A
	LD	(IX+ET_PKIND),A
	LD	(IX+ET_GOT),A
	LD	(IX+ET_GOT+1),A
	LD	A,EJ_RECV
	CALL	ESP_JOB
	CALL	ESP_ISSUE
	OR	A
	RET
	ELSE
	SCF
	RET
	ENDIF

; ----------------------------------------------------------------------
; ESP_ISSUE: start building the current command of the job.  IX = tp.
; ----------------------------------------------------------------------
ESP_ISSUE
	CALL	ES_TX_IDLE
	RET	NZ
	LD	A,(IX+ET_JOB)
	CP	EJ_SETUP
	JR	NZ,.job
	LD	A,(IX+ET_IDX)
	LD	L,A
	ADD	A,A
	ADD	A,L			; 3 bytes per entry
	LD	E,A
	LD	D,0
	LD	HL,ESP_SETUP_TAB
	ADD	HL,DE
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	EX	DE,HL			; HL = template
	LD	DE,ESP_CMD_MS
	LD	A,(IX+ET_IDX)
	OR	A
	JR	NZ,.go
	LD	DE,ESP_AT_MS
	JR	.go
.job
	CP	EJ_OPEN
	JR	NZ,.j_send
	LD	HL,T_CLOSE0
	LD	DE,ESP_CMD_MS
	LD	A,(IX+ET_IDX)
	OR	A
	JR	Z,.go
	LD	HL,T_START
	LD	DE,ESP_START_MS
	JR	.go
.j_send
	CP	EJ_SEND
	JR	NZ,.j_recv
	LD	HL,T_SEND
	LD	E,(IY+CX_SEND_STALL_TIMEOUT_MS)
	LD	D,(IY+CX_SEND_STALL_TIMEOUT_MS+1)
	JR	.go
.j_recv
	CP	EJ_RECV
	JR	NZ,.j_close
	LD	HL,T_RECV
	LD	DE,ESP_IO_MS
	JR	.go
.j_close
	LD	HL,T_CLOSE0		; EJ_CLOSE
	LD	DE,ESP_IO_MS
.go
	LD	(IX+ET_TPL),L
	LD	(IX+ET_TPL+1),H
	LD	(IX+ET_CTMO),E
	LD	(IX+ET_CTMO+1),D
	XOR	A
	LD	(IX+ET_BPOS),A
	LD	(IX+ET_BLEN),A
	LD	(IX+ET_CST),ECS_BUILD
	INC	(IX+ET_TRY)
	; fall through

; ----------------------------------------------------------------------
; ESP_BUILD: build the command text, one literal run + one substitution
; per budget piece; then hand it to the pump and wait for its terminal.
; ----------------------------------------------------------------------
ESP_BUILD
	LD	HL,COST_PIECE
	CALL	TAKE
	RET	C
	ET_IX
	LD	E,(IX+ET_BPOS)
	LD	D,0
	LD	L,(IX+ET_TPL)
	LD	H,(IX+ET_TPL+1)
	ADD	HL,DE
	PUSH	HL			; [template]
	LD	E,(IX+ET_BLEN)
	LD	HL,ES_CMD_OFS - CTX_BIAS
	ADD	HL,DE
	PUSH	IY
	POP	DE
	ADD	HL,DE
	EX	DE,HL			; DE = buffer + length
	POP	HL
.lit
	LD	A,(HL)
	INC	HL
	OR	A
	JR	Z,.end
	CP	16
	JR	C,.sub
	LD	(DE),A
	INC	DE
	JR	.lit
.brk
	CALL	.save			; code 15: piece break (bounds a literal run)
	JR	ESP_BUILD
.sub
	CP	15
	JR	Z,.brk
	PUSH	HL
	CALL	ESP_SUBST		; DE advanced
	POP	HL
	CALL	.save
	JR	ESP_BUILD
.end
	EX	DE,HL
	LD	(HL),13
	INC	HL
	LD	(HL),10
	INC	HL
	EX	DE,HL
	CALL	.save
	; the pump sends it (main only, no race with STEP_ISR)
	LD	HL,ES_CMD_OFS - CTX_BIAS
	PUSH	IY
	POP	DE
	ADD	HL,DE
	LD	C,(IX+ET_BLEN)
	HWSM_IX
	LD	(IX+ES_TXP),L
	LD	(IX+ES_TXP+1),H
	LD	(IX+ES_TXN),C
	LD	(IX+ES_TXN+1),0
	LD	(IX+ES_TXKIND),ETXK_CMD
	ET_IX
	LD	(IX+ET_CST),ECS_WAIT
	LD	(IX+ET_TERM),TK_NONE
	LD	E,(IX+ET_CTMO)
	LD	D,(IX+ET_CTMO+1)
	JP	ET_ARM_CDL
; .save: ET_BPOS / ET_BLEN from HL (template) and DE (buffer).  Both are
; short (< 64), so low-byte differences suffice.  Clobbers A, BC.
.save
	ET_IX
	LD	A,L
	SUB	(IX+ET_TPL)
	LD	(IX+ET_BPOS),A
	PUSH	IY
	POP	BC
	LD	A,C
	ADD	A,LOW (ES_CMD_OFS - CTX_BIAS)
	LD	C,A
	LD	A,E
	SUB	C
	LD	(IX+ET_BLEN),A
	RET

; ESP_SUBST: substitution A (1..4, 8..11) at DE.  Out: DE advanced.
; Clobbers A, BC, HL, IX.
ESP_SUBST
	CP	8
	JR	C,.word
	; one octet of the peer address
	SUB	8
	PUSH	DE
	LD	E,A
	LD	D,0
	LD	HL,CX_PEER_IP
	ADD	HL,DE
	EX	DE,HL
	CALL	IY_PTR
	POP	DE
	LD	L,(HL)
	LD	H,0
	JR	DEC16
.word
	DEC	A
	JR	NZ,.lport
	LD	L,(IY+CX_PEER_PORT)
	LD	H,(IY+CX_PEER_PORT+1)
	JR	DEC16
.lport
	DEC	A
	JR	NZ,.txlen
	LD	L,(IY+CX_LOCAL_PORT)
	LD	H,(IY+CX_LOCAL_PORT+1)
	JR	DEC16
.txlen
	DEC	A
	JR	NZ,.req
	PUSH	DE
	ET_IX
	LD	C,(IX+ET_TXSLOT)
	CALL	TX_LEN_PTR
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A
	POP	DE
	JR	DEC16
.req
	ET_IX
	LD	L,(IX+ET_REQ)
	LD	H,(IX+ET_REQ+1)
	; fall through

; DEC16: HL in decimal at DE, no leading zeros.  Out: DE advanced.
; Clobbers A, BC, HL.
DEC16
	PUSH	DE			; [start]
	LD	BC,-10000
	CALL	.dig
	LD	BC,-1000
	CALL	.dig
	LD	BC,-100
	CALL	.dig
	LD	BC,-10
	CALL	.dig
	LD	A,L
	ADD	A,'0'
	LD	(DE),A
	INC	DE
	POP	HL			; start
	PUSH	HL
	LD	B,4
.z
	LD	A,(HL)
	CP	'0'
	JR	NZ,.nz
	INC	HL
	DJNZ	.z
.nz
	EX	DE,HL			; HL = end, DE = first significant digit
	OR	A
	SBC	HL,DE
	LD	B,H
	LD	C,L			; digits
	EX	DE,HL			; HL = first significant digit
	POP	DE			; start
	LDIR
	RET
.dig
	LD	A,'0' - 1
.d1
	INC	A
	ADD	HL,BC
	JR	C,.d1
	SBC	HL,BC			; CF=0 here: undo the last step
	LD	(DE),A
	INC	DE
	RET

; ----------------------------------------------------------------------
; ESP_DONE: the command in flight ended with ET_TERM.  IX = tp.
; ----------------------------------------------------------------------
ESP_DONE
	LD	HL,COST_RESULT
	CALL	TAKE
	RET	C
	ET_IX
	LD	(IX+ET_CST),ECS_NONE
	LD	A,(IX+ET_JOB)
	CP	EJ_SETUP
	JR	Z,.setup
	CP	EJ_OPEN
	JR	Z,.open
	CP	EJ_SEND
	JP	Z,.send
	CP	EJ_RECV
	JP	Z,.recv
	JP	.close			; EJ_CLOSE
.setup
	LD	A,(IX+ET_TERM)
	CP	TK_OK
	JR	Z,.s_next
	CP	TK_ERROR
	JR	NZ,.s_bad
	LD	A,(IX+ET_IDX)
	LD	L,A
	ADD	A,A
	ADD	A,L
	LD	E,A
	LD	D,0
	LD	HL,ESP_SETUP_TAB + 2
	ADD	HL,DE
	BIT	0,(HL)			; ERROR acceptable for this entry
	JR	NZ,.s_next
.s_bad
	LD	A,(IX+ET_IDX)
	OR	A
	JP	NZ,ESP_SETUP_FAIL
	LD	A,(IX+ET_TRY)
	CP	ESP_AT_TRIES
	JP	NC,ESP_SETUP_FAIL
	LD	(IX+ET_CST),ECS_PAUSE
	LD	DE,ESP_AT_MS
	JP	ET_ARM_CDL
.s_next
	LD	(IX+ET_TRY),0
	INC	(IX+ET_IDX)
	LD	A,(IX+ET_IDX)
	CP	ESP_SETUP_N
	RET	C
	SET	EF_READY,(IX+ET_FL)
	HWSM_IX
	SET	ESF_SETUP_OK,(IX+ES_FLAGS)
	ET_IX
	JP	ESP_JOB_END
.open
	BIT	EF_DISCARD,(IX+ET_FL)
	JP	NZ,ESP_JOB_END		; the link may stay up: the next OPEN closes it
	LD	A,(IX+ET_IDX)
	OR	A
	JR	NZ,.started
	; AT+CIPCLOSE=0 before CIPSTART: any answer will do
	INC	(IX+ET_IDX)
	LD	(IX+ET_TRY),0
	LD	A,(IX+ET_FL)
	AND	~((1 << EF_CONN) | (1 << EF_CFAIL)) & 0xFF
	LD	(IX+ET_FL),A
	RET
.started
	LD	A,(IX+ET_TERM)
	CP	TK_OK
	JR	NZ,.refused
	BIT	EF_CONN,(IX+ET_FL)
	JR	Z,.refused
	LD	(IY+CX_CHAN),UCH_OPEN
	SET	0,(IY+CX_EV_FLAGS)	; UEVF_CONNECTED
	RES	3,(IY+CX_CLK_FLAGS)	; the connect deadline is met
	SET	1,(IY+CX_WORK)		; UWK_PROTO
	JP	ESP_JOB_END
.refused
	; the module reports only that the link did not come up
	CALL	ESP_JOB_END
	LD	A,UNETG_EV_PEER_CLOSED
	LD	DE,0
	JP	ESP_FAIL_LIVE
.send
	BIT	EF_DISCARD,(IX+ET_FL)
	JR	NZ,.send_end		; CH_TERMINATE already gave the outcome
	LD	C,(IX+ET_TXSLOT)
	LD	A,(IX+ET_TERM)
	CP	TK_SENDOK
	LD	A,UTX_DONE_OK
	JR	Z,.send_res
	LD	A,UTX_DONE_FAILED
.send_res
	PUSH	AF
	CALL	TX_STATE_PTR
	POP	AF
	TX_SET_DONE
	CP	UTX_DONE_OK
	JR	NZ,.send_next
	STAT_INC UNETG_STATS_TX_FRAMES
	LD	C,(IX+ET_TXSLOT)
	CALL	TX_LEN_PTR
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	STAT_ADD32 UNETG_STATS_TX_BYTES
.send_next
	LD	A,(IX+ET_TXSLOT)
	SLOT_INC CX_TX_SLOT_COUNT
	LD	(IY+CX_TX_SEND),A
	SET	1,(IY+CX_WORK)
.send_end
	CALL	ES_TX_STOP		; nothing more of this slot may go out
	JP	ESP_JOB_END
.recv
	IFDEF	UGB_RX_RING
	BIT	EF_DISCARD,(IX+ET_FL)
	JR	NZ,.recv_end
	LD	A,(IX+ET_TERM)
	CP	TK_OK
	JR	NZ,.recv_none
	LD	A,(IX+ET_PKIND)
	CP	EPK_TCP
	JR	NZ,.recv_none		; "+CIPRECVDATA:0," or no header
	LD	A,(IX+ET_PST)
	OR	A
	JR	NZ,.recv_none		; payload incomplete
	; publish exactly the bytes of this answer
	LD	C,(IX+ET_GOT)
	LD	B,(IX+ET_GOT+1)
	PUSH	BC
	CALL	RXR_COMMIT
	POP	DE
	STAT_ADD32 UNETG_STATS_RX_BYTES
	STAT_INC UNETG_STATS_RX_FRAMES
	ET_IX
	SET	1,(IY+CX_WORK)
	JR	.recv_end
.recv_none
	; ERROR / an empty answer: nothing is held; the next notice tells
	; when there is more (no immediate retry)
	LD	A,(IX+ET_TERM)
	CP	TK_OK
	JR	Z,.recv_end		; the header already lowered the count
	XOR	A
	LD	(IX+ET_AVAIL),A
	LD	(IX+ET_AVAIL+1),A
.recv_end
	LD	(IX+ET_PKIND),0
	ENDIF
	JP	ESP_JOB_END
.close
	RES	EF_CONN,(IX+ET_FL)
	BIT	EF_DISCARD,(IX+ET_FL)
	JP	NZ,ESP_JOB_END
	CALL	ESP_JOB_END
	LD	A,(IY+CX_CHAN)
	CP	UCH_CLOSING
	RET	NZ
	BIT	1,(IY+CX_CHAN_FLAGS)
	RET	NZ
	LD	A,UTX_DONE_FAILED
	JP	CH_TERMINATE

; ESP_SETUP_FAIL: the module did not take the set-up (absent, wrong
; firmware: no passive TCP).  The bring-up ends in FAULT; a running card
; becomes FAULT.  IX = tp.
ESP_SETUP_FAIL
	CALL	ESP_JOB_END
	HWSM_IX
	SET	ESF_SETUP_BAD,(IX+ES_FLAGS)
	LD	A,(IY+CX_HW_STATE)
	CP	UHW_RUN
	RET	NZ
	LD	(IY+CX_HW_STATE),UHW_FAULT
	RET

; ----------------------------------------------------------------------
; ESP_TIMEOUT: the command in flight got no terminal line in time.
; ----------------------------------------------------------------------
ESP_TIMEOUT
	LD	A,(IX+ET_JOB)
	CP	EJ_SETUP
	JR	NZ,.chan
	LD	A,(IX+ET_IDX)
	OR	A
	JR	NZ,ESP_SETUP_FAIL
	LD	A,(IX+ET_TRY)
	CP	ESP_AT_TRIES
	JR	NC,ESP_SETUP_FAIL
	LD	(IX+ET_CST),ECS_NONE	; "AT" again
	RET
.chan
	BIT	EF_DISCARD,(IX+ET_FL)
	JR	NZ,.resync
	LD	A,(IX+ET_JOB)
	CP	EJ_SEND
	JR	NZ,.lost
	LD	A,UNETG_EV_TIMEOUT
	LD	DE,UNETG_TIMEOUT_TX
	CALL	ESP_FAIL_LIVE
	JR	.resync
.lost
	; the reply boundary is lost: the channel cannot trust the stream
	LD	A,UNETG_STREAM_PARSER
	CALL	ESP_STREAM_ERROR
.resync
	CALL	ES_TX_STOP
	RES	EF_READY,(IX+ET_FL)
	RES	EF_CONN,(IX+ET_FL)
	JP	ESP_JOB_END

; ----------------------------------------------------------------------
; Command templates: text, 1 = peer port, 2 = local port, 3 = length of
; the slot being sent, 4 = bytes requested, 8..11 = peer address octet
; 0..3 (one substitution per budget piece), 15 = piece break (no literal
; run longer than 16 bytes); 0 = end (CR LF is appended).
; ----------------------------------------------------------------------
T_AT		DB	"AT", 0
T_ATE0		DB	"ATE0", 0
T_CLOSE5	DB	"AT+CIPCLOSE=5", 0
T_MUX1		DB	"AT+CIPMUX=1", 0
T_DINFO0	DB	"AT+CIPDINFO=0", 0
T_CLOSE0	DB	"AT+CIPCLOSE=0", 0
T_SEND		DB	"AT+CIPSEND=0,", 3, 0
	IFDEF	UGB_TP_TCP
T_RECVMODE	DB	"AT+CIPRECVMODE=", 15, "1", 0
T_TCPOPT	DB	"AT+CIPTCPOPT=", 15, "5,-1,0,4000", 0
T_START		DB	"AT+CIPSTART=0,", 15, 0x22, "TCP", 0x22, ",", 0x22, 8, ".", 9, ".", 10, ".", 11, 0x22, ",", 1, 0
T_RECV		DB	"AT+CIPRECVDATA=", 15, "0,", 4, 0
	ELSE
T_RECVMODE	DB	"AT+CIPRECVMODE=", 15, "0", 0
T_START		DB	"AT+CIPSTART=0,", 15, 0x22, "UDP", 0x22, ",", 0x22, 8, ".", 9, ".", 10, ".", 11, 0x22, ",", 1, ",", 2, ",0", 0
T_RECV		EQU	T_AT		; not used: UDP is received actively
	ENDIF

; Module set-up: DW template, DB flags (bit 0: ERROR is acceptable).
; "AT" is retried until the module answers; the passive receive mode is
; the qualification of the TCP profile (ESP-AT 2.2.x): ERROR -> FAULT.
ESP_SETUP_TAB
	DW	T_AT
	DB	0
	DW	T_ATE0
	DB	0
	DW	T_CLOSE5
	DB	1
	DW	T_MUX1
	DB	0
	IFDEF	UGB_TP_TCP
	DW	T_RECVMODE
	DB	0
	ELSE
	DW	T_RECVMODE
	DB	1
	ENDIF
	DW	T_DINFO0
	DB	1
	IFDEF	UGB_TP_TCP
	DW	T_TCPOPT
	DB	1
	ENDIF
ESP_SETUP_END
ESP_SETUP_N	EQU	(ESP_SETUP_END - ESP_SETUP_TAB) / 3
