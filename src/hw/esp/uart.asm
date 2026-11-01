; uart.asm -- SprinterESP card layer: TL16C550C bring-up and the UART pump.
;
; Register sequences follow sprinter_wifi/network/src/lib/esplib.asm
; (UART_INIT, RTS pause): only the knowledge is ported, the control flow is
; the non-blocking one of src/core/hwdrv.asm.  Polling only in v1: IER = 0.
;
; Byte path:  ESP -> UART RX FIFO -> (pump, any context) -> UART ring of
; ctx.hw_ring_ptr (512 bytes) -> (parser, main, src/core/esp) -> RX slots.
;             RX/TX slot or command buffer -> (pump, main only) -> THR.
; Flow control: TL16C550C auto-RTS (MCR AFE|RTS) drops RTS at the FIFO
; trigger level by itself; on top of that the pump drops RTS explicitly
; (and stops reading) while the parser is ER_PAUSE_AT bytes behind, and
; raises it again once the backlog is below ER_RESUME_AT.  The FIFO is reset once, at bring-up, before AFE is on:
; an FCR reset in a session leaves auto-RTS deasserted (esp_tcp_multi.asm
; 139-151).  MCR bits 2/3 (module RESET/PGM) are never set.
;
; Ring indices: ES_RH is written only by the pump, ES_RT only by the
; parser, both in STEP; the pump writes ES_RH after the data inside its DI
; portion.  The parser still reads ES_RH and writes ES_RT inside one short
; DI section (ER_HEAD / ER_SET_TAIL): a pump in STEP_ISR (a later profile)
; must not see half a u16.

COST_PREPARE	EQU	60	; NIC_PREPARE + bring-up deadline
COST_PUMP	EQU	165	; bracket + LSR + ring + RTS + up to ES_TX_MAX TX bytes (+ 4 per RX byte;
				; stand: real <= 0.73 of the old 185 + 4 * 12 reserve)

COST_BRINGUP	EQU	COST_PUMP + 4 * ES_RX_MAX	; table step, or a full pump in EUP_AT
COST_PORTION	EQU	90	; stop step
COST_STOP	EQU	COST_PORTION
	ASSERT	COST_PUMP + 4 < 256
BRINGUP_MS	EQU	5000	; UART + module set-up (AT retries, module boot)
	ASSERT	COST_BRINGUP <= PROF_MAX_ITEM_US && COST_PORTION <= PROF_MAX_ITEM_US

; UREG: HL = address of UART register A.  io_base is a multiple of 8
; (INIT_CONFIG), so the register number is ORed into the low byte.
; Clobbers A.
UREG
	OR	(IX+HS_IO)
	LD	L,A
	LD	H,(IX+HS_IO+1)
	RET

; ----------------------------------------------------------------------
; NIC_PREPARE (main, IX = hwsm): HS_IO and a clean pump state.
; ----------------------------------------------------------------------
NIC_PREPARE
	LD	L,(IY+CX_IO_BASE)
	LD	A,(IY+CX_IO_BASE+1)
	OR	0xC0
	LD	(IX+HS_IO),L
	LD	(IX+HS_IO+1),A
	XOR	A
	LD	(IX+HS_PHASE),A
	LD	(IX+ES_FLAGS),A
	LD	(IX+ES_RH),A
	LD	(IX+ES_RH+1),A
	LD	(IX+ES_RT),A
	LD	(IX+ES_RT+1),A
	LD	(IX+ES_TXN),A
	LD	(IX+ES_TXN+1),A
	LD	(IX+ES_TXKIND),A
	LD	(IX+ES_MCR),A
	RET

; ----------------------------------------------------------------------
; NIC_BRINGUP (P): EUP_PROBE -> EUP_INIT -> EUP_AT.  In EUP_AT the pump
; moves bytes while the sequencer (src/core/esp) sets the module up; the
; phase ends with its verdict.  Worst case: one full pump.
; ----------------------------------------------------------------------
NIC_BRINGUP
	LD	A,(IX+HS_PHASE)
	OR	A
	JR	Z,.probe
	DEC	A
	JR	Z,.init
	; EUP_AT
	LD	(IX+ES_RXMAX),ES_RX_MAX
	CALL	UART_PUMP
	LD	A,NBR_FAULT
	BIT	ESF_SETUP_BAD,(IX+ES_FLAGS)
	JR	NZ,.res
	LD	A,NBR_DONE
	BIT	ESF_SETUP_OK,(IX+ES_FLAGS)
	JR	NZ,.res
	LD	A,NBR_WAIT
