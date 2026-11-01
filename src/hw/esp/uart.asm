; uart.asm -- SprinterESP card layer: TL16C550C bring-up and the UART pump.
;
; Register sequences follow sprinter_wifi/network/src/lib/esplib.asm
; (UART_INIT, RTS pause): only the knowledge is ported, the control flow is
; the non-blocking one of src/core/hwdrv.asm.  Polling only in v1: IER = 0.
;
; Byte path:  ESP -> UART RX FIFO -> (pump: main or STEP_ISR) -> UART ring of
; ctx.hw_ring_ptr (512 bytes) -> (parser, main, src/core/esp) -> RX slots.
;             RX/TX slot or command buffer -> (pump, main only) -> THR.
; Flow control: TL16C550C auto-RTS (MCR AFE|RTS) drops RTS at the FIFO
; trigger level by itself; on top of that the pump drops RTS explicitly
; (and stops reading) while the parser is ER_PAUSE_AT bytes behind, and
; raises it again once the backlog is below ER_RESUME_AT.  The FIFO is reset once, at bring-up, before AFE is on:
; an FCR reset in a session leaves auto-RTS deasserted (esp_tcp_multi.asm
; 139-151).  MCR bits 2/3 (module RESET/PGM) are never set.
;
; Ring indices: ES_RH is written by the two pumps (UART_PUMP in a STEP
; portion under DI, ISRP_POLL in STEP_ISR at IFF=0 -- never both at
; once), ES_RT only by the parser (main); a pump writes ES_RH after the
; data.  Every main-context read of ES_RH outside a portion goes through
; ER_HEAD (one short DI section) and the parser writes ES_RT through
; ER_SET_TAIL, so neither side ever sees half a u16.

COST_PREPARE	EQU	60	; NIC_PREPARE + bring-up deadline
; A portion including HW_RUN's own sizing wrapper (stand:
; tools/dev/esp_pump_calib.js, direct HW_RUN calls, 21 MHz) costs 184 us
; at 16 RX + 0 TX but 233 us at 16 RX + 16 TX: the two sides are not
; additive (the active-portion entry cost is shared) but a 16-byte RX
; share together with any TX at all already exceeds what 220 us
; (PROF_MAX_ITEM_US) can afford.  A portion that also drains a TX stream
; therefore caps its RX share at ES_RX_JOINT_MAX (stand: 6 RX + 16 TX
; 194 us, comfortably under 220 with the COST rule's margin); a portion
; with nothing to send keeps the full ES_RX_MAX (stand: 16 RX + 0 TX
; 184 us).  COST_PUMP_TX_ENTRY covers the fixed part of entering the TX
; side at all (THRE check, length clamp, UREG(THR)) on top of
; COST_PUMP_FIXED; both are then charged 4 us/RX byte, 2 us/TX byte.
COST_PUMP_FIXED	EQU	145
COST_PUMP_TX_ENTRY EQU	15
ES_RX_JOINT_MAX	EQU	6	; RX share of a portion that also sends

COST_BRINGUP	EQU	COST_PUMP_FIXED + 4 * ES_RX_JOINT_MAX + COST_PUMP_TX_ENTRY + 2 * ES_TX_MAX
	; = 216 us: the worse of the two NIC_BRINGUP/HW_RUN cases (see above)
COST_PORTION	EQU	90	; stop step
COST_STOP	EQU	COST_PORTION
	ASSERT	COST_PUMP_FIXED + 4 * ES_RX_MAX < 256
	ASSERT	COST_PUMP_FIXED + COST_PUMP_TX_ENTRY + 2 * ES_TX_MAX + 4 * ES_RX_JOINT_MAX < 256
BRINGUP_MS	EQU	5000	; UART + module set-up (AT retries, module boot)
	ASSERT	COST_BRINGUP <= PROF_MAX_ITEM_US && COST_PORTION <= PROF_MAX_ITEM_US

; ISRP_ENTRY_RESERVE / ISRP_RX_MAX: the ISR byte-mover's sizing (see
; ISRP_POLL below).  A STEP_ISR that drains n bytes costs 84.6 + 4.14 * n
; us in all (stand, FIFO held at 16, both builds), of which EXP_STEP_ISR's
; generic part (return + base + poll, 65) is already deducted from the
; leftover in ES_ISRCAP.  The cost rule (max(real * 1.1, real + 15)) over
; n <= ISRP_RX_MAX asks 65 + reserve + 4 * n >= 99.6 + 4.14 * n and
; >= 93.1 + 4.55 * n: reserve 40.  ISRP_RX_MAX keeps the body itself
; under 150 / 1.1 us at any budget (12 bytes: 134.3 us); auto-RTS holds
; the module at the FIFO trigger, so a drain rarely finds more anyway.
ISRP_ENTRY_RESERVE EQU	40
ISRP_RX_MAX	EQU	12
	ASSERT	ISRP_RX_MAX <= ES_RX_MAX

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
	; EUP_AT: the same RX/TX joint cap as HW_RUN (a portion that also
	; sends an AT command stays under PROF_MAX_ITEM_US only with a
	; smaller RX share; COST_BRINGUP covers both cases)
	LD	A,(IX+ES_TXN)
	OR	(IX+ES_TXN+1)
	LD	A,ES_RX_MAX
	JR	Z,.at_cap
	LD	A,ES_RX_JOINT_MAX
