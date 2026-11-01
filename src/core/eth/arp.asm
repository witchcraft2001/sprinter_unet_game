; arp.asm -- ARP responder, next-hop cache and resolution schedule.
; The responder runs in every channel state (ТЗ §2).  One cache entry: the
; next hop of the configured peer (the peer itself inside the subnet,
; otherwise the gateway).  Requests repeat on the retry_wait_ms schedule,
; never faster than once per second; a valid entry is refreshed before it
; expires and resolved again when it does.

	MACRO	ARP_IX
	PUSH	DE			; preserves DE
	LD	DE,UCTX_ARP - CTX_BIAS
	PUSH	IY
	POP	IX
	ADD	IX,DE
	POP	DE
	ENDM

; ARP_INPUT: IX -> received frame (scratch).  Learns the next hop, queues a
; reply to a request for our address.  Clobbers A, BC, DE, HL, IX.
ARP_INPUT
	LD	A,(IX+ARP_HTYPE)
	OR	A
	RET	NZ
	LD	A,(IX+ARP_HTYPE+1)
	DEC	A
	RET	NZ
	LD	A,(IX+ARP_PTYPE)
	CP	0x08
	RET	NZ
	LD	A,(IX+ARP_PTYPE+1)
	OR	A
	RET	NZ
	PUSH	IX
	POP	HL			; HL -> frame
	; learn: sender address == cached next hop
	LD	DE,UCTX_ARP + AR_IP - CTX_BIAS
	PUSH	HL
	LD	BC,ARP_SPA
	ADD	HL,BC
	CALL	IP_EQ_CTX		; Z when equal
	POP	HL
	JR	NZ,.request
	LD	DE,UCTX_ARP + AR_STATE - CTX_BIAS
	CALL	IY_PTR_DE_HL		; HL -> AR_STATE (frame pointer in DE)
	LD	A,(HL)
	OR	A
	JR	Z,.request_hl
	LD	(HL),ARS_VALID
	PUSH	DE
	LD	BC,AR_MAC
	ADD	HL,BC
	EX	DE,HL			; DE -> AR_MAC, HL -> frame
	PUSH	HL
	LD	BC,ARP_SHA
	ADD	HL,BC
	LD	BC,6
	LDIR
	POP	HL
	POP	DE
	PUSH	DE
	CALL	ARP_SET_TIMES
	POP	DE
.request_hl
	EX	DE,HL			; HL -> frame
.request
	; a request for our address?
	PUSH	HL
	POP	IX
	LD	A,(IX+ARP_OP)
	OR	A
	RET	NZ
	LD	A,(IX+ARP_OP+1)
	DEC	A
	RET	NZ
	PUSH	HL
	LD	BC,ARP_TPA
	ADD	HL,BC
	LD	DE,CX_LOCAL_IP
	CALL	IP_EQ_CTX
	POP	HL
	RET	NZ
	; remember the requester: SPA then SHA
	PUSH	HL
	LD	DE,UCTX_ARP + AR_RQ_IP - CTX_BIAS
	CALL	IY_PTR
	EX	DE,HL
	POP	HL
	PUSH	HL
	LD	BC,ARP_SPA
	ADD	HL,BC
	LD	BC,4
	LDIR				; AR_RQ_IP, DE -> AR_RQ_MAC
	POP	HL
	LD	BC,ARP_SHA
	ADD	HL,BC
	LD	BC,6
	LDIR
	ARP_IX
	SET	0,(IX+AR_FLAGS)		; ARF_REPLY
	RET

; IY_PTR_DE_HL: DE = HL (frame), HL = IY + DE (old DE).
IY_PTR_DE_HL
	EX	DE,HL
	PUSH	DE
	PUSH	IY
	POP	DE
	ADD	HL,DE
	POP	DE
	RET

; IP_EQ_CTX: Z when the 4 bytes at HL equal IY + DE (CX offset or
; absolute UCTX - bias).  Clobbers A, B, DE, HL.
IP_EQ_CTX
	EX	DE,HL
	PUSH	DE
	PUSH	IY
	POP	DE
	ADD	HL,DE			; HL -> context address
	POP	DE			; DE -> frame bytes
	LD	B,4
.cmp
	LD	A,(DE)
	CP	(HL)
	RET	NZ
	INC	DE
	INC	HL
	DJNZ	.cmp
	RET

; ARP_SET_TIMES: entry expiry = now + ttl, refresh = now + ttl * 3/4.
ARP_SET_TIMES
	ARP_IX
	LD	E,(IY+CX_ARP_TTL_MS)
	LD	D,(IY+CX_ARP_TTL_MS+1)
	PUSH	DE
	PUSH	IX
	POP	HL
	LD	BC,AR_TTL
	ADD	HL,BC
	CALL	DL_SET
	POP	DE
	LD	H,D
	LD	L,E
	SRL	H
	RR	L
	SRL	H
	RR	L			; ttl / 4
	EX	DE,HL
	OR	A
	SBC	HL,DE			; ttl * 3/4
	EX	DE,HL
	PUSH	IX
	POP	HL
	LD	BC,AR_DL
	ADD	HL,BC
	LD	(IX+AR_TRY),0
	JP	DL_SET