.res
	LD	(IX+HS_RES),A
	RET
.probe
	; A 16550 reads IER bits 7..4 as 0 and keeps the scratch register;
	; an empty slot reads 0xFF.
	LD	A,U_IER
	CALL	UREG
	LD	A,(HL)
	AND	0xF0
	JR	NZ,.fault
	LD	A,U_SCR
	CALL	UREG
	LD	(HL),0x55
	LD	A,(HL)
	CP	0x55
	JR	NZ,.fault
	LD	(HL),0xAA
	LD	A,(HL)
	CP	0xAA
	JR	NZ,.fault
	LD	(IX+HS_PHASE),EUP_INIT
	LD	(IX+HS_RES),NBR_CONTINUE
	RET
.fault
	LD	(IX+HS_RES),NBR_FAULT
	RET
.init
	; IER = 0; divisor with DLAB; 8N1; FIFO on with both resets and the
	; configured RX trigger (the only FIFO reset of the session); auto flow.
	LD	A,U_IER
	CALL	UREG
	LD	(HL),0
	LD	A,U_LCR
	CALL	UREG
	LD	(HL),LCR_DLAB | LCR_8N1
	LD	A,U_DLL
	CALL	UREG
	LD	A,(IY+CX_UART_DIVISOR)
	LD	(HL),A
	INC	HL			; DLM
	LD	A,(IY+CX_UART_DIVISOR+1)
	LD	(HL),A
	LD	A,U_LCR
	CALL	UREG
	LD	(HL),LCR_8N1
	LD	A,(IY+CX_UART_RX_TRIGGER)	; 1, 4, 8 or 14 (INIT_CONFIG)
	LD	C,0x00
	CP	4
	JR	C,.trig
	LD	C,0x40
	CP	8
	JR	C,.trig
	LD	C,0x80
	CP	14
	JR	C,.trig
	LD	C,0xC0
.trig
	LD	A,U_FCR
	CALL	UREG
	LD	A,C
	OR	FCR_ENABLE | FCR_RX_RESET | FCR_TX_RESET
	LD	(HL),A
	LD	A,U_MCR
	CALL	UREG
	LD	(HL),MCR_RUN
	LD	(IX+ES_MCR),MCR_RUN
	SET	ESF_UP,(IX+ES_FLAGS)
	LD	(IX+HS_PHASE),EUP_AT
	LD	(IX+HS_RES),NBR_WAIT	; the first pump in the next STEP
	RET

; ----------------------------------------------------------------------
; NIC_STOP (P): interrupts off, RTS off (the module holds its output).
; The AT link of the module is left as it is: the next session starts
; with AT+CIPCLOSE=5.
; ----------------------------------------------------------------------
NIC_STOP
	RES	ESF_UP,(IX+ES_FLAGS)
	LD	A,U_IER
	CALL	UREG
	LD	(HL),0
	LD	A,U_MCR
	CALL	UREG
	LD	(HL),0
	LD	(IX+ES_MCR),0
	LD	(IX+HS_RES),NBR_DONE
	RET

; ----------------------------------------------------------------------
; UART_PUMP (P): one bounded exchange between the UART and the rings.
; In: ES_RXMAX = RX bytes allowed (1..ES_RX_MAX).  RX: up to that many
; bytes while LSR.DR, never more than the free ring space; TX (main only):
; up to ES_TX_MAX bytes of the TX stream when THR is empty.  LSR.OE sets
; ESF_OVERRUN (counted by the parser).  Clobbers A, BC, DE, HL.
; Cost: ~40 us + 5.3 us per RX byte + 2.2 us per TX byte (21 MHz).
; ----------------------------------------------------------------------
UART_PUMP
	STAT_INC UNETG_STATS_POLLS_TOTAL
	RES	ESF_GOT,(IX+ES_FLAGS)
	; backlog = (RH - RT) & ER_MASK: bytes the parser has not taken yet
	LD	L,(IX+ES_RH)
	LD	H,(IX+ES_RH+1)
	LD	E,(IX+ES_RT)
	LD	D,(IX+ES_RT+1)
	OR	A
	SBC	HL,DE
	LD	A,H
	AND	HIGH ER_MASK
	LD	H,A
	; explicit RX pause: RTS off while the parser is ER_PAUSE_AT behind,
	; on again below ER_RESUME_AT (auto-RTS also holds the module at the
	; FIFO trigger while the pump does not read)
	LD	DE,ER_PAUSE_AT
	BIT	ESF_RTSOFF,(IX+ES_FLAGS)
	JR	Z,.check
	LD	DE,ER_RESUME_AT
