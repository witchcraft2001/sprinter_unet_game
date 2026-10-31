; el3.asm -- 3Com EtherLink III (3C509B) card layer for the Ethernet engine.
;
; Register map and command words: 3Com 09-0398-002B, as summarised in
; sprinter-3C509B/src/include/el3.inc (clean-room: no packet-driver code).
; Polling only in v1: the interrupt mask stays 0.  16-bit registers are
; accessed low byte then high byte, back to back.  Every routine marked
; (P) runs inside PORTION with IX = ctx.hwsm.

EL3_LFSR_SEED	EQU	0xFF
EL3_LFSR_POLY	EQU	0xCF
EL3_ID_EEPROM	EQU	0x80
EL3_ID_TAG0	EQU	0xD0
EL3_ID_ACTIVATE	EQU	0xE0
EL3_MFG_3COM	EQU	0x6D50
EL3_REG_CMD	EQU	0x0E
EL3_W1_RX_STATUS EQU	0x08
EL3_W1_TX_STATUS EQU	0x0B
EL3_W1_TX_FREE	EQU	0x0C
EL3_W4_NET_DIAG	EQU	0x06
EL3_W4_MEDIA	EQU	0x0A
EL3_RX_INCOMPLETE_H EQU	0x80
EL3_RX_ERROR_H	EQU	0x40
EL3_CIP_H	EQU	0x10		; command in progress, status bit 12
EL3_TX_COMPLETE	EQU	0x80
EL3_TX_NOTIFY	EQU	0x40
EL3_TX_ERRORS	EQU	0x3C
EL3_TX_RESET_ERRORS EQU	0x30		; jabber, underrun: TX reset needed
EL3_CIP_MS	EQU	100		; one command may take this long
EL3_EEPROM_MS	EQU	2		; >= 162 us after an ID EEPROM read command

; bring-up phases (HS_PHASE)
EP_IDSEQ	EQU	0
EP_TAG		EQU	1
EP_EE_WRITE	EQU	2
EP_EE_READ	EQU	3
EP_ACTIVATE	EQU	4
EP_VERIFY	EQU	5
EP_TABLE	EQU	6
EP_CIP		EQU	7

; init/stop table opcodes
OP_END		EQU	0
OP_CMD		EQU	1		; word follows, then wait for CIP
OP_MAC		EQU	2		; window 2: station address
OP_MEDIA	EQU	3		; window 4: link beat + jabber guard
OP_NODIAG	EQU	4		; window 4: clear the loopback bit
OP_CLRSTAT	EQU	5		; window 6: read the 14 statistics bytes

; HS_LFSR is reused in the run phase: bit 0 = re-enable TX after a reset
EL3_TXFIX	EQU	0

; IO_PTR: HL = card register A (0xC000 + io_base + A).  Clobbers DE.
EL3_REG
	LD	E,A
	LD	D,0
	LD	L,(IX+HS_IO)
	LD	H,(IX+HS_IO+1)
	ADD	HL,DE
	RET

; EL3_CMD: write command word DE.  Clobbers A, HL.
EL3_CMD
	PUSH	DE
	LD	A,EL3_REG_CMD
	CALL	EL3_REG
	POP	DE
	LD	(HL),E
	INC	HL
	LD	(HL),D
	RET

; EL3_STATUS_H: A = high byte of the status register (low byte read
; first).  Clobbers DE, HL.
EL3_STATUS_H
	LD	A,EL3_REG_CMD
	CALL	EL3_REG
	LD	A,(HL)
	INC	HL
	LD	A,(HL)
	RET

; EL3_WINDOW: select register window A (cached in HS_WIN).
EL3_WINDOW
	CP	(IX+HS_WIN)
	RET	Z
	LD	(IX+HS_WIN),A
	LD	E,A
	LD	D,0x08			; SELECT_WINDOW = 0x0800 | n
	JP	EL3_CMD

; EL3_IDPORT: HL = mapped address of the ID port.  Preserves A.
EL3_IDPORT
	PUSH	AF
	LD	L,(IY+CX_ID_PORT)
	LD	A,(IY+CX_ID_PORT+1)
	OR	0xC0
	LD	H,A
	POP	AF
	RET

