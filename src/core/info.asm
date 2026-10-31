; info.asm -- GET_INFO (export 15) and GET_STATS (export 16).

	INCLUDE	"unetg_version.inc"

; ----------------------------------------------------------------------
; GET_INFO.  In: IX = buffer, DE = buffer size (>= 4).
; Out: A = OK or BAD_ARGUMENT.  Copies min(size, INFO_BYTES) bytes; works
; without a context.  image_base is patched from a relocated label.
; Stack: 2 + 4 + 2.
; ----------------------------------------------------------------------
EXP_GET_INFO
	PUSH	IX
	PUSH	IY
	CALL	OUT_PREFIX		; BC = bytes to copy, CF on bad buffer
	JP	C,RET_BADARG
	LD	HL,UNETG_INFO_BYTES
	CALL	MIN_BC_HL
	PUSH	IX
	POP	DE
	LD	HL,INFO_TABLE
	PUSH	BC
	LDIR
	POP	BC
	LD	HL,UNETG_INFO_IMAGE_BASE + 1
	OR	A
	SBC	HL,BC			; CF <=> n >= offset + 2
	JP	NC,RET_OK
	LD	HL,IMG_ORIGIN - 0x20	; relocated address of the L1 header
	LD	(IX+UNETG_INFO_IMAGE_BASE),L
	LD	(IX+UNETG_INFO_IMAGE_BASE+1),H
	JP	RET_OK

; ----------------------------------------------------------------------
; GET_STATS.  In: IX = buffer, DE = size (>= 4).  Out: A = OK, STATE (no
; context) or BAD_ARGUMENT.  Counters written by STEP_ISR are copied in
; DI chunks aligned to field boundaries, so no multi-byte field is torn.
; Stack: 2 + 4 + 2 + 2.
; ----------------------------------------------------------------------
STATS_CHUNK	EQU	38		; ends on a field boundary (block offset 42)

EXP_GET_STATS
	PUSH	IX
	PUSH	IY
	CALL	CTX_LOAD
	JP	Z,RET_STATE
	CALL	OUT_PREFIX
	JP	C,RET_BADARG
	LD	HL,UNETG_STATS_BYTES
	CALL	MIN_BC_HL
	; refresh the status bytes that live in the context header
	PUSH	BC
	LD	BC,UCTX_STATS - CTX_BIAS
	CALL	CTX_PTR_HL		; HL -> ctx.stats = block offset 4
	LD	A,(IY+CX_ROUTE_STATE)
	LD	B,UNETG_MODE_POLL
	CP	UNETG_ROUTE_IRQ_ENABLED
	JR	C,.mode
	CP	UNETG_ROUTE_POLL_FALLBACK
	JR	Z,.mode
	LD	B,UNETG_MODE_IRQ
.mode
	LD	(HL),B			; mode_actual
	INC	HL
	LD	(HL),A			; route_state
	INC	HL
	LD	A,(IY+CX_FALLBACK_REASON)
	LD	(HL),A
	INC	HL
	LD	A,(IY+CX_PROBE_RESULT)
	LD	(HL),A
	INC	HL
	INC	HL
	INC	HL			; avail is maintained in place
	LD	A,(IY+CX_TIMING_MODE)
	LD	(HL),A
	INC	HL
	LD	A,(IY+CX_STATE)
	LD	(HL),A
	POP	BC
	; header of the returned block
	LD	(IX+UNETG_STATS_ABI_VERSION),LOW UNETG_ABI_VERSION
	LD	(IX+UNETG_STATS_ABI_VERSION+1),HIGH UNETG_ABI_VERSION
	LD	(IX+UNETG_STATS_SIZE),LOW UNETG_STATS_BYTES
	LD	(IX+UNETG_STATS_SIZE+1),HIGH UNETG_STATS_BYTES
	LD	HL,-4
	ADD	HL,BC
	LD	B,H
	LD	C,L			; bytes after the header
	PUSH	IX
	POP	DE
	INC	DE
	INC	DE
	INC	DE
	INC	DE
	PUSH	BC
	LD	BC,UCTX_STATS - CTX_BIAS
	CALL	CTX_PTR_HL
	POP	BC
.chunk
	LD	A,B
	OR	C
	JP	Z,RET_OK
	PUSH	BC
	LD	A,B
	OR	A
	JR	NZ,.full
	LD	A,C
	CP	STATS_CHUNK
	JR	C,.part
.full
	LD	BC,STATS_CHUNK
.part
	EX	(SP),HL			; HL = remaining, (SP) = source
	OR	A
	SBC	HL,BC
	EX	(SP),HL			; (SP) = remaining after this chunk
	IFF_SAVE_DI
	LDIR
	EX	(SP),HL			; HL = saved AF, (SP) = source
	BIT	2,L
	JR	Z,.no_ei
	EI
.no_ei
	POP	HL
	POP	BC
	JR	.chunk

; OUT_PREFIX: validate an output buffer IX/DE.
; Out: BC = DE, CF=1 when DE < 4 or IX + DE overflows 16 bits.
OUT_PREFIX
	LD	A,D
	OR	A
	JR	NZ,.long
	LD	A,E
	CP	4
	RET	C
.long
	PUSH	DE
	PUSH	IX
	POP	HL
	CALL	RANGE
	POP	BC
	RET

; MIN_BC_HL: BC = min(BC, HL).  Clobbers HL.
MIN_BC_HL
	OR	A
	SBC	HL,BC
	RET	NC
	ADD	HL,BC
	LD	B,H
	LD	C,L
	RET

; ----------------------------------------------------------------------
; Constant GET_INFO image (the order is checked against the generated
; offsets below).
; ----------------------------------------------------------------------
INFO_TABLE
	DW	UNETG_ABI_VERSION
	DW	UNETG_INFO_BYTES
	DB	PROF_HW
	DB	PROF_TRANSPORTS
	DW	UNETG_IMAGE_VERSION
	DW	PROF_CAPS_HW | PROF_CAPS_TP
	DW	PROF_CPU_KHZ
	DW	PROF_MIN_USEFUL_US
	DW	PROF_MAX_ATOMIC_US
	DW	PROF_MIN_RETURN_US
	DW	PROF_EMPTY_POLL_US
	DW	PROF_BUS_BUSY_US
	DW	PROF_POLL_GAP_US
	DW	PROF_AUTO_GAP_US
	DW	PROF_IRQ_DELIVERY_US
	DW	PROF_MAX_SERVICE_US
	DW	PROF_MAX_STEP_GAP_MS
	DW	UNETG_STEP_BODY_MAX_US
	DW	UNETG_ISR_BODY_MAX_US
	DW	UNETG_STACK_MAIN_MAX
	DW	UNETG_STACK_ISR_MAX
	DW	UCTX_BYTES
	DW	UCTX_VERSION
	DW	PROF_MAX_PAYLOAD
	DW	PROF_MAX_PAYLOAD
	DB	UNETG_SLOTS_MIN
	DB	UNETG_SLOTS_MIN
	DB	UNETG_EVENT_SIZE
	DB	UNETG_EVENT_EXTRA
	DW	PROF_HW_RING_MIN
	DB	PROF_TIMING_MODES
	DB	PROF_UART_PROFILES
	DB	PROF_MUTABLE_BYTES
	DB	0
INFO_IMAGE_BASE
	DW	0			; patched at run time
	DW	IMG_END - IMG_ORIGIN + 0x20
	ASSERT	$ - INFO_TABLE == UNETG_INFO_BYTES
	ASSERT	INFO_IMAGE_BASE - INFO_TABLE == UNETG_INFO_IMAGE_BASE
