; udp.asm -- UDP to one configured partner over the Ethernet engine.
; Datagrams up to 512 bytes, accepted or dropped whole (ABI §2); only the
; partner's address/port reach the application; checksum 0 is accepted.

UD_ST		EQU	0	; UDS_*
UD_LPORT	EQU	2	; u16
UD_PREP		EQU	4	; UDP_PREP_* (same values as TCP_PREP_*)
UD_LEN		EQU	6	; u16 payload of the datagram being sent
UD_SUMPOS	EQU	8	; u16
UD_SUM		EQU	10	; u16 payload checksum (byte-swapped domain)
UD_SRC		EQU	12	; u16
UD_RXLEN	EQU	14	; u16 payload of the datagram being received
UD_RXSTORE	EQU	16	; u8
UD_PORTSEQ	EQU	17	; u8
UD_REC		EQU	18	; u8[2] records: the received header, checked by TP_RX_COMMIT
UD_SIZE		EQU	20

UDS_CLOSED	EQU	0
UDS_ARP		EQU	1
UDS_OPEN	EQU	2

UDP_PREP_NONE	EQU	0
UDP_PREP_SUM	EQU	1
UDP_PREP_READY	EQU	2
UDP_PREP_FAST	EQU	3		; short path: chosen by TP_STEP, TP_TX_PULL does it all in this STEP
; Short path (taken only when it fits, so not bound by PROF_MAX_ITEM_US):
; a datagram of at most UDP_FAST_MAX bytes is summed and its header built
; as ONE item (COST_UDP_FAST + 3/2 per byte: chosen by TP_STEP, taken and
; done by TP_TX_PULL right behind it) instead of the idle, summing and
; pull items;
; a received one whose whole IPv4 packet is in ctx.scratch (payload <= 22)
; is verified and published as one item (UDP_RX_FAST) instead of classify,
; sum, accept and finish.
UDP_FAST_MAX	EQU	64
; bytes at DE and HL equal, else to .other with NZ (UDP_RX_FAST)
	MACRO	UDP_SAME2
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.other
	INC	DE
	INC	HL
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.other
	INC	DE
	INC	HL
	ENDM
	MACRO	UDP_SAME4
	UDP_SAME2
	UDP_SAME2
	ENDM
COST_UDP_FAST	EQU	190	; (stand: 148 us with 1 byte, 200 with 40, 222 with 64; 25 for the choice in TP_STEP)
COST_UDP_RX_FAST EQU	280	; (stand: 249 us with 22 bytes; 10 for the checks in front of it)
UDP_SUM_CHUNK	EQU	96		; bytes summed per item (100 + 96 units)
COST_UDP_STEP	EQU	115	; ARP timers (96 us)
COST_UDP_IDLE	EQU	75	; (59 us)
COST_TEMPLATE	EQU	180	; IP_TEMPLATE (162 us)
	ASSERT	COST_UDP_STEP <= PROF_MAX_ITEM_US
	ASSERT	COST_TEMPLATE <= PROF_MAX_ITEM_US	; taken before the idle step (TP_STEP .open)

	MACRO	TP_IX
	PUSH	DE			; preserves DE
	LD	DE,UCTX_TP - CTX_BIAS
	PUSH	IY
	POP	IX
	ADD	IX,DE
	POP	DE
	ENDM

	MACRO	TP_IX_HL		; HL = ctx.tp, preserves DE
	PUSH	DE
	LD	DE,UCTX_TP - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,DE
	POP	DE
	ENDM

TP_OPEN
	TP_IX
	LD	A,(IX+UD_PORTSEQ)
	INC	A
	PUSH	AF
	PUSH	IX
	POP	HL
	LD	B,UD_SIZE
.clr
	LD	(HL),0
	INC	HL
	DJNZ	.clr
	POP	AF
	LD	(IX+UD_PORTSEQ),A
	LD	L,(IY+CX_LOCAL_PORT)
	LD	H,(IY+CX_LOCAL_PORT+1)
	LD	A,H
	OR	L
	JR	NZ,.port
	LD	L,(IY+CX_NOW_MS)
	LD	A,(IY+CX_NOW_MS+1)
	ADD	A,(IX+UD_PORTSEQ)
	AND	0x3F
	OR	0xC0
	LD	H,A
.port
	LD	(IX+UD_LPORT),L
	LD	(IX+UD_LPORT+1),H
	LD	(IX+UD_ST),UDS_ARP
	JP	ARP_RESOLVE

TP_CLOSE
	RET				; TP_STEP finishes once the queue is sent

TP_ABORT
TP_RESET
	TP_IX
	LD	(IX+UD_ST),UDS_CLOSED
	LD	(IX+UD_PREP),UDP_PREP_NONE
	RET

TP_DEADLINES
	JP	ARP_DEADLINES

TP_STEP
	TP_IX
	IFDEF	UGB_SHORT
	; a short-path choice of an earlier STEP that the pull did not take
	; (an ARP frame went first): chosen anew
	LD	A,(IX+UD_PREP)
	CP	UDP_PREP_FAST
	JR	NZ,.kept
	LD	(IX+UD_PREP),UDP_PREP_NONE
.kept
	ENDIF
	LD	A,(IX+UD_ST)
	OR	A
	JR	NZ,.active
	RES	4,(IY+CX_TMR_FLAGS)	; no connection: no transport timers owed
	RET
.active
	CP	UDS_ARP
	JR	NZ,.not_arp
	; resolved by ARP_INPUT: open before paying for the timer step, so the
	; template always fits a STEP
	LD	DE,UCTX_ARP + AR_STATE - CTX_BIAS
	CALL	IY_PTR
	LD	A,(HL)
	CP	ARS_VALID
	JR	NZ,.not_arp
	JP	.open