; ----------------------------------------------------------------------
; ARP_RESOLVE: start resolving the next hop of the configured peer.
; ----------------------------------------------------------------------
ARP_RESOLVE
	CALL	ARP_SAME_NET		; Z: the peer is on-link
	LD	DE,CX_PEER_IP
	JR	Z,.hop
	LD	A,(IY+CX_GATEWAY_IP)
	OR	(IY+CX_GATEWAY_IP+1)
	OR	(IY+CX_GATEWAY_IP+2)
	OR	(IY+CX_GATEWAY_IP+3)
	JR	Z,.hop			; no gateway: try the peer directly
	LD	DE,CX_GATEWAY_IP
.hop
	CALL	IY_PTR			; HL -> next-hop address
	ARP_IX
	PUSH	IX
	POP	DE
	INC	DE			; DE -> AR_IP
	LD	BC,4
	LDIR
	LD	(IX+AR_STATE),ARS_RESOLVING
	LD	(IX+AR_TRY),0
	LD	A,(IX+AR_FLAGS)
	AND	~ARF_FAILED & 0xFF
	OR	ARF_REQUEST		; first request at the first portion
	LD	(IX+AR_FLAGS),A
	STAT_INC UNETG_STATS_ARP_REQUESTS
	ARP_IX
	LD	E,(IY+CX_RETRY_WAIT_MS)
	LD	D,(IY+CX_RETRY_WAIT_MS+1)
	JP	ARP_ARM_RETRY

; ARP_SAME_NET: Z when (peer ^ local) & mask == 0.  Clobbers A, B, DE, HL.
ARP_SAME_NET
	LD	B,4
	LD	DE,0
.loop
	PUSH	BC
	LD	HL,CX_PEER_IP
	ADD	HL,DE
	PUSH	IY
	POP	BC
	ADD	HL,BC
	LD	A,(HL)
	LD	HL,CX_LOCAL_IP
	ADD	HL,DE
	ADD	HL,BC
	XOR	(HL)
	LD	HL,CX_NETMASK
	ADD	HL,DE
	ADD	HL,BC
	AND	(HL)
	POP	BC
	RET	NZ
	INC	DE
	DJNZ	.loop
	RET

; ARP_ARM_RETRY: AR_DL = now + max(DE, 1000 ms).  IX = arp.
ARP_ARM_RETRY
	LD	HL,ARP_MIN_RETRY_MS - 1
	OR	A
	SBC	HL,DE
	JR	C,.ok
	LD	DE,ARP_MIN_RETRY_MS
.ok
	PUSH	IX
	POP	HL
	LD	BC,AR_DL
	ADD	HL,BC
	JP	DL_SET

