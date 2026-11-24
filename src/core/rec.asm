; rec.asm -- UDP records (UNETG_CFGF_UDP_RECORDS; docs/unet-game-abi.md,
; tools/harness/net/xrec.js): with the flag every datagram on the wire is
; one record on every UDP build and mode, so a server reads the same bytes
; from any card:
;
;   byte 0 = check << 2 | len >> 8      check = (0x2B + lo + hi) & 0x3F
;   byte 1 = len & 0xFF                 len = 0..512 payload bytes
;
; The application never sees the header: TX prepends it to the slot's
; datagram, RX checks it, requires it to fill the datagram and strips it.
; (GUDPESP's transparent mode, esp_fw = 2, always uses records and keeps
; its own copy of this arithmetic in esp/esp_x.asm.)

REC_HDR		EQU	2		; header bytes

; REC_ON: ZF=0 when the channel uses records.  Clobbers nothing but F.
	MACRO	REC_ON
	BIT	4,(IY+CX_CFG_FLAGS)
	ENDM
	ASSERT	UNETG_CFGF_UDP_RECORDS == 1 << 4

; REC_OFS: A = REC_HDR with records, 0 without.  Clobbers F.
	MACRO	REC_OFS
	LD	A,(IY+CX_CFG_FLAGS)
	AND	UNETG_CFGF_UDP_RECORDS
	RRCA
	RRCA
	RRCA
	ENDM
	ASSERT	UNETG_CFGF_UDP_RECORDS >> 3 == REC_HDR

; REC_B0: A = header byte 0 of a record of DE bytes (0..512).
; Clobbers F only.  Cost: 13 instructions, ~10 us.
REC_B0
	LD	A,E
	ADD	A,D
	ADD	A,0x2B
	AND	0x3F
	RLCA
	RLCA
	OR	D
	RET

; REC_CHECK: A = byte 0, E = byte 1 of a header.  ZF=1: a valid header,
; DE = len (0..512); ZF=0: none (DE undefined).  Clobbers A, D.
; Cost: ~20 us.
REC_CHECK
	PUSH	BC
	LD	B,A
	AND	3
	LD	D,A			; len >> 8
	CP	3
	JR	Z,.bad
	CP	2
	JR	NZ,.ok
	LD	A,E
	OR	A
	JR	NZ,.bad			; above 512
.ok
	CALL	REC_B0
	CP	B
	POP	BC
	RET
.bad
	OR	1			; ZF=0 (A is 2 or 3 here, or E != 0)
	POP	BC
	RET
