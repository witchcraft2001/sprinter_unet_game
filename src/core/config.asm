; config.asm -- INIT_CONFIG (export 2).
;
; In:  IX = INIT_CONFIG block (UNETG_CFG_*).
; Out: A = OK, BAD_CONFIG, UNSUPPORTED_TIMING or STATE (a context is
;      already active: SHUTDOWN must reach OK first).
; The card is never touched here: hardware bring-up is a state of STEP.
; Every BAD_CONFIG check runs before any UNSUPPORTED_TIMING check, and the
; context is written only after all checks have passed.
; Stack: 2 (ret) + 4 (IX,IY) + 2 (entry SP) + 44 (region table) + 6 (calls).

CFG_NREG	EQU	11		; regions validated below
CFG_FRAME	EQU	4 * CFG_NREG + 2	; table + saved entry SP
CFG_SPE		EQU	4 * CFG_NREG	; IY offset of the saved entry SP

; Region table indices (4 bytes each: start u16, last u16; empty = FFFF,0000)
RG_CTX		EQU	0
RG_TX		EQU	1
RG_RX		EQU	2
RG_EV		EQU	3
RG_RING		EQU	4
RG_LOCK		EQU	5
RG_SH1FFD	EQU	6
RG_SH9FBD	EQU	7
RG_GW		EQU	8
RG_MSTACK	EQU	9
RG_ISTACK	EQU	10
RG_CORE_OWNED	EQU	5		; indices 0..4 may not overlap anything

; Store BC = start, DE = last into region entry k.
	MACRO	REGSTORE k
	LD	(IY+4*k),C
	LD	(IY+4*k+1),B
	LD	(IY+4*k+2),E
	LD	(IY+4*k+3),D
	ENDM

; CF=1 (-> CFG_BAD) when the region just computed (BC = start) is empty.
	MACRO	REQUIRE_NONEMPTY
	LD	A,B
	AND	C
	INC	A
	JP	Z,CFG_BAD
	ENDM

; Jump to CFG_BAD when the u16 field is zero.
	MACRO	REQUIRE_NZ16 field
	LD	A,(IX+field-CFGB)
	OR	(IX+field-CFGB+1)
	JP	Z,CFG_BAD
	ENDM

