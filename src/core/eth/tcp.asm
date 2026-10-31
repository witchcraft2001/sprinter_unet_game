; tcp.asm -- the TCP subset of ABI §2/§4 over the Ethernet engine.
;
; One connection, active open only.  Local MSS 536, at most two segments
; in flight, no Nagle delay, in-order receive straight into the RX byte
; ring (the advertised window is its free space), go-back retransmission
; on the retry_wait_ms schedule, send-stall timeout, FIN = full close.
; Sequence numbers are kept little-endian in ctx.tp.

TC_ST		EQU	0	; TCS_*
TC_FL		EQU	1	; TCF_*
TC_LPORT	EQU	2	; u16 local port
TC_UNA		EQU	4	; u32 oldest unacknowledged sequence
TC_NXT		EQU	8	; u32 next sequence to send
TC_RCV		EQU	12	; u32 next sequence expected
TC_SWND		EQU	16	; u16 peer window
TC_MSS		EQU	18	; u16 peer MSS (<= 536)
TC_NSLOT	EQU	20	; u8  send cursor: slot
TC_NOFF		EQU	21	; u16 send cursor: offset in the slot
TC_SEGS		EQU	23	; u8  segments in flight (0..2)
TC_SEG1		EQU	24	; u32 end of the oldest segment in flight
TC_RTXDL	EQU	28	; u32 retransmission deadline
TC_RTXI		EQU	32	; u8  retry index
TC_TMR		EQU	33	; u8  bit0 RTX armed, bit1 stall armed
TC_STALL	EQU	34	; u32 send-stall deadline
TC_RXSEQ	EQU	38	; u32 received segment: sequence
TC_RXACK	EQU	42	; u32 received segment: acknowledgment
TC_RXFL		EQU	46	; u8  received segment: flags
TC_RXWND	EQU	47	; u16 received segment: window
TC_RXLEN	EQU	49	; u16 received segment: payload length
TC_RXSTORE	EQU	51	; u8  1 when the payload is being stored
TC_TXSEQ	EQU	52	; u32 segment being prepared: sequence
TC_TXLEN	EQU	56	; u16 payload length
TC_TXFL		EQU	58	; u8  TCP flags
TC_PREP		EQU	59	; u8  TCP_PREP_*
TC_SUMPOS	EQU	60	; u16 payload bytes already summed
TC_SUM		EQU	62	; u16 payload checksum (byte-swapped domain)
TC_SRC		EQU	64	; u16 payload source
TC_LADV		EQU	66	; u16 last advertised window
TC_PORTSEQ	EQU	68	; u8  ephemeral port rotation
TC_HLEN		EQU	69	; u8  header length of the segment being sent
TC_RXHLEN	EQU	70	; u8  header length of the received segment
TC_RXN0		EQU	71	; u8  segment bytes already in scratch
TC_SIZE		EQU	72
	ASSERT	TC_SIZE <= 96

TCS_CLOSED	EQU	0
TCS_ARP		EQU	1	; resolving the next hop
TCS_SYN		EQU	2	; SYN sent
TCS_EST		EQU	3
TCS_FW1		EQU	4	; our FIN sent
TCS_FW2		EQU	5	; our FIN acknowledged
TCS_CLOSING	EQU	6	; both FINs, ours not acknowledged
TCS_CW		EQU	7	; peer FIN received, ours pending
TCS_LACK	EQU	8	; peer FIN received, ours sent
TCS_DONE	EQU	9	; finished once the last ACK is out

TCF_ACK		EQU	0x01	; send an ACK
TCF_FIN		EQU	0x02	; send FIN after the queued data
TCF_FINSENT	EQU	0x04
TCF_SYN		EQU	0x08	; send (or resend) SYN

TCP_PREP_NONE	EQU	0
TCP_PREP_SUM	EQU	1
TCP_PREP_READY	EQU	2

TCP_SUM_CHUNK	EQU	128
COST_TCP_STEP	EQU	220	; timers + segment choice (units)
COST_TCP_IDLE	EQU	60	; segment choice without due timers
COST_TCP_DATA	EQU	140	; choosing a data segment (slot cursor, window)
COST_TCP_INPUT	EQU	160
COST_TEMPLATE	EQU	210	; SYN: IP_TEMPLATE + control segment (stand: 198 us)
	ASSERT	COST_TCP_STEP <= PROF_MAX_ITEM_US
	ASSERT	COST_TCP_INPUT <= PROF_MAX_ITEM_US
	ASSERT	COST_TCP_IDLE + COST_TEMPLATE <= PROF_MAX_ITEM_US	; idle step -> SYN in one STEP
	ASSERT	COST_TCP_IDLE + COST_TCP_DATA <= PROF_MAX_ITEM_US
COST_TERMINATE	EQU	60	; CH_TERMINATE (stand: 51 us)

	MACRO	TP_IX
	PUSH	DE			; preserves DE
	LD	DE,UCTX_TP - CTX_BIAS
	PUSH	IY
	POP	IX
	ADD	IX,DE
	POP	DE
	ENDM

; SEQ_SUB a, b: BC = low 16 bits of (a - b), HL = high 16 bits (IX = tp).
	MACRO	SEQ_SUB a, b
	LD	L,(IX+a)
	LD	H,(IX+a+1)
	LD	E,(IX+b)
	LD	D,(IX+b+1)
	OR	A
	SBC	HL,DE
	LD	B,H
	LD	C,L
	LD	L,(IX+a+2)
	LD	H,(IX+a+3)
	LD	E,(IX+b+2)
	LD	D,(IX+b+3)
	SBC	HL,DE
	ENDM

	MACRO	SEQ_COPY dst, src
	LD	A,(IX+src)
	LD	(IX+dst),A
	LD	A,(IX+src+1)
	LD	(IX+dst+1),A
	LD	A,(IX+src+2)
	LD	(IX+dst+2),A
	LD	A,(IX+src+3)
	LD	(IX+dst+3),A
	ENDM

; SEQ_ADD f: u32 at (IX+f) += DE.  Clobbers A.
	MACRO	SEQ_ADD f
	LD	A,(IX+f)
	ADD	A,E
	LD	(IX+f),A
	LD	A,(IX+f+1)
	ADC	A,D
	LD	(IX+f+1),A
	LD	A,(IX+f+2)
	ADC	A,0
	LD	(IX+f+2),A
	LD	A,(IX+f+3)
	ADC	A,0
	LD	(IX+f+3),A
	ENDM