.at_cap
	LD	(IX+ES_RXMAX),A
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
; In: ES_RXMAX = RX bytes allowed (0..ES_RX_MAX).  RX: up to that many
; bytes while LSR.DR, never more than the free ring space; TX (main only):
; up to ES_TX_MAX bytes of the TX stream when THR is empty.  LSR.OE is
; read once, at the top of the portion (latched until read; the FIFO only
; shrinks during a drain, so a second OE cannot appear inside one): it
; sets ESF_OVERRUN (counted by the parser).  An idle portion (no DR, no
; TX stream, RTS already open) bails out before the ring/RTS arithmetic.
; Clobbers A, BC, DE, HL.
; Cost: COST_PUMP_FIXED us (idle: just the LSR read) + 4 us per RX byte +
; 2 us per TX byte reserved (21 MHz, stand).
; ----------------------------------------------------------------------
UART_PUMP
	STAT_INC UNETG_STATS_POLLS_TOTAL
	RES	ESF_GOT,(IX+ES_FLAGS)
	LD	A,U_LSR
	CALL	UREG
	LD	A,(HL)
	BIT	1,A			; OE
	JR	Z,.no_oe
	SET	ESF_OVERRUN,(IX+ES_FLAGS)
.no_oe
	LD	B,A			; B = LSR snapshot (DR used below)
	BIT	ESF_RTSOFF,(IX+ES_FLAGS)
	JR	NZ,.active		; paused: always re-check the backlog
	BIT	0,B			; DR
	JR	NZ,.active
	LD	A,(IX+ES_TXN)
	OR	(IX+ES_TXN+1)
	RET	Z			; idle: FIFO empty, RTS open, no TX pending
.active
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
	LD	C,0
	BIT	ESF_RTSOFF,(IX+ES_FLAGS)
	JR	NZ,.free_ok
	LD	C,(IX+ES_RXMAX)
.free_ok
	LD	A,C
	OR	A
	JR	Z,.tx			; ring full: the bytes wait in the FIFO
	BIT	0,B			; DR, from the snapshot at the top of the portion
	JR	Z,.tx
	LD	B,A
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
	RRA				; DR -> CF (OE already handled at the top)
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
	AND	LSR_THRE		; THR + TX FIFO empty in FIFO mode (OE already handled)
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

; ----------------------------------------------------------------------
; HW_RUN (main): one pump sized by the budget.  n_tx = min(EX_TXN,
; ES_TX_MAX); the RX share's ceiling is ES_RX_MAX when n_tx = 0 but only
; ES_RX_JOINT_MAX when the portion also sends (see COST_PUMP_FIXED):
; cap_rx = min(ceiling, (units - fixed) / 4), fixed = COST_PUMP_FIXED,
; +COST_PUMP_TX_ENTRY + 2 * n_tx when n_tx > 0.  A portion with cap_rx < 4
; and nothing to send is not worth running (a refused attempt still costs
; only base time); cap_rx < 4 with a TX stream pending runs a TX-only
; portion instead.  The reserve is flat (no refund for a
; smaller-than-asked RX drain: on the Z stand it bought nothing, and on
; the M stand it stalled a GUDPESP CIPSEND).  Clobbers A, BC, DE, HL, IX.
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
	; not even the cheapest portion fits (4 RX bytes, or 1 TX byte which
	; costs more): no sizing -- a refused attempt costs base time too
	LD	A,(IY+CX_UNITS+1)
	OR	A
	JR	NZ,.size
	LD	A,(IY+CX_UNITS)
	CP	COST_PUMP_FIXED + 4 * 4
	JP	C,.yield
