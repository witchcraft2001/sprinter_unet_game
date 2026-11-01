; esp_parse.asm -- byte parser of the ESP-AT stream (main only).
;
; Bytes come from the UART ring (src/hw/esp/uart.asm) in budgeted rounds;
; the parser keeps its whole state in ctx.tp, so it resumes after any byte,
; including the middle of a +IPD or +CIPRECVDATA header (ТЗ §2, ABI §5).
;
; Grammar (ESP-AT 2.2, CIPMUX=1, link 0, CIPDINFO=0):
;   lines           <text> CR LF; CR alone also ends a line ("+IPD,0,<n>\r")
;   link prefixes   "<n>," before CONNECT / CLOSED / SEND OK ... (stripped;
;                   the first number is the link id, other links ignored)
;   prompt          '>' as the first byte of a line (CIPSEND)
;   payload         "+IPD,<link>,<len>:" (active UDP) and
;                   "+CIPRECVDATA:<len>," (passive TCP): exactly <len>
;                   binary bytes follow; they are never searched for text.
; Lines longer than ES_LINE_MAX are counted, not stored, and ignored.

ES_PARSE_MAX	EQU	48	; line bytes per parse round
ES_PAY_MAX	EQU	55	; payload bytes per parse round
COST_PARSE	EQU	150	; line round: ring head, sizing, tail, refund, two slow line bytes
				; (+ 16 units per line byte: 8 overran the STEP on the stand);
				; its own cost only, never on top of COST_PAY
COST_PAY	EQU	165	; payload round, its own item: ESP_PAY twice (the payload
				; reaches the end of the RX ring and continues at its
				; start), the round's sizing and tail (ESP_PROGRESS,
				; ER_SET_TAIL: stand ~150 us for the whole round); a
				; completed UDP datagram's RXD_PUBLISH is deferred to its
				; own item (EPD_PUBLISH) so this stays bytes-only (+ 1
				; unit per payload byte)
; ESP_PEND: a pending action's own cost, by kind (WP2: replaces the one flat
; COST_LINE -- no item chains two costs, and a cheap action no longer
; reserves the worst case of every kind).
COST_EOL	EQU	190	; EPD_EOL: ESP_LINE classification + token dispatch
COST_HDR	EQU	165	; EPD_COLON / EPD_COMMA: a header candidate (ESP_HDR_IPD/_RECV)
COST_PROMPT	EQU	95	; EPD_PROMPT: ESP_PROMPT (CIPSEND payload hookup)
COST_PUBLISH	EQU	80	; EPD_PUBLISH: RXD_PUBLISH + stats of a completed UDP datagram
COST_OVERRUN	EQU	60	; TP_STEP's realignment after LSR.OE (ESP_OVERRUN)
	ASSERT	ES_PAY_MAX < 256 && ES_PARSE_MAX < 256 && COST_PARSE + 1 < 256
	ASSERT	COST_PAY + ES_PAY_MAX < 256

; IX = ctx.tp (preserves DE)
	MACRO	ET_IX
	PUSH	DE
	LD	DE,UCTX_TP - CTX_BIAS
	PUSH	IY
	POP	IX
	ADD	IX,DE
	POP	DE
	ENDM

; ----------------------------------------------------------------------
; ESP_PARSE: one round per STEP (a second one only after a ring wrap):
; the UART brings < 16 bytes per poll, and every round has its fixed cost.
; Clobbers A, BC, DE, HL, IX.
; ----------------------------------------------------------------------
ESP_PARSE
	ET_IX
	CALL	.one			; CF=0: the round reached the ring end
	RET	C
	; the bytes after the wrap
	ET_IX
.one
	LD	A,(IX+ET_PEND)
	OR	A
	SCF
	RET	NZ			; the pending action first
	; not even a one-byte round fits: no sizing (a refused attempt costs
	; base time too)
	LD	A,(IY+CX_UNITS+1)
	OR	A
	JR	NZ,.sizing
	LD	A,(IY+CX_UNITS)
	CP	COST_PARSE + 1
	JR	NC,.sizing
	SET	4,(IY+CX_WORK)		; UWK_YIELD
	SCF
	RET
