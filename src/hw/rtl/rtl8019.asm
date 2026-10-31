; rtl8019.asm -- RTL8019AS (DP8390 / NE2000, 8-bit mode) card layer for
; the Ethernet engine.
;
; Register sequences follow the DP8390 programming model as used by
; sprinter-rtl8019a/src/lib/rtl8019.asm (INIT_NORMAL, DMA_READ,
; READ_PACKET, RECOVER_OVERFLOW, SEND_FRAME_SG) and its notes in
; sprinter_rtl8019_soft.md; the control flow is re-implemented as
; resumable states.  Polling only in v1: IMR stays 0.  Every routine
; marked (P) runs inside PORTION with IX = ctx.hwsm.
;
; Hardware rules kept here:
;   * DCR = 0x48 always (8-bit transfers; the chip resets to 0x04);
;   * the reset port (+0x1F) is never touched: clone chips hang the ISA
;     cycle there and no software timeout catches that.  Reset is soft:
;     CR = STOP, wait >= 1.6 ms (a frame in flight ends), reprogram;
;   * every remote DMA is programmed for one portion (CR, ISR.RDC, RBCR,
;     RSAR, CR) and completed within it, so RX and TX portions interleave
;     freely; NIC_RX_LIMIT ends a portion at PSTOP, so one portion is
;     always one remote read (DI stays below 200 us);
;   * CR = 0x26 (TXP) is written exactly once per frame: re-issuing it
;     produced duplicate frames in a field test;
;   * the receive ring is reset as a whole on overflow, on a damaged
;     receive header and after a transmitter that never completed
;     (counted in hw_overflow); TCP recovers the lost segments.
; io_base is 32-aligned (INIT_CONFIG), so register N is (HS_IO | N).

RTL_CR		EQU	0x00
RTL_PSTART	EQU	0x01		; page 0
RTL_PSTOP	EQU	0x02
RTL_BNRY	EQU	0x03
RTL_TPSR	EQU	0x04
RTL_TBCR0	EQU	0x05
RTL_TBCR1	EQU	0x06
RTL_ISR		EQU	0x07
RTL_RSAR0	EQU	0x08
RTL_RSAR1	EQU	0x09
RTL_RBCR0	EQU	0x0A
RTL_RBCR1	EQU	0x0B
RTL_RCR		EQU	0x0C
RTL_TCR		EQU	0x0D
RTL_DCR		EQU	0x0E
RTL_IMR		EQU	0x0F
RTL_P1_PAR0	EQU	0x01		; page 1
RTL_P1_CURR	EQU	0x07
RTL_P1_MAR0	EQU	0x08
RTL_DATA	EQU	0x10

CR_STOP		EQU	0x21		; page 0, stop, no DMA
CR_START	EQU	0x22		; page 0, start, no DMA (aborts remote DMA)
CR_RREAD	EQU	0x0A		; page 0, start, remote read
CR_RWRITE	EQU	0x12		; page 0, start, remote write
CR_TX		EQU	0x26		; page 0, start, transmit
CR_P1_STOP	EQU	0x61
CR_P1_START	EQU	0x62

ISR_PRX		EQU	0x01
ISR_PTX		EQU	0x02
ISR_RXE		EQU	0x04
ISR_TXE		EQU	0x08
ISR_OVW		EQU	0x10
ISR_RDC		EQU	0x40

RTL_DCR_VAL	EQU	0x48		; byte-wide, normal, FIFO threshold 8
RTL_RCR_RUN	EQU	0x04		; own address + broadcast
RTL_RCR_MON	EQU	0x20		; monitor: nothing is stored
RTL_TCR_LOOP	EQU	0x02		; internal loopback
RTL_TX_PAGE	EQU	0x40		; 6 pages of transmit buffer
RTL_RX_START	EQU	0x46		; receive ring PSTART..PSTOP-1
RTL_RX_STOP	EQU	0x60		; 8-bit mode maximum
RTL_CURR0	EQU	RTL_RX_START + 1
RTL_TXBUF	EQU	RTL_TX_PAGE * 256
RTL_STOP_MS	EQU	2		; >= 1.6 ms: a maximum frame ends
RTL_BURST	EQU	8		; table entries per portion (DI budget)
RTL_RDC_READS	EQU	4		; ISR samples for the end of a TX write