.size
	; n_tx = min(EX_TXN, ES_TX_MAX)
	LD	B,ES_TX_MAX
	LD	A,(IY+EX_TXN+1)
	OR	A
	JR	NZ,.txn_capped
	LD	A,(IY+EX_TXN)
	CP	B
	JR	NC,.txn_capped
	LD	B,A
.txn_capped
	; ceiling = (n_tx > 0) ? ES_RX_JOINT_MAX : ES_RX_MAX
	LD	A,ES_RX_MAX
	LD	C,A
	LD	A,B
	OR	A
	JR	Z,.ceiling_set
	LD	C,ES_RX_JOINT_MAX
.ceiling_set
	; fixed = COST_PUMP_FIXED [+ COST_PUMP_TX_ENTRY + 2 * n_tx]
	LD	A,COST_PUMP_FIXED
	LD	E,A
	LD	A,B
	OR	A
	JR	Z,.no_tx_cost
	LD	A,B
	ADD	A,A
	ADD	A,COST_PUMP_TX_ENTRY
	ADD	A,E
	LD	E,A
.no_tx_cost
	LD	D,0
	; avail = units - fixed
	LD	L,(IY+CX_UNITS)
	LD	H,(IY+CX_UNITS+1)
	OR	A
	SBC	HL,DE
	JP	C,.yield
	; cap_rx = min(ceiling, avail / 4)
	SRL	H
	RR	L
	SRL	H
	RR	L			; HL = avail / 4
	LD	A,H
	OR	A
	JR	NZ,.clamp
	LD	A,C			; A = ceiling
	CP	L
	JR	NC,.use_l		; ceiling >= L: use L
	JR	.clamped		; ceiling < L: A already = ceiling
.clamp
	LD	A,C
	JR	.clamped
.use_l
	LD	A,L
.clamped
	CP	4
	JR	NC,.afford		; room for >= 4 RX bytes
	LD	C,A
	LD	A,B
	OR	C
	JP	Z,.yield		; no RX room and nothing to send either
	XOR	A			; a TX-only portion this time
.afford
	LD	C,A			; C = cap_rx (final)
	; cost = COST_PUMP_FIXED [+ COST_PUMP_TX_ENTRY + 2 * n_tx] + 4 * cap_rx
	LD	A,COST_PUMP_FIXED
	LD	E,A
	LD	A,B
	OR	A
	JR	Z,.cost_no_tx
	LD	A,B
	ADD	A,A
	ADD	A,COST_PUMP_TX_ENTRY
	ADD	A,E
	LD	E,A
.cost_no_tx
	LD	A,C
	ADD	A,A
	ADD	A,A
	ADD	A,E
	LD	L,A
	LD	H,0
	CALL	TAKE
	JP	C,.yield
	HWSM_IX
	LD	(IX+ES_RXMAX),C
	LD	HL,UART_PUMP
	CALL	RUN_PORTION
	JR	C,.busy
	HWSM_IX
	BIT	ESF_GOT,(IX+ES_FLAGS)
	JR	Z,.no_rx
	SET	0,(IY+CX_WORK)		; UWK_HW
.no_rx
	; bytes waiting in the ring or a TX stream in progress: call again soon.
	; RH/RT through ER_HEAD (DI): RUN_PORTION already restored interrupts
	; above, and ISRP_POLL (STEP_ISR) may now write ES_RH between here and
	; a raw two-byte read would tear.
	LD	A,(IX+ES_TXN)
	OR	(IX+ES_TXN+1)
	JR	NZ,.more
	CALL	ER_HEAD			; HL = backlog
	LD	A,H
	OR	L
	RET	Z
.more
	SET	2,(IY+CX_WORK)		; UWK_MORE
	RET
.busy
	RET				; BUS_BUSY already counted by RUN_PORTION
.yield
	SET	4,(IY+CX_WORK)		; UWK_YIELD
	RET