; ----------------------------------------------------------------------
NIC_PREPARE
	LD	L,(IY+CX_IO_BASE)
	LD	A,(IY+CX_IO_BASE+1)
	OR	0xC0
	LD	H,A
	LD	(IX+HS_IO),L
	LD	(IX+HS_IO+1),H
	LD	(IX+HS_WIN),0xFF
	LD	(IX+HS_PHASE),EP_IDSEQ
	LD	(IX+HS_CNT),0
	LD	(IX+HS_STEP),0
	LD	(IX+HS_LFSR),EL3_LFSR_SEED
	; configured MAC overrides the EEPROM address
	LD	DE,CX_MAC
	CALL	IY_PTR
	LD	A,(HL)
	LD	B,5
.any
	INC	HL
	OR	(HL)
	DJNZ	.any
	RET	Z
	LD	DE,CX_MAC
	CALL	IY_PTR
	PUSH	IX
	POP	DE
	LD	A,E
	ADD	A,HS_MAC
	LD	E,A
	JR	NC,.dst
	INC	D
.dst
	LD	BC,6
	LDIR
	LD	(IX+HS_STEP),3		; EEPROM words already known
	RET

; ----------------------------------------------------------------------
; NIC_BRINGUP (P): one step.  HS_RES = NBR_*.
; ----------------------------------------------------------------------
NIC_BRINGUP
	LD	(IX+HS_RES),NBR_CONTINUE
	LD	A,(IX+HS_PHASE)
	OR	A
	JR	Z,.idseq
	DEC	A
	JR	Z,.tag
	DEC	A
	JR	Z,.ee_write
	DEC	A
	JR	Z,.ee_read
	DEC	A
	JP	Z,.activate
	DEC	A
	JP	Z,.verify
	DEC	A
	JP	Z,EL3_TABLE
	JP	EL3_CIP_WAIT
.idseq
	; two zero bytes, then 255 LFSR bytes, 16 per portion (DI budget)
	CALL	EL3_IDPORT
	LD	A,(IX+HS_CNT)
	OR	A
	JR	NZ,.lfsr
	LD	(HL),A
	LD	(HL),A
.lfsr
	LD	B,16
	LD	C,(IX+HS_LFSR)
	LD	E,(IX+HS_CNT)
.lfsr_loop
	LD	A,E
	CP	255
	JR	Z,.lfsr_done
	LD	(HL),C
	INC	E
	LD	A,C
	ADD	A,A
	JR	NC,.lfsr_next
	XOR	EL3_LFSR_POLY
.lfsr_next
	LD	C,A
	DJNZ	.lfsr_loop
	LD	(IX+HS_LFSR),C
	LD	(IX+HS_CNT),E
	RET
.lfsr_done
	LD	(IX+HS_CNT),E
	LD	(IX+HS_PHASE),EP_TAG
	RET
.tag
	CALL	EL3_IDPORT
	LD	(HL),EL3_ID_TAG0
	LD	(IX+HS_PHASE),EP_EE_WRITE
	RET
.ee_write
	LD	A,(IX+HS_STEP)
	CP	3
	JR	NC,.ee_done
	OR	EL3_ID_EEPROM		; words 0..2: station address
	CALL	EL3_IDPORT
	LD	(HL),A
	LD	(IX+HS_PHASE),EP_EE_READ
	PUSH	IX
	POP	HL
	LD	DE,HS_DL
	ADD	HL,DE
	LD	DE,EL3_EEPROM_MS
	CALL	DL_SET
	LD	(IX+HS_RES),NBR_WAIT
	RET
.ee_done
	LD	(IX+HS_PHASE),EP_ACTIVATE
	RET
.ee_read
	PUSH	IX
	POP	HL
	LD	DE,HS_DL
	ADD	HL,DE
	CALL	DL_LEFT
	JR	C,.ee_due
	LD	(IX+HS_RES),NBR_WAIT
	RET
.ee_due
	CALL	EL3_IDPORT
	LD	DE,0
	LD	B,16
.bit
	SLA	E
	RL	D
	LD	A,(HL)
	AND	1
	OR	E
	LD	E,A
	DJNZ	.bit
	; word i -> MAC bytes 2i (high), 2i+1 (low)
	LD	A,(IX+HS_STEP)
	ADD	A,A
	ADD	A,HS_MAC
	PUSH	IX
	POP	HL
	ADD	A,L
	LD	L,A
	JR	NC,.mac
	INC	H