; REV32: (DE) = byte-reversed (HL), 4 bytes.  Clobbers A, BC, DE, HL.
REV32
	INC	HL
	INC	HL
	INC	HL
	LD	B,4
.loop
	LD	A,(HL)
	LD	(DE),A
	DEC	HL
	INC	DE
	DJNZ	.loop
	RET

; TP_FIELD: HL = address of tp field A.  Clobbers DE.
TP_FIELD
	LD	E,A
	LD	D,0
	LD	HL,UCTX_TP - CTX_BIAS
	ADD	HL,DE
	PUSH	IY
	POP	DE
	ADD	HL,DE
	RET

; ----------------------------------------------------------------------
TP_OPEN
	TP_IX
	LD	A,(IX+TC_PORTSEQ)
	PUSH	AF
	PUSH	IX
	POP	HL
	LD	B,TC_SIZE
.clr
	LD	(HL),0
	INC	HL
	DJNZ	.clr
	POP	AF
	INC	A
	LD	(IX+TC_PORTSEQ),A
	; local port: configured, else 49152 + low bits of time + rotation
	LD	L,(IY+CX_LOCAL_PORT)
	LD	H,(IY+CX_LOCAL_PORT+1)
	LD	A,H
	OR	L
	JR	NZ,.port
	LD	L,(IY+CX_NOW_MS)
	LD	A,(IY+CX_NOW_MS+1)
	AND	0x3F
	ADD	A,(IX+TC_PORTSEQ)
	AND	0x3F
	OR	0xC0
	LD	H,A
.port
	LD	(IX+TC_LPORT),L
	LD	(IX+TC_LPORT+1),H
	; ISS from the clock
	LD	A,(IY+CX_NOW_MS)
	LD	(IX+TC_UNA+1),A
	LD	A,(IY+CX_NOW_MS+1)
	LD	(IX+TC_UNA+2),A
	LD	A,(IY+CX_NOW_MS+2)
	XOR	(IX+TC_PORTSEQ)
	LD	(IX+TC_UNA+3),A
	SEQ_COPY TC_NXT, TC_UNA
	LD	(IX+TC_MSS),LOW UNETG_TCP_MSS
	LD	(IX+TC_MSS+1),HIGH UNETG_TCP_MSS
	LD	A,(IY+CX_TX_NEXT)
	LD	(IX+TC_NSLOT),A
	LD	(IX+TC_ST),TCS_ARP
	JP	ARP_RESOLVE

TP_CLOSE
	TP_IX
	SET	1,(IX+TC_FL)		; TCF_FIN after the queued data
	RET

TP_ABORT
TP_RESET
	TP_IX
	LD	(IX+TC_ST),TCS_CLOSED
	LD	(IX+TC_PREP),TCP_PREP_NONE
	LD	(IX+TC_TMR),0
	RET

TP_DEADLINES
	CALL	ARP_DEADLINES
	TP_IX
	BIT	0,(IX+TC_TMR)
	JR	Z,.stall
	PUSH	IX
	POP	HL
	LD	DE,TC_RTXDL
	ADD	HL,DE
	CALL	DL_MERGE
	TP_IX
.stall
	BIT	1,(IX+TC_TMR)
	RET	Z
	PUSH	IX
	POP	HL
	LD	DE,TC_STALL
	ADD	HL,DE
	JP	DL_MERGE

; ----------------------------------------------------------------------
; TP_STEP: timers, connection progress and the next outgoing segment.
; ----------------------------------------------------------------------
TP_STEP
	TP_IX
	LD	A,(IX+TC_ST)
	OR	A
	JR	NZ,.active
	RES	4,(IY+CX_TMR_FLAGS)	; no connection: no transport timers owed
	RET
.active
	BIT	4,(IY+CX_TMR_FLAGS)	; UTMR_TPDUE: timers owed
	JR	NZ,.due
	LD	HL,COST_TCP_IDLE
	CALL	TAKE
	RET	C
	TP_IX
	LD	A,(IX+TC_ST)
	CP	TCS_ARP
	RET	Z			; ARP progress always invalidates the cache
	JP	.window
.due
	LD	HL,COST_TCP_STEP
	CALL	TAKE
	RET	C			; UTMR_TPDUE stays: next STEP
	RES	4,(IY+CX_TMR_FLAGS)
.due_ok
	CALL	ARP_TIMERS		; Z: next hop resolved
	TP_IX
	JR	NZ,.no_hop
	LD	A,(IX+TC_ST)
	CP	TCS_ARP
	JR	NZ,.timers
	LD	(IX+TC_ST),TCS_SYN
	SET	3,(IX+TC_FL)		; TCF_SYN
	JR	.timers
.no_hop
	LD	A,(IX+TC_ST)
	CP	TCS_ARP
	RET	Z			; still resolving (OPEN deadline in the core)
.timers
	; retransmission
	BIT	0,(IX+TC_TMR)
	JP	Z,.stall
	PUSH	IX
	POP	HL
	LD	DE,TC_RTXDL
	ADD	HL,DE
	CALL	DL_LEFT
	; IX is kept by DL_LEFT (TP_IX would clobber CF)
	JP	NC,.stall
	LD	A,(IX+TC_RTXI)
	INC	A
	CP	(IY+CX_RETRY_COUNT)
	JR	Z,.retry
	JR	C,.retry
	RES	0,(IX+TC_TMR)
	LD	A,(IX+TC_ST)
	CP	TCS_SYN
	JR	Z,.stall		; SYN: the connect deadline decides
	LD	A,UNETG_EV_RETRY_EXHAUSTED
	LD	DE,0
	CALL	CH_FAIL
	JP	TP_RESET
.retry
	LD	(IX+TC_RTXI),A
	CALL	TCP_ARM_RTX
	STAT_INC UNETG_STATS_TCP_RETRANSMITS
	TP_IX
	LD	(IX+TC_PREP),TCP_PREP_NONE
	LD	A,(IX+TC_ST)
	CP	TCS_SYN
	JR	NZ,.rewind
	SET	3,(IX+TC_FL)
	JR	.stall
.rewind
	CALL	TCP_REWIND