.not_arp
	BIT	4,(IY+CX_TMR_FLAGS)	; UTMR_TPDUE: timers owed
	JR	NZ,.due
	; no timer due and a datagram prepared for the engine: nothing to do,
	; no budget taken
	LD	A,(IX+UD_PREP)
	CP	UDP_PREP_READY
	RET	Z
	; nothing for .send (its conditions, checked without budget: a refused
	; idle step costs base time too) -> no budget taken
	LD	A,(IX+UD_ST)
	CP	UDS_OPEN
	RET	NZ
	LD	A,(IX+UD_PREP)
	OR	A
	JR	NZ,.idle		; UDP_PREP_SUM: payload being summed
	LD	C,(IY+CX_TX_SEND)
	CALL	TX_STATE_PTR		; keeps IX
	LD	A,(HL)
	CP	UTX_COMMITTED
	IFDEF	UGB_SHORT
	JR	NZ,.not_queued
	; short path: with a free TX pipeline a small datagram is one item of
	; TP_TX_PULL, in this same STEP (the TX phase follows the transport
	; step and nothing takes units in between; UDP_FAST_FITS also leaves
	; the TX phase its entry check) -- no item here
	BIT	USCH_SHORT,(IY+CX_SCHED_FLAGS)
	JR	Z,.idle
	LD	A,(IY+EX_TXS)
	OR	A
	JR	NZ,.idle
	CALL	UDP_FAST_FITS		; DE = length, HL = its cost
	JR	C,.idle
	LD	(IX+UD_LEN),E
	LD	(IX+UD_LEN+1),D
	LD	(IX+UD_SUM),L		; (the pull sums the payload itself)
	LD	(IX+UD_SUM+1),H
	LD	(IX+UD_PREP),UDP_PREP_FAST
	RET
.not_queued
	ELSE
	JR	Z,.idle
	ENDIF
	CP	UTX_SENDING
	RET	Z			; in the card
	LD	A,(IY+CX_CHAN)		; nothing queued: only a closing channel
	CP	UCH_CLOSING		; has work (finish it)
	RET	NZ
	BIT	1,(IY+CX_CHAN_FLAGS)	; UCHF_FINISHED
	RET	NZ
.idle
	LD	HL,COST_UDP_IDLE
	CALL	TAKE
	RET	C
	TP_IX
	JP	.send
.due
	LD	HL,COST_UDP_STEP
	CALL	TAKE
	RET	C			; UTMR_TPDUE stays: next STEP
	RES	4,(IY+CX_TMR_FLAGS)
.due_ok
	CALL	ARP_TIMERS		; Z: next hop resolved
	TP_IX
	JR	NZ,.no_hop
	LD	A,(IX+UD_ST)
	CP	UDS_ARP
	JR	NZ,.send
.open
	; the partner is reachable: UDP has no handshake (ABI §3)
	LD	HL,COST_TEMPLATE
	CALL	TAKE
	JR	NC,.template
	TMR_INVALIDATE			; retry the transition next STEP
	RET
.template
	LD	A,IP_PROTO_UDP
	CALL	IP_TEMPLATE
	TP_IX
	LD	(IX+UD_ST),UDS_OPEN
	LD	(IY+CX_CHAN),UCH_OPEN
	SET	0,(IY+CX_EV_FLAGS)	; UEVF_CONNECTED
	RES	3,(IY+CX_CLK_FLAGS)
	SET	1,(IY+CX_WORK)
	JR	.send
.no_hop
	LD	A,(IX+UD_ST)
	CP	UDS_ARP
	RET	Z
	; an expired neighbour entry is being refreshed: wait, keep the queue
	RET
.send
	LD	A,(IX+UD_PREP)
	CP	UDP_PREP_SUM
	JR	Z,.summing
	OR	A
	RET	NZ			; ready, waiting for the engine
	LD	C,(IY+CX_TX_SEND)
	CALL	TX_STATE_PTR
	LD	A,(HL)
	CP	UTX_COMMITTED
	JR	Z,.start
	CP	UTX_SENDING
	RET	Z			; in the card
	; nothing queued: a closing channel is finished
	LD	A,(IY+CX_CHAN)
	CP	UCH_CLOSING
	RET	NZ
	BIT	1,(IY+CX_CHAN_FLAGS)
	RET	NZ
	LD	A,UTX_DONE_FAILED
	JP	CH_TERMINATE
.start
	LD	(HL),UTX_SENDING
	CALL	TX_LEN_PTR
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	PUSH	DE
	CALL	TX_BUF			; clobbers DE
	POP	DE
	TP_IX
	LD	(IX+UD_LEN),E
	LD	(IX+UD_LEN+1),D
	LD	(IX+UD_SRC),L
	LD	(IX+UD_SRC+1),H
	XOR	A
	LD	(IX+UD_SUMPOS),A
	LD	(IX+UD_SUMPOS+1),A
	LD	(IX+UD_SUM),A
	LD	(IX+UD_SUM+1),A
	LD	(IX+UD_PREP),UDP_PREP_SUM
.summing
	LD	L,(IX+UD_LEN)
	LD	H,(IX+UD_LEN+1)
	LD	E,(IX+UD_SUMPOS)
	LD	D,(IX+UD_SUMPOS+1)
	OR	A
	SBC	HL,DE
	JR	Z,.ready
	EX	DE,HL
	LD	HL,UDP_SUM_CHUNK
	CALL	MIN_DE_HL
	PUSH	DE
	LD	HL,100			; summing portion overhead (stand: 1.0 us / unit at 80 + 128)
	XOR	A
	CALL	BUDGET_BYTES
	POP	DE
	RET	C
	PUSH	DE
	TP_IX				; clobbers DE
	POP	DE
	LD	A,C
	CP	E
	JR	Z,.even
	RES	0,C			; keep the next portion word aligned
	LD	A,B
	OR	C
	RET	Z