.mac
	LD	(HL),D
	INC	HL
	LD	(HL),E
	INC	(IX+HS_STEP)
	LD	(IX+HS_PHASE),EP_EE_WRITE
	RET
.activate
	; index = (io_base - 0x200) / 16
	LD	L,(IY+CX_IO_BASE)
	LD	H,(IY+CX_IO_BASE+1)
	LD	DE,-0x200
	ADD	HL,DE
	LD	A,L
	SRL	H
	RRA
	SRL	H
	RRA
	SRL	H
	RRA
	SRL	H
	RRA
	AND	0x1F
	OR	EL3_ID_ACTIVATE
	CALL	EL3_IDPORT
	LD	(HL),A
	LD	(IX+HS_PHASE),EP_VERIFY
	LD	(IX+HS_WIN),0		; an activated card starts in window 0
	RET
.verify
	XOR	A			; window 0 register 0: manufacturer ID
	CALL	EL3_REG
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	LD	HL,EL3_MFG_3COM
	OR	A
	SBC	HL,DE
	JR	Z,.verified
	LD	(IX+HS_RES),NBR_FAULT
	RET
.verified
	LD	(IX+HS_PHASE),EP_TABLE
	LD	(IX+HS_STEP),0		; EL3_INIT_TABLE offset
	RET

; EL3_TABLE (P): run up to EL3_TABLE_BURST ops from table offset HS_STEP
; in one portion; a command whose CIP is still set ends the burst and the
; next portions wait for it.  The init table starts at 0, the stop table at
; EL3_STOP_OFS.
EL3_TABLE_BURST	EQU	2
EL3_TABLE
	LD	(IX+HS_CNT),EL3_TABLE_BURST
.again
	CALL	EL3_TABLE_OP
	LD	A,(IX+HS_RES)
	CP	NBR_CONTINUE
	RET	NZ			; done / fault
	LD	A,(IX+HS_PHASE)
	CP	EP_CIP
	JR	NZ,.next
	CALL	EL3_STATUS_H		; most commands complete at once
	AND	EL3_CIP_H
	RET	NZ			; really busy: wait in later portions
	LD	(IX+HS_PHASE),EP_TABLE
.next
	DEC	(IX+HS_CNT)
	JR	NZ,.again
	RET

EL3_TABLE_OP
	LD	E,(IX+HS_STEP)
	LD	D,0
	LD	HL,EL3_TABLES
	ADD	HL,DE
	LD	A,(HL)
	INC	(IX+HS_STEP)
	OR	A			; OP_END
	JR	NZ,.op
	LD	(IX+HS_RES),NBR_DONE
	LD	(IX+HS_WIN),0xFF	; unknown after the table: recompute
	LD	A,1
	JP	EL3_WINDOW		; run phase lives in window 1
.op
	DEC	A
	JR	NZ,.not_cmd
	INC	HL
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	INC	(IX+HS_STEP)
	INC	(IX+HS_STEP)
	LD	A,D
	AND	0xF8
	CP	0x08			; SELECT_WINDOW: track the cache
	JR	NZ,.issue
	LD	(IX+HS_WIN),E
.issue
	CALL	EL3_CMD
	LD	(IX+HS_PHASE),EP_CIP
	PUSH	IX
	POP	HL
	LD	DE,HS_DL
	ADD	HL,DE
	LD	DE,EL3_CIP_MS
	JP	DL_SET
.not_cmd
	DEC	A
	JR	NZ,.not_mac
	XOR	A			; window 2 registers 0..5
	CALL	EL3_REG
	EX	DE,HL
	PUSH	IX
	POP	HL
	LD	BC,HS_MAC
	ADD	HL,BC
	LD	BC,6
	LDIR
	RET
.not_mac
	DEC	A
	JR	NZ,.not_media
	LD	A,EL3_W4_MEDIA
	CALL	EL3_REG
	LD	A,(HL)
	OR	0xC0			; jabber guard + link beat enable
	LD	E,A
	INC	HL
	LD	D,(HL)
	DEC	HL
	LD	(HL),E
	INC	HL
	LD	(HL),D
	RET