.stall
	BIT	1,(IX+TC_TMR)
	JR	Z,.window
	PUSH	IX
	POP	HL
	LD	DE,TC_STALL
	ADD	HL,DE
	CALL	DL_LEFT
	; IX is kept by DL_LEFT (TP_IX would clobber CF)
	JR	NC,.window
	LD	A,UNETG_EV_TIMEOUT
	LD	DE,UNETG_TIMEOUT_TX
	CALL	CH_FAIL
	JP	TP_RESET
.window
	; RX space released: announce it if the last window was below MSS
	BIT	2,(IY+CX_CHAN_FLAGS)	; UCHF_WINUPD
	JR	Z,.prep
	RES	2,(IY+CX_CHAN_FLAGS)
	LD	L,(IX+TC_LADV)
	LD	H,(IX+TC_LADV+1)
	LD	DE,UNETG_TCP_MSS
	OR	A
	SBC	HL,DE
	JR	NC,.prep
	SET	0,(IX+TC_FL)		; TCF_ACK
.prep
	LD	A,(IX+TC_PREP)
	CP	TCP_PREP_SUM
	JP	Z,TCP_PREP_SUMMING
	OR	A
	RET	NZ			; ready, waiting for the engine
	JP	TCP_CHOOSE

; TCP_ARM_RTX: RTX deadline = now + retry_wait_ms[TC_RTXI].  IX = tp.
; TCP_REWIND: send again from the oldest unacknowledged byte (IX = tp).
TCP_REWIND
	LD	(IX+TC_PREP),TCP_PREP_NONE
	SEQ_COPY TC_NXT, TC_UNA
	LD	A,(IY+CX_TX_SEND)
	LD	(IX+TC_NSLOT),A
	LD	A,(IY+CX_TX_OFF)
	LD	(IX+TC_NOFF),A
	LD	A,(IY+CX_TX_OFF+1)
	LD	(IX+TC_NOFF+1),A
	LD	(IX+TC_SEGS),0
	BIT	2,(IX+TC_FL)		; our FIN was in flight: send it again
	RET	Z
	RES	2,(IX+TC_FL)
	SET	1,(IX+TC_FL)
	RET

TCP_ARM_RTX
	SET	0,(IX+TC_TMR)
	LD	A,(IX+TC_RTXI)
	ADD	A,A
	LD	E,A
	LD	D,0
	LD	HL,CX_RETRY_WAIT_MS
	ADD	HL,DE
	PUSH	IY
	POP	DE
	ADD	HL,DE
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	PUSH	IX
	POP	HL
	LD	BC,TC_RTXDL
	ADD	HL,BC
	JP	DL_SET

; TCP_ARM_STALL: stall deadline = now + send_stall_timeout_ms.
TCP_ARM_STALL
	SET	1,(IX+TC_TMR)
	LD	E,(IY+CX_SEND_STALL_TIMEOUT_MS)
	LD	D,(IY+CX_SEND_STALL_TIMEOUT_MS+1)
	PUSH	IX
	POP	HL
	LD	BC,TC_STALL
	ADD	HL,BC
	JP	DL_SET

; ----------------------------------------------------------------------
; TCP_CHOOSE: decide the next segment (RST is not sent in v1: ABORT just
; forgets the connection).  IX = tp.
; ----------------------------------------------------------------------
TCP_CHOOSE
	LD	A,(IX+TC_ST)
	CP	TCS_SYN
	JR	NZ,.data
	BIT	3,(IX+TC_FL)
	RET	Z
	LD	HL,COST_TEMPLATE
	CALL	TAKE
	RET	C
	TP_IX
	RES	3,(IX+TC_FL)
	LD	A,IP_PROTO_TCP		; next hop known now: build the template
	PUSH	IX
	CALL	IP_TEMPLATE
	POP	IX
	SEQ_COPY TC_TXSEQ, TC_UNA
	LD	DE,1
	SEQ_COPY TC_NXT, TC_UNA
	SEQ_ADD	TC_NXT			; SYN takes one sequence number
	LD	A,TCPF_SYN
	JP	.control
.data
	CP	TCS_EST
	JR	Z,.can_send
	CP	TCS_CW
	JP	NZ,.ack_only
.can_send
	LD	A,(IX+TC_SEGS)
	CP	2
	JP	NC,.ack_only
	LD	C,(IX+TC_NSLOT)
	PUSH	IX
	CALL	TX_STATE_PTR
	POP	IX
	LD	A,(HL)
	CP	UTX_COMMITTED
	JR	Z,.slot
	CP	UTX_SENDING
	JP	NZ,.fin
.slot
	PUSH	HL
	LD	HL,COST_TCP_DATA
	CALL	TAKE
	POP	HL
	RET	C			; next STEP
	PUSH	HL
	; n = min(len - off, mss, window - in flight)
	PUSH	IX
	CALL	TX_LEN_PTR
	POP	IX
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A
	LD	E,(IX+TC_NOFF)
	LD	D,(IX+TC_NOFF+1)
	OR	A
	SBC	HL,DE
	EX	DE,HL			; DE = bytes left in the slot
	LD	L,(IX+TC_MSS)
	LD	H,(IX+TC_MSS+1)
	CALL	MIN_DE_HL
	PUSH	DE
	SEQ_SUB	TC_NXT, TC_UNA		; BC = in flight
	LD	L,(IX+TC_SWND)
	LD	H,(IX+TC_SWND+1)
	OR	A
	SBC	HL,BC
	POP	DE
	JR	NC,.wnd
	LD	HL,0
.wnd
	CALL	MIN_DE_HL		; DE = segment payload
	POP	HL			; slot state
	LD	A,D
	OR	E
	JP	Z,.ack_only		; zero window: the stall timer decides
	LD	(HL),UTX_SENDING
	LD	(IX+TC_TXLEN),E
	LD	(IX+TC_TXLEN+1),D
	SEQ_COPY TC_TXSEQ, TC_NXT
	PUSH	DE
	SEQ_ADD	TC_NXT
	POP	DE
	; payload source = slot buffer + offset, then move the cursor
	PUSH	DE
	LD	C,(IX+TC_NSLOT)
	PUSH	IX
	CALL	TX_BUF
	POP	IX
	LD	E,(IX+TC_NOFF)
	LD	D,(IX+TC_NOFF+1)
	ADD	HL,DE
	LD	(IX+TC_SRC),L
	LD	(IX+TC_SRC+1),H
	POP	DE
	LD	L,(IX+TC_NOFF)
	LD	H,(IX+TC_NOFF+1)
	ADD	HL,DE
	LD	(IX+TC_NOFF),L
	LD	(IX+TC_NOFF+1),H
	PUSH	HL
	LD	C,(IX+TC_NSLOT)
	PUSH	IX
	CALL	TX_LEN_PTR
	POP	IX
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A
	POP	DE
	OR	A
	SBC	HL,DE
	JR	NZ,.same_slot
	LD	(IX+TC_NOFF),L		; HL = 0 here
	LD	(IX+TC_NOFF+1),L
	LD	A,(IX+TC_NSLOT)
	SLOT_INC CX_TX_SLOT_COUNT
	LD	(IX+TC_NSLOT),A