.even
	PUSH	BC
	LD	L,(IX+UD_SRC)
	LD	H,(IX+UD_SRC+1)
	LD	E,(IX+UD_SUMPOS)
	LD	D,(IX+UD_SUMPOS+1)
	ADD	HL,DE
	EX	DE,HL
	LD	L,(IX+UD_SUM)
	LD	H,(IX+UD_SUM+1)
	CALL	CSUM_RAM
	TP_IX
	LD	(IX+UD_SUM),L
	LD	(IX+UD_SUM+1),H
	POP	BC
	LD	L,(IX+UD_SUMPOS)
	LD	H,(IX+UD_SUMPOS+1)
	ADD	HL,BC
	LD	(IX+UD_SUMPOS),L
	LD	(IX+UD_SUMPOS+1),H
	SET	2,(IY+CX_WORK)
	JR	.summing
.ready
	LD	(IX+UD_PREP),UDP_PREP_READY
	RET

; TP_TX_PULL: the prepared datagram -> ctx.txh.  CF=1 nothing ready.
; checksum = TPT_L4S0 (addresses, protocol, ports) + length (pseudo
; header) + length (UDP header) + payload; a zero result is sent as FFFF.
TP_TX_PULL
	TP_IX
	LD	A,(IX+UD_PREP)
	IFDEF	UGB_SHORT
	CP	UDP_PREP_FAST
	JR	Z,.fast
	ENDIF
	CP	UDP_PREP_READY
	SCF
	RET	NZ
	LD	HL,COST_TP_PULL
	IFDEF	UGB_RECORDS
	REC_ON
	JR	Z,.pull
	LD	HL,COST_TP_PULL + COST_REC_TX
.pull
	ENDIF
	CALL	TAKE
	RET	C
	TP_IX
	IFDEF	UGB_SHORT
	JR	.build
.fast
	; short path, chosen by TP_STEP in this STEP: commit -> frame (its
	; cost kept in UD_SUM by the choice)
	LD	L,(IX+UD_SUM)
	LD	H,(IX+UD_SUM+1)
	CALL	SHORT_TAKE		; (keeps IX)
	JR	NC,.fast_go
	LD	(IX+UD_PREP),UDP_PREP_NONE	; chosen anew next STEP
	RET				; CF=1
.fast_go
	LD	C,(IY+CX_TX_SEND)
	CALL	TX_STATE_PTR
	LD	(HL),UTX_SENDING
	CALL	TX_BUF			; HL = payload
	LD	C,(IX+UD_LEN)
	LD	B,(IX+UD_LEN+1)
	LD	(IX+UD_SRC),L
	LD	(IX+UD_SRC+1),H
	EX	DE,HL
	LD	HL,0
	CALL	CSUM_RAM		; the whole payload (an odd last byte is padded)
	LD	(IX+UD_SUM),L
	LD	(IX+UD_SUM+1),H
	SET	2,(IY+CX_WORK)
	ENDIF
.build
	IFDEF	UGB_RECORDS
	REC_ON
	JP	NZ,UDP_BUILD_REC	; (a copy: no record test on the plain path)
	ENDIF
	LD	(IX+UD_PREP),UDP_PREP_NONE
	LD	L,(IX+UD_LEN)
	LD	H,(IX+UD_LEN+1)
	LD	DE,UDP_HDR
	ADD	HL,DE
	PUSH	HL			; UDP length
	EX	DE,HL
	CALL	IP_FINISH
	POP	DE
	PUSH	DE
	TXH_IX
	LD	(IX+UDP_LEN),D
	LD	(IX+UDP_LEN+1),E
	XOR	A
	LD	(IX+UDP_CSUM),A
	LD	(IX+UDP_CSUM+1),A
	CALL	L4_SUM0
	POP	DE
	PUSH	DE
	CALL	CSUM_ADD_BE		; pseudo-header length
	POP	DE
	PUSH	DE
	CALL	CSUM_ADD_BE		; UDP length field
	PUSH	HL
	TP_IX
	LD	E,(IX+UD_SUM)
	LD	D,(IX+UD_SUM+1)
	POP	HL
	ADD	HL,DE
	CALL	CSUM_FOLD
	LD	A,H
	AND	L
	INC	A
	JR	NZ,.csum
	LD	HL,0			; sum FFFF -> checksum 0 is sent as FFFF
.csum
	PUSH	HL
	LD	DE,UCTX_TXH + UDP_CSUM - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,DE
	EX	DE,HL
	POP	HL
	CALL	CSUM_STORE
	POP	DE			; UDP length
	TP_IX
	LD	A,ETH_L4 + UDP_HDR
	LD	L,(IX+UD_SRC)
	LD	H,(IX+UD_SRC+1)
	LD	C,(IX+UD_LEN)
	LD	B,(IX+UD_LEN+1)
	CALL	TX_FRAME_SET
	OR	A
	RET

	IFDEF	UGB_RECORDS