EXP_INIT_CONFIG
	PUSH	IX
	PUSH	IY
	LD	HL,4
	ADD	HL,SP			; caller SP = address of our return address
	PUSH	HL
	LD	HL,-4 * CFG_NREG
	ADD	HL,SP
	LD	SP,HL
	PUSH	HL
	POP	IY			; IY = region table (frame base)

	LD	HL,(IMG_CTX_PTR)
	LD	A,H
	OR	L
	LD	A,UNETG_STATUS_STATE
	JP	NZ,CFG_EXIT

	; --- block header: version first, then the declared size -------------
	PUSH	IX
	POP	HL
	LD	DE,4
	CALL	RANGE
	JP	C,CFG_BAD
	LD	A,(IX+UNETG_CFG_ABI_VERSION+1)	; major (little-endian u16)
	CP	UNETG_ABI_MAJOR
	JP	NZ,CFG_BAD
	LD	E,(IX+UNETG_CFG_SIZE)
	LD	D,(IX+UNETG_CFG_SIZE+1)
	LD	HL,UNETG_CFG_BYTES - 1
	OR	A
	SBC	HL,DE			; CF <=> size >= required v1.0 prefix
	JP	NC,CFG_BAD
	PUSH	IX
	POP	HL
	CALL	RANGE			; the whole declared block is addressable
	JP	C,CFG_BAD
	LD	DE,CFGB
	ADD	IX,DE			; IX = block + CFGB from here on

	; --- profile selection --------------------------------------------------
	LD	A,(IX+UNETG_CFG_HW_PROFILE-CFGB)
	CP	PROF_HW
	JP	NZ,CFG_BAD
	LD	A,(IX+UNETG_CFG_TRANSPORT-CFGB)
	IFDEF	UGB_TP_ANY
	DEC	A
	CP	2
	JP	NC,CFG_BAD
	ELSE
	IFDEF	UGB_TP_TCP
	CP	UNETG_TRANSPORT_TCP
	ELSE
	CP	UNETG_TRANSPORT_UDP
	ENDIF
	JP	NZ,CFG_BAD
	ENDIF
	LD	A,(IX+UNETG_CFG_MODE-CFGB)
	DEC	A
	CP	2			; POLL or AUTO
	JP	NC,CFG_BAD
	LD	A,(IX+UNETG_CFG_TIMING_MODE-CFGB)
	DEC	A
	CP	2
	JP	NC,CFG_BAD
	LD	A,(IX+UNETG_CFG_FLAGS-CFGB)
	AND	~(UNETG_CFGF_HAS_EXPIRY | UNETG_CFGF_ALLOW_PROBE | UNETG_CFGF_CBL_QUALIFIED | UNETG_CFGF_FLOW_VERIFIED) & 0xFF
	JP	NZ,CFG_BAD
	LD	A,(IX+UNETG_CFG_RESERVED0-CFGB)
	OR	(IX+UNETG_CFG_RESERVED1-CFGB)
	OR	(IX+UNETG_CFG_ROUTE_FLAGS-CFGB)
	JP	NZ,CFG_BAD
	LDCFG_HL UNETG_CFG_CPU_KHZ
	LD	DE,3500
	OR	A
	SBC	HL,DE
	JP	C,CFG_BAD
	LD	DE,28000 - 3500 + 1
	SBC	HL,DE			; CF=0 here
	JP	NC,CFG_BAD

	; --- card addressing ---------------------------------------------------
	IFNDEF	UGB_HW_LOOP
	LD	A,(IX+UNETG_CFG_ISA_SLOT-CFGB)
	CP	2
	JP	NC,CFG_BAD
	LDCFG_HL UNETG_CFG_IO_BASE
	LD	A,H
	OR	L
	JP	Z,CFG_BAD
	LD	A,L
	AND	PROF_IO_MASK & 0xFF
	JP	NZ,CFG_BAD
	LD	A,H
	CP	0x40			; ISA I/O window is 14 bits wide
	JP	NC,CFG_BAD
	ENDIF
	IFDEF	UGB_HW_EL3
	LD	A,(IX+UNETG_CFG_ID_PORT+1-CFGB)
	DEC	A			; ID port 0x100..0x1F0
	JP	NZ,CFG_BAD
	LD	A,(IX+UNETG_CFG_ID_PORT-CFGB)
	AND	0x0F
	JP	NZ,CFG_BAD
	ENDIF
	IFDEF	UGB_HW_ETH
	LD	A,(IX+UNETG_CFG_LOCAL_IP-CFGB)
	OR	(IX+UNETG_CFG_LOCAL_IP+1-CFGB)
	OR	(IX+UNETG_CFG_LOCAL_IP+2-CFGB)
	OR	(IX+UNETG_CFG_LOCAL_IP+3-CFGB)
	JP	Z,CFG_BAD
	LDCFG_HL UNETG_CFG_ARP_TTL_MS
	LD	DE,1000
	OR	A
	SBC	HL,DE
	JP	C,CFG_BAD
	ENDIF
	IFDEF	UGB_HW_ESP
	REQUIRE_NZ16 UNETG_CFG_UART_DIVISOR
	LD	A,(IX+UNETG_CFG_ESP_FW-CFGB)
	CP	1			; only the ESP-AT 2.2.2 passive-TCP profile
	JP	NZ,CFG_BAD
	LD	A,(IX+UNETG_CFG_UART_RX_TRIGGER-CFGB)
	CP	1
	JR	Z,.trig_ok
	CP	4
	JR	Z,.trig_ok
	CP	8
	JR	Z,.trig_ok
	CP	14
	JP	NZ,CFG_BAD
.trig_ok
	ENDIF
	LD	A,(IX+UNETG_CFG_ROUTE_PRESENT-CFGB)
	OR	A
	JR	Z,.route_ok
	LD	A,(IX+UNETG_CFG_ROUTE_PIO_BIT-CFGB)
	CP	2
	JP	NC,CFG_BAD
	LD	A,(IX+UNETG_CFG_ROUTE_VECTOR-CFGB)
	RRCA				; IM2 vectors are even
	JP	C,CFG_BAD
.route_ok

	; --- protocol timers ----------------------------------------------------
	LD	A,(IX+UNETG_CFG_RETRY_COUNT-CFGB)
	CP	8
	JP	NC,CFG_BAD
	INC	A
	LD	B,A			; schedule length = retry_count + 1
	PUSH	IX
	POP	HL
	LD	DE,UNETG_CFG_RETRY_WAIT_MS - CFGB
	ADD	HL,DE