; ----------------------------------------------------------------------
; ISRP_POLL: the STEP_ISR body of a running card (lock.asm ISR_PORTION;
; contract in engine.asm: IY only, CF=1 IDLE / CF=0 WORK, clobbers A, HL,
; preserves BC, DE) -- received bytes waiting in the FIFO set UPEND_RX and
; make STEP_ISR return WORK; a byte-mover, bounded by the budget EXP_STEP_ISR
; (sched.asm) already converted to ES_ISRCAP, drains up to ISRP_RX_MAX of
; them straight into the ring (the same ring the main pump fills) so the
; main STEP needs less of its own 500-unit budget for RX; the rest (if
; any) still waits in the hardware FIFO for the next pump (main or ISR).
; Writes no per-call field, no events, no TX; never touches ES_RXMAX,
; ESF_GOT, ES_MCR/ESF_RTSOFF (RTS pause/resume stays the main pump's own
; call: the ring is 512 bytes vs a 64-byte pause threshold, so this can
; never make the ring itself overflow -- checked anyway, defensively,
; against both the ring tail and the ring end).
; Cost (whole STEP_ISR, stand): ~52 us (DR clear, or ES_ISRCAP too small
; to afford a byte), 84.6 + 4.14 us per RX byte moved otherwise.
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
	JR	C,.has_dr		; CF=0 here: nothing received
	SCF
	RET
.has_dr
	; cap = min(ISRP_RX_MAX, (ES_ISRCAP - ISRP_ENTRY_RESERVE) / 4).
	; ES_ISRCAP is EXP_STEP_ISR's generic leftover (budget - return - base
	; - poll, sched.asm); this routine's own entry (backlog/free/span,
	; re-deriving the LSR address) and the margin of the cost rule come on
	; top of it as ISRP_ENTRY_RESERVE before the first byte.
	LD	A,(IY+EX_ISRCAP)
	SUB	ISRP_ENTRY_RESERVE
	JR	NC,.afford		; not even one byte affordable: still WORK
	OR	A
	RET
.afford
	SRL	A
	SRL	A
	CP	ISRP_RX_MAX+1
	JR	C,.cap_ok
	LD	A,ISRP_RX_MAX
.cap_ok
	OR	A
	JR	Z,.work			; this call's ISR budget buys no byte: still WORK
	PUSH	BC
	PUSH	DE
	LD	B,A			; B = cap (1..ISRP_RX_MAX)
	; backlog = (RH-RT) & ER_MASK; free = ER_MASK - backlog (defensive:
	; the pause margin already makes this >= ES_RX_MAX in practice)
	LD	L,(IY+EX_RH)
	LD	H,(IY+EX_RH+1)
	LD	E,(IY+EX_RT)
	LD	D,(IY+EX_RT+1)
	OR	A
	SBC	HL,DE
	LD	A,H
	AND	HIGH ER_MASK
	LD	H,A
	LD	DE,ER_SIZE - 1		; ER_MASK
	EX	DE,HL
	OR	A
	SBC	HL,DE			; HL = free
	LD	A,H
	OR	A
	JR	NZ,.free_ok
	LD	A,L
	CP	B
	JR	NC,.free_ok
	LD	B,A
.free_ok
	LD	A,B
	OR	A
	JR	Z,.done			; no ring room: should not happen (pause margin)
	; span to the ring end (DE kept = RH for the address calc below)
	LD	HL,ER_SIZE
	LD	E,(IY+EX_RH)
	LD	D,(IY+EX_RH+1)
	OR	A
	SBC	HL,DE
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
	ADD	HL,DE			; DE = RH; ring + RH = write pointer
	EX	DE,HL			; DE = write pointer
	LD	A,(IY+EX_IO)
	OR	U_LSR
	LD	L,A
	LD	H,(IY+EX_IO+1)
	LD	C,L			; C = LSR/RBR low byte (H = fixed register page)
	PUSH	BC			; n (via the POP AF trick below), C unused here
.rx
	LD	L,C
	LD	A,(HL)			; LSR
	RRA				; DR -> CF
	JR	NC,.rx_end
	RES	0,L
	RES	2,L			; LSR (base+5) -> RBR (base+0)
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	DJNZ	.rx
.rx_end
	POP	AF			; A = n (original cap for this drain)
	SUB	B			; A = bytes actually moved
	JR	Z,.done
	ADD	A,(IY+EX_RH)
	LD	L,A
	LD	A,(IY+EX_RH+1)
	ADC	A,0
	AND	HIGH ER_MASK
	LD	(IY+EX_RH),L
	LD	(IY+EX_RH+1),A		; publish the new head (IFF=0: a plain write)
	STAT_INC UNETG_STATS_POLLS_USEFUL
.done
	POP	DE
	POP	BC
.work
	OR	A			; CF=0: WORK
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