; card fields in ctx.hwsm (the 3C509B meaning in brackets)
HS_NEXT		EQU	HS_LFSR		; page of the next frame (= BNRY + 1)
HS_RFLAGS	EQU	HS_WIN		; RF_* below
HS_RXPTR	EQU	HS_TMP		; card address of the next RX byte
RF_MACSET	EQU	0		; station address comes from INIT_CONFIG
RF_RECOVER	EQU	1		; the recovery table is running
RF_TXFAIL	EQU	2		; the frame being sent will not be started
RF_TXSTUCK	EQU	3		; TXP outlived the engine timeout

; HS_PHASE: bit 0 = waiting for the table deadline, bit 7 = stop table.

; table entries: two bytes each.  A register number 0x00..0x1F writes the
; second byte to that register; 0x80+ are operations.
OP_END		EQU	0x80
OP_WAIT		EQU	0x81		; arg = ms, ends the portion
OP_PROBE	EQU	0x82		; BNRY/TPSR read-back: absent card -> FAULT
OP_PROM		EQU	0x83		; station address from the PROM
OP_MAC		EQU	0x84		; PAR0..5 = HS_MAC (page 1 selected)
OP_RING		EQU	0x85		; HS_NEXT = first ring page after a reset

; ----------------------------------------------------------------------
; RTL_REG: HL = card register A (A < 0x20).  Preserves BC, DE.
; ----------------------------------------------------------------------
RTL_REG
	OR	(IX+HS_IO)
	LD	L,A
	LD	H,(IX+HS_IO+1)
	RET

; RTL_DMA (P): start remote DMA command A (CR_RREAD / CR_RWRITE) of BC
; bytes at card address DE.  Order: CR (abort), ISR.RDC, RBCR, RSAR, CR.
; Out: HL = data port.  Clobbers A.  Preserves BC, DE.  ~150 T.
RTL_DMA
	PUSH	AF
	XOR	A
	CALL	RTL_REG			; HL = CR
	LD	(HL),CR_START
	LD	A,L
	OR	RTL_ISR
	LD	L,A
	LD	(HL),ISR_RDC
	XOR	RTL_ISR ^ RTL_RBCR0
	LD	L,A
	LD	(HL),C
	INC	L
	LD	(HL),B
	LD	A,L
	XOR	RTL_RBCR1 ^ RTL_RSAR0
	LD	L,A
	LD	(HL),E
	INC	L
	LD	(HL),D
	LD	A,L
	AND	0xE0
	LD	L,A			; CR
	POP	AF
	LD	(HL),A
	LD	A,L
	OR	RTL_DATA
	LD	L,A
	RET

; RTL_CURR (P): A = CURR (page 1), page 0 selected again.  Out: HL = CR.
; Preserves BC, DE.
RTL_CURR
	XOR	A
	CALL	RTL_REG
	LD	(HL),CR_P1_START
	LD	A,L
	OR	RTL_P1_CURR
	LD	L,A
	LD	A,(HL)
	LD	L,(IX+HS_IO)
	LD	(HL),CR_START
	RET

; RTL_WAIT_HL: HL -> deadline of table waits (HS_BDL while recovering in
; the run phase, where HS_DL belongs to the TX pipeline).  Preserves BC, DE.
RTL_WAIT_HL
	PUSH	DE
	PUSH	IX
	POP	HL
	LD	DE,HS_DL
	BIT	RF_RECOVER,(IX+HS_RFLAGS)
	JR	Z,.dl
	LD	E,HS_BDL
.dl
	ADD	HL,DE
	POP	DE
	RET