.retry
	LD	A,(HL)
	INC	HL
	OR	(HL)
	INC	HL
	JP	Z,CFG_BAD		; every interval must be positive
	DJNZ	.retry
	REQUIRE_NZ16 UNETG_CFG_CONNECT_TIMEOUT_MS
	REQUIRE_NZ16 UNETG_CFG_SEND_STALL_TIMEOUT_MS
	REQUIRE_NZ16 UNETG_CFG_CLOSE_TIMEOUT_MS

	; --- slots and events ---------------------------------------------------
	LD	A,(IX+UNETG_CFG_TX_SLOT_COUNT-CFGB)
	CALL	SLOT_COUNT_OK
	JP	C,CFG_BAD
	LD	A,(IX+UNETG_CFG_RX_SLOT_COUNT-CFGB)
	CALL	SLOT_COUNT_OK
	JP	C,CFG_BAD
	CALL	CFG_PAYLOAD		; DE = payload limit of the configured transport
	LDCFG_HL UNETG_CFG_TX_SLOT_SIZE
	OR	A
	SBC	HL,DE
	JP	C,CFG_BAD
	LDCFG_HL UNETG_CFG_RX_SLOT_SIZE
	OR	A
	SBC	HL,DE
	JP	C,CFG_BAD
	LD	A,(IX+UNETG_CFG_EVENT_CAP-CFGB)
	LD	B,A
	DEC	A
	AND	B			; power of two <=> cap & (cap-1) == 0
	JP	NZ,CFG_BAD
	LD	A,B
	CP	128 + 1
	JP	NC,CFG_BAD
	LD	A,(IX+UNETG_CFG_TX_SLOT_COUNT-CFGB)
	ADD	A,UNETG_EVENT_EXTRA + 1	; useful entries + sentinel
	DEC	A
	CP	B			; need cap > tx + EXTRA
	JP	NC,CFG_BAD

	; --- memory regions -----------------------------------------------------
	LDCFG_HL UNETG_CFG_CTX_LEN
	LD	DE,UCTX_BYTES
	OR	A
	SBC	HL,DE
	JP	C,CFG_BAD
	LDCFG_HL UNETG_CFG_CTX_PTR
	LDCFG_DE UNETG_CFG_CTX_LEN
	CALL	RANGE
	JP	C,CFG_BAD
	REQUIRE_NONEMPTY
	REGSTORE RG_CTX

	LD	A,(IX+UNETG_CFG_TX_SLOT_COUNT-CFGB)
	LDCFG_DE UNETG_CFG_TX_SLOT_SIZE
	CALL	MUL8
	JP	C,CFG_BAD
	EX	DE,HL
	LDCFG_HL UNETG_CFG_TX_SLOTS_PTR
	CALL	RANGE
	JP	C,CFG_BAD
	REQUIRE_NONEMPTY
	REGSTORE RG_TX

	LD	A,(IX+UNETG_CFG_RX_SLOT_COUNT-CFGB)
	LDCFG_DE UNETG_CFG_RX_SLOT_SIZE
	CALL	MUL8
	JP	C,CFG_BAD
	EX	DE,HL
	LDCFG_HL UNETG_CFG_RX_SLOTS_PTR
	CALL	RANGE
	JP	C,CFG_BAD
	REQUIRE_NONEMPTY
	REGSTORE RG_RX

	LD	A,(IX+UNETG_CFG_EVENT_CAP-CFGB)
	LD	DE,UNETG_EVENT_SIZE
	CALL	MUL8
	EX	DE,HL
	LDCFG_HL UNETG_CFG_EVENT_PTR
	CALL	RANGE
	JP	C,CFG_BAD
	REQUIRE_NONEMPTY
	REGSTORE RG_EV

	LDCFG_HL UNETG_CFG_HW_RING_PTR
	LDCFG_DE UNETG_CFG_HW_RING_LEN
	IFDEF	UGB_HW_ESP
	PUSH	HL
	LD	HL,PROF_HW_RING_MIN - 1
	OR	A
	SBC	HL,DE			; CF <=> len >= minimum
	POP	HL
	JP	NC,CFG_BAD
	ELSE
	LD	A,D
	OR	E
	JP	NZ,CFG_BAD		; no software ring on this card
	ENDIF
	CALL	RANGE
	JP	C,CFG_BAD
	IFDEF	UGB_HW_ESP
	REQUIRE_NONEMPTY		; the UART ring is mandatory: ptr 0 is no ring
	ENDIF
	REGSTORE RG_RING

	LDCFG_HL UNETG_CFG_ISA_LOCK_PTR
	CALL	RANGE1
	IFNDEF	UGB_HW_LOOP
	REQUIRE_NONEMPTY
	ENDIF
	REGSTORE RG_LOCK
	LDCFG_HL UNETG_CFG_SHADOW_1FFD_PTR
	CALL	RANGE1
	IFNDEF	UGB_HW_LOOP
	REQUIRE_NONEMPTY
	ENDIF
	REGSTORE RG_SH1FFD
	LDCFG_HL UNETG_CFG_SHADOW_9FBD_PTR
	CALL	RANGE1
	IFNDEF	UGB_HW_LOOP
	REQUIRE_NONEMPTY
	ENDIF
	REGSTORE RG_SH9FBD

	LDCFG_HL UNETG_CFG_GW_PTR
	LDCFG_DE UNETG_CFG_GW_LEN
	CALL	RANGE
	JP	C,CFG_BAD
	REGSTORE RG_GW

	LDCFG_HL UNETG_CFG_MAIN_STACK_PTR
	LDCFG_DE UNETG_CFG_MAIN_STACK_LEN
	CALL	RANGE
	JP	C,CFG_BAD
	REQUIRE_NONEMPTY
	REGSTORE RG_MSTACK

	LDCFG_HL UNETG_CFG_ISR_STACK_PTR
	LDCFG_DE UNETG_CFG_ISR_STACK_LEN
	CALL	RANGE
	JP	C,CFG_BAD
	REGSTORE RG_ISTACK

	CALL	CFG_REGIONS_OK
	JP	C,CFG_BAD
	CALL	CFG_STACKS_OK
	JP	C,CFG_BAD

	; --- guarantees of the platform (UNSUPPORTED_TIMING) ---------------------
	LDCFG_HL UNETG_CFG_WORST_POLL_GAP_US
	LD	DE,PROF_POLL_GAP_US
	CALL	IN_1_TO_DE
	JP	C,CFG_TIMING
	LDCFG_HL UNETG_CFG_WORST_STEP_GAP_MS
	LD	DE,PROF_MAX_STEP_GAP_MS
	CALL	IN_1_TO_DE
	JP	C,CFG_TIMING
	LDCFG_HL UNETG_CFG_STEP_BUDGET_US
	LD	DE,PROF_MIN_USEFUL_US
	CALL	BUDGET_OK
	JP	C,CFG_TIMING
	LDCFG_HL UNETG_CFG_ISR_BUDGET_US
	LD	A,H
	OR	L
	JR	Z,.isr_budget_ok	; 0 = no STEP_ISR entries
	LD	DE,PROF_ISR_MIN_US
	CALL	BUDGET_OK
	JP	C,CFG_TIMING
	LD	DE,UNETG_ISR_BODY_MAX_US + 1
	OR	A
	SBC	HL,DE
	JP	NC,CFG_TIMING