; UDP_BUILD_REC (TP_TX_PULL .build with records): the same frame with the
; record header behind the UDP header -- UDP length + 2, the header summed,
; header bytes + 2.  IX = tp.  Out: CF=0.
UDP_BUILD_REC
	LD	(IX+UD_PREP),UDP_PREP_NONE
	LD	L,(IX+UD_LEN)
	LD	H,(IX+UD_LEN+1)
	LD	DE,UDP_HDR + REC_HDR
	ADD	HL,DE
	PUSH	HL			; UDP length
	EX	DE,HL
	CALL	IP_FINISH
	POP	DE
	PUSH	DE
	TXH_IX
	LD	(IX+UDP_LEN),D
	LD	(IX+UDP_LEN+1),E
	XOR	A
	LD	(IX+UDP_CSUM),A
	LD	(IX+UDP_CSUM+1),A
	CALL	L4_SUM0
	POP	DE
	PUSH	DE
	CALL	CSUM_ADD_BE		; pseudo-header length
	POP	DE
	PUSH	DE
	CALL	CSUM_ADD_BE		; UDP length field (keeps DE, IX = txh)
	; the record header of len = UDP length - 10 behind the UDP header,
	; summed (REC_B0 inline: this is the short path's send item)
	PUSH	HL
	EX	DE,HL
	LD	DE,-(UDP_HDR + REC_HDR)
	ADD	HL,DE
	EX	DE,HL			; DE = len (0..512)
	LD	A,E
	ADD	A,D
	ADD	A,0x2B
	AND	0x3F
	RLCA
	RLCA
	OR	D
	LD	D,A			; D = byte 0, E = byte 1
	LD	(IX+ETH_L4+UDP_HDR),D
	LD	(IX+ETH_L4+UDP_HDR+1),E
	POP	HL
	CALL	CSUM_ADD_BE
	PUSH	HL
	TP_IX
	LD	E,(IX+UD_SUM)
	LD	D,(IX+UD_SUM+1)
	POP	HL
	ADD	HL,DE
	CALL	CSUM_FOLD
	LD	A,H
	AND	L
	INC	A
	JR	NZ,.csum
	LD	HL,0			; sum FFFF -> checksum 0 is sent as FFFF
.csum
	PUSH	HL
	LD	DE,UCTX_TXH + UDP_CSUM - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,DE
	EX	DE,HL
	POP	HL
	CALL	CSUM_STORE
	POP	DE			; UDP length
	TP_IX
	LD	A,ETH_L4 + UDP_HDR + REC_HDR	; the record header is part of the frame header
	LD	L,(IX+UD_SRC)
	LD	H,(IX+UD_SRC+1)
	LD	C,(IX+UD_LEN)
	LD	B,(IX+UD_LEN+1)
	CALL	TX_FRAME_SET
	OR	A
	RET

; Record costs (UDP_BUILD_REC writes and sums the header inline; stand,
; pieces of 1..64 bytes): the header part of the pull is +11 us (+18
; through a helper with its own TP_IX: the short path's need base 278 of
; 275 at 732 units), the plain pull COST_REC_TX on top of COST_TP_PULL,
; the short path's COST_REC_FAST on top of its formula.  COST_REC_FAST 20
; put Headball's input behind the state on GUDP509B (game_load.js: 20 %
; skipped).  The mid receive takes no surcharge: the record adds 8..16
; us, and its formula still reserves 1.03..1.13 of the real time (586
; units of 661 for Headball's 88-byte state, 1441 us; 1.06..1.15 without
; records).  Any surcharge put that state on the generic path at 3000 us
; (two STEPs, the next input skipped): it fits with a few units to spare
; -- check game_load.js after a cost change on GUDP509B.
	IFDEF	UGB_SHORT
COST_REC_TX	EQU	30
	ELSE
COST_REC_TX	EQU	25
	ENDIF
COST_REC_FAST	EQU	15
	ASSERT	COST_TP_PULL + COST_REC_TX <= PROF_MAX_ITEM_US
	ENDIF

	IFDEF	UGB_SHORT
; UDP_FAST_FITS: the datagram to send next is committed, at most
; UDP_FAST_MAX bytes, and its short-path cost fits the units together
; with the entry check of the TX phase (ETH_MIN_ITEM: the pull must follow
; in this STEP).  Out: CF=0: DE = length, HL = the item's
; cost; CF=1: no.  Clobbers A, BC.
UDP_FAST_FITS
	LD	C,(IY+CX_TX_SEND)
	CALL	TX_STATE_PTR
	LD	A,(HL)
	CP	UTX_COMMITTED
	SCF
	RET	NZ
	CALL	TX_LEN_PTR
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	LD	HL,UDP_FAST_MAX
	OR	A
	SBC	HL,DE
	RET	C			; longer
	CALL	UDP_FAST_COST
	PUSH	HL
	LD	BC,ETH_MIN_ITEM
	ADD	HL,BC
	CALL	UNITS_FIT
	POP	HL			; HL = the item's cost (TP_TX_PULL takes it)
	RET
; UDP_FAST_COST: HL = COST_UDP_FAST + 3/2 of the length DE (<= UDP_FAST_MAX).
; Clobbers A.
UDP_FAST_COST
	LD	HL,COST_UDP_FAST
	IFDEF	UGB_RECORDS
	REC_ON
	JR	Z,.raw
	LD	HL,COST_UDP_FAST + COST_REC_FAST
.raw
	ENDIF
	ADD	HL,DE
	LD	A,E
	SRL	A			; length / 2 (<= 32)
	ADD	A,L
	LD	L,A
	RET	NC
	INC	H
	RET

; UDP_RX_FAST (short path, RX state ERX_HDR): a datagram of the open
; channel is verified in ctx.scratch and taken as one item -- published
; at once when its whole IPv4 packet is in scratch (payload <= 22), or,
; for a payload of up to UDP_MID_MAX bytes, accepted into its slot with
; the rest read from the card in the same item (UDP_RX_MID).  The cheap
; reads come first and take nothing; from the take on every check is made
; before anything is written: any doubt answers CF=1 and leaves the frame
; to the generic states, which decide and count the drop.
; Out: CF=0: an item (published: HS_RXS = ERX_DISCARD; a mid datagram
; whose card portion met a busy bus: ERX_COPY, the generic states go on).
; Clobbers A, BC, DE, HL, IX.
UDP_MID_MAX	EQU	96
; Cost of a mid datagram: COST_UDP_RX_MID + 2 per card byte, plus
; COST_UDP_RX_MIDP for every card portion after the first (stand, 3C509B,
; units, the item's own window with the verdict and publication: 391
; with 1 card byte, 419 with 18, 445 with 40, 551 with 41, 594 with 66,
; 597 with 74; tools/dev/profile_step.js --piece 23..96 --items).
COST_UDP_RX_MID	EQU	430
COST_UDP_RX_MIDP EQU	95
UDP_RX_FAST
	BIT	6,(IY+EX_RXLEN+1)
	SCF
	RET	NZ			; one try per frame
	LD	DE,UCTX_SCRATCH - CTX_BIAS
	PUSH	IY
	POP	IX
	ADD	IX,DE			; IX -> frame
	; not IPv4 (ARP, anything else): nothing is taken
	LD	A,(IX+ETH_TYPE)
	CP	0x08
	SCF
	RET	NZ
	LD	A,(IX+ETH_TYPE+1)
	OR	A
	SCF
	RET	NZ
	; a packet past scratch is UDP_RX_MID's: its cost is checked before
	; any work (the fast item's take, the checks and the refund were base
	; time of every STEP that could not afford it: need 277 against 270
	; at 812 units with 23-byte datagrams, or 22 with records).  Read
	; only: anything odd goes on to the fast item, which refunds it.
	LD	A,(IX+ETH_IP_LEN)
	OR	A
	JR	NZ,.take
	LD	A,(IX+ETH_IP_LEN+1)
	CP	IP_HDR + UDP_HDR + UDP_MID_MAX + 1
	JR	NC,.take
	ADD	A,ETH_HDR
	CP	RX_HDR_BYTES + 1
	JR	C,.take			; whole in scratch: the fast item
	LD	B,A
	CALL	UDP_MID_COST
	CALL	UNITS_FIT
	RET	C			; the generic states (tried again next STEP)