; ----------------------------------------------------------------------
NIC_PREPARE
	LD	L,(IY+CX_IO_BASE)
	LD	A,(IY+CX_IO_BASE+1)
	OR	0xC0
	LD	H,A
	LD	(IX+HS_IO),L
	LD	(IX+HS_IO+1),H
	XOR	A
	LD	(IX+HS_PHASE),A
	LD	(IX+HS_STEP),A		; init table
	LD	(IX+HS_RFLAGS),A
	LD	(IX+HS_NEXT),RTL_CURR0
	; a configured MAC overrides the PROM
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
	SET	RF_MACSET,(IX+HS_RFLAGS)
	RET

; ----------------------------------------------------------------------
; NIC_BRINGUP / NIC_STOP (P): one portion of the init / stop table.
; HS_RES = NBR_*.
; ----------------------------------------------------------------------
NIC_STOP
	BIT	7,(IX+HS_PHASE)
	JR	NZ,RTL_TABLE
	LD	(IX+HS_PHASE),0x80
	LD	(IX+HS_STEP),RTL_STOP_OFS
	RES	RF_RECOVER,(IX+HS_RFLAGS)
NIC_BRINGUP
; RTL_TABLE (P): up to RTL_BURST entries from offset HS_STEP; a wait ends
; the portion and the next call resumes after its deadline.
RTL_TABLE
	LD	(IX+HS_RES),NBR_CONTINUE
	BIT	0,(IX+HS_PHASE)
	JR	Z,.run
	CALL	RTL_WAIT_HL
	CALL	DL_LEFT
	JR	C,.due
	LD	(IX+HS_RES),NBR_WAIT
	RET
.due
	RES	0,(IX+HS_PHASE)
.run
	LD	(IX+HS_CNT),RTL_BURST
.op
	LD	E,(IX+HS_STEP)
	LD	D,0
	LD	HL,RTL_TABLES
	ADD	HL,DE
	INC	(IX+HS_STEP)
	INC	(IX+HS_STEP)
	LD	A,(HL)
	INC	HL
	LD	C,(HL)			; value / argument
	CP	OP_END
	JR	NC,.special
	CALL	RTL_REG
	LD	(HL),C
.next
	DEC	(IX+HS_CNT)
	JR	NZ,.op
	RET
.special
	SUB	OP_END
	JR	Z,.end
	DEC	A
	JR	Z,.wait
	DEC	A
	JR	Z,.probe
	DEC	A
	JR	Z,.prom
	DEC	A
	JR	Z,.mac
	LD	(IX+HS_NEXT),RTL_CURR0	; OP_RING
	JR	.next
.end
	LD	(IX+HS_RES),NBR_DONE
	RET
.wait
	SET	0,(IX+HS_PHASE)
	LD	E,C
	LD	D,0
	CALL	RTL_WAIT_HL
	CALL	DL_ARM
	LD	(IX+HS_RES),NBR_WAIT
	RET
.probe
	; BNRY and TPSR keep what was written; an empty slot reads 0xFF
	LD	A,RTL_BNRY
	CALL	RTL_REG
	LD	C,0xAA
	CALL	.pattern
	JR	NZ,.fault
	LD	C,0x55
	CALL	.pattern
	JR	Z,.next
.fault
	LD	(IX+HS_RES),NBR_FAULT
	RET
.pattern				; BNRY = C, TPSR = ~C, Z when BNRY reads C
	LD	(HL),C
	LD	A,L
	XOR	RTL_BNRY ^ RTL_TPSR
	LD	L,A
	LD	A,C
	CPL
	LD	(HL),A
	LD	A,L
	XOR	RTL_BNRY ^ RTL_TPSR
	LD	L,A
	LD	A,(HL)
	CP	C
	RET
.prom
	; the PROM read (~100 us under DI) gets a portion of its own
	LD	A,(IX+HS_CNT)
	CP	RTL_BURST
	JR	Z,.prom_now
	DEC	(IX+HS_STEP)
	DEC	(IX+HS_STEP)
	RET				; NBR_CONTINUE: the next portion starts here
.prom_now
	BIT	RF_MACSET,(IX+HS_RFLAGS)
	CALL	Z,RTL_PROM
	LD	(IX+HS_CNT),1
	JR	.next