.isr_budget_ok
	LD	A,(IX+UNETG_CFG_TIMING_MODE-CFGB)
	CP	UNETG_TIMING_APP_COUNTER
	JR	NZ,.time_ok
	LDCFG_HL UNETG_CFG_TIME_READ_COST_US
	LD	DE,PROF_TIME_READ_MAX_US + 1
	OR	A
	SBC	HL,DE
	JP	NC,CFG_TIMING
.time_ok
	IFDEF	UGB_HW_ESP
	; 115200 baud fills the 16-byte FIFO in 1.39 ms: without verified
	; RTS/CTS on both sides no POLL interval of this profile is safe.
	LD	A,(IX+UNETG_CFG_FLAGS-CFGB)
	AND	UNETG_CFGF_FLOW_VERIFIED
	JP	Z,CFG_TIMING
	LD	A,(IX+UNETG_CFG_UART_FLOW-CFGB)
	CP	1
	JP	NZ,CFG_TIMING
	LD	A,(IX+UNETG_CFG_ESP_FLOW-CFGB)
	CP	3
	JP	NZ,CFG_TIMING
	ENDIF

	; --- commit -------------------------------------------------------------
	CALL	CFG_COMMIT
	XOR	A
	JR	CFG_EXIT
CFG_TIMING
	LD	A,UNETG_STATUS_UNSUPPORTED_TIMING
	JR	CFG_EXIT
