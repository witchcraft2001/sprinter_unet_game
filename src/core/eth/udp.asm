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
UD_SIZE		EQU	18

UDS_CLOSED	EQU	0
UDS_ARP		EQU	1
UDS_OPEN	EQU	2

UDP_PREP_NONE	EQU	0
UDP_PREP_SUM	EQU	1
UDP_PREP_READY	EQU	2
UDP_SUM_CHUNK	EQU	128
COST_UDP_STEP	EQU	170
COST_UDP_IDLE	EQU	80
COST_TEMPLATE	EQU	170	; IP_TEMPLATE (stand: 151 us)

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
	LD	A,(IX+UD_ST)
	OR	A
	RET	Z
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
	LD	HL,COST_UDP_IDLE
	CALL	TAKE
	RET	C
	TP_IX
	LD	A,(IX+UD_ST)
	CP	UDS_OPEN
	RET	NZ
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
	LD	HL,80			; summing portion overhead (stand: 201 us / 128 B)
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
	CP	UDP_PREP_READY
	SCF
	RET	NZ
	LD	HL,COST_TP_PULL
	CALL	TAKE
	RET	C
	TP_IX
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
	; payload bytes already in scratch: in scratch - 8
	EX	DE,HL
	PUSH	DE
	LD	DE,UDP_HDR
	OR	A
	SBC	HL,DE
	POP	DE			; DE = destination
	LD	B,H
	LD	C,L			; BC = payload in scratch
	PUSH	BC
	PUSH	IX
	POP	HL
	LD	A,ETH_L4 + UDP_HDR
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
	PUSH	BC
	CALL	RXD_PUBLISH
	POP	DE
	STAT_ADD32 UNETG_STATS_RX_BYTES
	SET	1,(IY+CX_WORK)
	RET
.drop
	JP	RXD_DROP