.check
	OR	A
	SBC	HL,DE			; CF: backlog < threshold
	LD	C,MCR_RUN
	JR	C,.below
	LD	C,MCR_PAUSE
.below
	LD	A,C
	CP	(IX+ES_MCR)
	JR	Z,.rts_same
	LD	(IX+ES_MCR),A
	RES	ESF_RTSOFF,(IX+ES_FLAGS)
	CP	MCR_RUN
	JR	Z,.rts_write
	SET	ESF_RTSOFF,(IX+ES_FLAGS)
.rts_write
	LD	A,U_MCR
	CALL	UREG
	LD	(HL),C
.rts_same
	; no RX while paused (the ring always has room then: 512 > pause level)
	LD	B,0
	BIT	ESF_RTSOFF,(IX+ES_FLAGS)
	JR	NZ,.free_ok
	LD	B,(IX+ES_RXMAX)
.free_ok
	LD	A,B
	OR	A
	JR	Z,.tx			; ring full: the bytes wait in the FIFO
	LD	HL,ER_SIZE
	LD	E,(IX+ES_RH)
	LD	D,(IX+ES_RH+1)
	OR	A
	SBC	HL,DE			; span to the ring end (1..512)
	LD	A,H
	OR	A
	JR	NZ,.span_ok
	LD	A,L
	CP	B
	JR	NC,.span_ok
	LD	B,A
.span_ok
	LD	L,(IY+CX_HW_RING_PTR)
	LD	H,(IY+CX_HW_RING_PTR+1)
	ADD	HL,DE
	EX	DE,HL			; DE = ring + RH
	LD	A,U_LSR
	CALL	UREG
	LD	C,L			; C = LSR low byte, H = register page
	PUSH	BC			; B = n
.rx
	LD	L,C
	LD	A,(HL)			; LSR
	BIT	1,A			; OE
	JR	NZ,.oe
.oe_back
	RRA				; DR -> CF
	JR	NC,.rx_end
	RES	0,L
	RES	2,L			; LSR (base+5) -> RBR (base+0)
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	DJNZ	.rx
.rx_end
	POP	AF			; A = n
	SUB	B			; A = bytes moved
	JR	Z,.tx
	SET	ESF_GOT,(IX+ES_FLAGS)
	ADD	A,(IX+ES_RH)
	LD	L,A
	LD	A,(IX+ES_RH+1)
	ADC	A,0
	AND	HIGH ER_MASK
	; publish the head after the data, both bytes inside this DI section
	LD	(IX+ES_RH),L
	LD	(IX+ES_RH+1),A
.tx
	LD	A,(IX+ES_TXN)
	OR	(IX+ES_TXN+1)
	RET	Z
	LD	A,U_LSR
	CALL	UREG
	LD	A,(HL)
	BIT	1,A
	JR	Z,.tx_no_oe
	SET	ESF_OVERRUN,(IX+ES_FLAGS)
.tx_no_oe
	AND	LSR_THRE		; THR + TX FIFO empty in FIFO mode
	RET	Z
	; B = min(TXN, ES_TX_MAX)
	LD	B,ES_TX_MAX
	LD	A,(IX+ES_TXN+1)
	OR	A
	JR	NZ,.tx_n
	LD	A,(IX+ES_TXN)
	CP	B
	JR	NC,.tx_n
	LD	B,A
.tx_n
	LD	C,B
	LD	A,U_THR
	CALL	UREG
	LD	E,(IX+ES_TXP)
	LD	D,(IX+ES_TXP+1)
.tx_loop
	LD	A,(DE)
	LD	(HL),A
	INC	DE
	DJNZ	.tx_loop
	LD	(IX+ES_TXP),E
	LD	(IX+ES_TXP+1),D
	LD	A,(IX+ES_TXN)
	SUB	C
	LD	(IX+ES_TXN),A
	RET	NC
	DEC	(IX+ES_TXN+1)
	RET
.oe
	SET	ESF_OVERRUN,(IX+ES_FLAGS)
	JR	.oe_back

