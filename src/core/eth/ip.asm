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
	PUSH	AF			; protocol
	PUSH	IY
	POP	HL
	LD	DE,UCTX_TXH - CTX_BIAS
	ADD	HL,DE
	EX	DE,HL			; DE -> ctx.txh (moves along the frame)
	LD	HL,UCTX_ARP + AR_MAC - UCTX_TXH
	ADD	HL,DE
	LD	BC,6
	LDIR				; destination: next-hop MAC
	LD	HL,UCTX_HWSM + HS_MAC - UCTX_TXH - 6
	ADD	HL,DE
	LD	C,6
	LDIR				; source: the station address
	LD	HL,IP_FIXED
	LD	C,IP_FIXED_LEN
	LDIR				; type 0800, 45 00, length 0, id 0, DF, TTL 64
	POP	AF
	PUSH	AF
	LD	(DE),A			; protocol
	INC	DE
	XOR	A
	LD	(DE),A			; checksum 0
	INC	DE
	LD	(DE),A
	INC	DE			; DE -> ETH_IP_SRC
	LD	HL,UCTX_LOCAL_IP - UCTX_TXH - ETH_IP_SRC
	ADD	HL,DE
	LD	C,4
	LDIR				; source
	LD	HL,UCTX_PEER_IP - UCTX_TXH - ETH_IP_SRC - 4
	ADD	HL,DE
	LD	C,4
	LDIR				; destination; DE -> ETH_L4
	LD	HL,UCTX_TP + 3 - UCTX_TXH - ETH_L4
	ADD	HL,DE
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
	; sums (byte-swapped domain, csum.asm): S = the 8 address bytes;
	; TPT_IPS0 = S + the first 10 header bytes (checksum 0 follows),
	; TPT_L4S0 = S + both ports + protocol
	LD	HL,UCTX_TXH + ETH_IP_SRC - CTX_BIAS
	PUSH	IY
	POP	DE
	ADD	HL,DE
	EX	DE,HL
	LD	HL,0
	LD	BC,8
	CALL	CSUM_RAM		; HL = S, DE -> ports
	PUSH	HL			; [protocol][S]
	LD	BC,4
	CALL	CSUM_RAM		; HL = S + ports
	POP	BC			; S
	POP	AF			; protocol
	PUSH	BC
	LD	E,A
	LD	D,0
	CALL	CSUM_ADD_BE
	EX	DE,HL			; DE = L4S0
	LD	HL,UCTX_TP + TPT_L4S0 - CTX_BIAS
	PUSH	IY
	POP	BC
	ADD	HL,BC
	LD	(HL),E
	INC	HL
	LD	(HL),D
	POP	HL			; S
	LD	DE,UCTX_TXH + ETH_IP - CTX_BIAS
	PUSH	IY
	POP	BC
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL			; DE -> the IPv4 header
	LD	BC,10
	CALL	CSUM_RAM		; HL = IPS0
	EX	DE,HL
	LD	HL,UCTX_TP + TPT_IPS0 - CTX_BIAS
	PUSH	IY
	POP	BC
	ADD	HL,BC
	LD	(HL),E
	INC	HL
	LD	(HL),D
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
; HL = payload source, BC = payload length.  HS_TXREM counts the header
; and the payload still to write (the header goes first, as DATA portions).
TX_FRAME_SET
	PUSH	HL
	PUSH	BC
	LD	DE,UCTX_HWSM - CTX_BIAS
	PUSH	IY
	POP	IX
	ADD	IX,DE
	LD	(IX+HS_TXHDR),A
	POP	BC
	LD	L,A
	LD	H,0
	ADD	HL,BC
	LD	(IX+HS_TXLEN),L
	LD	(IX+HS_TXLEN+1),H
	LD	(IX+HS_TXREM),L
	LD	(IX+HS_TXREM+1),H
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