.take
	LD	HL,COST_UDP_RX_FAST
	CALL	SHORT_TAKE		; (keeps IX)
	RET	C
	SET	6,(IY+EX_RXLEN+1)
	; not a frame for these paths (anything but IPv4 without options,
	; UDP, a packet the short paths take, inside the frame): the units go
	; back
	LD	A,(IX+ETH_IP_VIHL)
	CP	0x45
	JR	NZ,.refund
	LD	A,(IX+ETH_IP_PROTO)
	CP	IP_PROTO_UDP
	JR	NZ,.refund
	LD	A,(IX+ETH_IP_LEN)
	OR	A
	JR	NZ,.refund
	LD	A,(IX+ETH_IP_LEN+1)
	CP	IP_HDR + UDP_HDR
	JR	C,.refund
	CP	IP_HDR + UDP_HDR + UDP_MID_MAX + 1
	JR	NC,.refund
	ADD	A,ETH_HDR
	LD	B,A			; frame bytes the packet needs
	LD	A,(IY+EX_RXLEN+1)
	AND	0x07
	JR	NZ,.inside
	LD	A,(IY+EX_RXLEN)
	CP	B
	JR	NC,.inside		; (else the frame is shorter than its packet)
.refund
	LD	HL,COST_UDP_RX_FAST
	CALL	UNITS_REFUND
	SCF
	RET
.inside
	LD	A,B
	CP	RX_HDR_BYTES + 1
	JP	NC,UDP_RX_MID
	CALL	UDP_RX_CHK		; C = UDP length, DE -> UDP header
	RET	C
	; UDP checksum (0: sent without one)
	LD	A,(IX+UDP_CSUM)
	OR	(IX+UDP_CSUM+1)
	JR	Z,.valid
	; addresses, protocol and ports are the channel's own: their sum is
	; the template's TPT_L4S0 (a sum does not care which side sent them);
	; the lengths and everything behind the ports are summed here
	PUSH	BC
	PUSH	DE
	CALL	L4_SUM0			; HL = TPT_L4S0
	POP	DE
	INC	DE
	INC	DE
	INC	DE
	INC	DE			; DE -> the UDP length field
	POP	BC
	PUSH	BC
	PUSH	DE
	LD	E,C
	LD	D,0
	CALL	CSUM_ADD_BE		; the pseudo header's length
	POP	DE
	LD	A,C
	SUB	4
	LD	C,A
	LD	B,0
	CALL	CSUM_RAM
	POP	BC
	LD	A,H
	AND	L
	INC	A
	SCF
	RET	NZ
.valid
	IFDEF	UGB_RECORDS
	CALL	UDP_REC_SCR		; records: a header that fills the datagram, else CF=1
	RET	C
	ENDIF
	PUSH	BC
	CALL	RXD_TAKE		; HL = slot buffer; a full ring: the generic states count it
	POP	BC
	RET	C
	; nothing fails from here: payload, publication
	EX	DE,HL			; DE = destination
	PUSH	IX
	POP	HL
	IFDEF	UGB_RECORDS
	REC_OFS
	LD	B,A			; the record header is skipped
	ADD	A,ETH_L4 + UDP_HDR
	ELSE
	LD	A,ETH_L4 + UDP_HDR
	ENDIF
	ADD	A,L
	LD	L,A
	JR	NC,.src
	INC	H
.src
	LD	A,C
	SUB	UDP_HDR
	IFDEF	UGB_RECORDS
	SUB	B
	ENDIF
	LD	C,A
	LD	B,0
	PUSH	BC
	JR	Z,.empty
	LDIR
.empty
	POP	BC
	PUSH	BC
	CALL	RXD_PUBLISH
	POP	DE
	STAT_ADD32 UNETG_STATS_RX_BYTES
	SET	1,(IY+CX_WORK)
	LD	(IY+EX_RXS),ERX_DISCARD
	OR	A
	RET

	IFDEF	UGB_RECORDS