CFG_BAD
	LD	A,UNETG_STATUS_BAD_CONFIG
CFG_EXIT
	LD	HL,CFG_FRAME
	ADD	HL,SP
	LD	SP,HL
	POP	IY
	POP	IX
	RET

; ----------------------------------------------------------------------
; RANGE: HL = start, DE = length -> BC = start, DE = last.
; A region with start 0 or length 0 is empty: BC = 0xFFFF, DE = 0.
; Out: CF=1 when start + length > 0x10000 (17-bit arithmetic).
; Clobbers A, HL.
; ----------------------------------------------------------------------
RANGE1
	LD	DE,1
RANGE
	LD	A,H
	OR	L
	JR	Z,.empty
	LD	A,D
	OR	E
	JR	Z,.empty
	LD	B,H
	LD	C,L
	ADD	HL,DE
	JR	NC,.ok
	LD	A,H
	OR	L			; exactly 0x10000 is still addressable
	JR	Z,.ok
	SCF
	RET
.ok
	DEC	HL
	EX	DE,HL
	OR	A
	RET
.empty
	LD	BC,0xFFFF
	LD	DE,0
	OR	A
	RET

; MUL8: HL = A * DE, CF=1 on 16-bit overflow.  Clobbers B.
MUL8
	LD	HL,0
	OR	A
	RET	Z
	LD	B,A
.loop
	ADD	HL,DE
	RET	C
	DJNZ	.loop
	RET

; SLOT_COUNT_OK: CF=1 unless SLOTS_MIN <= A <= UCTX_MAX_SLOTS.
SLOT_COUNT_OK
	CP	UNETG_SLOTS_MIN
	RET	C
	CP	UCTX_MAX_SLOTS + 1
	CCF
	RET

; CFG_PAYLOAD: DE = payload limit of the configured transport.
CFG_PAYLOAD
	LD	DE,UNETG_TCP_MSS
	LD	A,(IX+UNETG_CFG_TRANSPORT-CFGB)
	CP	UNETG_TRANSPORT_UDP
	RET	NZ
	LD	DE,UNETG_UDP_MAX
	RET

; IN_1_TO_DE: CF=1 unless 1 <= HL <= DE.  Clobbers HL.
IN_1_TO_DE
	LD	A,H
	OR	L
	SCF
	RET	Z
	EX	DE,HL
	OR	A
	SBC	HL,DE			; DE_limit - value
	RET

; BUDGET_OK: CF=1 unless the budget HL (real microseconds) buys at least
; DE units at the configured clock and HL <= STEP_BODY_MAX_US.
; HL preserved.  Clobbers A, BC, DE.
BUDGET_OK
	PUSH	HL
	PUSH	DE			; minimum units
	PUSH	HL
	CALL	CFG_F16
	POP	DE
	CALL	MUL_F16			; HL = units bought by the budget
	POP	DE
	OR	A
	SBC	HL,DE
	JR	C,.out
	POP	HL
	PUSH	HL
	LD	DE,UNETG_STEP_BODY_MAX_US + 1
	OR	A
	SBC	HL,DE
	CCF
.out
	POP	HL
	RET

; ----------------------------------------------------------------------
; CFG_REGIONS_OK: forbidden zones and pairwise overlaps of the table at IY.
; Core-owned regions (ctx, slots, events, ring) may not overlap any other
; region; the two stacks may not overlap each other.  Gateway-owned bytes
; (lock, shadows) may live inside the gateway region.  Out: CF=1 on error.
; ----------------------------------------------------------------------
CFG_REGIONS_OK
	PUSH	IY
	POP	HL
	LD	B,CFG_NREG
.zone
	PUSH	BC
	LD	C,(HL)
	INC	HL
	LD	B,(HL)
	INC	HL
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	INC	HL
	LD	A,B
	AND	C
	INC	A
	JR	Z,.zone_next		; empty region
	LD	A,D
	CP	0xC0			; ISA window 0xC000..0xFFFF
	JR	NC,.zone_bad
	PUSH	HL
	LD	HL,IMG_ORIGIN		; our own 16 KiB window may be paged out
	LD	A,H
	AND	0xC0
	LD	L,A			; first page byte of the window
	ADD	A,0x3F
	LD	H,A			; last page byte of the window
	LD	A,H
	CP	B
	JR	C,.zone_clear		; window ends before the region
	LD	A,D
	CP	L
	JR	C,.zone_clear		; region ends before the window
	POP	HL