.same_slot
	INC	(IX+TC_SEGS)
	LD	A,(IX+TC_SEGS)
	DEC	A
	JR	NZ,.second
	SEQ_COPY TC_SEG1, TC_NXT
.second
	BIT	1,(IX+TC_TMR)
	CALL	Z,TCP_ARM_STALL
	LD	(IX+TC_TXFL),TCPF_ACK | TCPF_PSH
	XOR	A
	LD	(IX+TC_SUMPOS),A
	LD	(IX+TC_SUMPOS+1),A
	LD	(IX+TC_SUM),A
	LD	(IX+TC_SUM+1),A
	LD	(IX+TC_PREP),TCP_PREP_SUM
	JP	TCP_PREP_SUMMING
.fin
	; no data waiting at the cursor: FIN when asked for
	BIT	1,(IX+TC_FL)
	JR	Z,.ack_only
	RES	1,(IX+TC_FL)
	SET	2,(IX+TC_FL)		; TCF_FINSENT
	SEQ_COPY TC_TXSEQ, TC_NXT
	LD	DE,1
	SEQ_ADD	TC_NXT
	LD	A,(IX+TC_ST)
	CP	TCS_EST
	LD	(IX+TC_ST),TCS_FW1
	JR	Z,.fin_flags
	LD	(IX+TC_ST),TCS_LACK
.fin_flags
	LD	A,TCPF_FIN | TCPF_ACK
	JR	.control
.ack_only
	BIT	0,(IX+TC_FL)
	JR	NZ,.pure_ack
	LD	A,(IX+TC_ST)
	CP	TCS_DONE
	RET	NZ
	JR	.finished
.pure_ack
	SEQ_COPY TC_TXSEQ, TC_NXT
	LD	A,TCPF_ACK
.control
	LD	(IX+TC_TXFL),A
	XOR	A
	LD	(IX+TC_TXLEN),A
	LD	(IX+TC_TXLEN+1),A
	LD	(IX+TC_SUM),A
	LD	(IX+TC_SUM+1),A
	LD	(IX+TC_PREP),TCP_PREP_READY
	RET
.finished
	LD	HL,COST_TERMINATE
	CALL	TAKE
	RET	C
	TP_IX
	LD	(IX+TC_ST),TCS_CLOSED
	LD	A,UTX_DONE_FAILED
	JP	CH_TERMINATE

; TCP_PREP_SUMMING: checksum the payload in budgeted chunks.
TCP_PREP_SUMMING
	LD	L,(IX+TC_TXLEN)
	LD	H,(IX+TC_TXLEN+1)
	LD	E,(IX+TC_SUMPOS)
	LD	D,(IX+TC_SUMPOS+1)
	OR	A
	SBC	HL,DE
	JR	Z,.ready
	EX	DE,HL			; DE = bytes left
	LD	HL,TCP_SUM_CHUNK
	CALL	MIN_DE_HL
	PUSH	DE
	LD	HL,80			; summing portion overhead (stand: 201 us / 128 B)
	LD	A,0
	CALL	BUDGET_BYTES		; BC = affordable bytes (<= DE)
	POP	DE
	RET	C
	PUSH	DE
	TP_IX				; clobbers DE
	POP	DE
	; keep portions even so the next one starts on a word boundary
	LD	A,C
	CP	E
	JR	Z,.full_ok
	RES	0,C
	LD	A,B
	OR	C
	RET	Z
.full_ok
	PUSH	BC
	LD	L,(IX+TC_SRC)
	LD	H,(IX+TC_SRC+1)
	LD	E,(IX+TC_SUMPOS)
	LD	D,(IX+TC_SUMPOS+1)
	ADD	HL,DE
	EX	DE,HL
	LD	L,(IX+TC_SUM)
	LD	H,(IX+TC_SUM+1)
	CALL	CSUM_RAM
	TP_IX
	LD	(IX+TC_SUM),L
	LD	(IX+TC_SUM+1),H
	POP	BC
	LD	L,(IX+TC_SUMPOS)
	LD	H,(IX+TC_SUMPOS+1)
	ADD	HL,BC
	LD	(IX+TC_SUMPOS),L
	LD	(IX+TC_SUMPOS+1),H
	SET	2,(IY+CX_WORK)
	JR	TCP_PREP_SUMMING
.ready
	LD	(IX+TC_PREP),TCP_PREP_READY
	RET

; ----------------------------------------------------------------------
; TP_TX_PULL: hand a prepared segment to the engine (header in ctx.txh).
; Out: CF=1 nothing ready.
; ----------------------------------------------------------------------
TP_TX_PULL
	TP_IX
	LD	A,(IX+TC_PREP)
	CP	TCP_PREP_READY
	SCF
	RET	NZ
	LD	HL,COST_TP_PULL
	CALL	TAKE
	RET	C
	TP_IX
	LD	(IX+TC_PREP),TCP_PREP_NONE
	LD	B,TCP_HDR		; 24 with the MSS option on SYN
	BIT	1,(IX+TC_TXFL)		; TCPF_SYN
	JR	Z,.hlen
	LD	B,TCP_HDR + 4