.mac
	LD	A,RTL_P1_PAR0
	CALL	RTL_REG
	PUSH	IX
	LD	B,6
.par
	LD	A,(IX+HS_MAC)
	LD	(HL),A
	INC	L
	INC	IX
	DJNZ	.par
	POP	IX
	JP	.next

; RTL_PROM (P): read the 32-byte station PROM into ctx.scratch and take
; the address from it.  8-bit cards return it either directly (bytes
; 0..5) or with every byte doubled (bytes 0, 2, .. 10): doubled when all
; 16 byte pairs are equal.  The 0x57 signature is not required.
RTL_PROM
	LD	DE,0
	LD	BC,32
	LD	A,CR_RREAD
	CALL	RTL_DMA			; HL = data port
	PUSH	HL
	LD	DE,UCTX_SCRATCH - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,DE
	EX	DE,HL			; DE -> scratch
	POP	HL
	PUSH	DE
	LD	BC,32 * 256 + NRX_COPY
	CALL	NIC_PORT_READ
	POP	HL			; HL -> raw PROM
	PUSH	HL
	LD	B,16
.pair
	LD	A,(HL)
	INC	HL
	CP	(HL)
	INC	HL
	JR	NZ,.direct
	DJNZ	.pair
	LD	DE,2			; doubled
	JR	.take
.direct
	LD	DE,1
.take
	POP	HL
	PUSH	IX
	LD	B,6
.byte
	LD	A,(HL)
	LD	(IX+HS_MAC),A
	INC	IX
	ADD	HL,DE
	DJNZ	.byte
	POP	IX
	RET

; RTL_RECOVER_START (P): reset the receive ring through the recovery
; table (run by NIC_RX_STATUS, i.e. only with the RX pipeline idle).
; Clobbers BC, HL.
RTL_RECOVER_START
	LD	A,(IX+HS_RFLAGS)
	AND	~(1 << RF_TXSTUCK)
	OR	1 << RF_RECOVER
	LD	(IX+HS_RFLAGS),A
	LD	(IX+HS_STEP),RTL_RECOV_OFS
	LD	(IX+HS_PHASE),0
	STAT_INC UNETG_STATS_HW_OVERFLOW
	RET

RTL_TABLES
	; --- init (offset 0): soft reset, probe, PROM, ring, start ---
	DB	RTL_CR, CR_STOP
	DB	OP_WAIT, RTL_STOP_MS
	DB	RTL_DCR, RTL_DCR_VAL
	DB	RTL_RBCR0, 0
	DB	RTL_RBCR1, 0
	DB	RTL_RCR, RTL_RCR_MON
	DB	RTL_TCR, RTL_TCR_LOOP
	DB	RTL_IMR, 0
	DB	OP_PROBE, 0
	DB	OP_PROM, 0		; the remote read starts the NIC (monitor, loopback)
	DB	RTL_CR, CR_STOP
	DB	RTL_TPSR, RTL_TX_PAGE
	DB	RTL_PSTART, RTL_RX_START
	DB	RTL_PSTOP, RTL_RX_STOP
	DB	RTL_BNRY, RTL_RX_START
	DB	RTL_ISR, 0xFF
	DB	RTL_CR, CR_P1_STOP
	DB	OP_MAC, 0
	DB	RTL_P1_CURR, RTL_CURR0
	DB	RTL_P1_MAR0, 0
	DB	RTL_P1_MAR0 + 1, 0
	DB	RTL_P1_MAR0 + 2, 0
	DB	RTL_P1_MAR0 + 3, 0
	DB	RTL_P1_MAR0 + 4, 0
	DB	RTL_P1_MAR0 + 5, 0
	DB	RTL_P1_MAR0 + 6, 0
	DB	RTL_P1_MAR0 + 7, 0
	DB	RTL_CR, CR_START
	DB	RTL_TCR, 0
	DB	RTL_RCR, RTL_RCR_RUN
	DB	RTL_ISR, 0xFF
	DB	OP_RING, 0
	DB	OP_END, 0
