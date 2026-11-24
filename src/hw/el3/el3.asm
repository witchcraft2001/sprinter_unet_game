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
EL3_ID_RESET	EQU	0xC0		; global reset: power-on state, AUTOINIT 310 us
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
; Card waits (global reset AUTOINIT >= 310 us, ID EEPROM read >= 162 us;
; Linux waits 4 ms, "some chips need much longer") are two-stage: arm
; EL3_WAIT1_MS, and when that is due -- now_ms has moved at least once --
; arm EL3_WAIT_MS more.  now_ms is the application's clock and may move in
; ticks of any length G (a 20 ms video frame in UGTEST, 2 ms in NETDEMO):
; a single "now + 2 ms" deadline is due at the first tick edge, which can
; come microseconds after the command (the first Zh runs of the 3C509B
; failed so: the card read garbage EEPROM bits and was never activated).
; Two stages need one more edge after the first one was seen, so the real
; wait is >= G and >= EL3_WAIT_MS + 1 - G, i.e. >= (EL3_WAIT_MS + 1) / 2
; = 4 ms for any G.
EL3_WAIT1_MS	EQU	1
EL3_WAIT_MS	EQU	7

; bring-up phases (HS_PHASE), as UNET509B DISCOVER: attach to the card as
; it is -- ID sequence, tag, EEPROM word 7 (3Com's ID: did a card follow
; the sequence?), station address words, activation, window 0,
; manufacturer ID, init table.  The init table makes the datapath known
; whatever an earlier driver or run left behind (window, RX/TX state).
; The ID-port global reset is a recovery only: a card that does not answer
; (word 7 or the manufacturer ID wrong) gets one reset per bring-up -- ID
; sequence, reset, wait, and the discovery again.  A reset switches the
; 10baseT transceiver off and on: the link drops and the switch port
; forwards nothing for 2..6 s.  Resetting at every INIT_CONFIG lost the
; first 3..5 ARP requests of every run on the real card and timed an OPEN
; out (third Zh series: NETDEMO GUDP509B W).
EP_IDSEQ	EQU	0
EP_TAG		EQU	1
EP_EE_WRITE	EQU	2
EP_EE_WAIT	EQU	3		; first stage of the EEPROM wait
EP_EE_READ	EQU	4
EP_ACTIVATE	EQU	5
EP_VERIFY	EQU	6
EP_TABLE	EQU	7
EP_CIP		EQU	8
EP_IDSEQR	EQU	9		; recovery: ID sequence before the reset
EP_RESET	EQU	10
EP_RWAIT	EQU	11		; first stage of the reset wait
EP_RWAIT2	EQU	12
EL3_STOP_MARK	EQU	16		; NIC_STOP: phase + this = the stop table started
	ASSERT	EP_RWAIT2 < EP_TABLE + EL3_STOP_MARK

; EEPROM steps (HS_STEP): 0 = word 7, 1..3 = station address words 0..2
EL3_EE_MFG	EQU	7
EL3_EE_STEPS	EQU	4
; bring-up only (the run phase uses the byte as TX scratch): 1 = the
; global reset of this bring-up has been used
HS_PASS		EQU	HS_TMP

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

; EL3_ARM: hwsm card deadline HS_DL = now_ms + DE ms.  Clobbers A, BC, HL.
EL3_ARM
	PUSH	IX
	POP	HL
	LD	BC,HS_DL
	ADD	HL,BC
	JP	DL_ARM

; EL3_DUE: CF = 1 when HS_DL is due; otherwise CF = 0 and HS_RES =
; NBR_WAIT.  Clobbers A, C, DE, HL.
EL3_DUE
	PUSH	IX
	POP	HL
	LD	DE,HS_DL
	ADD	HL,DE
	CALL	DL_LEFT
	RET	C
	LD	(IX+HS_RES),NBR_WAIT
	RET

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
	XOR	A
	LD	(IX+HS_PHASE),A		; EP_IDSEQ
	LD	(IX+HS_PASS),A
	LD	(IX+HS_CNT),A
	LD	(IX+HS_STEP),A
	LD	(IX+HS_LFSR),EL3_LFSR_SEED
	RET

; EL3_CFG_MAC: a configured MAC (not all zero) overrides the EEPROM
; address in HS_MAC.  Clobbers A, BC, DE, HL.
EL3_CFG_MAC
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
	RET