.hlen
	LD	(IX+TC_HLEN),B
	LD	L,(IX+TC_TXLEN)
	LD	H,(IX+TC_TXLEN+1)
	LD	E,B
	LD	D,0
	ADD	HL,DE
	EX	DE,HL			; DE = TCP length
	PUSH	DE
	CALL	IP_FINISH
	CALL	TCP_HDR_FILL
	POP	DE
	CALL	TCP_CSUM_TX
	TP_IX
	LD	A,(IX+TC_HLEN)
	ADD	A,ETH_L4
	LD	L,(IX+TC_SRC)
	LD	H,(IX+TC_SRC+1)
	LD	C,(IX+TC_TXLEN)
	LD	B,(IX+TC_TXLEN+1)
	CALL	TX_FRAME_SET
	TP_IX
	RES	0,(IX+TC_FL)		; this segment carries the ACK
	; anything that takes sequence space arms the retransmission timer
	LD	A,(IX+TC_TXFL)
	AND	TCPF_SYN | TCPF_FIN
	OR	(IX+TC_TXLEN)
	OR	(IX+TC_TXLEN+1)
	JR	Z,.no_rtx
	BIT	0,(IX+TC_TMR)
	CALL	Z,TCP_ARM_RTX
.no_rtx
	OR	A
	RET

; TCP_HDR_FILL: the variable part of the TCP header (ports are in the
; template): sequence, acknowledgment, offset, flags, window, options.
TCP_HDR_FILL
	TP_IX
	LD	DE,UCTX_TXH + TCP_SEQ - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,DE			; HL -> sequence field
	LD	A,(IX+TC_TXSEQ+3)
	LD	(HL),A
	INC	HL
	LD	A,(IX+TC_TXSEQ+2)
	LD	(HL),A
	INC	HL
	LD	A,(IX+TC_TXSEQ+1)
	LD	(HL),A
	INC	HL
	LD	A,(IX+TC_TXSEQ)
	LD	(HL),A
	INC	HL
	LD	A,(IX+TC_RCV+3)
	LD	(HL),A
	INC	HL
	LD	A,(IX+TC_RCV+2)
	LD	(HL),A
	INC	HL
	LD	A,(IX+TC_RCV+1)
	LD	(HL),A
	INC	HL
	LD	A,(IX+TC_RCV)
	LD	(HL),A
	INC	HL
	LD	A,(IX+TC_HLEN)
	ADD	A,A
	ADD	A,A			; (length / 4) << 4
	LD	(HL),A
	INC	HL
	LD	A,(IX+TC_TXFL)
	LD	(HL),A
	INC	HL
	PUSH	HL
	CALL	RXR_FREE		; advertised window = free RX ring
	LD	(IX+TC_LADV),L
	LD	(IX+TC_LADV+1),H
	EX	DE,HL
	POP	HL
	LD	(HL),D
	INC	HL
	LD	(HL),E
	INC	HL
	XOR	A
	LD	(HL),A			; checksum (below) and urgent pointer
	INC	HL
	LD	(HL),A
	INC	HL
	LD	(HL),A
	INC	HL
	LD	(HL),A
	INC	HL
	LD	A,(IX+TC_HLEN)
	CP	TCP_HDR + 4
	RET	NZ
	LD	(HL),2			; MSS option: kind 2, length 4, 536
	INC	HL
	LD	(HL),4
	INC	HL
	LD	(HL),HIGH UNETG_TCP_MSS
	INC	HL
	LD	(HL),LOW UNETG_TCP_MSS
	RET

; TCP_CSUM_TX: DE = TCP length.  checksum = TPT_L4S0 (addresses, protocol,
; ports) + length + the header from the sequence field + payload sum.
TCP_CSUM_TX
	PUSH	DE
	CALL	L4_SUM0
	POP	DE
	CALL	CSUM_ADD_BE		; pseudo-header length
	PUSH	HL
	LD	A,TC_HLEN
	CALL	TP_FIELD
	LD	A,(HL)
	SUB	4			; ports are already in L4S0
	LD	C,A
	LD	B,0
	LD	DE,UCTX_TXH + TCP_SEQ - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,DE
	EX	DE,HL			; DE -> sequence field
	POP	HL
	CALL	CSUM_RAM
	PUSH	HL
	LD	A,TC_SUM
	CALL	TP_FIELD
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	POP	HL
	ADD	HL,DE			; payload sum, same byte-swapped domain
	CALL	CSUM_FOLD
	PUSH	HL
	LD	DE,UCTX_TXH + TCP_CSUM - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,DE
	EX	DE,HL
	POP	HL
	JP	CSUM_STORE

TP_TX_DONE
	RET				; losses are repaired by retransmission

; ----------------------------------------------------------------------
; TP_RX_ACCEPT: A = protocol, BC = segment length, IX -> frame (scratch).
; Out: CF=1 dropped (counted); CF=0 accepted (engine copies the rest).
; ----------------------------------------------------------------------
TP_RX_ACCEPT
	CP	IP_PROTO_TCP
	JP	NZ,.foreign
	PUSH	BC
	PUSH	IX
	POP	HL
	LD	DE,ETH_IP_SRC
	ADD	HL,DE
	LD	DE,CX_PEER_IP
	CALL	IP_EQ_CTX
	POP	BC
	JP	NZ,.foreign
	LD	A,(IX+TCP_SPORT)
	CP	(IY+CX_PEER_PORT+1)
	JP	NZ,.foreign
	LD	A,(IX+TCP_SPORT+1)
	CP	(IY+CX_PEER_PORT)
	JP	NZ,.foreign
	LD	A,TC_LPORT
	PUSH	BC
	CALL	TP_FIELD		; HL -> local port
	POP	BC
	LD	A,(IX+TCP_DPORT+1)
	CP	(HL)
	JP	NZ,.foreign
	INC	HL
	LD	A,(IX+TCP_DPORT)
	CP	(HL)
	JP	NZ,.foreign
	LD	A,TC_ST
	PUSH	BC
	CALL	TP_FIELD
	POP	BC
	LD	A,(HL)
	CP	TCS_SYN
	JP	C,.foreign		; no connection in progress
	; header length
	LD	A,(IX+TCP_DOFF)
	AND	0xF0
	RRCA
	RRCA				; data offset * 4
	CP	TCP_HDR
	JP	C,.size
	LD	E,A
	LD	D,0
	LD	H,B
	LD	L,C
	OR	A
	SBC	HL,DE			; payload length
	JP	C,.size
	PUSH	DE			; header length
	PUSH	HL			; payload length
	LD	A,IP_PROTO_TCP
	CALL	ETH_SEG_START		; DE = segment bytes in scratch
	PUSH	DE
	; header fields of the segment -> tp
	LD	A,TC_RXSEQ
	CALL	TP_FIELD
	EX	DE,HL			; DE -> TC_RXSEQ
	PUSH	IX
	POP	HL
	LD	BC,TCP_SEQ
	ADD	HL,BC
	CALL	REV32			; DE -> TC_RXACK
	PUSH	IX
	POP	HL
	LD	BC,TCP_ACK
	ADD	HL,BC
	CALL	REV32			; DE -> TC_RXFL
	LD	A,(IX+TCP_FLAGS)
	LD	(DE),A
	INC	DE
	LD	A,(IX+TCP_WND+1)
	LD	(DE),A
	INC	DE
	LD	A,(IX+TCP_WND)
	LD	(DE),A
	POP	BC			; BC = segment bytes in scratch
	POP	DE			; DE = payload length
	POP	HL			; HL = header length
	PUSH	IX			; frame
	TP_IX
	LD	(IX+TC_RXLEN),E
	LD	(IX+TC_RXLEN+1),D
	LD	(IX+TC_RXSTORE),0
	LD	(IX+TC_RXHLEN),L
	LD	(IX+TC_RXN0),C
	; header bytes still on the card: max(0, hlen - in scratch)
	PUSH	HL
	PUSH	DE
	PUSH	BC
	OR	A
	SBC	HL,BC
	JR	NC,.skip
	LD	HL,0