RTL_RECOV_OFS	EQU	$ - RTL_TABLES
	; --- receive ring reset (DP8390 overflow procedure) ---
	DB	RTL_RCR, RTL_RCR_MON
	DB	RTL_CR, CR_STOP
	DB	RTL_RBCR0, 0
	DB	RTL_RBCR1, 0
	DB	OP_WAIT, RTL_STOP_MS
	DB	RTL_TCR, RTL_TCR_LOOP
	DB	RTL_BNRY, RTL_RX_START
	DB	RTL_CR, CR_P1_STOP
	DB	RTL_P1_CURR, RTL_CURR0
	DB	RTL_CR, CR_START
	DB	RTL_ISR, 0xFF
	DB	RTL_TCR, 0
	DB	RTL_RCR, RTL_RCR_RUN
	DB	OP_RING, 0
	DB	OP_END, 0
RTL_STOP_OFS	EQU	$ - RTL_TABLES
	; --- stop ---
	DB	RTL_CR, CR_STOP
	DB	RTL_RCR, RTL_RCR_MON
	DB	RTL_IMR, 0
	DB	RTL_ISR, 0xFF
	DB	OP_END, 0
	ASSERT	$ - RTL_TABLES < 256

; ----------------------------------------------------------------------
; RX
; ----------------------------------------------------------------------
; NIC_RX_STATUS (P): CF=1 no frame; else HL = frame length (FCS
; included when the chip stores it, at most ETH_MAX_FRAME), A = 0.
; Runs the ring recovery while it is active (one portion per call).
NIC_RX_STATUS
	BIT	RF_RECOVER,(IX+HS_RFLAGS)
	JR	NZ,.recover
	BIT	RF_TXSTUCK,(IX+HS_RFLAGS)
	JR	NZ,.reset
	CALL	RTL_CURR		; A = CURR, HL = CR
	CP	RTL_RX_START
	JR	C,.none			; bus glitch: try again later
	CP	RTL_RX_STOP
	JR	NC,.none
	CP	(IX+HS_NEXT)
	JR	Z,.empty
	; receive header: status, next page, count (header included)
	LD	D,(IX+HS_NEXT)
	LD	E,0
	LD	BC,4
	LD	A,CR_RREAD
	CALL	RTL_DMA
	LD	B,(HL)			; receive status
	LD	C,(HL)			; next page
	LD	E,(HL)
	LD	D,(HL)			; DE = count
	BIT	0,B			; PRX: received intact
	JR	Z,.reset
	LD	A,C
	CP	RTL_RX_START
	JR	C,.reset
	CP	RTL_RX_STOP
	JR	NC,.reset
	LD	(IX+HS_NEXTPG),A
	EX	DE,HL
	LD	DE,-(4 + ETH_HDR)
	ADD	HL,DE
	JR	NC,.reset		; shorter than a header
	LD	DE,ETH_MAX_FRAME + 8 - ETH_HDR + 1
	PUSH	HL
	OR	A
	SBC	HL,DE
	POP	HL
	JR	NC,.reset		; longer than a frame with FCS
	LD	DE,ETH_HDR
	ADD	HL,DE			; HL = count - 4
	LD	DE,ETH_MAX_FRAME + 1
	PUSH	HL
	OR	A
	SBC	HL,DE
	POP	HL
	JR	C,.len
	LD	HL,ETH_MAX_FRAME	; the FCS tail is never read
.len
	LD	A,(IX+HS_NEXT)
	LD	(IX+HS_RXPTR+1),A
	LD	(IX+HS_RXPTR),4
	XOR	A			; A = 0, CF = 0
	RET
.empty
	LD	A,L
	OR	RTL_ISR
	LD	L,A
	LD	A,(HL)
	INC	A
	JR	Z,.none			; 0xFF: nothing driven the bus
	DEC	A
	AND	ISR_OVW
	JR	Z,.none
.reset
	CALL	RTL_RECOVER_START
.none
	SCF
	RET