; ----------------------------------------------------------------------
; NIC_BRINGUP (P): one step.  HS_RES = NBR_*.
; ----------------------------------------------------------------------
NIC_BRINGUP
	LD	(IX+HS_RES),NBR_CONTINUE
	LD	A,(IX+HS_PHASE)
	OR	A			; EP_IDSEQ
	JR	Z,.idseq
	DEC	A			; EP_TAG
	JP	Z,.tag
	DEC	A			; EP_EE_WRITE
	JP	Z,.ee_write
	DEC	A			; EP_EE_WAIT
	JR	Z,.wait1
	DEC	A			; EP_EE_READ
	JP	Z,.ee_read
	DEC	A			; EP_ACTIVATE
	JP	Z,.activate
	DEC	A			; EP_VERIFY
	JP	Z,.verify
	DEC	A			; EP_TABLE
	JP	Z,EL3_TABLE
	DEC	A			; EP_CIP
	JP	Z,EL3_CIP_WAIT
	DEC	A			; EP_IDSEQR
	JR	Z,.idseq
	DEC	A			; EP_RESET
	JR	Z,.reset
	DEC	A			; EP_RWAIT
	JR	Z,.wait1
	; EP_RWAIT2: the reset is over, the discovery starts again
	CALL	EL3_DUE
	RET	NC
	LD	(IX+HS_PHASE),EP_IDSEQ
	JR	.again
.recover
	; no 3C509B answered: one global reset per bring-up
	LD	A,(IX+HS_PASS)
	OR	A
	JR	NZ,.fault
	INC	(IX+HS_PASS)
	LD	(IX+HS_PHASE),EP_IDSEQR
.again
	XOR	A
	LD	(IX+HS_CNT),A		; the ID sequence from its start
	LD	(IX+HS_STEP),A
	LD	(IX+HS_LFSR),EL3_LFSR_SEED
	RET
.fault
	LD	(IX+HS_RES),NBR_FAULT
	RET
.reset
	CALL	EL3_IDPORT
	LD	(HL),EL3_ID_RESET
	LD	DE,EL3_WAIT1_MS
	JR	.armed
.wait1
	; first stage of a card wait: due = now_ms has moved; arm the second
	CALL	EL3_DUE
	RET	NC
	LD	DE,EL3_WAIT_MS
.armed
	CALL	EL3_ARM
	INC	(IX+HS_PHASE)
	LD	(IX+HS_RES),NBR_WAIT
	RET
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
	INC	(IX+HS_PHASE)		; EP_IDSEQ -> EP_TAG, EP_IDSEQR -> EP_RESET
	RET
.tag
	CALL	EL3_IDPORT
	LD	(HL),EL3_ID_TAG0
	LD	(IX+HS_PHASE),EP_EE_WRITE
	RET
.ee_write
	LD	A,(IX+HS_STEP)
	CP	EL3_EE_STEPS
	JR	NC,.ee_done
	DEC	A			; steps 1..3: station address words 0..2
	JP	P,.ee_cmd
	LD	A,EL3_EE_MFG		; step 0: 3Com's ID
.ee_cmd
	OR	EL3_ID_EEPROM
	CALL	EL3_IDPORT
	LD	(HL),A
	LD	(IX+HS_PHASE),EP_EE_WAIT
	LD	DE,EL3_WAIT1_MS
	CALL	EL3_ARM
	LD	(IX+HS_RES),NBR_WAIT
	RET
.ee_done
	LD	(IX+HS_PHASE),EP_ACTIVATE
	JP	EL3_CFG_MAC
.ee_read
	CALL	EL3_DUE
	RET	NC
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
	LD	(IX+HS_PHASE),EP_EE_WRITE
	LD	A,(IX+HS_STEP)
	INC	(IX+HS_STEP)
	OR	A
	JR	NZ,.mac_word
	; word 7 is 3Com's ID when a card followed the ID sequence
	LD	HL,EL3_MFG_3COM
	SBC	HL,DE			; CF = 0 after OR A
	RET	Z
	JP	.recover
.mac_word
	; word i -> MAC bytes 2i (high), 2i+1 (low)
	DEC	A
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
	LD	(IX+HS_WIN),0xFF	; unknown: activation keeps the old window
	RET
.verify
	XOR	A			; window 0 selected explicitly (Linux does too)
	CALL	EL3_WINDOW
	XOR	A			; window 0 register 0: manufacturer ID
	CALL	EL3_REG
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	LD	HL,EL3_MFG_3COM
	OR	A
	SBC	HL,DE
	JP	NZ,.recover
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
	; each table selects its own last window (init: 1, the run phase;
	; stop: 0, what the system driver expects to find).  Selecting
	; window 1 here for both left the card in window 1 after SHUTDOWN:
	; UNET509B then read the RX FIFO for the manufacturer ID and its
	; first command after every Zh series failed.
	LD	(IX+HS_RES),NBR_DONE
	RET
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
	JP	DL_ARM
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
	DB	OP_CMD
	DW	0x0801			; window 1: the run phase lives there
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
	DW	0x0800			; window 0: left selected for the next driver
	DB	OP_END