.not_media
	DEC	A
	JR	NZ,.clrstat
	LD	A,EL3_W4_NET_DIAG
	CALL	EL3_REG
	LD	E,(HL)
	INC	HL
	LD	A,(HL)
	AND	0xDF			; loopback (bit 13) off
	DEC	HL
	LD	(HL),E
	INC	HL
	LD	(HL),A
	RET
.clrstat
	XOR	A
	CALL	EL3_REG
	LD	B,14
.stat
	LD	A,(HL)			; statistics clear when read
	INC	HL
	DJNZ	.stat
	RET

; EL3_CIP_WAIT (P): the last command completed?
EL3_CIP_WAIT
	CALL	EL3_STATUS_H
	AND	EL3_CIP_H
	JR	Z,.done
	PUSH	IX
	POP	HL
	LD	DE,HS_DL
	ADD	HL,DE
	CALL	DL_LEFT
	LD	A,NBR_WAIT
	JR	NC,.res
	LD	A,NBR_FAULT
.res
	LD	(IX+HS_RES),A
	RET
.done
	LD	(IX+HS_PHASE),EP_TABLE
	RET

EL3_TABLES
	; --- init (offset 0) ---
	DB	OP_CMD
	DW	0x7000			; SET_INTR_MASK 0 (polling only)
	DB	OP_CMD
	DW	0x7896			; SET_READ_ZERO_MASK
	DB	OP_CMD
	DW	0x1800			; RX_DISABLE
	DB	OP_CMD
	DW	0x5000			; TX_DISABLE
	DB	OP_CMD
	DW	0x2800			; RX_RESET
	DB	OP_CMD
	DW	0x5800			; TX_RESET
	DB	OP_CMD
	DW	0x0802			; window 2
	DB	OP_MAC
	DB	OP_CMD
	DW	0x0804			; window 4
	DB	OP_NODIAG
	DB	OP_MEDIA
	DB	OP_CMD
	DW	0xB000			; STATS_DISABLE
	DB	OP_CMD
	DW	0x0806			; window 6
	DB	OP_CLRSTAT
	DB	OP_CMD
	DW	0x8005			; SET_RX_FILTER: station + broadcast
	DB	OP_CMD
	DW	0x8FFF			; SET_RX_EARLY disabled
	DB	OP_CMD
	DW	0x97FF			; SET_TX_AVAIL disabled
	DB	OP_CMD
	DW	0x9E00			; SET_TX_START 1536: only whole frames start
	DB	OP_CMD
	DW	0xA800			; STATS_ENABLE
	DB	OP_CMD
	DW	0x2000			; RX_ENABLE
	DB	OP_CMD
	DW	0x4800			; TX_ENABLE
	DB	OP_CMD
	DW	0x6869			; ACK_INTR: polling causes
	DB	OP_END
EL3_STOP_OFS	EQU	$ - EL3_TABLES
	; --- stop ---
	DB	OP_CMD
	DW	0x7000			; no interrupt causes
	DB	OP_CMD
	DW	0x1800			; RX_DISABLE
	DB	OP_CMD
	DW	0x5000			; TX_DISABLE
	DB	OP_CMD
	DW	0x68FF			; ACK every cause
	DB	OP_CMD
	DW	0x0800			; window 0
	DB	OP_END

; ----------------------------------------------------------------------
; RX
; ----------------------------------------------------------------------
; NIC_RX_STATUS (P): CF=1 no frame; else HL = length, A = 0 / 1 (error).
NIC_RX_STATUS
	LD	A,EL3_W1_RX_STATUS
	CALL	EL3_REG
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	LD	A,D
	AND	EL3_RX_INCOMPLETE_H
	SCF
	RET	NZ
	LD	A,D
	OR	E
	SCF
	RET	Z
	LD	A,D
	AND	EL3_RX_ERROR_H
	LD	A,0
	JR	Z,.len
	INC	A
.len
	EX	DE,HL
	LD	D,A
	LD	A,H
	AND	0x07
	LD	H,A
	LD	A,D
	OR	A			; CF=0
	RET

; NIC_ISR_POLL (P): CF=0 when a complete frame waits.
NIC_ISR_POLL
	JP	NIC_RX_STATUS