.skip
	EX	DE,HL
	LD	A,HS_RXSKIP
	CALL	HS_FIELD
	LD	(HL),E
	INC	HL
	LD	(HL),D
	POP	BC
	POP	DE
	POP	HL
	; store only in-order payload that fits the free ring
	LD	A,D
	OR	E
	JR	Z,.accept
	LD	A,(IX+TC_ST)
	CP	TCS_EST
	JR	Z,.state_ok
	CP	TCS_FW1
	JR	Z,.state_ok
	CP	TCS_FW2
	JR	NZ,.accept
.state_ok
	PUSH	HL
	PUSH	DE
	PUSH	BC
	SEQ_SUB	TC_RXSEQ, TC_RCV
	LD	A,H
	OR	L
	OR	B
	OR	C
	JR	NZ,.no_store		; out of order: ACK only
	CALL	RXR_FREE
	POP	BC
	POP	DE
	PUSH	DE
	PUSH	BC
	OR	A
	SBC	HL,DE
	JR	NC,.store
	STAT_INC UNETG_STATS_RING_OVERFLOW
.no_store
	POP	BC
	POP	DE
	POP	HL
.accept
	POP	IX
	OR	A
	RET
.store
	; placement in the ring is a second portion (ERX_STORE)
	LD	(IX+TC_RXSTORE),1
	POP	BC
	POP	DE
	POP	HL
	POP	IX
	LD	A,HS_RXS
	CALL	HS_FIELD
	LD	(HL),ERX_STORE
	OR	A
	RET

.foreign
	STAT_INC UNETG_STATS_DROP_FOREIGN
	SCF
	RET
.size
	STAT_INC UNETG_STATS_DROP_SIZE
	SCF
	RET

; TP_RX_STORE: ERX_STORE -- set up the payload placement for the accepted
; segment, then continue with the card part (COPY) or the verdict.
TP_RX_STORE
	TP_IX
	LD	L,(IX+TC_RXHLEN)
	LD	H,0
	LD	E,(IX+TC_RXLEN)
	LD	D,(IX+TC_RXLEN+1)
	LD	C,(IX+TC_RXN0)
	LD	B,0
	LD	A,(IX+TC_RXSTORE)
	PUSH	AF
	PUSH	DE
	LD	DE,UCTX_SCRATCH - CTX_BIAS
	PUSH	IY
	POP	IX
	ADD	IX,DE			; IX -> frame
	POP	DE
	POP	AF
	OR	A
	CALL	NZ,TCP_RX_STORE_SETUP
	HWSM_IX
	LD	A,(IX+HS_RXREM)
	OR	(IX+HS_RXREM+1)
	LD	(IX+HS_RXS),ERX_COPY
	RET	NZ
	LD	(IX+HS_RXS),ERX_FINISH
	RET

; TCP_RX_STORE_SETUP: HL = header length, DE = payload length, BC = segment
; bytes already in scratch, IX -> frame.  Copies the payload bytes found in
; scratch to the ring write position and tells the engine where the card
; part goes (HS_RXDST / HS_RXSPAN / HS_RXLIM).  Out: CF=0.
TCP_RX_STORE_SETUP
	PUSH	DE			; payload
	PUSH	HL			; hlen
	PUSH	BC			; in scratch
	CALL	RXR_DEST		; DE = cursor address
	LD	L,(IY+CX_RX_SLOTS_PTR)
	LD	H,(IY+CX_RX_SLOTS_PTR+1)
	EX	DE,HL			; HL = cursor, DE = ring base
	PUSH	HL
	OR	A
	SBC	HL,DE			; linear offset of the cursor
	EX	DE,HL
	LD	L,(IY+CX_RX_TOTAL)
	LD	H,(IY+CX_RX_TOTAL+1)
	OR	A
	SBC	HL,DE			; bytes before the ring wraps
	LD	B,H
	LD	C,L
	POP	DE
	LD	A,HS_RXDST
	CALL	HS_FIELD
	LD	(HL),E			; HS_RXDST
	INC	HL
	LD	(HL),D
	INC	HL
	LD	(HL),C			; HS_RXSPAN
	INC	HL
	LD	(HL),B
	POP	BC			; in scratch
	POP	DE			; hlen
	; payload bytes already in scratch = in scratch - hlen (if positive)
	LD	H,B
	LD	L,C
	OR	A
	SBC	HL,DE
	JR	NC,.some
	LD	HL,0
.some
	PUSH	HL
	PUSH	IX
	POP	BC
	EX	DE,HL
	ADD	HL,BC
	LD	BC,ETH_L4
	ADD	HL,BC			; HL -> payload in scratch
	POP	BC
	PUSH	BC
	CALL	RXT_PUT
	POP	BC			; payload in scratch
	POP	HL			; payload
	OR	A
	SBC	HL,BC			; payload still on the card
	EX	DE,HL
	LD	A,HS_RXLIM
	CALL	HS_FIELD
	LD	(HL),E
	INC	HL
	LD	(HL),D
	OR	A
	RET