; ----------------------------------------------------------------------
; RX
; ----------------------------------------------------------------------
; NIC_RX_STATUS (P): CF=1 no frame; else HL = length, A = 0 / 1 (error).
; Short path (UGB_SHORT): "no frame" while a command is in progress --
; RX_DISCARD of the previous frame (NIC_RX_DISCARD) has no wait state.
NIC_RX_STATUS
	IFDEF	UGB_SHORT
	; The command first, the RX status after it: a status read before the
	; command is seen complete may still be the dropped frame's (the
	; other order passed every test but the slow-discard one).
	; Both registers by hand (io_base is a multiple of 16, as in
	; NIC_ISR_POLL): the poll is the item every STEP pays for.
	LD	A,(IX+HS_IO)
	OR	EL3_REG_CMD
	LD	L,A
	LD	H,(IX+HS_IO+1)
	LD	A,(HL)
	INC	HL
	LD	A,(HL)
	AND	EL3_CIP_H
	SCF
	RET	NZ
	LD	A,L
	XOR	(EL3_REG_CMD + 1) ^ EL3_W1_RX_STATUS
	LD	L,A
	ELSE
	LD	A,EL3_W1_RX_STATUS
	CALL	EL3_REG
	ENDIF
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

; NIC_ISR_POLL (P, STEP_ISR: IY only, see engine.asm ISRP_POLL): CF=0
; when a complete frame waits (NIC_RX_STATUS without the length: io_base
; is a multiple of 16, low byte then high byte back to back).
; Clobbers A, HL.
NIC_ISR_POLL
	LD	A,(IY+EX_IO)
	OR	EL3_W1_RX_STATUS
	LD	L,A
	LD	H,(IY+EX_IO+1)
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	ASSERT	EL3_RX_INCOMPLETE_H == 0x80
	BIT	7,H			; EL3_RX_INCOMPLETE_H
	SCF
	RET	NZ
	OR	H
	SCF
	RET	Z
	CCF				; CF=0
	RET

; NIC_RX_READ (P): DE = destination, B = bytes (1..64), C = NRX_* mode.
; The RX FIFO data register is window 1 register 0; the copy/sum loop is
; shared with the other cards (engine.asm NIC_PORT_READ).
NIC_RX_READ
	PUSH	DE
	XOR	A
	CALL	EL3_REG			; HL = FIFO data port
	POP	DE
	JP	NIC_PORT_READ

; NIC_RX_LIMIT (P): the FIFO has no wrap: any portion length is fine.
NIC_RX_LIMIT
	RET

; NIC_RX_DISCARD (P): RX_DISCARD drops the whole top frame.  Short path:
; the next NIC_RX_STATUS waits for the command, and a STEP_ISR sample
; taken while it runs must not make the main STEP skip its poll --
; UPEND_RX stays set until that poll (STEP_ISR only ever sets these bits).
NIC_RX_DISCARD
	IFDEF	UGB_SHORT
	SET	UPEND_RX,(IY+CX_ISR_PENDING)
	ENDIF
	LD	DE,0x4000
	JP	EL3_CMD
	IFNDEF	UGB_SHORT
NIC_RX_DISC_DONE
	CALL	EL3_STATUS_H
	AND	EL3_CIP_H
	RET	Z			; CF=0
	SCF
	RET
	ENDIF

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
	JP	NIC_PORT_WRITE

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
	CP	EP_TABLE + EL3_STOP_MARK	; marker: stop table started
	JR	NC,.running
	LD	(IX+HS_PHASE),EP_TABLE + EL3_STOP_MARK
	LD	(IX+HS_STEP),EL3_STOP_OFS
.running
	LD	(IX+HS_RES),NBR_CONTINUE
	LD	A,(IX+HS_PHASE)
	CP	EP_CIP + EL3_STOP_MARK
	JR	Z,.cip
	LD	(IX+HS_PHASE),EP_TABLE
	CALL	EL3_TABLE
	LD	A,(IX+HS_PHASE)
	ADD	A,EL3_STOP_MARK		; keep the stop marker
	LD	(IX+HS_PHASE),A
	RET
.cip
	LD	(IX+HS_PHASE),EP_CIP
	CALL	EL3_CIP_WAIT
	LD	A,(IX+HS_PHASE)
	ADD	A,EL3_STOP_MARK
	LD	(IX+HS_PHASE),A
	RET