.recover
	CALL	RTL_TABLE
	LD	A,(IX+HS_RES)
	CP	NBR_DONE
	JR	NZ,.none
	RES	RF_RECOVER,(IX+HS_RFLAGS)
	JR	.none

; NIC_ISR_POLL (P): CF=0 when the main STEP has receive work: a frame, an
; overflow or a running recovery (STEP_ISR never runs the recovery, but
; must not make the main poll skip it).
NIC_ISR_POLL
	LD	A,(IX+HS_RFLAGS)
	AND	(1 << RF_RECOVER) | (1 << RF_TXSTUCK)
	RET	NZ			; CF=0
	CALL	RTL_CURR
	CP	(IX+HS_NEXT)
	JR	Z,.empty
	OR	A
	RET
.empty
	LD	A,L
	OR	RTL_ISR
	LD	L,A
	LD	A,(HL)
	AND	ISR_OVW
	RET	NZ			; CF=0
	SCF
	RET

; NIC_RX_LIMIT (P): B = E = portion length; never across the ring end, so
; every portion is one remote read (the rest follows in the next one).
NIC_RX_LIMIT
	LD	A,(IX+HS_RXPTR+1)
	CP	RTL_RX_STOP - 1
	RET	C			; >= 256 bytes before the ring end
	XOR	A
	SUB	(IX+HS_RXPTR)		; bytes before the end (0 = 256)
	RET	Z
	CP	B
	RET	NC
	LD	B,A
	LD	E,A
	RET

; NIC_RX_READ (P): DE = destination, B = bytes (1..64), C = NRX_* mode,
; from card address HS_RXPTR (NIC_RX_LIMIT keeps it inside the ring).
; DE is advanced in the stored modes and kept in NRX_SKIP; HS_RXPTR
; follows with the ring wrap.
NIC_RX_READ
	LD	L,(IX+HS_RXPTR)
	LD	H,(IX+HS_RXPTR+1)
	LD	A,L
	ADD	A,B
	LD	(IX+HS_RXPTR),A
	LD	A,H
	ADC	A,0
	CP	RTL_RX_STOP
	JR	C,.ptr
	LD	A,RTL_RX_START
.ptr
	LD	(IX+HS_RXPTR+1),A
	PUSH	BC
	PUSH	DE
	EX	DE,HL
	LD	C,B
	LD	B,0
	LD	A,CR_RREAD
	CALL	RTL_DMA			; HL = data port
	POP	DE
	POP	BC
	JP	NIC_PORT_READ

; NIC_RX_DISCARD (P): release the frame: BNRY = next - 1 (ring wrap).
NIC_RX_DISCARD
	LD	A,(IX+HS_NEXTPG)
	LD	(IX+HS_NEXT),A
	DEC	A
	CP	RTL_RX_START
	JR	NC,.bnry
	LD	A,RTL_RX_STOP - 1
.bnry
	LD	C,A
	XOR	A
	CALL	RTL_REG
	LD	(HL),CR_START		; page 0, no remote DMA
	LD	A,L
	OR	RTL_BNRY
	LD	L,A
	LD	(HL),C
	XOR	RTL_BNRY ^ RTL_ISR
	LD	L,A
	LD	(HL),ISR_PRX | ISR_RXE
	RET
NIC_RX_DISC_DONE
	OR	A			; immediate
	RET

; ----------------------------------------------------------------------
; TX: the frame is written into the transmit pages in portions, each its
; own remote DMA at TX page + offset (offset = HS_TXLEN - HS_TXREM - B,
; the engine updates HS_TXREM before the portion).
; ----------------------------------------------------------------------
; NIC_TX_BEGIN (P): HL = frame length.  CF=1 when the card cannot take a
; frame now (recovery, or a transmitter that outlived the engine timeout:
; the ring reset that follows also stops it).
NIC_TX_BEGIN
	LD	A,(IX+HS_RFLAGS)
	AND	(1 << RF_RECOVER) | (1 << RF_TXSTUCK)
	SCF
	RET	NZ
	RES	RF_TXFAIL,(IX+HS_RFLAGS)
	XOR	A
	CALL	RTL_REG
	BIT	2,(HL)			; CR.TXP
	RET	Z			; CF=0 (XOR A)
	SET	RF_TXSTUCK,(IX+HS_RFLAGS)
	SCF
	RET

