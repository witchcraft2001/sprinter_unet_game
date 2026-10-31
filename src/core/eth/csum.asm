; csum.asm -- RFC 1071 Internet checksum, resumable.
;
; The accumulator is kept byte-swapped: the byte at an even offset goes to
; L and the following odd byte to H, so bytes are added in memory order.
; The one's complement sum is byte-order independent: fold and swap only
; at the end.  A verified segment sums to 0xFFFF in either domain.

; CSUM_RAM: HL = accumulator, DE -> data, BC = bytes (even, except for the
; last call of a segment: an odd last byte is padded with zero).
; Out: HL = accumulator, DE advanced.  Clobbers A, BC.
; Cost: ~48 T per word (2-word unrolled loop) + 70 T per call.
CSUM_RAM
	SRL	B
	RR	C			; BC = words, CF = odd byte left
	PUSH	AF
.outer
	LD	A,B
	OR	A
	JR	Z,.last			; fewer than 256 words left
	PUSH	BC
	LD	B,0			; 256 words
	CALL	.run
	POP	BC
	DEC	B
	JR	.outer
.last
	OR	C
	LD	B,C
	CALL	NZ,.run
	POP	AF
	RET	NC
	LD	A,(DE)			; odd last byte: even lane, zero padded
	INC	DE
	ADD	A,L
	LD	L,A
	LD	A,0
	ADC	A,H
	LD	H,A
	JR	CSUM_FOLD
.run					; B words (0 = 256), carry chain inside
	OR	A
.word
	LD	A,(DE)
	INC	DE
	ADC	A,L
	LD	L,A
	LD	A,(DE)
	INC	DE
	ADC	A,H
	LD	H,A
	DJNZ	.word
	; fall through: fold the carry of this run

; CSUM_FOLD: add the carry flag into HL (end-around).  Clobbers A.
CSUM_FOLD
	LD	A,0
	ADC	A,L
	LD	L,A
	LD	A,0
	ADC	A,H
	LD	H,A
	RET	NC
	INC	HL			; only after FFFF + 1: HL was 0
	RET

; CSUM_ADD_BE: HL += big-endian word DE (D = first byte on the wire).
; Clobbers A.
CSUM_ADD_BE
	LD	A,D
	ADD	A,L
	LD	L,A
	LD	A,E
	ADC	A,H
	LD	H,A
	JP	CSUM_FOLD

; CSUM_STORE: write the checksum of accumulator HL at (DE), network order.
; Clobbers A.
CSUM_STORE
	LD	A,L
	CPL
	LD	(DE),A
	INC	DE
	LD	A,H
	CPL
	LD	(DE),A
	DEC	DE
	RET

; CSUM_PSEUDO: HL = pseudo-header sum for addresses at (IX+off_src) and
; (IX+off_src+4), protocol C and transport length DE.  IX -> frame header
; (the IPv4 source address is at offset 26, destination at 30).
; Clobbers A, BC, DE.
CSUM_PSEUDO
	PUSH	DE
	PUSH	BC
	PUSH	IX
	POP	DE
	LD	HL,ETH_IP_SRC
	ADD	HL,DE
	EX	DE,HL			; DE -> source address
	LD	HL,0
	LD	BC,8			; source + destination
	CALL	CSUM_RAM
	POP	BC
	LD	D,0
	LD	E,C
	CALL	CSUM_ADD_BE		; zero, protocol
	POP	DE
	JP	CSUM_ADD_BE		; transport length