; NIC_RX_READ (P): DE = destination, B = bytes (1..64), C = NRX_* mode.
; The RX FIFO data register is window 1 register 0.  The checksum lanes
; follow HS_PAR (odd offset = high lane).  ~28 T per byte + ISA waits.
NIC_RX_READ
	PUSH	DE
	XOR	A
	CALL	EL3_REG			; HL = FIFO data port
	POP	DE
	LD	A,C
	OR	A
	JR	NZ,.summed
.copy
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	DJNZ	.copy
	RET
.summed
	PUSH	IX
	PUSH	AF			; mode
	LD	A,B
	LD	C,(IX+HS_SUM)
	LD	B,(IX+HS_SUM+1)
	BIT	0,(IX+HS_PAR)
	LD	IXL,A			; IXL = bytes left (IX is saved)
	JR	Z,.even
	; odd start: one byte into the high lane
	POP	AF
	PUSH	AF
	LD	A,(HL)
	CALL	.store
	ADD	A,B
	LD	B,A
	LD	A,0
	ADC	A,C
	LD	C,A
	JR	NC,.par0
	INC	B
.par0
	DEC	IXL
	JR	Z,.even_end
.even
	LD	A,IXL
	SRL	A
	JR	Z,.tail			; no whole pairs
	LD	IXH,A
	POP	AF
	PUSH	AF
	CP	NRX_SKIP
	JR	Z,.pairs_skip
	OR	A			; CF = 0
.pairs_copy
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	ADC	A,C
	LD	C,A
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	ADC	A,B
	LD	B,A
	DEC	IXH
	JR	NZ,.pairs_copy
	JR	.fold
.pairs_skip
	OR	A
.pairs_skip_loop
	LD	A,(HL)
	ADC	A,C
	LD	C,A
	LD	A,(HL)
	ADC	A,B
	LD	B,A
	DEC	IXH
	JR	NZ,.pairs_skip_loop
.fold
	LD	A,0
	ADC	A,C
	LD	C,A
	LD	A,0
	ADC	A,B
	LD	B,A
	JR	NC,.tail
	INC	BC
.tail
	LD	A,IXL
	AND	1
	JR	Z,.even_end
	; one byte left: low lane, the next segment byte is odd
	POP	AF
	PUSH	AF
	LD	A,(HL)
	CALL	.store
	ADD	A,C
	LD	C,A
	LD	A,0
	ADC	A,B
	LD	B,A
	JR	NC,.par1
	INC	BC
.par1
	POP	AF
	POP	IX
	LD	(IX+HS_PAR),1
	JR	.save
.even_end
	POP	AF
	POP	IX
	LD	(IX+HS_PAR),0
.save
	LD	(IX+HS_SUM),C
	LD	(IX+HS_SUM+1),B
	RET
.store					; A = byte; (SP+2) = mode
	PUSH	AF
	PUSH	HL
	LD	HL,6
	ADD	HL,SP
	LD	H,(HL)			; saved mode in the high byte of AF
	LD	A,H
	CP	NRX_SKIP
	POP	HL
	JR	Z,.no_store
	POP	AF
	LD	(DE),A
	INC	DE
	RET
.no_store
	POP	AF
	RET

; NIC_RX_DISCARD (P): RX_DISCARD drops the whole top frame.
NIC_RX_DISCARD
	LD	DE,0x4000
	JP	EL3_CMD
NIC_RX_DISC_DONE
	CALL	EL3_STATUS_H
	AND	EL3_CIP_H
	RET	Z			; CF=0
	SCF
	RET

; ----------------------------------------------------------------------
; TX
; ----------------------------------------------------------------------
; NIC_TX_BEGIN (P): HL = frame length.  CF=1 no room (or recovering).
NIC_TX_BEGIN
	PUSH	HL
	CALL	EL3_STATUS_H
	POP	HL
	AND	EL3_CIP_H
	SCF
	RET	NZ			; a TX reset is still running
	BIT	EL3_TXFIX,(IX+HS_LFSR)
	JR	Z,.room
	RES	EL3_TXFIX,(IX+HS_LFSR)
	LD	DE,0x4800		; TX_ENABLE after the reset
	CALL	EL3_CMD
	SCF
	RET
.room
	; effective length = max(len, 60), padded to a DWORD
	LD	DE,ETH_MIN_FRAME
	PUSH	HL
	OR	A
	SBC	HL,DE
	POP	HL
	JR	NC,.long
	EX	DE,HL