; NIC_TX_WRITE (P): HL = source, B = bytes.
NIC_TX_WRITE
	BIT	RF_RECOVER,(IX+HS_RFLAGS)
	RET	NZ			; the frame fails at NIC_TX_END
	PUSH	HL
	PUSH	BC
	LD	L,(IX+HS_TXLEN)
	LD	H,(IX+HS_TXLEN+1)
	LD	E,(IX+HS_TXREM)
	LD	D,(IX+HS_TXREM+1)
	OR	A
	SBC	HL,DE
	LD	E,B
	LD	D,0
	SBC	HL,DE
	LD	DE,RTL_TXBUF
	ADD	HL,DE
	EX	DE,HL			; DE = card address
	LD	C,B
	LD	B,0
	LD	A,CR_RWRITE
	CALL	RTL_DMA
	EX	DE,HL			; DE = data port
	POP	BC
	POP	HL
.loop
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	DJNZ	.loop
	RET

; NIC_TX_END (P): zero padding up to 60 bytes, then TBCR, TPSR and one
; CR.TXP once the last remote write has completed (RDC).
NIC_TX_END
	BIT	RF_RECOVER,(IX+HS_RFLAGS)
	JR	NZ,.fail
	LD	L,(IX+HS_TXLEN)
	LD	H,(IX+HS_TXLEN+1)
	LD	A,H
	OR	A
	JR	NZ,.start
	LD	A,L
	SUB	ETH_MIN_FRAME
	JR	NC,.start
	NEG
	LD	C,A
	LD	B,0
	LD	DE,RTL_TXBUF
	ADD	HL,DE
	EX	DE,HL
	LD	A,CR_RWRITE
	CALL	RTL_DMA
	LD	B,C
	XOR	A
.pad
	LD	(HL),A
	DJNZ	.pad
.start
	LD	A,RTL_ISR
	CALL	RTL_REG
	LD	B,RTL_RDC_READS
.rdc
	BIT	6,(HL)			; ISR.RDC
	JR	NZ,.go
	DJNZ	.rdc
.fail
	SET	RF_TXFAIL,(IX+HS_RFLAGS)
	RET
.go
	LD	(HL),ISR_RDC | ISR_PTX | ISR_TXE	; no stale completion
	LD	E,(IX+HS_TXLEN)
	LD	D,(IX+HS_TXLEN+1)
	LD	A,D
	OR	A
	JR	NZ,.len
	LD	A,E
	CP	ETH_MIN_FRAME
	JR	NC,.len
	LD	E,ETH_MIN_FRAME
.len
	LD	A,L
	XOR	RTL_ISR ^ RTL_TBCR0
	LD	L,A
	LD	(HL),E
	INC	L
	LD	(HL),D
	XOR	RTL_TBCR0 ^ RTL_TPSR
	LD	L,A
	LD	(HL),RTL_TX_PAGE
	AND	0xE0
	LD	L,A
	LD	(HL),CR_TX		; exactly once per frame
	RET

; NIC_TX_CHECK (P): A = NTX_PENDING / NTX_OK / NTX_ERROR.
NIC_TX_CHECK
	LD	A,(IX+HS_RFLAGS)
	AND	(1 << RF_TXFAIL) | (1 << RF_RECOVER)
	JR	NZ,.fail
	LD	A,RTL_ISR
	CALL	RTL_REG
	LD	A,(HL)
	BIT	1,A			; PTX
	JR	NZ,.ok
	AND	ISR_TXE
	RET	Z			; NTX_PENDING
	LD	(HL),ISR_TXE
	JR	.fail
.ok
	LD	(HL),ISR_PTX
	LD	A,NTX_OK
	RET
.fail
	RES	RF_TXFAIL,(IX+HS_RFLAGS)
	LD	A,NTX_ERROR
	RET