; RXT_PUT: copy BC bytes from HL to HS_RXDST, wrapping at the ring end
; (HS_RXSPAN).  Clobbers A, BC, DE, HL.
RXT_PUT
	LD	A,B
	OR	C
	RET	Z
	PUSH	BC			; count
	PUSH	HL			; source
	LD	A,HS_RXDST
	CALL	HS_FIELD
	LD	E,(HL)
	INC	HL
	LD	D,(HL)			; DE = destination
	INC	HL
	LD	C,(HL)
	INC	HL
	LD	B,(HL)			; BC = span
	POP	HL			; source
	EX	(SP),HL			; HL = count, (SP) = source
	PUSH	HL
	OR	A
	SBC	HL,BC
	POP	HL
	JR	NC,.piece		; count >= span: the span first
	LD	B,H
	LD	C,L
.piece
	; HL = count, BC = piece
	OR	A
	SBC	HL,BC
	EX	(SP),HL			; (SP) = count left, HL = source
	PUSH	BC
	LDIR
	POP	BC			; piece
	PUSH	HL			; source after the piece
	LD	A,HS_RXDST
	CALL	HS_FIELD
	LD	(HL),E
	INC	HL
	LD	(HL),D
	INC	HL
	LD	A,(HL)
	SUB	C
	LD	(HL),A
	INC	HL
	LD	A,(HL)
	SBC	A,B
	LD	(HL),A
	DEC	HL
	OR	(HL)
	JR	NZ,.no_wrap
	LD	A,(IY+CX_RX_TOTAL)
	LD	(HL),A
	INC	HL
	LD	A,(IY+CX_RX_TOTAL+1)
	LD	(HL),A
	LD	A,HS_RXDST
	CALL	HS_FIELD
	LD	A,(IY+CX_RX_SLOTS_PTR)
	LD	(HL),A
	INC	HL
	LD	A,(IY+CX_RX_SLOTS_PTR+1)
	LD	(HL),A
.no_wrap
	POP	HL			; source
	POP	BC			; count left
	JR	RXT_PUT