.long
	LD	(IX+HS_TMP),L		; effective length
	LD	(IX+HS_TMP+1),H
	PUSH	HL
	LD	DE,3 + 4		; DWORD padding + preamble
	ADD	HL,DE
	EX	DE,HL
	LD	A,EL3_W1_TX_FREE
	CALL	EL3_REG
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A
	OR	A
	SBC	HL,DE
	POP	HL
	RET	C			; not enough room yet
	PUSH	HL
	XOR	A
	CALL	EL3_REG			; FIFO port
	POP	DE
	LD	(HL),E			; preamble: length, bit 15 = notify
	LD	A,D
	OR	0x80
	LD	(HL),A
	XOR	A
	LD	(HL),A
	LD	(HL),A
	RET				; CF=0

; NIC_TX_WRITE (P): HL = source, B = bytes.
NIC_TX_WRITE
	PUSH	HL
	XOR	A
	CALL	EL3_REG
	EX	DE,HL			; DE = FIFO port
	POP	HL
.loop
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	DJNZ	.loop
	RET

; NIC_TX_END (P): zero padding up to max(len, 60) rounded to a DWORD.
NIC_TX_END
	LD	L,(IX+HS_TMP)
	LD	H,(IX+HS_TMP+1)
	LD	DE,3
	ADD	HL,DE
	LD	A,L
	AND	0xFC
	LD	L,A
	LD	E,(IX+HS_TXLEN)
	LD	D,(IX+HS_TXLEN+1)
	OR	A
	SBC	HL,DE			; padding bytes (< 64)
	LD	B,L
	LD	A,B
	OR	A
	RET	Z
	XOR	A
	PUSH	BC
	CALL	EL3_REG
	POP	BC
	XOR	A
.pad
	LD	(HL),A
	DJNZ	.pad
	RET

; NIC_TX_CHECK (P): A = NTX_PENDING / NTX_OK / NTX_ERROR.
NIC_TX_CHECK
	LD	A,EL3_W1_TX_STATUS
	CALL	EL3_REG
	LD	A,(HL)
	BIT	7,A
	JR	NZ,.complete
	XOR	A			; NTX_PENDING
	RET
.complete
	LD	(HL),A			; pop the status
	LD	B,A
	AND	EL3_TX_ERRORS
	JR	NZ,.error
	LD	A,B
	AND	EL3_TX_COMPLETE | EL3_TX_NOTIFY
	CP	EL3_TX_COMPLETE | EL3_TX_NOTIFY
	LD	A,NTX_OK
	RET	Z
	LD	A,NTX_ERROR
	RET
.error
	AND	EL3_TX_RESET_ERRORS
	LD	DE,0x5800		; TX_RESET
	JR	NZ,.reset
	LD	DE,0x4800		; TX_ENABLE is enough
	CALL	EL3_CMD
	LD	A,NTX_ERROR
	RET
.reset
	CALL	EL3_CMD
	SET	EL3_TXFIX,(IX+HS_LFSR)
	LD	A,NTX_ERROR
	RET

; ----------------------------------------------------------------------
; NIC_STOP (P): run the stop table.  HS_RES = NBR_*.
; ----------------------------------------------------------------------
NIC_STOP
	LD	A,(IX+HS_PHASE)
	CP	EP_TABLE + 8		; marker: stop table started
	JR	NC,.running
	LD	(IX+HS_PHASE),EP_TABLE + 8
	LD	(IX+HS_STEP),EL3_STOP_OFS
.running
	LD	(IX+HS_RES),NBR_CONTINUE
	LD	A,(IX+HS_PHASE)
	CP	EP_CIP + 8
	JR	Z,.cip
	LD	(IX+HS_PHASE),EP_TABLE
	CALL	EL3_TABLE
	LD	A,(IX+HS_PHASE)
	ADD	A,8			; keep the stop marker
	LD	(IX+HS_PHASE),A
	RET
.cip
	LD	(IX+HS_PHASE),EP_CIP
	CALL	EL3_CIP_WAIT
	LD	A,(IX+HS_PHASE)
	ADD	A,8
	LD	(IX+HS_PHASE),A
	RET
