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
	IFDEF	UGB_XMODE
	BIT	EXF_DATA,(IY+EX_XFL)
	JP	NZ,ESP_XPARSE		; data mode: records, no AT lines
	ENDIF
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
	IFDEF	UGB_FAT
	RES	ESF_LWAIT,(IY+EX_FLAGS)	; the tail moves: ESP_LEAN's mark is void
	ENDIF
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
	IFDEF	UGB_FAT
	BIT	USCH_FAT,(IY+CX_SCHED_FLAGS)
	JR	NZ,.fat
.took
	ENDIF
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
	IFDEF	UGB_FAT
.fat
	; fat STEP: the way back through TP_FAT is longer (stand: a
	; publication 102 units against COST_PUBLISH 80)
	LD	DE,COST_PEND_FAT
	ADD	HL,DE
	JR	.took
	ENDIF
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

	IFDEF	UGB_FAT
; ----------------------------------------------------------------------
; ESP_LEAN (fat STEP, profile.inc): what the module says in a small-packet
; exchange, taken from the UART ring in one pass instead of a parse round
; and a pending action per line.
;
; The pass walks the bytes that lie in the ring without a wrap, line by
; line, and stops at the first one that is an action or is not for it:
;   - line ends (CR, LF: the empty lines between the answers);
;   - the answers of a CIPSEND in flight, recognised in place: "OK" (it
;     comes before the prompt and means nothing), "Recv <n> bytes"
;     (noise), "SEND OK" (the terminal line: ET_TERM, ECS_DONE -- the
;     pass ends, the result is the sequencer's);
;   - the CIPSEND prompt '>' at a line start (ESP_PROMPT; the pass ends);
;   - any other complete text line ("0,CLOSED", "ERROR", TCP: the passive
;     "+IPD,0,<n>" notice): copied into the line buffer and classified by
;     ESP_LINE, exactly as ESP_PEND's EPD_EOL does (the pass ends);
;   - UDP: "+IPD,0,<n>:" with all its n bytes (n < 256): slot, copy,
;     publication -- what ESP_HDR_IPD, ESP_PAY and EPD_PUBLISH do (the
;     pass ends).
; Only at a line start with nothing pending.  Everything else (a line
; across the ring end, a line too long for the buffer, another link's
; datagram, a datagram with no free slot, "+CIPRECVDATA:" and its
; payload) is left untouched to the generic parser, which also counts the
; losses.  A line whose end has not arrived yet is waited for (the pump
; brings it in the next round or STEP): parsed in part it would fall back
; to a round and an action; a datagram is waited for only up to
; LEAN_IPD_WAIT bytes -- a longer one is parsed as it comes (the pump
; pauses the module at ER_PAUSE_AT bytes of backlog, so it would never be
; whole).  An incomplete line is not looked at again until the bytes it
; needs are in the ring (ESF_LWAIT / ET_LNEED: one more for a line, the
; whole datagram once its length is known; ESP_PROMPT sets the length of
; the CIPSEND answer the same way, ESF_LANS; any pass and a round of
; the generic parser clear the mark).
; Out: A = 0: an action was done or bytes were consumed (call again);
; 1: not for this path; 2: wait (nothing to parse now, or no budget for
; it in this STEP: UWK_YIELD, the bytes stay in the ring).
; Clobbers all but IY.
; Costs (stand, units; cost rule): COST_LEAN_SCAN is taken before the
; ring is looked at and is all that a pass without an action costs;
; every recognised answer and every action takes its own cost on top,
; checked before it starts.
; ----------------------------------------------------------------------
; Stand (tools/dev/items_fat.sh; the TAKEs of one visit are one item for
; the tools, budget_calls.js FOLD): a pass without an action 116 units
; with its way back through TP_FAT, one with "OK" 135, with the prompt
; too 179, a line of 5 bytes 184, a datagram of 16 bytes 223.
COST_LEAN_SCAN	EQU	135	; the pass: ring head, sizing, line ends, the tail, the way back
COST_LEAN_HOT	EQU	25	; an answer recognised in place ("Recv": the search for its CR)
COST_LEAN_LINE	EQU	65	; a text line: the search for its CR, copy, ESP_LINE, token (+ 1 unit per byte)
COST_LEAN_PROMPT EQU	70	; the prompt: ESP_PROMPT
COST_LEAN_IPD	EQU	120	; a datagram: slot, publication, counters (+ 1.25 units per byte)
COST_LEAN_PREFIX EQU	105	; ... on top for a line with a link prefix ("0,CONNECT", "0,CLOSED": stand 285 in all)
COST_LEAN_NOTICE EQU	50	; TCP: the notice of held bytes in place, the sequencer's look after it
LEAN_IPD_WAIT	EQU	40	; a datagram up to this long is waited for
LEAN_IPD_MAX	EQU	64	; a longer one never lies whole in the ring (ER_PAUSE_AT)
COST_PEND_FAT	EQU	40	; a generic pending action in a fat STEP: on top of its cost
	ASSERT	COST_LEAN_LINE + COST_LEAN_PREFIX + ES_LINE_MAX < 256
	ASSERT	LEAN_IPD_WAIT + 12 + 4 < ER_PAUSE_AT
ESP_LEAN
	ET_IX
	IFDEF	UGB_XMODE
	; the transparent profile has no CIPSEND exchanges to recognise: its
	; few AT lines (set-up, OPEN, CLOSE) go to the generic parser, whose
	; actions are priced by kind, and its records to ESP_XPARSE
	CALL	ESP_XCFG
	JP	Z,.generic
	ENDIF
	LD	A,(IX+ET_PEND)
	OR	(IX+ET_PST)
	OR	(IX+ET_LLEN)
	JP	NZ,.generic
	BIT	EF_RESYNC,(IX+ET_FL)
	JP	NZ,.generic
	; the backlog (read without DI: a torn value only delays the pass)
	LD	A,(IY+EX_RH)
	SUB	(IY+EX_RT)
	LD	L,A
	LD	A,(IY+EX_RH+1)
	SBC	A,(IY+EX_RT+1)
	AND	HIGH ER_MASK
	LD	H,A
	OR	L
	JP	Z,.wait			; the ring is empty
	BIT	ESF_LWAIT,(IY+EX_FLAGS)
	JR	Z,.pass
	LD	A,H
	OR	A
	JR	NZ,.pass
	LD	A,L
	CP	(IX+ET_LNEED)
	JR	NC,.pass		; what was waited for is here
	; Fewer bytes than waited for.  A line seen in part: nothing to
	; look at.  The estimate of a CIPSEND answer (ESP_PROMPT: "Recv <n>
	; bytes" and "SEND OK" are 25 bytes and the digits, in several FIFO
	; loads): wait while the pump is bringing bytes; once it has brought
	; nothing new, a shorter answer (SEND FAIL, ERROR, busy) is all here.
	BIT	ESF_LANS,(IY+EX_FLAGS)
	JP	Z,.wait
	BIT	ESF_GOT,(IY+EX_FLAGS)
	JP	NZ,.wait
.pass
	RES	ESF_LWAIT,(IY+EX_FLAGS)
	RES	ESF_LANS,(IY+EX_FLAGS)
	LD	HL,COST_LEAN_SCAN
	CALL	TAKE			; refused: the bytes wait (UWK_YIELD)
	JP	C,.wait
	CALL	ER_HEAD			; HL = waiting, DE = tail
	LD	A,H
	OR	L
	JP	Z,.wait
	PUSH	DE			; [tail]
	LD	B,H
	LD	C,L
	LD	HL,ER_SIZE
	OR	A
	SBC	HL,DE			; bytes up to the ring end
	LD	D,B
	LD	E,C
	CALL	MIN_DE_HL		; DE = bytes waiting without a wrap
	LD	B,E
	LD	A,D
	OR	A
	JR	Z,.n_ok
	LD	B,255
.n_ok
	POP	DE
	PUSH	DE			; [tail]
	LD	L,(IY+CX_HW_RING_PTR)
	LD	H,(IY+CX_HW_RING_PTR+1)
	ADD	HL,DE			; HL -> the first byte
	PUSH	HL			; [tail][first]
	; ---- a line start: HL -> byte, B = bytes from it --------------------
.line
	LD	A,B
	OR	A
	JR	Z,.all			; everything here is consumed
	LD	A,(HL)
	CP	13
	JR	Z,.eol
	CP	10
	JR	NZ,.text
.eol
	INC	HL
	DJNZ	.line
.all
	CALL	.commit
	XOR	A
	RET
.text
	; HL -> the text, B = bytes from it (>= 1); the bytes before it are
	; consumed by .commit whatever this line turns out to be
	LD	(IX+ET_N1),L
	LD	(IX+ET_N1+1),H		; the line start
	LD	(IX+ET_N2),B
	CP	'>'
	JP	Z,.prompt
	CP	'+'
	JP	Z,.plus
	LD	C,A
	LD	A,(IX+ET_JOB)
	CP	EJ_SEND
	JP	NZ,.scan
	LD	A,(IX+ET_CST)
	CP	ECS_WAIT
	JP	NZ,.scan
	; the answers of the CIPSEND in flight, in place
	LD	A,C
	LD	DE,S_SENDOK
	LD	C,7
	CP	'S'
	JR	Z,.hot
	LD	DE,S_OK
	LD	C,2
	CP	'O'
	JR	Z,.hot
	LD	DE,S_RECV
	LD	C,5
	CP	'R'
	JP	NZ,.scan
.hot
	; C text bytes at DE, then (but for "Recv ") the CR: all here?
	LD	A,B
	CP	C
	JR	C,.hot_part
	JR	Z,.hot_part
	PUSH	BC
	LD	B,C
.hc
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.hot_miss
	INC	DE
	INC	HL
	DJNZ	.hc
	POP	BC
	LD	A,B
	SUB	C
	LD	B,A			; bytes after the text (>= 1)
	LD	A,C
	CP	5
	JR	Z,.recv
	LD	A,(HL)
	CP	13
	JR	NZ,.rescan		; "OKAY", "SEND OK?": a line like any other
	PUSH	BC
	PUSH	HL
	LD	HL,COST_LEAN_HOT
	CALL	TAKE
	JR	C,.hot_poor
	POP	HL
	POP	BC
	INC	HL
	DEC	B			; past the CR
	LD	A,C
	CP	7
	JP	NZ,.line		; "OK": nothing
	LD	(IX+ET_TERM),TK_SENDOK
	LD	(IX+ET_CST),ECS_DONE
	; its LF with it, when it is here (no pass of its own later)
	LD	A,B
	OR	A
	JP	Z,.all
	LD	A,(HL)
	CP	10
	JP	NZ,.all
	INC	HL
	JP	.all			; its result first
.recv
	; "Recv <n> bytes": up to its CR
	PUSH	BC
	PUSH	HL
	LD	HL,COST_LEAN_HOT
	CALL	TAKE
	JR	C,.hot_poor
	POP	HL
	POP	BC
	LD	C,B
	LD	B,0
	LD	A,13
	CPIR
	LD	B,C
	JP	Z,.line
	JR	.back_part		; its CR has not arrived
.hot_poor
	; no budget for it in this STEP: what was consumed stays consumed
	POP	HL
	POP	BC
	CALL	.back
	CALL	.commit
	JP	.wait
.hot_miss
	POP	BC
.rescan
	CALL	.back
	JR	.scan
.hot_part
	; fewer bytes than the answer: its start may still be another line
.back_part
	LD	A,(IX+ET_N2)
	CP	ES_LINE_MAX + 1
	JP	NC,.to_generic		; no line is that long: counted there
	CALL	.back
	JP	.partial
; .back: HL = the line start, B = bytes from it.
.back
	LD	L,(IX+ET_N1)
	LD	H,(IX+ET_N1+1)
	LD	B,(IX+ET_N2)
	RET
.scan
	; a text line: its CR within min(B, ES_LINE_MAX + 1) bytes
	LD	A,B
	CP	ES_LINE_MAX + 2
	JR	C,.lim
	LD	A,ES_LINE_MAX + 1
.lim
	LD	C,A
	LD	B,0
	LD	E,A			; bytes searched
	LD	A,13
	CPIR
	JR	NZ,.no_cr
	LD	A,E
	SUB	C
	DEC	A			; text length (1..ES_LINE_MAX)
	LD	E,A
	IFDEF	UGB_RX_RING
	; a '+' line with a ':' would be a payload header: never a plain line
	CALL	.back
	LD	A,(HL)
	CP	'+'
	JR	NZ,.plain
	LD	C,E
	LD	B,0
	LD	A,':'
	CPIR
	JP	Z,.to_generic
.plain
	ENDIF
	CALL	.back_hl
	LD	A,(HL)
	CP	':'			; a digit first: a link prefix to strip
	LD	A,E
	JR	NC,.cheap
	ADD	A,COST_LEAN_PREFIX
.cheap
	ADD	A,COST_LEAN_LINE
	LD	L,A
	LD	H,0
	PUSH	DE			; E = text length
	CALL	TAKE
	JR	NC,.line_ok
	POP	DE
	JP	.poor
.line_ok
	XOR	A
	CALL	LINE_AT			; HL = line buffer
	EX	DE,HL
	POP	BC
	LD	B,0			; BC = text length
	CALL	.back_hl
	LD	(IX+ET_LLEN),C
	LD	A,C
	LDIR				; HL -> the CR
	INC	HL
	LD	C,A
	LD	A,(IX+ET_N2)
	SUB	C
	DEC	A			; bytes after the CR
	JR	Z,.no_lf
	LD	A,(HL)
	CP	10
	JR	NZ,.no_lf
	INC	HL			; its LF is here too
.no_lf
	CALL	.commit
	CALL	ESP_PROGRESS
	ET_IX
	CALL	ESP_LINE
	ET_IX
	LD	(IX+ET_LLEN),0
	XOR	A
	RET
; .back_hl: HL = the line start.
.back_hl
	LD	L,(IX+ET_N1)
	LD	H,(IX+ET_N1+1)
	RET
.no_cr
	LD	A,(IX+ET_N2)
	CP	ES_LINE_MAX + 1
	JR	NC,.to_generic		; too long for the buffer: counted there
.partial
	; the rest of this line has not arrived: one byte more at least
	LD	A,(IX+ET_N2)
	INC	A
.partial_a
	; A = the bytes this line needs to be looked at again -- unless the
	; ring wraps right after what is here (then the rest may be waiting
	; at the ring start)
	LD	(IX+ET_LNEED),A
	CALL	.back
	LD	C,B
	LD	B,0
	PUSH	HL
	ADD	HL,BC			; the end of what is here
	LD	E,(IY+CX_HW_RING_PTR)
	LD	D,(IY+CX_HW_RING_PTR+1)
	OR	A
	SBC	HL,DE			; its ring offset
	LD	A,H
	POP	HL
	CP	HIGH ER_SIZE
	JR	Z,.to_generic_hl
	CALL	.commit
	SET	ESF_LWAIT,(IY+EX_FLAGS)	; until that many bytes wait
.wait
	LD	A,2
	RET
.poor
	; no budget for the action in this STEP
	CALL	.back_hl
	CALL	.commit
	JR	.wait
.to_generic
	CALL	.back_hl
.to_generic_hl
	CALL	.commit
.generic
	LD	A,1
	RET
.prompt
	PUSH	HL
	LD	HL,COST_LEAN_PROMPT
	CALL	TAKE
	POP	HL
	JR	C,.poor
	INC	HL			; the '>' itself
	CALL	.commit
	CALL	ESP_PROMPT
	XOR	A
	RET
; .commit: everything before HL is consumed: the ring tail moves there.
; In: HL -> the first byte not consumed, the stack holds [tail][first]
; under the return address; both are dropped.  Clobbers A, BC, DE, HL.
.commit
	POP	BC			; return address
	POP	DE			; first
	OR	A
	SBC	HL,DE			; bytes consumed (0..255)
	POP	DE			; tail
	PUSH	BC
	LD	A,L
	OR	A
	RET	Z
	ADD	HL,DE
	LD	A,H
	AND	HIGH ER_MASK
	LD	H,A
	JP	ER_SET_TAIL
.plus
	IFDEF	UGB_RX_RING
	; "+IPD,<link>,<len>" is a notice here (passive receive): the bytes
	; the module holds.  "+IPD,0,<len>" CR in place (ESP_TOKEN's TK_IPD);
	; another link's is a line like any other; anything else that starts
	; with '+' ("+CIPRECVDATA:" and its payload) is the generic parser's.
	LD	A,B
	CP	9
	JP	C,.back_part
	LD	DE,STR_IPD0
	LD	B,7
.pc
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.plus_other
	INC	DE
	INC	HL
	DJNZ	.pc
	LD	A,(IX+ET_N2)
	SUB	7
	LD	B,A			; bytes after "+IPD,0," (>= 2)
	LD	DE,0
.dig
	LD	A,(HL)
	INC	HL
	DEC	B
	CP	13
	JR	Z,.notice
	SUB	'0'
	CP	10
	JP	NC,.to_generic		; a ':' or text: not a notice
	LD	C,A
	PUSH	HL
	LD	H,D
	LD	L,E
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,DE
	ADD	HL,HL
	LD	E,C
	LD	D,0
	ADD	HL,DE
	EX	DE,HL			; length * 10 + digit
	POP	HL
	LD	A,B
	OR	A
	JR	NZ,.dig
	JP	.back_part		; its CR has not arrived
.notice
	PUSH	HL
	PUSH	DE
	LD	HL,COST_LEAN_NOTICE
	CALL	TAKE
	POP	DE
	POP	HL
	JP	C,.poor
	LD	(IX+ET_AVAIL),E
	LD	(IX+ET_AVAIL+1),D
	JP	.all			; the sequencer may ask for them at once
.plus_other
	; "+IPD," of another link: a line; else the generic parser
	CALL	.back
	LD	DE,STR_IPD
	LD	C,5
.po
	LD	A,(DE)
	CP	(HL)
	JP	NZ,.to_generic
	INC	DE
	INC	HL
	DEC	C
	JR	NZ,.po
	CALL	.back
	JP	.scan
	ELSE
	; UDP: "+IPD,0,<n>:" and its n bytes
	LD	A,B
	CP	9
	JP	C,.partial
	LD	DE,STR_IPD0
	LD	B,7
.pc
	LD	A,(DE)
	CP	(HL)
	JP	NZ,.to_generic		; another link, another '+' line
	INC	DE
	INC	HL
	DJNZ	.pc
	LD	A,(IX+ET_N2)
	SUB	7
	LD	B,A			; bytes after "+IPD,0," (>= 2)
	LD	DE,0
.dig
	LD	A,(HL)
	INC	HL
	DEC	B
	CP	':'
	JR	Z,.colon
	SUB	'0'
	CP	10
	JP	NC,.to_generic
	LD	C,A
	LD	A,D
	OR	A
	JP	NZ,.to_generic		; 256 bytes and more: as it comes
	PUSH	HL
	LD	H,D
	LD	L,E
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,DE
	ADD	HL,HL
	LD	E,C
	LD	D,0
	ADD	HL,DE
	EX	DE,HL			; length * 10 + digit
	POP	HL
	LD	A,B
	OR	A
	JR	NZ,.dig
	JP	.partial		; the header is not all here
.colon
	; DE = length, B = bytes here after the ':', HL -> the payload
	LD	A,D
	OR	A
	JP	NZ,.to_generic
	OR	E
	JP	Z,.to_generic		; an empty datagram
	LD	A,E
	CP	LEAN_IPD_MAX + 1
	JP	NC,.to_generic		; a long one is parsed as it comes
	LD	A,B
	CP	E
	JR	NC,.whole
	LD	A,E
	CP	LEAN_IPD_WAIT + 1
	JP	NC,.to_generic
	; all of it is waited for: the header (HL - line start) and E bytes
	LD	A,L
	SUB	(IX+ET_N1)
	ADD	A,E
	JP	.partial_a
.whole
	LD	A,(IY+CX_CHAN)
	CP	UCH_OPEN
	JP	NZ,.to_generic
	LD	A,(IY+CX_RX_SLOT_SIZE+1)
	OR	A
	JR	NZ,.slot_ok
	LD	A,(IY+CX_RX_SLOT_SIZE)
	CP	E
	JP	C,.to_generic		; longer than a slot: lost whole, counted there
.slot_ok
	LD	(IX+ET_GOT),E
	LD	(IX+ET_GOT+1),0
	PUSH	HL			; [tail][first][payload]
	LD	A,E
	SRL	A
	SRL	A
	ADD	A,E			; 1.25 units per byte (the length is <= LEAN_IPD_MAX)
	LD	L,A
	LD	H,0
	LD	BC,COST_LEAN_IPD
	ADD	HL,BC
	CALL	UNITS_FIT
	JR	C,.ipd_poor
	PUSH	HL
	PUSH	IX
	CALL	RXD_TAKE		; HL = buffer
	POP	IX
	EX	DE,HL
	POP	HL			; the cost
	JR	C,.ipd_none		; no free slot: the loss is counted there
	PUSH	DE
	CALL	TAKE
	POP	DE
	POP	HL			; payload
	LD	C,(IX+ET_GOT)
	LD	B,0
	LDIR				; HL -> past the datagram
	CALL	.commit
	ET_IX
	LD	C,(IX+ET_GOT)
	LD	B,0
	CALL	RXD_PUBLISH
	STAT_INC UNETG_STATS_RX_FRAMES
	ET_IX
	LD	E,(IX+ET_GOT)
	LD	D,0
	STAT_ADD32 UNETG_STATS_RX_BYTES
	SET	1,(IY+CX_WORK)		; UWK_PROTO
	XOR	A
	RET
.ipd_poor
	POP	HL
	JP	.poor
.ipd_none
	POP	HL
	JP	.to_generic
	ENDIF
	ENDIF

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
	IFDEF	UGB_FAT
STR_IPD0	DB	"+IPD,0,"
	ENDIF