; ----------------------------------------------------------------------
; TP_RX_COMMIT: A = 1 when the segment checksum is valid.
; ----------------------------------------------------------------------
TP_RX_COMMIT
	OR	A
	RET	Z
	PUSH	AF
	LD	A,TC_ST
	CALL	TP_FIELD
	POP	AF
	LD	A,(HL)
	CP	TCS_SYN
	RET	C			; the connection went away meanwhile
	TP_IX				; (budget: the engine's COST_FINISH)
	LD	A,(IX+TC_RXFL)
	BIT	2,A			; RST
	JR	Z,.no_rst
	SEQ_SUB	TC_RXSEQ, TC_RCV
	LD	A,(IX+TC_ST)
	CP	TCS_SYN
	JR	Z,.rst_ok		; in SYN-SENT an RST with our ACK resets
	LD	A,H
	OR	L
	OR	B
	OR	C
	RET	NZ			; RST outside the window: ignore
.rst_ok
	LD	A,UNETG_EV_RESET
	LD	DE,0
	CALL	CH_FAIL
	JP	TP_RESET
.no_rst
	LD	A,(IX+TC_ST)
	CP	TCS_SYN
	JP	NZ,.synchronized
	; SYN-SENT: expect SYN+ACK acknowledging our SYN
	LD	A,(IX+TC_RXFL)
	AND	TCPF_SYN | TCPF_ACK
	CP	TCPF_SYN | TCPF_ACK
	RET	NZ
	SEQ_SUB	TC_RXACK, TC_NXT
	LD	A,H
	OR	L
	OR	B
	OR	C
	RET	NZ
	SEQ_COPY TC_UNA, TC_RXACK
	SEQ_COPY TC_RCV, TC_RXSEQ
	LD	DE,1
	SEQ_ADD	TC_RCV
	CALL	TCP_TAKE_WINDOW
	CALL	TCP_PARSE_MSS
	TP_IX
	LD	(IX+TC_ST),TCS_EST
	LD	(IX+TC_TMR),0
	LD	(IX+TC_RTXI),0
	SET	0,(IX+TC_FL)		; ACK the SYN
	LD	(IY+CX_CHAN),UCH_OPEN
	SET	0,(IY+CX_EV_FLAGS)	; UEVF_CONNECTED
	RES	3,(IY+CX_CLK_FLAGS)	; connect deadline met
	SET	1,(IY+CX_WORK)
	RET
.synchronized
	LD	A,(IX+TC_RXFL)
	BIT	4,A			; ACK
	CALL	NZ,TCP_ACKED
	TP_IX
	; payload
	LD	A,(IX+TC_RXLEN)
	OR	(IX+TC_RXLEN+1)
	JR	Z,.fin
	SET	0,(IX+TC_FL)		; every data segment is acknowledged
	LD	A,(IX+TC_RXSTORE)
	OR	A
	JR	Z,.fin
	LD	C,(IX+TC_RXLEN)
	LD	B,(IX+TC_RXLEN+1)
	PUSH	BC
	CALL	RXR_COMMIT
	POP	DE
	PUSH	DE
	STAT_ADD32 UNETG_STATS_RX_BYTES
	POP	DE
	TP_IX
	SEQ_ADD	TC_RCV
	SET	1,(IY+CX_WORK)
.fin
	BIT	0,(IX+TC_RXFL)		; FIN
	RET	Z
	; FIN counts only when it follows the data we have taken
	LD	E,(IX+TC_RXLEN)
	LD	D,(IX+TC_RXLEN+1)
	SEQ_ADD	TC_RXSEQ
	SEQ_SUB	TC_RXSEQ, TC_RCV
	LD	A,H
	OR	L
	OR	B
	OR	C
	RET	NZ
	LD	DE,1
	SEQ_ADD	TC_RCV
	SET	0,(IX+TC_FL)
	LD	A,(IX+TC_ST)
	CP	TCS_EST
	JR	NZ,.fin_closing
	; peer closed: report it, close our side after the queued data
	LD	(IX+TC_ST),TCS_CW
	SET	1,(IX+TC_FL)
	LD	A,UNETG_EV_PEER_CLOSED
	LD	DE,0
	CALL	CH_REASON
	LD	A,(IY+CX_CHAN)
	CP	UCH_OPEN
	RET	NZ
	LD	(IY+CX_CHAN),UCH_CLOSING
	LD	A,(IY+CX_CLK_FLAGS)
	OR	UCLK_OP_ARM		; close deadline
	LD	(IY+CX_CLK_FLAGS),A
	TMR_INVALIDATE
	RET
.fin_closing
	CP	TCS_FW2
	JR	Z,.done
	CP	TCS_FW1
	RET	NZ
	LD	(IX+TC_ST),TCS_CLOSING
	RET
.done
	LD	(IX+TC_ST),TCS_DONE	; finished once the ACK is out
	RET

; TCP_ACKED: process TC_RXACK.  IX = tp.
TCP_ACKED
	SEQ_SUB	TC_RXACK, TC_UNA	; BC = newly acknowledged
	LD	A,H
	OR	L
	RET	NZ			; old or far: ignore
	LD	A,B
	OR	C
	JP	Z,.window		; duplicate: window update only
	PUSH	BC
	SEQ_SUB	TC_NXT, TC_UNA		; BC = in flight
	POP	DE
	PUSH	DE
	LD	H,B
	LD	L,C
	OR	A
	SBC	HL,DE
	POP	BC
	RET	C			; acknowledges data never sent
	; FIN acknowledged?
	PUSH	BC
	LD	A,H
	OR	L
	JR	NZ,.data_only		; something is still in flight
	BIT	2,(IX+TC_FL)
	JR	Z,.data_only
	POP	BC
	DEC	BC			; the FIN sequence number is not data
	PUSH	BC
	RES	2,(IX+TC_FL)
	LD	A,(IX+TC_ST)
	CP	TCS_FW1
	LD	(IX+TC_ST),TCS_FW2
	JR	Z,.data_only
	LD	(IX+TC_ST),TCS_DONE	; CLOSING / LAST-ACK: finished
.data_only
	SEQ_COPY TC_UNA, TC_RXACK
	POP	BC
	CALL	TCP_RELEASE		; BC data bytes acknowledged
	TP_IX
	; A prepared data segment that starts before the new UNA (a
	; retransmission overtaken by the ACK of the original) points into
	; slots that may be reused now: drop it and send again from UNA.
	LD	A,(IX+TC_PREP)
	OR	A			; TCP_PREP_NONE
	JR	Z,.prep_ok
	LD	A,(IX+TC_TXLEN)
	OR	(IX+TC_TXLEN+1)
	JR	Z,.prep_ok		; control segment: no payload
	SEQ_SUB	TC_UNA, TC_TXSEQ
	BIT	7,H
	JR	NZ,.prep_ok		; UNA before the segment
	LD	A,H
	OR	L
	OR	B
	OR	C
	CALL	NZ,TCP_REWIND
.prep_ok
	; segments still in flight
	SEQ_SUB	TC_NXT, TC_UNA
	LD	A,B
	OR	C
	JR	NZ,.partial
	LD	(IX+TC_SEGS),0
	RES	0,(IX+TC_TMR)
	RES	1,(IX+TC_TMR)
	LD	(IX+TC_RTXI),0
	JR	.window
.partial
	SEQ_SUB	TC_UNA, TC_SEG1
	BIT	7,H
	JR	NZ,.restart		; the oldest segment is not complete yet
	LD	(IX+TC_SEGS),1
	SEQ_COPY TC_SEG1, TC_NXT
.restart
	LD	(IX+TC_RTXI),0
	CALL	TCP_ARM_RTX
	TP_IX
	CALL	TCP_ARM_STALL
	TP_IX
.window
	JP	TCP_TAKE_WINDOW

; TCP_TAKE_WINDOW: peer window from the received segment.
TCP_TAKE_WINDOW
	TP_IX
	LD	A,(IX+TC_RXWND)
	LD	(IX+TC_SWND),A
	LD	A,(IX+TC_RXWND+1)
	LD	(IX+TC_SWND+1),A
	RET

; TCP_PARSE_MSS: MSS option right after the fixed header (SYN+ACK).
TCP_PARSE_MSS
	LD	DE,UCTX_SCRATCH - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,DE
	LD	DE,TCP_OPT
	ADD	HL,DE
	LD	A,(HL)
	CP	2
	RET	NZ
	INC	HL
	LD	A,(HL)
	CP	4
	RET	NZ
	INC	HL
	LD	D,(HL)
	INC	HL
	LD	E,(HL)
	LD	HL,UNETG_TCP_MSS
	CALL	MIN_DE_HL
	LD	A,D
	OR	E
	RET	Z
	TP_IX
	LD	(IX+TC_MSS),E
	LD	(IX+TC_MSS+1),D
	RET

; TCP_RELEASE: BC data bytes acknowledged -> finished slots become DONE_OK.
TCP_RELEASE
	LD	A,B
	OR	C
	RET	Z
	PUSH	BC
	LD	D,B
	LD	E,C
	STAT_ADD32 UNETG_STATS_TX_BYTES
	POP	BC
.loop
	LD	A,B
	OR	C
	RET	Z
	PUSH	BC
	LD	C,(IY+CX_TX_SEND)
	CALL	TX_LEN_PTR
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A
	LD	E,(IY+CX_TX_OFF)
	LD	D,(IY+CX_TX_OFF+1)
	OR	A
	SBC	HL,DE			; bytes of this slot not yet acknowledged
	POP	BC
	PUSH	HL
	OR	A
	SBC	HL,BC
	POP	HL
	JR	Z,.whole
	JR	NC,.part
.whole
	; the slot is complete
	PUSH	HL
	PUSH	BC
	LD	C,(IY+CX_TX_SEND)
	CALL	TX_STATE_PTR
	LD	A,UTX_DONE_OK
	TX_SET_DONE
	XOR	A
	LD	(IY+CX_TX_OFF),A
	LD	(IY+CX_TX_OFF+1),A
	LD	A,(IY+CX_TX_SEND)
	SLOT_INC CX_TX_SLOT_COUNT
	LD	(IY+CX_TX_SEND),A
	POP	BC
	POP	HL
	PUSH	BC
	LD	D,H
	LD	E,L
	POP	HL
	OR	A
	SBC	HL,DE			; acknowledged bytes left
	LD	B,H
	LD	C,L
	JR	.loop
.part
	LD	L,(IY+CX_TX_OFF)
	LD	H,(IY+CX_TX_OFF+1)
	ADD	HL,BC
	LD	(IY+CX_TX_OFF),L
	LD	(IY+CX_TX_OFF+1),H
	RET

; RXR_COMMIT: publish BC bytes written at the ring cursor (slot pieces).
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
