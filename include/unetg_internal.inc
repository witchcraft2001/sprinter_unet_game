; unetg_internal.inc -- core-internal constants and macros (not public ABI).

	IFNDEF	_UNETG_INTERNAL_INC
	DEFINE	_UNETG_INTERNAL_INC

; INIT_CONFIG is addressed as IX = block + CFGB so that every field of the
; 134-byte block is reachable with a signed 8-bit displacement.
CFGB		EQU	64

; Channel states (UCTX.chan)
UCH_CLOSED	EQU	0
UCH_OPENING	EQU	1
UCH_OPEN	EQU	2
UCH_CLOSING	EQU	3

; TX slot states (UCTX.tx_state[]).  DONE_* = outcome known, TX_DONE not
; yet published; the slot becomes FREE only when the event is in the queue.
UTX_FREE	EQU	0
UTX_RESERVED	EQU	1
UTX_COMMITTED	EQU	2	; waiting for the transport
UTX_SENDING	EQU	3	; handed to the transport (bytes may be in flight)
UTX_DONE_OK	EQU	4 + UNETG_TXDONE_OK
UTX_DONE_CANCEL	EQU	4 + UNETG_TXDONE_CANCEL
UTX_DONE_FAILED	EQU	4 + UNETG_TXDONE_FAILED
UTX_DONE_FIRST	EQU	UTX_DONE_OK

; RX slot states (UCTX.rx_state[])
URX_FREE	EQU	0
URX_FILLING	EQU	1
URX_READY	EQU	2
URX_PEEKED	EQU	3

; UCTX.clk_flags
UCLK_HAVE_LAST	EQU	0x01	; last_useful_ms is valid
UCLK_T0_SET	EQU	0x02	; SHUTDOWN t0 recorded
UCLK_EXPIRED	EQU	0x04	; CONFIG_EXPIRED already raised
UCLK_OP_ARMED	EQU	0x08	; op_deadline_ms is valid
UCLK_OP_ARM	EQU	0x10	; arm op_deadline_ms at the next STEP
UCLK_FAULT_SEEN	EQU	0x20	; DEVICE_FAULT of the last stop attempt reported

; UCTX.tmr_flags
UTMR_VALID	EQU	0x01	; tmr_due holds the earliest deadline
UTMR_NONE	EQU	0x02	; valid and no protocol deadline is armed
UTMR_DUE	EQU	0x04	; this STEP re-evaluates the timers
UTMR_AGAIN	EQU	0x08	; evaluation incomplete: keep the cache invalid
UTMR_TPDUE	EQU	0x10	; the transport still owes its timer evaluation

; TMR_INVALIDATE: a deadline was armed or a timer state changed; also
; marks an evaluation that could not finish in this STEP.
	MACRO	TMR_INVALIDATE
	LD	A,(IY+CX_TMR_FLAGS)
	AND	~UTMR_VALID & 0xFF
	OR	UTMR_AGAIN
	LD	(IY+CX_TMR_FLAGS),A
	ENDM

; UCTX.call_flags (valid during one export call)
UCF_PREACQ	EQU	0x01	; gateway holds the ISA lock for this portion
UCF_ISR		EQU	0x02	; inside STEP_ISR
UCF_ISA_HELD	EQU	0x04	; the core took the ISA lock itself
UCF_BUDGET	EQU	0x08	; budgeted call (STEP): publication costs are taken

; UCTX.ev_flags -- notifications waiting for room in the event queue
UEVF_CONNECTED	EQU	0x01
UEVF_REASON	EQU	0x02	; ev_reason / ev_reason_detail
UEVF_RXR_PEND	EQU	0x04	; RX went empty -> non-empty
UEVF_RXR_QUEUED	EQU	0x08	; an RX_READY is in the queue, not yet read
UEVF_MODE	EQU	0x10	; MODE_CHANGED (detail = fallback_reason)
UEVF_EXPIRED	EQU	0x20	; CONFIG_EXPIRED
UEVF_CLOSED	EQU	0x40	; CLOSED once TX outcomes and RX are drained
UEVF_TXDONE	EQU	0x80	; some TX slot is DONE_* and not yet published

; UCTX.chan_flags
UCHF_ABORTED	EQU	0x01	; RX discarded, nothing more is sent
UCHF_FINISHED	EQU	0x02	; transport is done, waiting for CLOSED
UCHF_WINUPD	EQU	0x04	; RX space freed: transport should update its window

; UCTX.hw_state
UHW_DOWN	EQU	0	; card not touched yet
UHW_INIT	EQU	1	; bring-up in progress (hwsm sub-state)
UHW_RUN		EQU	2
UHW_STOP	EQU	3	; SHUTDOWN: stopping the card
UHW_STOPPED	EQU	4	; safe state confirmed
UHW_FAULT	EQU	5

; UCTX.isr_pending bits (set by STEP_ISR, consumed by STEP)
UPEND_RX	EQU	0
UPEND_TX	EQU	1
UPEND_ERR	EQU	2
UPEND_POLLED	EQU	3	; STEP_ISR sampled the card since the last STEP

; UCTX.work bits (what the current STEP achieved)
UWK_HW		EQU	0x01
UWK_PROTO	EQU	0x02
UWK_MORE	EQU	0x04	; work remains: return WORK
UWK_BUSY	EQU	0x08	; ISA busy blocked hardware work
UWK_YIELD	EQU	0x10	; budget ran out with work remaining

; Context guard byte value checked by the stand.
UCTX_GUARD_BYTE	EQU	0xA5

; Minimum stack the caller must leave free below its SP at INIT_CONFIG:
; main exports alone, or main + nested network ISR on the same stack.
STACK_NEED_MAIN	EQU	UNETG_STACK_MAIN_MAX
STACK_NEED_SHARED	EQU	UNETG_STACK_MAIN_MAX + UNETG_STACK_ISR_MAX + 64
STACK_NEED_ISR	EQU	UNETG_STACK_ISR_MAX + 64

; ---------------------------------------------------------------------
; IFF_SAVE_DI: sample IFF2 (twice, Z80 LD A,I erratum), push it as F
; (P/V = IFF2) and disable interrupts.  Clobbers A, F.  Pair with
; IFF_RESTORE_HL, which pops it into HL and re-enables only if it was on.
; Inside STEP_ISR IFF2 is 0, so the pair never executes EI there.
; ---------------------------------------------------------------------
	MACRO	IFF_SAVE_DI
	LD	A,I
	JP	PE,1F
	LD	A,I
1
	PUSH	AF
	DI
	ENDM

	MACRO	IFF_RESTORE_HL
	POP	HL
	BIT	2,L
	JR	Z,1F
	EI
1
	ENDM
	MACRO	IFF_RESTORE_BC
	POP	BC
	BIT	2,C
	JR	Z,1F
	EI
1
	ENDM

; LDCFG16 reg-pair low, high, field: read a u16 INIT_CONFIG field (IX=cfg+CFGB)
; TX_SET_DONE: (HL) = outcome state A, and tell EV_FLUSH to scan the slots.
	MACRO	TX_SET_DONE
	LD	(HL),A
	SET	7,(IY+CX_EV_FLAGS)
	ENDM

	MACRO	LDCFG_HL field
	LD	L,(IX+field-CFGB)
	LD	H,(IX+field-CFGB+1)
	ENDM
	MACRO	LDCFG_DE field
	LD	E,(IX+field-CFGB)
	LD	D,(IX+field-CFGB+1)
	ENDM

	ENDIF