.zone_bad
	POP	BC
	SCF
	RET
.zone_clear
	POP	HL
.zone_next
	POP	BC
	DJNZ	.zone

	PUSH	IY
	POP	HL			; HL -> region i
	LD	B,RG_CORE_OWNED
.outer
	PUSH	BC
	LD	A,B
	ADD	A,CFG_NREG - RG_CORE_OWNED - 1
	LD	C,A			; number of regions after i
	LD	D,H
	LD	E,L
.inner
	INC	DE
	INC	DE
	INC	DE
	INC	DE
	CALL	OVERLAP
	JR	C,.pair_bad
	DEC	C
	JR	NZ,.inner
	INC	HL
	INC	HL
	INC	HL
	INC	HL
	POP	BC
	DJNZ	.outer
	PUSH	IY
	POP	HL
	LD	DE,4 * RG_MSTACK
	ADD	HL,DE
	LD	D,H
	LD	E,L
	INC	DE
	INC	DE
	INC	DE
	INC	DE			; DE -> RG_ISTACK
	JP	OVERLAP
.pair_bad
	POP	BC
	RET

; OVERLAP: HL -> region a, DE -> region b.  CF=1 when they intersect.
; Empty regions (FFFF,0000) never intersect.  Preserves HL, DE, C.
OVERLAP
	PUSH	BC
	PUSH	HL
	PUSH	DE
	LD	C,(HL)
	INC	HL
	LD	B,(HL)			; BC = a.start
	INC	HL			; HL -> a.last
	EX	DE,HL			; HL -> b, DE -> a.last
	INC	HL
	INC	HL
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A			; HL = b.last
	OR	A
	SBC	HL,BC			; b.last < a.start -> disjoint
	JR	C,.disjoint
	POP	HL
	PUSH	HL			; HL -> b
	LD	C,(HL)
	INC	HL
	LD	B,(HL)			; BC = b.start
	EX	DE,HL			; HL -> a.last
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A			; HL = a.last
	OR	A
	SBC	HL,BC			; a.last < b.start -> disjoint
	JR	C,.disjoint
	SCF
	JR	.done
.disjoint
	OR	A
.done
	POP	DE
	POP	HL
	POP	BC
	RET

; ----------------------------------------------------------------------
; CFG_STACKS_OK: the caller's SP and return address lie inside the main
; stack region with enough room below it; a separate ISR stack, when
; given, is large enough.  Out: CF=1 on error.
; ----------------------------------------------------------------------
CFG_STACKS_OK
	LD	L,(IY+CFG_SPE)
	LD	H,(IY+CFG_SPE+1)	; HL = caller SP
	LD	C,(IY+4*RG_MSTACK)
	LD	B,(IY+4*RG_MSTACK+1)	; BC = main stack start
	OR	A
	SBC	HL,BC			; room below SP
	RET	C
	LD	DE,STACK_NEED_SHARED
	LD	A,(IY+4*RG_ISTACK)
	AND	(IY+4*RG_ISTACK+1)
	INC	A
	JR	Z,.need			; no ISR stack: ISRs nest on this one
	LD	DE,STACK_NEED_MAIN
.need
	OR	A
	SBC	HL,DE
	RET	C
	LD	L,(IY+CFG_SPE)
	LD	H,(IY+CFG_SPE+1)
	INC	HL			; last byte of the return address
	EX	DE,HL
	LD	L,(IY+4*RG_MSTACK+2)
	LD	H,(IY+4*RG_MSTACK+3)	; HL = main stack last
	OR	A
	SBC	HL,DE
	RET	C
	LD	A,(IY+4*RG_ISTACK)
	AND	(IY+4*RG_ISTACK+1)
	INC	A
	RET	Z			; CF=0
	LD	L,(IY+4*RG_ISTACK+2)
	LD	H,(IY+4*RG_ISTACK+3)
	LD	C,(IY+4*RG_ISTACK)
	LD	B,(IY+4*RG_ISTACK+1)
	OR	A
	SBC	HL,BC			; length - 1
	LD	DE,STACK_NEED_ISR - 1
	OR	A
	SBC	HL,DE
	RET