.sizing
	CALL	ER_HEAD			; HL = waiting, DE = tail
	LD	A,H
	OR	L
	SCF
	RET	Z
	PUSH	DE			; [tail]
	LD	B,H
	LD	C,L			; BC = waiting
	LD	HL,ER_SIZE
	OR	A
	SBC	HL,DE			; HL = bytes up to the ring end
	LD	D,B
	LD	E,C
	CALL	MIN_DE_HL		; DE = contiguous bytes waiting
	ET_IX
	LD	A,(IX+ET_PST)
	OR	A
	JR	NZ,.pay_round
	; line bytes: the round stops at the first byte that needs an action
	; (ET_PEND, its own budget item); the bytes it did not reach are
	; refunded
	LD	HL,ES_PARSE_MAX
	CALL	MIN_DE_HL
	LD	BC,-COST_PARSE
.size
	LD	A,4			; 16 units per line byte
	CALL	PARSE_BUDGET
	POP	DE			; tail
	RET	C
	JR	.go
.pay_round
	; payload bytes: a round never runs past the payload (its bytes are
	; charged at the copy rate); its own item (COST_PAY), never on top of
	; COST_PARSE
	LD	L,(IX+ET_PLEFT)
	LD	H,(IX+ET_PLEFT+1)
	CALL	MIN_DE_HL
	LD	HL,ES_PAY_MAX
	CALL	MIN_DE_HL
	LD	BC,-COST_PAY
	XOR	A			; 1 unit per payload byte (LDIR)
	CALL	PARSE_BUDGET
	POP	DE
	RET	C
.go
	PUSH	DE			; [tail]
	PUSH	BC			; [tail][n]
	LD	L,(IY+CX_HW_RING_PTR)
	LD	H,(IY+CX_HW_RING_PTR+1)
	ADD	HL,DE
	CALL	ESP_BYTES		; BC = bytes not consumed
	; give back what an unaffordable action left unused (line rounds only:
	; a payload round is always consumed whole)
	LD	H,B
	LD	L,C
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,HL			; 16 units per line byte
	CALL	UNITS_REFUND
	POP	HL			; n
	OR	A
	SBC	HL,BC			; consumed
	CALL	NZ,ESP_PROGRESS
	POP	DE			; tail
	ADD	HL,DE
	LD	A,H
	AND	HIGH ER_MASK
	LD	H,A
	PUSH	HL
	CALL	ER_SET_TAIL
	POP	HL
	LD	A,H
	OR	L
	RET	Z			; CF=0: wrapped to the ring start
	SCF
	RET