; UDP_REC_SCR (short path, records): the record header in scratch must be
; the one of a record that fills the datagram; read only, a doubt answers
; CF=1 (the generic states decide and count the drop).  Without records
; CF=0 at once.  In: IX -> frame, C = UDP length (< 256).  Clobbers A
; (keeps DE: UDP_RX_MID's pointer to the UDP header for its sum).
UDP_REC_SCR
	REC_ON
	JR	NZ,.rec
	OR	A			; no records: CF=0
	RET
.rec
	LD	A,C
	SUB	UDP_HDR + REC_HDR
	RET	C			; shorter than a record header
	PUSH	DE
	LD	E,A
	LD	D,0
	CALL	REC_B0
	CP	(IX+ETH_L4 + UDP_HDR)
	JR	NZ,.bad
	LD	A,E
	CP	(IX+ETH_L4 + UDP_HDR + 1)
	JR	NZ,.bad
	POP	DE
	OR	A
	RET
.bad
	POP	DE
	SCF
	RET
	ENDIF

; UDP_MID_COST: HL = the cost of UDP_RX_MID for a packet of B frame
; bytes (65..138): COST_UDP_RX_MID + 2 per
; card byte + COST_UDP_RX_MIDP per card portion after the first.
; Clobbers A, DE.
UDP_MID_COST
	LD	A,B
	SUB	RX_HDR_BYTES		; card bytes (1..74)
	LD	L,A
	LD	H,0
	ADD	HL,HL			; 2 per card byte
	LD	DE,COST_UDP_RX_MIDP
.portions
	SUB	NIC_CHUNK_RX		; a further portion per NIC_CHUNK_RX bytes
	JR	C,.one
	JR	Z,.one
	ADD	HL,DE
	JR	.portions
.one
	LD	DE,COST_UDP_RX_MID
	ADD	HL,DE
	RET

; UDP_RX_CHK: the read-only checks of a datagram in scratch, paid for by
; the caller's item (a doubt answers CF=1: one try per frame).  In: IX ->
; frame.  Out: CF=0, C = UDP length, DE -> the UDP header, IX kept.
; Clobbers A, B, HL.
UDP_RX_CHK
	LD	A,(IX+ETH_IP_FRAG)
	AND	0x3F
	OR	(IX+ETH_IP_FRAG+1)
	SCF
	RET	NZ
	LD	A,(IX+UDP_LEN)
	OR	A
	SCF
	RET	NZ
	LD	A,(IX+ETH_IP_LEN+1)
	SUB	IP_HDR
	CP	(IX+UDP_LEN+1)
	SCF
	RET	NZ			; (a shorter UDP length: the generic states)
	LD	C,A			; C = UDP length
	; the channel is open: its header template (ctx.txh) holds both
	; addresses and both ports -- the frame carries them the other way
	; round
	TP_IX_HL
	LD	A,(HL)			; UD_ST
	CP	UDS_OPEN
	SCF
	RET	NZ
	PUSH	BC
	PUSH	IX
	POP	HL
	LD	DE,ETH_IP_SRC
	ADD	HL,DE
	EX	DE,HL			; DE -> the frame's source address
	LD	HL,UCTX_TXH + ETH_IP_DST - CTX_BIAS
	PUSH	IY
	POP	BC
	ADD	HL,BC			; HL -> the template's destination
	; (unrolled: every unit counts on this path)
	UDP_SAME4			; from the peer
	LD	BC,-8
	ADD	HL,BC
	UDP_SAME4			; to our address
	LD	BC,6
	ADD	HL,BC
	UDP_SAME2			; from the peer's port
	DEC	HL
	DEC	HL
	DEC	HL
	DEC	HL
	UDP_SAME2			; to our port
.other
	POP	BC
	SCF
	RET	NZ
	; IPv4 header checksum
	PUSH	BC
	PUSH	IX
	POP	HL
	LD	DE,ETH_IP
	ADD	HL,DE
	EX	DE,HL
	LD	HL,0
	LD	BC,IP_HDR
	CALL	CSUM_RAM		; DE -> the UDP header
	POP	BC
	LD	A,H
	AND	L
	INC	A
	SCF
	RET	NZ
	OR	A			; CF=0 (A = 0)
	RET

; UDP_RX_MID (from UDP_RX_FAST, COST_UDP_RX_FAST taken, B = frame bytes
; of the packet, 65..138):
; a datagram whose packet goes past scratch, payload 23..UDP_MID_MAX.  One
; item: the checks, the sum of its bytes in scratch, the slot (the accept
; of the generic path, TP_RX_ACCEPT: HS_RXDST / HS_RXLIM / UD_RXLEN) and
; card portions of the rest (RXP_COPY, NIC_CHUNK_RX bytes summed each)
; while the frame lasts; the verdict and publication (ETH_RX_VERDICT, the
; generic ERX_FINISH) end it.  A portion refused for the bus leaves
; ERX_COPY to the generic states.  Cost: see COST_UDP_RX_MID (taken only when it fits; the
; COST_UDP_RX_FAST reserve of the checks in front is given back first;
; when it does not fit the generic states take the frame).
UDP_RX_MID
	CALL	UDP_MID_COST
	; one item of its own: the fast path's reserve goes back first
	PUSH	HL
	LD	HL,COST_UDP_RX_FAST
	CALL	UNITS_REFUND
	POP	HL
	CALL	SHORT_TAKE		; (keeps IX)
	RET	C
.taken
	CALL	UDP_RX_CHK		; C = UDP length, DE -> UDP header
	RET	C
	IFDEF	UGB_RECORDS
	CALL	UDP_REC_SCR		; records: a header that fills the datagram, else CF=1
	RET	C
	ENDIF
	PUSH	BC
	PUSH	DE
	CALL	RXD_TAKE		; HL = slot buffer; a full ring: the generic states count it
	POP	DE
	POP	BC
	RET	C
	; nothing fails from here: the slot is filled, the frame goes on
	PUSH	HL			; [slot]
	LD	B,0
	PUSH	BC			; [slot][UDP length]
	; the sum: template's TPT_L4S0 (addresses, protocol, ports) + the
	; pseudo header's length + the UDP length field onwards in scratch
	LD	HL,0
	LD	A,(IX+UDP_CSUM)
	OR	(IX+UDP_CSUM+1)
	JR	Z,.nosum
	PUSH	DE
	CALL	L4_SUM0			; HL = TPT_L4S0
	POP	DE
	INC	DE
	INC	DE
	INC	DE
	INC	DE			; DE -> the UDP length field
	POP	BC
	PUSH	BC
	PUSH	DE
	LD	E,C
	LD	D,0
	CALL	CSUM_ADD_BE
	POP	DE
	LD	BC,L4_IN_SCRATCH - 4
	CALL	CSUM_RAM
.nosum
	POP	BC			; [slot] BC = UDP length
	EX	(SP),HL			; [sum] HL = slot
	; the payload bytes in scratch into the slot
	PUSH	BC
	EX	DE,HL			; DE = slot
	PUSH	IX
	POP	HL
	LD	BC,ETH_L4 + UDP_HDR
	ADD	HL,BC
	IFDEF	UGB_RECORDS
	REC_OFS				; the record header is skipped
	LD	C,A
	ADD	HL,BC			; (B = 0)
	NEG
	ADD	A,L4_IN_SCRATCH - UDP_HDR
	LD	C,A
	ELSE
	LD	BC,L4_IN_SCRATCH - UDP_HDR
	ENDIF
	LDIR				; DE -> the rest's place
	POP	BC			; BC = UDP length
	LD	A,(IX+UDP_CSUM)
	OR	(IX+UDP_CSUM+1)
	LD	B,1			; checksum 0: sent without one
	JR	Z,.nochk
	DEC	B
.nochk
	HWSM_IX
	POP	HL			; sum
	LD	(IX+HS_SUM),L
	LD	(IX+HS_SUM+1),H
	XOR	A
	LD	(IX+HS_PAR),A		; the card part starts on an even offset
	LD	(IX+HS_RXSKIP),A
	LD	(IX+HS_RXSKIP+1),A
	LD	(IX+HS_RXLIM+1),A
	LD	(IX+HS_RXREM+1),A
	LD	(IX+HS_RXDST),E
	LD	(IX+HS_RXDST+1),D
	DEC	A
	LD	(IX+HS_RXSPAN),A	; no wrap inside a datagram slot
	LD	(IX+HS_RXSPAN+1),A
	LD	(IX+HS_NOCHK),B
	LD	A,C
	SUB	L4_IN_SCRATCH
	LD	(IX+HS_RXLIM),A		; card bytes, all of them payload
	LD	(IX+HS_RXREM),A
	LD	(IX+HS_RXS),ERX_COPY
	; the transport's record of the stored datagram (TP_RX_COMMIT)
	IFDEF	UGB_RECORDS
	REC_OFS
	ADD	A,UDP_HDR
	LD	E,A
	LD	A,C
	SUB	E
	ELSE
	LD	A,C
	SUB	UDP_HDR
	ENDIF
	LD	E,A			; payload
	TP_IX_HL
	LD	BC,UD_RXLEN
	ADD	HL,BC
	LD	(HL),E
	INC	HL
	LD	(HL),0
	INC	HL
	LD	(HL),1			; UD_RXSTORE
	IFDEF	UGB_RECORDS
	; the header UDP_REC_SCR checked, for TP_RX_COMMIT's verdict
	INC	HL
	INC	HL			; UD_REC
	ASSERT	UD_REC == UD_RXSTORE + 2 && UD_RXSTORE == UD_RXLEN + 2
	EX	DE,HL			; (IX is the hwsm here: the header from scratch)
	LD	HL,UCTX_SCRATCH + ETH_L4 + UDP_HDR - CTX_BIAS
	PUSH	IY
	POP	BC
	ADD	HL,BC
	LDI
	LDI
	ENDIF
	; the card portions of the rest, then the verdict and publication
.portion
	LD	HL,RXP_COPY
	CALL	RUN_PORTION
	JR	C,.left			; the bus: the generic ERX_COPY goes on
	SET	2,(IY+CX_WORK)
	LD	A,(IY+EX_RXS)
	CP	ERX_COPY
	JR	Z,.portion
	CALL	ETH_RX_VERDICT		; ERX_FINISH -> ERX_DISCARD
.left
	OR	A
	RET
	ENDIF

; TP_TX_DONE: A = 1 sent, 0 failed.  One datagram = one slot.
TP_TX_DONE
	LD	B,UTX_DONE_OK
	OR	A
	JR	NZ,.outcome
	LD	B,UTX_DONE_FAILED
.outcome
	PUSH	BC
	LD	C,(IY+CX_TX_SEND)
	CALL	TX_STATE_PTR
	POP	BC
	LD	A,(HL)
	CP	UTX_SENDING
	RET	NZ			; cancelled meanwhile (ABORT): outcome kept
	LD	A,B
	TX_SET_DONE
	PUSH	BC
	LD	C,(IY+CX_TX_SEND)
	CALL	TX_LEN_PTR
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	POP	BC
	LD	A,B
	CP	UTX_DONE_OK
	JR	NZ,.next
	STAT_ADD32 UNETG_STATS_TX_BYTES
.next
	LD	A,(IY+CX_TX_SEND)
	SLOT_INC CX_TX_SLOT_COUNT
	LD	(IY+CX_TX_SEND),A
	RET

; ----------------------------------------------------------------------
; TP_RX_ACCEPT: A = protocol, BC = IP payload length, IX -> frame.
; ----------------------------------------------------------------------
TP_RX_ACCEPT
	CP	IP_PROTO_UDP
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
	LD	A,(IX+UDP_SPORT)
	CP	(IY+CX_PEER_PORT+1)
	JP	NZ,.foreign
	LD	A,(IX+UDP_SPORT+1)
	CP	(IY+CX_PEER_PORT)
	JP	NZ,.foreign
	PUSH	BC
	TP_IX_HL
	POP	BC
	LD	A,(HL)			; UD_ST
	CP	UDS_OPEN
	JP	NZ,.foreign
	INC	HL
	INC	HL			; UD_LPORT
	LD	A,(IX+UDP_DPORT+1)
	CP	(HL)
	JP	NZ,.foreign
	INC	HL
	LD	A,(IX+UDP_DPORT)
	CP	(HL)
	JP	NZ,.foreign
	; UDP length within the IP payload, payload <= 512
	LD	H,(IX+UDP_LEN)
	LD	L,(IX+UDP_LEN+1)
	PUSH	HL
	SCF
	SBC	HL,BC			; ulen - iplen - 1 >= 0: longer than the datagram
	POP	BC			; BC = UDP length
	JP	NC,.size
	LD	H,B
	LD	L,C
	LD	DE,UDP_HDR
	OR	A
	SBC	HL,DE
	JP	C,.size
	IFDEF	UGB_RECORDS
	; records: the datagram is a header and the application's payload;
	; the header is kept for TP_RX_COMMIT's verdict
	REC_ON
	JR	Z,.raw
	LD	DE,REC_HDR
	SBC	HL,DE			; (CF=0 from the SBC above)
	JP	C,.size			; shorter than a record header
	PUSH	HL
	TP_IX_HL
	LD	DE,UD_REC
	ADD	HL,DE
	LD	A,(IX+ETH_L4 + UDP_HDR)
	LD	(HL),A
	INC	HL
	LD	A,(IX+ETH_L4 + UDP_HDR + 1)
	LD	(HL),A
	POP	HL
.raw
	ENDIF
	LD	DE,UNETG_UDP_MAX + 1
	PUSH	HL
	OR	A
	SBC	HL,DE
	POP	DE			; DE = payload
	JP	NC,.size		; too long: dropped whole
	PUSH	DE
	PUSH	BC
	CALL	RXD_TAKE		; HL = slot buffer
	POP	BC
	POP	DE
	JR	C,.full
	PUSH	HL			; destination
	PUSH	DE			; payload
	LD	A,IP_PROTO_UDP
	CALL	ETH_SEG_START		; DE = segment bytes in scratch
	; checksum 0: transmitted without one
	LD	A,(IX+UDP_CSUM)
	OR	(IX+UDP_CSUM+1)
	JR	NZ,.checked
	LD	A,HS_NOCHK
	CALL	HS_FIELD
	LD	(HL),1
.checked
	POP	BC			; payload
	POP	HL			; destination
	PUSH	BC
	; payload bytes already in scratch: in scratch - 8 (records: - 10)
	EX	DE,HL
	PUSH	DE
	IFDEF	UGB_RECORDS
	REC_OFS
	ADD	A,UDP_HDR
	LD	E,A
	LD	D,0
	ELSE
	LD	DE,UDP_HDR
	ENDIF
	OR	A
	SBC	HL,DE
	POP	DE			; DE = destination
	LD	B,H
	LD	C,L			; BC = payload in scratch
	PUSH	BC
	PUSH	IX
	POP	HL
	IFDEF	UGB_RECORDS
	REC_OFS
	ADD	A,ETH_L4 + UDP_HDR
	ELSE
	LD	A,ETH_L4 + UDP_HDR
	ENDIF
	ADD	A,L
	LD	L,A
	JR	NC,.src
	INC	H
.src
	LD	A,B
	OR	C
	JR	Z,.none_here
	LDIR
.none_here
	POP	BC			; payload in scratch
	POP	HL			; payload
	PUSH	HL
	OR	A
	SBC	HL,BC			; payload on the card
	PUSH	HL
	LD	A,HS_RXDST
	CALL	HS_FIELD
	LD	(HL),E
	INC	HL
	LD	(HL),D
	INC	HL
	LD	(HL),0xFF		; no wrap inside a datagram slot
	INC	HL
	LD	(HL),0xFF
	POP	DE
	LD	A,HS_RXLIM
	CALL	HS_FIELD
	LD	(HL),E
	INC	HL
	LD	(HL),D
	POP	DE			; payload
	TP_IX_HL
	LD	BC,UD_RXLEN
	ADD	HL,BC
	LD	(HL),E
	INC	HL
	LD	(HL),D
	INC	HL
	LD	(HL),1			; UD_RXSTORE
	OR	A
	RET
.full
	STAT_INC UNETG_STATS_RING_OVERFLOW
	SCF
	RET
.foreign
	STAT_INC UNETG_STATS_DROP_FOREIGN
	SCF
	RET
.size
	STAT_INC UNETG_STATS_DROP_SIZE
	SCF
	RET

; TP_RX_STORE: UDP places its payload during the accept itself.
TP_RX_STORE
	RET

; TP_RX_COMMIT: A = 1 valid.  Publishes or abandons the filled slot.
; TP_RX_ACK: no acknowledgements in UDP (ERX_TCPACK is never entered).
COST_TP_ACK	EQU	COST_PORTION
TP_RX_ACK
	RET

TP_RX_COMMIT
	PUSH	AF
	TP_IX
	POP	AF
	LD	B,(IX+UD_RXSTORE)
	LD	(IX+UD_RXSTORE),0
	DEC	B
	RET	NZ			; nothing was stored
	LD	B,A
	LD	A,(IX+UD_ST)
	CP	UDS_OPEN
	JR	NZ,.drop		; the channel went away meanwhile
	LD	A,B
	OR	A
	JR	Z,.drop
	LD	C,(IX+UD_RXLEN)
	LD	B,(IX+UD_RXLEN+1)
	IFDEF	UGB_RECORDS
	; records: the header must be the one of a record that fills the
	; datagram (a valid header of another length is no better)
	REC_ON
	JR	Z,.rec_ok
	LD	A,C
	CP	(IX+UD_REC+1)
	JR	NZ,.rec_bad
	LD	E,C
	LD	D,B
	CALL	REC_B0
	CP	(IX+UD_REC)
	JR	NZ,.rec_bad
.rec_ok
	ENDIF
	PUSH	BC
	CALL	RXD_PUBLISH
	POP	DE
	STAT_ADD32 UNETG_STATS_RX_BYTES
	SET	1,(IY+CX_WORK)
	RET
.drop
	JP	RXD_DROP
	IFDEF	UGB_RECORDS
.rec_bad
	STAT_INC UNETG_STATS_DROP_CHECKSUM
	JP	RXD_DROP
	ENDIF