; ----------------------------------------------------------------------
; CFG_COMMIT: clear the context, copy the configuration runs, set the
; initial state and publish IMG_CTX_PTR.  IX = cfg + CFGB.
; ----------------------------------------------------------------------
CFG_COMMIT
	LDCFG_HL UNETG_CFG_CTX_PTR
	PUSH	HL
	LD	(HL),0
	LD	D,H
	LD	E,L
	INC	DE
	LD	BC,UCTX_BYTES - 1
	LDIR
	POP	HL
	PUSH	HL
	LD	BC,CTX_BIAS
	ADD	HL,BC
	PUSH	HL
	POP	IY			; IY = ctx + bias (table frame no longer needed)
	LD	HL,CFG_COPY
	LD	B,CFG_COPY_COUNT
.copy
	PUSH	BC
	LD	A,(HL)			; cfg offset
	INC	HL
	PUSH	HL
	PUSH	IX
	POP	HL
	LD	DE,-CFGB
	ADD	HL,DE
	LD	E,A
	LD	D,0
	ADD	HL,DE			; source
	EX	(SP),HL			; HL -> table, (SP) = source
	LD	A,(HL)			; ctx offset
	INC	HL
	LD	C,(HL)			; length
	INC	HL
	EX	(SP),HL			; HL = source, (SP) -> next table entry
	PUSH	HL
	PUSH	IY
	POP	HL
	LD	DE,-CTX_BIAS
	ADD	HL,DE
	LD	E,A
	LD	D,0
	ADD	HL,DE
	EX	DE,HL			; DE = destination
	POP	HL
	LD	B,0
	LDIR
	POP	HL
	POP	BC
	DJNZ	.copy

	LD	(IY+CX_LAYOUT),LOW UCTX_VERSION
	LD	(IY+CX_LAYOUT+1),HIGH UCTX_VERSION
	LD	(IY+CX_STATE),UNETG_CTXSTATE_CONFIGURED
	LD	(IY+CX_CHAN),UCH_CLOSED
	LD	(IY+CX_ROUTE_STATE),UNETG_ROUTE_NO_ROUTE
	LD	A,(IY+CX_EVENT_CAP)
	DEC	A
	LD	(IY+CX_EVENT_MASK),A
	LD	A,0xFF
	LD	(IY+CX_RX_PEEK_SLOT),A
	LD	(IY+CX_TX_RES_SLOT),A
	LD	A,(IY+CX_RX_SLOT_COUNT)	; ring mode spans every RX slot
	LD	E,(IY+CX_RX_SLOT_SIZE)
	LD	D,(IY+CX_RX_SLOT_SIZE+1)
	CALL	MUL8
	LD	(IY+CX_RX_TOTAL),L
	LD	(IY+CX_RX_TOTAL+1),H
	; v1: no qualified IRQ route on any board, AUTO serves through POLL.
	LD	A,(IY+CX_MODE)
	CP	UNETG_MODE_AUTO
	JR	NZ,.poll
	LD	(IY+CX_FALLBACK_REASON),UNETG_FALLBACK_NO_ROUTE
	LD	(IY+CX_PROBE_RESULT),UNETG_PROBE_UNAVAILABLE
.poll
	; Budgets are converted once per call into microseconds of a 21 MHz
	; CPU, the unit of all cost tables (time.asm).
	CALL	CFG_F16
	LD	(IY+CX_CPU_F16),A
	POP	HL			; ctx
	PUSH	HL
	LD	BC,UCTX_GUARD
	ADD	HL,BC
	LD	A,UCTX_GUARD_BYTE
	LD	B,4
.guard
	LD	(HL),A
	INC	HL
	DJNZ	.guard
	POP	HL
	LD	(IMG_CTX_PTR),HL
	RET

; CFG_F16: A = floor(cpu_khz / 1312) = floor(16 * cpu_khz / 21000) for
; the accepted 3500..28000 kHz range (IX = cfg + CFGB).  Clobbers DE, HL.
CFG_F16
	LDCFG_HL UNETG_CFG_CPU_KHZ
	LD	DE,1312
	XOR	A
.loop
	OR	A
	SBC	HL,DE
	RET	C
	INC	A
	JR	.loop

CFG_COPY
	CFG_COPY_TABLE
