; ip.asm -- header template of the transport's outgoing frames (ctx.txh).
;
; The Ethernet + IPv4 header and both ports are built once per connection
; (IP_TEMPLATE) together with two partial sums: the IPv4 header with
; length 0 and checksum 0 (TPT_IPS0) and the pseudo-header addresses +
; protocol + ports (TPT_L4S0).  Each frame then only writes its length and
; derives the IPv4 checksum incrementally (IP_FINISH); the transport adds
; its variable header words and the payload sum to TPT_L4S0.
; DF is set and the identification is 0 (atomic datagrams, RFC 6864).

	MACRO	TXH_IX
	PUSH	DE			; preserves DE
	LD	DE,UCTX_TXH - CTX_BIAS
	PUSH	IY
	POP	IX
	ADD	IX,DE
	POP	DE
	ENDM

; IP_TEMPLATE: A = protocol.  Builds ctx.txh[0..37] towards the configured
; peer through the cached next hop, the local port taken from tp+2 (same
; offset for TCP and UDP).  Clobbers A, BC, DE, HL, IX.
IP_TEMPLATE
	PUSH	AF
	TXH_IX
	PUSH	IX
	POP	DE
	LD	HL,UCTX_ARP + AR_MAC - CTX_BIAS
	PUSH	DE
	PUSH	IY
	POP	DE
	ADD	HL,DE
	POP	DE
	LD	BC,6
	LDIR				; destination: next-hop MAC
	CALL	TXH_OUR_MAC
	LD	HL,IP_FIXED
	LD	BC,IP_FIXED_LEN
	LDIR				; type 0800, 45 00, length 0, id 0, DF, TTL 64
	POP	AF
	LD	(DE),A			; protocol
	INC	DE
	XOR	A
	LD	(DE),A			; checksum 0
	INC	DE
	LD	(DE),A
	INC	DE
	LD	HL,CX_LOCAL_IP
	CALL	.ctx_copy4		; source
	LD	HL,CX_PEER_IP
	CALL	.ctx_copy4		; destination
	LD	HL,UCTX_TP + 3 - CTX_BIAS
	CALL	.ctx_hl
	LD	A,(HL)			; local port, network order
	LD	(DE),A
	INC	DE
	DEC	HL
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	LD	A,(IY+CX_PEER_PORT+1)
	LD	(DE),A
	INC	DE
	LD	A,(IY+CX_PEER_PORT)
	LD	(DE),A
	; TPT_IPS0: the 20-byte IPv4 header as it stands
	PUSH	IX
	POP	HL
	LD	DE,ETH_IP
	ADD	HL,DE
	EX	DE,HL
	LD	HL,0
	LD	BC,IP_HDR
	CALL	CSUM_RAM
	PUSH	HL
	LD	HL,UCTX_TP + TPT_IPS0 - CTX_BIAS
	CALL	.ctx_hl
	POP	DE
	LD	(HL),E
	INC	HL
	LD	(HL),D
	; TPT_L4S0: addresses + ports (12 bytes from offset 26) + protocol
	PUSH	IX
	POP	HL
	LD	DE,ETH_IP_SRC
	ADD	HL,DE
	EX	DE,HL
	LD	HL,0
	LD	BC,12
	CALL	CSUM_RAM
	LD	E,(IX+ETH_IP_PROTO)
	LD	D,0
	CALL	CSUM_ADD_BE
	PUSH	HL
	LD	HL,UCTX_TP + TPT_L4S0 - CTX_BIAS
	CALL	.ctx_hl
	POP	DE
	LD	(HL),E
	INC	HL
	LD	(HL),D
	RET
.ctx_copy4				; copy 4 context bytes at CX offset HL to DE
	CALL	.ctx_hl
	LD	BC,4
	LDIR
	RET
.ctx_hl					; HL = IY + HL.  Preserves DE.
	PUSH	DE
	PUSH	IY
	POP	DE
	ADD	HL,DE
	POP	DE
	RET

IP_FIXED
	DB	0x08, 0x00, 0x45, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 64
IP_FIXED_LEN	EQU	11

; IP_FINISH: DE = transport length.  Writes the IPv4 total length and the
; checksum derived from TPT_IPS0.  Clobbers A, BC, DE, HL.
IP_FINISH
	LD	HL,IP_HDR
	ADD	HL,DE
	EX	DE,HL			; DE = total length
	LD	HL,UCTX_TXH + ETH_IP_LEN - CTX_BIAS
	PUSH	IY
	POP	BC
	ADD	HL,BC
	LD	(HL),D
	INC	HL
	LD	(HL),E
	LD	HL,UCTX_TP + TPT_IPS0 - CTX_BIAS
	ADD	HL,BC
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A
	CALL	CSUM_ADD_BE
	LD	DE,UCTX_TXH + ETH_IP_CSUM - CTX_BIAS
	PUSH	HL
	PUSH	IY
	POP	HL
	ADD	HL,DE
	EX	DE,HL
	POP	HL
	JP	CSUM_STORE

; L4_SUM0: HL = TPT_L4S0.  Clobbers DE.
L4_SUM0
	LD	DE,UCTX_TP + TPT_L4S0 - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,DE
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	EX	DE,HL
	RET

; TX_FRAME_SET: the transport frame in ctx.txh is ready: A = header bytes,
; HL = payload source, BC = payload length.
TX_FRAME_SET
	PUSH	HL
	PUSH	BC
	LD	DE,UCTX_HWSM - CTX_BIAS
	PUSH	IY
	POP	IX
	ADD	IX,DE
	LD	(IX+HS_TXHDR),A
	POP	BC
	LD	(IX+HS_TXREM),C
	LD	(IX+HS_TXREM+1),B
	LD	L,A
	LD	H,0
	ADD	HL,BC
	LD	(IX+HS_TXLEN),L
	LD	(IX+HS_TXLEN+1),H
	POP	HL
	LD	(IX+HS_TXSRC),L
	LD	(IX+HS_TXSRC+1),H
	PUSH	IY
	POP	HL
	LD	DE,UCTX_TXH - CTX_BIAS
	ADD	HL,DE
	LD	(IX+HS_TXHSRC),L
	LD	(IX+HS_TXHSRC+1),H
	RET