; ----------------------------------------------------------------------
; HW_RUN (main): one pump sized by the budget.  Clobbers A, BC, DE, HL, IX.
; ----------------------------------------------------------------------
HW_RUN
	; RX paused and nothing to send: the budget goes to the parser, which
	; makes the room (the pump resumes once the backlog is low)
	BIT	ESF_RTSOFF,(IY+EX_FLAGS)
	JR	Z,.pump
	CALL	ER_HEAD			; HL = bytes waiting
	LD	DE,ER_RESUME_AT
	OR	A
	SBC	HL,DE
	JR	C,.pump
	LD	A,(IY+EX_TXN)
	OR	(IY+EX_TXN+1)
	JR	NZ,.pump
	SET	2,(IY+CX_WORK)		; UWK_MORE
	RET
.pump
	; not even one byte besides the fixed part: no sizing (a refused
	; attempt costs base time too)
	LD	A,(IY+CX_UNITS+1)
	OR	A
	JR	NZ,.size
	LD	A,(IY+CX_UNITS)
	CP	COST_PUMP + 4
	JR	NC,.size
	SET	4,(IY+CX_WORK)		; UWK_YIELD
	RET
.size
	LD	HL,COST_PUMP
	LD	A,2			; 4 units per RX byte
	LD	DE,ES_RX_MAX
	CALL	BUDGET_BYTES
	RET	C
	HWSM_IX
	LD	(IX+ES_RXMAX),C
	LD	HL,UART_PUMP
	CALL	RUN_PORTION
	RET	C
	HWSM_IX
	BIT	ESF_GOT,(IX+ES_FLAGS)
	JR	Z,.no_rx
	SET	0,(IY+CX_WORK)		; UWK_HW
.no_rx
	; bytes waiting in the ring or a TX stream in progress: call again soon
	LD	A,(IX+ES_TXN)
	OR	(IX+ES_TXN+1)
	JR	NZ,.more
	LD	A,(IX+ES_RH)
	CP	(IX+ES_RT)
	JR	NZ,.more
	LD	A,(IX+ES_RH+1)
	CP	(IX+ES_RT+1)
	RET	Z
.more
	SET	2,(IY+CX_WORK)		; UWK_MORE
	RET

; ----------------------------------------------------------------------
; ISRP_POLL: the STEP_ISR body of a running card (lock.asm ISR_PORTION;
; contract in engine.asm: IY only, CF=1 IDLE / CF=0 WORK, clobbers A, HL)
; -- a status sample: received bytes waiting in the FIFO set UPEND_RX and
; make STEP_ISR return WORK; STEP moves them.  Writes no per-call field.  (Moving the bytes here costs
; ~120 us besides the STEP_ISR base: it does not fit the 150 us STEP_ISR
; bound with the current core; the auto-RTS flow control holds the module
; meanwhile.)  No events, no TX.
; ----------------------------------------------------------------------
ISRP_POLL
	LD	A,(IY+EX_IO)
	OR	U_LSR			; io_base is a multiple of 8
	LD	L,A
	LD	H,(IY+EX_IO+1)
	LD	A,(HL)
	BIT	1,A
	JR	Z,.no_oe
	SET	ESF_OVERRUN,(IY+EX_ESFLAGS)
.no_oe
	RRA				; DR -> CF
	CCF				; CF=1: nothing received
	RET

; ----------------------------------------------------------------------
; Ring access for the parser (main).
; ----------------------------------------------------------------------

; ER_HEAD: HL = bytes waiting in the ring, DE = ring tail.  The head is
; read inside one DI section (the pump may run in STEP_ISR).
; Clobbers A, BC.
ER_HEAD
	IFF_SAVE_DI
	LD	L,(IY+EX_RH)
	LD	H,(IY+EX_RH+1)
	IFF_RESTORE_BC
	LD	E,(IY+EX_RT)
	LD	D,(IY+EX_RT+1)
	OR	A
	SBC	HL,DE
	LD	A,H
	AND	HIGH ER_MASK
	LD	H,A
	RET

; ER_SET_TAIL: ES_RT = HL (already masked), inside one DI section.
; Clobbers A, BC.
ER_SET_TAIL
	IFF_SAVE_DI
	LD	(IY+EX_RT),L
	LD	(IY+EX_RT+1),H
	IFF_RESTORE_BC
	RET