; PARSE_BUDGET: size a parse round.  In: DE = bytes wanted (> 0), BC =
; -(fixed) (the round's own fixed cost, as its negative: the same value is
; the affordability threshold and the charge -- a round pays only its own
; item, never another round's fixed cost too), A = log2 of units per byte.
; Out: CF=0, BC = bytes (1..DE), units -= fixed + (BC << A); CF=1
; (UWK_YIELD) when not one byte fits.  Clobbers A, DE, HL.
PARSE_BUDGET
	LD	L,(IY+CX_UNITS)
	LD	H,(IY+CX_UNITS+1)
	ADD	HL,BC			; CF=1: units >= fixed
	JR	NC,.refuse
	PUSH	BC			; [-(fixed)]
	LD	C,A			; shift
	OR	A
	JR	Z,.aff
	LD	B,A
.shr
	SRL	H
	RR	L
	DJNZ	.shr
.aff
	CALL	MIN_DE_HL		; DE = min(wanted, affordable)
	LD	A,D
	OR	E
	JR	Z,.refuse_pop
	LD	H,D
	LD	L,E
	LD	A,C
	OR	A
	JR	Z,.cost
	LD	B,A
.shl
	ADD	HL,HL
	DJNZ	.shl
.cost
	LD	B,D
	LD	C,E			; BC = bytes
	POP	DE			; DE = -(fixed)
	OR	A
	SBC	HL,DE			; HL += fixed (DE is -(fixed))
	EX	DE,HL
	LD	L,(IY+CX_UNITS)
	LD	H,(IY+CX_UNITS+1)
	OR	A
	SBC	HL,DE
	LD	(IY+CX_UNITS),L
	LD	(IY+CX_UNITS+1),H
	RET				; CF=0
.refuse_pop
	POP	BC			; stack balance (the saved -(fixed) is unused)
.refuse
	SET	4,(IY+CX_WORK)		; UWK_YIELD
	SCF
	RET

; ESP_BYTES: HL = first byte, BC = count.  Out: BC = bytes left over
; (the round stopped at a byte that left an action).  Clobbers A, DE, HL, IX.
ESP_BYTES
	ET_IX
.loop
	LD	A,B
	OR	C
	RET	Z
	LD	A,(IX+ET_PST)
	OR	A
	JR	NZ,.pay
	BIT	EF_RESYNC,(IX+ET_FL)
	JR	NZ,.slow
	LD	A,(IX+ET_LLEN)
	CP	ES_LINE_MAX
	JR	NC,.slow
	; a run of plain line bytes straight into the line buffer; it stops at
	; CR, LF, ',', ':', '>' (handled one by one) or a full buffer
	PUSH	HL
	CALL	LINE_AT			; HL = line + LLEN (A = LLEN)
	EX	DE,HL			; DE = write pointer
	POP	HL
	LD	B,(IX+ET_LLEN)		; rounds are < 256 bytes: C is the count
.run
	LD	A,(HL)
	CP	0x3F
	JR	NC,.plain		; letters
	CP	'0'
	JR	C,.low
	CP	':'
	JR	C,.plain		; digits
	JR	.stop			; ':' ';' '<' '=' '>'
.low
	CP	','
	JR	Z,.stop
	CP	14
	JR	NC,.plain		; space, '+', '-', '.' ...
	CP	13
	JR	Z,.stop
	CP	10
	JR	Z,.stop
.plain
	LD	(DE),A
	INC	DE
	INC	HL
	INC	B
	DEC	C
	JR	Z,.stop
	LD	A,B
	CP	ES_LINE_MAX
	JR	C,.run
.stop
	LD	(IX+ET_LLEN),B
	LD	B,0
	LD	A,C
	OR	A
	RET	Z
.slow
	LD	A,(HL)
	PUSH	HL
	PUSH	BC
	CALL	ESP_LBYTE		; consumed; may leave an action pending
	POP	BC
	POP	HL
	INC	HL
	DEC	BC
	LD	A,(IX+ET_PEND)
	OR	A
	JR	Z,.loop
	RET				; the action comes first
.pay
	CALL	ESP_PAY			; HL / BC advanced; IX = tp
	LD	A,(IX+ET_PEND)
	OR	A
	JR	Z,.loop
	RET				; a completed datagram's publish comes first

; ----------------------------------------------------------------------
; ESP_PAY: payload bytes.  In: HL = source, BC = bytes available (> 0),
; IX = tp.  Out: HL, BC advanced by the bytes taken; IX = tp.
; ----------------------------------------------------------------------
ESP_PAY
	PUSH	HL			; [src]
	LD	E,(IX+ET_PLEFT)
	LD	D,(IX+ET_PLEFT+1)
	LD	H,B
	LD	L,C
	CALL	MIN_DE_HL		; DE = min(payload left, available)
	LD	A,(IX+ET_PKIND)
	CP	EPK_TCP
	JR	NZ,.span_ok
	LD	L,(IX+ET_RXSPAN)
	LD	H,(IX+ET_RXSPAN+1)
	CALL	MIN_DE_HL		; never across the end of the RX ring
.span_ok
	POP	HL			; src
	PUSH	BC			; [avail]
	PUSH	DE			; [avail][k]
	LD	A,(IX+ET_PKIND)
	CP	EPK_SINK
	JR	Z,.skip
	LD	B,D
	LD	C,E
	LD	E,(IX+ET_RXDST)
	LD	D,(IX+ET_RXDST+1)
	LDIR
	LD	(IX+ET_RXDST),E
	LD	(IX+ET_RXDST+1),D
	JR	.copied
.skip
	ADD	HL,DE
.copied
	POP	DE			; k
	POP	BC			; avail
	PUSH	HL			; [src']
	LD	H,B
	LD	L,C
	OR	A
	SBC	HL,DE
	LD	B,H
	LD	C,L			; avail -= k
	LD	L,(IX+ET_PLEFT)
	LD	H,(IX+ET_PLEFT+1)
	OR	A
	SBC	HL,DE
	LD	(IX+ET_PLEFT),L
	LD	(IX+ET_PLEFT+1),H
	LD	A,(IX+ET_PKIND)
	CP	EPK_TCP
	JR	NZ,.span_done
	LD	L,(IX+ET_RXSPAN)
	LD	H,(IX+ET_RXSPAN+1)
	OR	A
	SBC	HL,DE
	JR	NZ,.span_left
	; the RX ring wraps: continue at the start of the slots
	LD	A,(IY+CX_RX_SLOTS_PTR)
	LD	(IX+ET_RXDST),A
	LD	A,(IY+CX_RX_SLOTS_PTR+1)
	LD	(IX+ET_RXDST+1),A
	LD	L,(IY+CX_RX_TOTAL)
	LD	H,(IY+CX_RX_TOTAL+1)
.span_left
	LD	(IX+ET_RXSPAN),L
	LD	(IX+ET_RXSPAN+1),H
.span_done
	POP	HL			; src'
	LD	A,(IX+ET_PLEFT)
	OR	(IX+ET_PLEFT+1)
	RET	NZ
	; payload complete; TCP bytes are published by the final OK.  A UDP
	; datagram's publish (RXD_PUBLISH, its stats, PKIND reset) is its own
	; item (EPD_PUBLISH, ESP_PEND): not bytes-proportional, so folding it
	; into this round would force every payload round's own cost
	; (COST_PAY) to cover it too, shrinking ES_PAY_MAX far below what a
	; round actually needs for the common (non-final) case.
	LD	(IX+ET_PST),EPS_LINE
	IFDEF	UGB_RX_DGRAM
	LD	A,(IX+ET_PKIND)
	CP	EPK_UDP
	RET	NZ
	LD	(IX+ET_PEND),EPD_PUBLISH
	ENDIF
	RET

; ----------------------------------------------------------------------
; ESP_LBYTE: one byte outside a payload, always consumed.  In: A = byte,
; IX = tp.  A byte that needs an action (line end, CIPSEND prompt, the ':'
; / ',' that may end a payload header) is left in ET_PEND: the round stops
; and ESP_PEND performs it as its own budget item.  Clobbers A, C, DE, HL.
; ----------------------------------------------------------------------
ESP_LBYTE
	LD	C,A
	BIT	EF_RESYNC,(IX+ET_FL)
	JR	Z,.norm
	; after an overrun: drop everything up to the next LF
	CP	10
	RET	NZ
	RES	EF_RESYNC,(IX+ET_FL)
	LD	(IX+ET_LLEN),0
	RET
.norm
	CP	13
	JR	Z,.eol
	CP	10
	JR	Z,.eol
	LD	A,(IX+ET_LLEN)
	OR	A
	JR	NZ,.mid
	LD	A,C
	CP	'>'
	JR	NZ,.mid
	LD	(IX+ET_PEND),EPD_PROMPT
	RET
.mid
	LD	A,C
	CP	':'
	JR	Z,.hdr
	CP	','
	JR	Z,.hdr
; LINE_STORE: append byte C to the line (counted, not stored, when full).
LINE_STORE
	LD	A,(IX+ET_LLEN)
	CP	ES_LINE_MAX
	JR	NC,.long
	CALL	LINE_AT			; HL = line + A
	LD	(HL),C
	INC	(IX+ET_LLEN)
	RET
.long
	LD	(IX+ET_LLEN),ES_LINE_MAX + 1	; ignored at its end
	RET
ESP_LBYTE.hdr
	; ':' may end "+IPD,<link>,<len>", ',' may end "+CIPRECVDATA:<len>";
	; both headers start with '+' -- skip the (longer) prefix compare for
	; any other line without even reading it (WP2: the candidate probe is
	; the slow byte of a round, cheapened to this one extra check)
	LD	A,(IX+ET_LLEN)
	CP	ES_LINE_MAX + 1
	JR	NC,LINE_STORE
	PUSH	BC
	XOR	A
	CALL	LINE_AT
	LD	A,(HL)
	POP	BC
	CP	'+'
	JR	NZ,LINE_STORE
	LD	A,C
	CP	':'
	JR	NZ,.comma
	LD	A,(IX+ET_LLEN)
	CP	7			; "+IPD,<l>,<n>": at least 7 bytes
	JR	C,LINE_STORE
	PUSH	BC
	LD	HL,STR_IPD
	LD	B,5
	CALL	LINE_PREFIX
	POP	BC
	JR	NZ,LINE_STORE
	LD	(IX+ET_PEND),EPD_COLON
	RET
.comma
	LD	A,(IX+ET_LLEN)
	CP	14			; "+CIPRECVDATA:" and a digit
	JR	C,LINE_STORE
	PUSH	BC
	LD	HL,STR_RECVDATA
	LD	B,13
	CALL	LINE_PREFIX
	POP	BC
	JR	NZ,LINE_STORE
	LD	(IX+ET_PEND),EPD_COMMA
	RET
ESP_LBYTE.eol
	LD	A,(IX+ET_LLEN)
	OR	A
	RET	Z			; empty line
	LD	(IX+ET_PEND),EPD_EOL
	RET

; ----------------------------------------------------------------------
; ESP_PEND: the action left by the parser, at its own cost by kind (WP2:
; COST_EOL / COST_HDR / COST_PROMPT -- no item chains two costs).  CF=1
; when the budget refused it (the parser waits for it).  Clobbers A, BC,
; DE, HL, IX.
; ----------------------------------------------------------------------
ESP_PEND
	ET_IX
	LD	A,(IX+ET_PEND)
	OR	A
	RET	Z
	CP	EPD_EOL
	LD	HL,COST_EOL
	JR	Z,.take
	CP	EPD_PROMPT
	LD	HL,COST_PROMPT
	JR	Z,.take
	CP	EPD_PUBLISH
	LD	HL,COST_PUBLISH
	JR	Z,.take
	LD	HL,COST_HDR		; EPD_COLON / EPD_COMMA
.take
	CALL	TAKE
	RET	C
	ET_IX
	LD	A,(IX+ET_PEND)
	LD	(IX+ET_PEND),EPD_NONE
	CP	EPD_EOL
	JR	Z,.eol
	CP	EPD_PROMPT
	JP	Z,ESP_PROMPT
	CP	EPD_PUBLISH
	JR	Z,.publish
	CP	EPD_COLON
	JR	Z,.colon
	CALL	ESP_HDR_RECV		; CF=1: not a header, the ',' is text
	RET	NC
	LD	C,','
	JP	LINE_STORE
.colon
	CALL	ESP_HDR_IPD
	RET	NC
	LD	C,':'
	JP	LINE_STORE
.eol
	CALL	ESP_LINE
	ET_IX
	LD	(IX+ET_LLEN),0
	OR	A
	RET
.publish
	; a completed UDP datagram (ESP_PAY deferred this out of its own round)
	IFDEF	UGB_RX_DGRAM
	LD	C,(IX+ET_GOT)
	LD	B,(IX+ET_GOT+1)
	CALL	RXD_PUBLISH
	STAT_INC UNETG_STATS_RX_FRAMES
	ET_IX
	LD	E,(IX+ET_GOT)
	LD	D,(IX+ET_GOT+1)
	STAT_ADD32 UNETG_STATS_RX_BYTES
	ET_IX
	LD	(IX+ET_PKIND),0
	SET	1,(IY+CX_WORK)		; UWK_PROTO
	ENDIF
	OR	A			; CF=0: performed
	RET

; LINE_AT: HL = line buffer + A.  Clobbers DE.
LINE_AT
	LD	E,A
	LD	D,0
	LD	HL,ES_LINE_OFS - CTX_BIAS
	ADD	HL,DE
	PUSH	IY
	POP	DE
	ADD	HL,DE
	RET

; LINE_PREFIX: Z when the line starts with the B bytes at HL.  The line
; must hold at least B bytes.  Clobbers A, B, DE, HL.
LINE_PREFIX
	PUSH	HL
	XOR	A
	CALL	LINE_AT
	EX	DE,HL			; DE = line
	POP	HL
.cmp
	LD	A,(DE)
	CP	(HL)
	RET	NZ
	INC	DE
	INC	HL
	DJNZ	.cmp
	RET				; Z

; LINE_NUMS: ET_N1, ET_N2 = the first two decimal fields of the line from
; position A (fields separated by ','; a field ends at any other byte).
; Clobbers A, BC, DE, HL.
LINE_NUMS
	LD	C,A
	LD	A,(IX+ET_LLEN)
	SUB	C
	LD	B,A			; bytes left
	LD	A,C
	CALL	LINE_AT
	EX	DE,HL			; DE -> first byte
	XOR	A
	LD	(IX+ET_N2),A
	LD	(IX+ET_N2+1),A
	CALL	.field
	LD	(IX+ET_N1),L
	LD	(IX+ET_N1+1),H
	RET	C
	CALL	.field
	LD	(IX+ET_N2),L
	LD	(IX+ET_N2+1),H
	RET
.field
	LD	HL,0
.fd
	LD	A,B
	OR	A
	SCF
	RET	Z			; end of the line
	LD	A,(DE)
	INC	DE
	DEC	B
	CP	','
	RET	Z			; CF=0: another field follows
	SUB	'0'
	CP	10
	CCF
	RET	C			; not a digit
	PUSH	DE
	LD	D,H
	LD	E,L
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,DE
	ADD	HL,HL			; HL * 10
	LD	E,A
	LD	D,0
	ADD	HL,DE
	POP	DE
	JR	.fd

; ----------------------------------------------------------------------
; ESP_HDR_IPD: ':' after "+IPD,<link>,<len>": an active-mode datagram.
; Out: CF=1 when the line is not such a header.  IX kept.
; ----------------------------------------------------------------------
ESP_HDR_IPD
	LD	HL,STR_IPD
	LD	B,5
	CALL	LINE_PREFIX
	SCF
	RET	NZ
	LD	A,5
	CALL	LINE_NUMS
	LD	(IX+ET_LLEN),0
	LD	L,(IX+ET_N2)
	LD	H,(IX+ET_N2+1)
	LD	A,H
	OR	L
	RET	Z			; empty datagram: nothing follows (CF=0)
	LD	(IX+ET_PLEFT),L
	LD	(IX+ET_PLEFT+1),H
	LD	(IX+ET_GOT),L
	LD	(IX+ET_GOT+1),H
	LD	(IX+ET_PST),EPS_PAY
	LD	(IX+ET_PKIND),EPK_SINK
	IFDEF	UGB_RX_DGRAM
	LD	A,(IX+ET_N1)		; link id
	OR	(IX+ET_N1+1)
	JR	NZ,.out
	LD	A,(IY+CX_CHAN)
	CP	UCH_OPEN
	JR	NZ,.out
	; a datagram longer than a slot or without a free slot is lost whole
	LD	E,(IY+CX_RX_SLOT_SIZE)
	LD	D,(IY+CX_RX_SLOT_SIZE+1)
	EX	DE,HL
	OR	A
	SBC	HL,DE			; CF: slot < datagram
	JR	C,.lost
	PUSH	IX
	CALL	RXD_TAKE		; HL = buffer
	POP	IX
	JR	C,.lost
	LD	(IX+ET_RXDST),L
	LD	(IX+ET_RXDST+1),H
	LD	(IX+ET_PKIND),EPK_UDP
	JR	.out
.lost
	PUSH	IX
	STAT_INC UNETG_STATS_RING_OVERFLOW
	POP	IX
	ENDIF
.out
	OR	A
	RET

; ----------------------------------------------------------------------
; ESP_HDR_RECV: ',' after "+CIPRECVDATA:<len>": the answer of the passive
; read in flight.  Accepts the actual length 0..requested.  Out: CF=1 when
; the line is not such a header.  IX kept.
; ----------------------------------------------------------------------
ESP_HDR_RECV
	LD	A,(IX+ET_LLEN)
	CP	14
	RET	C			; prefix + at least one digit
	LD	HL,STR_RECVDATA
	LD	B,13
	CALL	LINE_PREFIX
	SCF
	RET	NZ
	LD	A,13
	CALL	LINE_NUMS
	LD	(IX+ET_LLEN),0
	IFDEF	UGB_RX_RING
	; the module holds this much less; a notice it sends after the answer
	; carries the new total (so the count is updated here, not at the OK)
	LD	L,(IX+ET_AVAIL)
	LD	H,(IX+ET_AVAIL+1)
	LD	E,(IX+ET_N1)
	LD	D,(IX+ET_N1+1)
	OR	A
	SBC	HL,DE
	JR	NC,.avail
	LD	HL,0
.avail
	LD	(IX+ET_AVAIL),L
	LD	(IX+ET_AVAIL+1),H
	ENDIF
	LD	L,(IX+ET_N1)
	LD	H,(IX+ET_N1+1)
	LD	A,H
	OR	L
	JR	NZ,.data
	; an empty answer: the module holds nothing now (not a FIN); no new
	; read until its next notice
	IFDEF	UGB_RX_RING
	LD	(IX+ET_AVAIL),A
	LD	(IX+ET_AVAIL+1),A
	ENDIF
	RET				; CF=0: the OK follows at once
.data
	LD	(IX+ET_PLEFT),L
	LD	(IX+ET_PLEFT+1),H
	LD	(IX+ET_PST),EPS_PAY
	LD	(IX+ET_PKIND),EPK_SINK
	IFDEF	UGB_RX_RING
	LD	A,(IX+ET_JOB)
	CP	EJ_RECV
	JR	NZ,.out
	LD	A,(IX+ET_CST)
	CP	ECS_WAIT
	JR	NZ,.out
	BIT	EF_DISCARD,(IX+ET_FL)
	JR	NZ,.out
	LD	E,(IX+ET_REQ)
	LD	D,(IX+ET_REQ+1)
	EX	DE,HL
	OR	A
	SBC	HL,DE			; CF: requested < actual
	JR	C,.too_long
	LD	(IX+ET_GOT),E
	LD	(IX+ET_GOT+1),D
	LD	(IX+ET_PKIND),EPK_TCP
	JR	.out
.too_long
	; more than asked for: the bytes are skipped, the channel fails
	PUSH	IX
	LD	A,UNETG_STREAM_LENGTH
	CALL	ESP_STREAM_ERROR
	POP	IX
	ENDIF
.out
	OR	A
	RET

; ----------------------------------------------------------------------
; ESP_LINE: classify a complete line and hand its token to the sequencer.
; IX = tp.  Clobbers A, BC, DE, HL, IX.
; ----------------------------------------------------------------------
ESP_LINE
	LD	A,(IX+ET_LLEN)
	CP	ES_LINE_MAX + 1
	RET	NC			; too long: not a line we act on
	LD	(IX+ET_LINK),0xFF
	; strip "<n>," prefixes; the first one is the link id
	LD	C,0			; text position
.strip
	LD	A,C
	CALL	LINE_AT			; HL -> text
	LD	A,(IX+ET_LLEN)
	SUB	C
	LD	B,A			; bytes left
	LD	DE,0			; value of the field
	PUSH	BC			; [position, left] at the field start
.sdig
	LD	A,B
	OR	A
	JR	Z,.no_prefix		; the line ends inside the number
	LD	A,(HL)
	CP	','
	JR	Z,.comma
	SUB	'0'
	CP	10
	JR	NC,.no_prefix
	PUSH	HL
	LD	H,D
	LD	L,E
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,DE
	ADD	HL,HL
	LD	E,A
	LD	D,0
	ADD	HL,DE
	EX	DE,HL			; value = value * 10 + digit
	POP	HL
	INC	HL
	DEC	B
	INC	C
	JR	.sdig
.comma
	POP	AF			; A = bytes left at the field start
	CP	B
	JR	Z,.match		; ',' with no digit before it: text
	LD	A,(IX+ET_LINK)
	INC	A
	JR	NZ,.slink		; only the first prefix is the link id
	LD	A,D
	OR	A
	JR	NZ,.slink
	LD	(IX+ET_LINK),E
.slink
	INC	C			; past the comma
	JR	.strip
.no_prefix
	POP	BC			; C = start of the text
.match
	LD	(IX+ET_N1),C		; text position (LINE_NUMS rewrites it)
	LD	A,(IX+ET_LLEN)
	SUB	C
	LD	(IX+ET_N2),A		; text length
	LD	A,C
	CALL	LINE_AT
	EX	DE,HL			; DE = text
	LD	A,(DE)
	LD	C,A			; first byte of the text
	LD	HL,ESP_TOKENS
	LD	B,ESP_TOKEN_N
.entry
	LD	A,(HL)
	CP	C
	JR	Z,.cand
.next
	LD	A,L
	ADD	A,5
	LD	L,A
	JR	NC,.dj
	INC	H
.dj
	DJNZ	.entry
	RET				; unknown line: ignored
.cand
	PUSH	HL
	PUSH	BC
	PUSH	DE
	INC	HL
	LD	A,(HL)			; token
	PUSH	AF			; [entry][count][text][token]
	INC	HL
	LD	C,(HL)			; length | 0x80 for a prefix
	INC	HL
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A			; HL = string
	LD	A,C
	AND	0x7F
	CP	(IX+ET_N2)
	JR	Z,.cmp			; same length: exact or prefix
	JR	NC,.miss		; string longer than the text
	BIT	7,C
	JR	Z,.miss			; exact entry, longer text
.cmp
	LD	B,A
.sc
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.miss
	INC	DE
	INC	HL
	DJNZ	.sc
	POP	AF			; A = token
	POP	DE
	POP	BC
	POP	HL
	CP	TK_IPD
	JP	NZ,ESP_TOKEN
	PUSH	AF
	LD	A,(IX+ET_N1)		; text position
	ADD	A,5
	CALL	LINE_NUMS
	POP	AF
	JP	ESP_TOKEN
.miss
	POP	AF
	POP	DE
	POP	BC
	POP	HL
	JR	.next

; Tokens: DB first byte, token, length (+0x80: prefix match); DW text.
; Ordered by frequency; "CONNECT" is exact, so "CONNECT FAIL" misses it.
ESP_TOKENS
	DB	'O', TK_OK, 2
	DW	S_OK
	DB	'S', TK_SENDOK, 7
	DW	S_SENDOK
	DB	'+', TK_IPD, 5 | 0x80
	DW	STR_IPD
	DB	'R', TK_IGNORE, 5 | 0x80
	DW	S_RECV
	DB	'C', TK_CLOSED, 6
	DW	S_CLOSED
	DB	'C', TK_CONNECT, 7
	DW	S_CONNECT
	DB	'E', TK_ERROR, 5
	DW	S_ERROR
	DB	'b', TK_BUSY, 4 | 0x80
	DW	S_BUSY
	DB	'S', TK_SENDFAIL, 9
	DW	S_SENDFAIL
	DB	'F', TK_FAIL, 4
	DW	S_FAIL
	DB	'C', TK_CONNFAIL, 9 | 0x80
	DW	S_CONNFAIL
	DB	'r', TK_READY, 5
	DW	S_READY
	DB	'W', TK_WIFIOFF, 15
	DW	S_WIFIOFF
	DB	'A', TK_ALREADY, 17
	DW	S_ALREADY
ESP_TOKENS_END
ESP_TOKEN_N	EQU	(ESP_TOKENS_END - ESP_TOKENS) / 5
S_OK		DB	"OK"
S_SENDOK	DB	"SEND OK"
STR_IPD		DB	"+IPD,"
S_RECV		DB	"Recv "
S_CLOSED	DB	"CLOSED"
S_CONNECT	DB	"CONNECT"
S_ERROR		DB	"ERROR"
S_BUSY		DB	"busy"
S_SENDFAIL	DB	"SEND FAIL"
S_FAIL		DB	"FAIL"
S_CONNFAIL	DB	"CONNECT F"
S_READY		DB	"ready"
S_WIFIOFF	DB	"WIFI DISCONNECT"
S_ALREADY	DB	"ALREADY CONNECTED"
STR_RECVDATA	DB	"+CIPRECVDATA:"