; ARP_TIMERS: retries, refresh and expiry (from the transport's TP_STEP).
; Out: Z when the next hop is resolved (ARS_VALID).
ARP_TIMERS
	ARP_IX
	LD	A,(IX+AR_STATE)
	CP	ARS_RESOLVING
	JR	Z,.resolving
	CP	ARS_VALID
	RET	NZ
	PUSH	IX
	POP	HL
	LD	BC,AR_TTL
	ADD	HL,BC
	CALL	DL_LEFT
	JR	NC,.alive
	; expired: resolve again
	ARP_IX
	LD	(IX+AR_STATE),ARS_RESOLVING
	LD	(IX+AR_TRY),0
	SET	1,(IX+AR_FLAGS)
	LD	E,(IY+CX_RETRY_WAIT_MS)
	LD	D,(IY+CX_RETRY_WAIT_MS+1)
	CALL	ARP_ARM_RETRY
	OR	1			; NZ: not usable now
	RET
.alive
	ARP_IX
	PUSH	IX
	POP	HL
	LD	BC,AR_DL
	ADD	HL,BC
	CALL	DL_LEFT
	JR	NC,.valid
	; refresh before expiry; the entry stays usable meanwhile
	ARP_IX
	SET	1,(IX+AR_FLAGS)
	LD	DE,ARP_MIN_RETRY_MS
	CALL	ARP_ARM_RETRY
.valid
	XOR	A			; Z
	RET
.resolving
	BIT	2,(IX+AR_FLAGS)		; ARF_FAILED: no more requests, but a late
	JR	NZ,.waiting		; reply is still learned until the deadline
	PUSH	IX
	POP	HL
	LD	BC,AR_DL
	ADD	HL,BC
	CALL	DL_LEFT
	JR	NC,.waiting
	ARP_IX
	LD	A,(IX+AR_TRY)
	INC	A
	CP	(IY+CX_RETRY_COUNT)
	JR	Z,.again
	JR	C,.again
	; schedule exhausted: the OPEN deadline (or the transport) decides
	SET	2,(IX+AR_FLAGS)		; ARF_FAILED
	OR	1
	RET
.again
	LD	(IX+AR_TRY),A
	SET	1,(IX+AR_FLAGS)
	STAT_INC UNETG_STATS_ARP_REQUESTS
	ARP_IX
	LD	A,(IX+AR_TRY)
	ADD	A,A
	LD	C,A
	LD	B,0
	LD	HL,CX_RETRY_WAIT_MS
	ADD	HL,BC
	PUSH	IY
	POP	BC
	ADD	HL,BC
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	CALL	ARP_ARM_RETRY
.waiting
	OR	1			; NZ
	RET

; ARP_DEADLINES: fold the ARP timer into dl_next.
ARP_DEADLINES
	ARP_IX
	LD	A,(IX+AR_STATE)
	OR	A
	RET	Z
	BIT	2,(IX+AR_FLAGS)
	RET	NZ
	PUSH	IX
	POP	HL
	LD	BC,AR_DL
	ADD	HL,BC
	JP	DL_MERGE

; ----------------------------------------------------------------------
; ARP_TX_PULL: build a pending ARP reply or request in ctx.txh.
; Out: CF=1 nothing to send; CF=0 frame ready (HS_TXLEN/HDR/REM set).
; ----------------------------------------------------------------------
ARP_TX_PULL
	ARP_IX
	LD	A,(IX+AR_FLAGS)
	AND	ARF_REPLY | ARF_REQUEST
	SCF
	RET	Z
	LD	HL,COST_ARP_PULL
	CALL	TAKE
	RET	C			; stays pending for the next STEP
	ARP_IX
	BIT	0,(IX+AR_FLAGS)
	JR	Z,.request
	RES	0,(IX+AR_FLAGS)
	; reply: target = requester
	PUSH	IX
	POP	HL
	LD	BC,AR_RQ_MAC
	ADD	HL,BC
	PUSH	HL			; -> requester MAC
	LD	BC,AR_RQ_IP - AR_RQ_MAC
	ADD	HL,BC
	PUSH	HL			; -> requester IP
	LD	A,2			; reply
	JR	.build
.request
	RES	1,(IX+AR_FLAGS)
	LD	HL,ARP_BCAST
	PUSH	HL			; target MAC: broadcast (tha = 0 below)
	PUSH	IX
	POP	HL
	INC	HL			; AR_IP
	PUSH	HL
	LD	A,1
.build
	; txh: eth dst, src, type, ARP fixed part
	PUSH	AF
	LD	DE,UCTX_ARPTX - CTX_BIAS
	PUSH	IY
	POP	IX
	ADD	IX,DE			; IX -> ARP frame buffer
	POP	AF
	POP	DE			; DE -> target IP
	POP	HL			; HL -> target MAC (eth destination)
	PUSH	DE
	PUSH	AF
	PUSH	HL
	PUSH	IX
	POP	DE
	LD	BC,6
	LDIR				; eth dst
	CALL	TXH_OUR_MAC		; eth src at DE
	LD	HL,ARP_FIXED
	LD	BC,ARP_FIXED_LEN
	LDIR				; type .. hlen/plen
	POP	HL			; target MAC
	POP	AF
	LD	(IX+ARP_OP),0
	LD	(IX+ARP_OP+1),A
	PUSH	AF
	PUSH	HL
	PUSH	IX
	POP	HL
	LD	DE,ARP_SHA
	ADD	HL,DE
	EX	DE,HL
	CALL	TXH_OUR_MAC		; sha
	LD	HL,CX_LOCAL_IP
	PUSH	DE
	PUSH	IY
	POP	DE
	ADD	HL,DE
	POP	DE
	LD	BC,4
	LDIR				; spa
	POP	HL			; target MAC
	POP	AF
	CP	1
	JR	NZ,.tha
	LD	HL,ARP_ZERO		; a request asks for an unknown MAC
.tha
	LD	BC,6
	LDIR
	POP	HL			; target IP
	LD	BC,4
	LDIR
	; frame: 42 bytes, the card pads to 60
	LD	DE,UCTX_HWSM - CTX_BIAS
	PUSH	IY
	POP	IX
	ADD	IX,DE
	LD	(IX+HS_TXLEN),ARP_FRAME
	LD	(IX+HS_TXLEN+1),0
	LD	(IX+HS_TXHDR),ARP_FRAME
	LD	(IX+HS_TXREM),ARP_FRAME	; header + payload still to write
	LD	(IX+HS_TXREM+1),0
	PUSH	IY
	POP	HL
	LD	DE,UCTX_ARPTX - CTX_BIAS
	ADD	HL,DE
	LD	(IX+HS_TXHSRC),L
	LD	(IX+HS_TXHSRC+1),H
	XOR	A
	RET				; CF=0

; TXH_OUR_MAC: copy the station address to DE.  Clobbers BC, HL.
TXH_OUR_MAC
	LD	HL,UCTX_HWSM + HS_MAC - CTX_BIAS
	PUSH	DE
	PUSH	IY
	POP	DE
	ADD	HL,DE
	POP	DE
	LD	BC,6
	LDIR
	RET

ARP_BCAST
	DB	0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
ARP_ZERO
	DB	0, 0, 0, 0, 0, 0
ARP_FIXED
	DB	0x08, 0x06, 0x00, 0x01, 0x08, 0x00, 6, 4
ARP_FIXED_LEN	EQU	8
