; ugtime.asm -- UNET-GAME SDK time adapters (ТЗ §5.2).  now_ms lives in the
; gateway block (UGW_NOW, u32); the main loop reads it with UG_NOW.
;
; FIXED_SCHEDULE: no counter is read during the game; every tick adds the
; real tick length (whole us + 1/256 us, e.g. CTC1 timer /256 * 164 at
; 21 MHz = 41 984 T = 1999.238 us), never a rounded "2 ms"; now_ms is
; written by the tick ISR only.
; APP_COUNTER: with the owner's permission the tick samples the game's
; CTC2 -> CTC3 counter chain (Worms: 875 kHz, /112, /156, period 17 472
; counts = 19.968 ms): CTC3, CTC2, CTC3; on a CTC3 change one more triple,
; a second change gives no stamp for this tick (the next one catches up);
; phase = (156 - CTC3) * 112 + (112 - CTC2); the delta modulo 17 472 is
; published as a u32 count (UGW_COUNT, ISR only).  UG_NOW turns the count
; into ms in the main loop (875 counts/ms), so the ISR pays only the read
; and the publication.  The adapter only READS the CTC.
; Requires ugate.inc.

; Upper bound of one APP_COUNTER sample with its publication (two phase
; reads, delta, the u32 count), measured on the Z stand;
; INIT_CONFIG.time_read_cost_us (ТЗ §5.2: <= 20 us in the Worms profile).
UGT_READ_US	EQU	20
UGT_CTC2	EQU	0x12
UGT_CTC3	EQU	0x13
UGT_CTC2_N	EQU	112
UGT_CTC3_N	EQU	156
UGT_PERIOD	EQU	UGT_CTC2_N * UGT_CTC3_N	; 17472 counts
UGT_PER_MS	EQU	875			; counts per ms (875 kHz)

; ----------------------------------------------------------------------
; UGT_INIT: start the clock at now_ms = DE:HL (DE = high word, HL = low
; word); APP_COUNTER takes its reference phase now.  Before UG_START, the
; CTC chain already running.  Clobbers AF, BC, DE, HL.
; ----------------------------------------------------------------------
UGT_INIT
	LD	(UG_BLOCK + UGW_NOW),HL
	LD	(UG_BLOCK + UGW_NOW + 2),DE
	LD	HL,0
	LD	(UG_BLOCK + UGW_T_REM),HL
	LD	(UG_BLOCK + UGW_COUNT),HL
	LD	(UG_BLOCK + UGW_COUNT + 2),HL
	LD	(UG_BLOCK + UGW_T_LASTC),HL
	XOR	A
	LD	(UG_BLOCK + UGW_T_FRAC),A
	LD	A,(UG_BLOCK + UGW_TIMING)
	CP	UNETG_TIMING_APP_COUNTER
	RET	NZ
	CALL	UGT_PHASE
	RET	C
	LD	(UG_BLOCK + UGW_T_LAST),HL
	RET

; ----------------------------------------------------------------------
; UGT_TICK: one timer tick (application timer ISR, IFF = 0).
; Clobbers AF, BC, DE, HL.  Cost: FIXED ~190 T; APP_COUNTER <= UGT_READ_US.
; ----------------------------------------------------------------------
UGT_TICK
	LD	A,(UG_BLOCK + UGW_TIMING)
	CP	UNETG_TIMING_APP_COUNTER
	JR	Z,UGT_CTC_SAMPLE
	; FIXED_SCHEDULE: now_ms += TICK_MS, us remainder += TICK_REM (+ the
	; carry of the 1/256 us fraction), one more ms when it reaches 1000
	LD	HL,UG_BLOCK + UGW_T_FRAC
	LD	A,(UG_BLOCK + UGW_TICK_FRAC)
	ADD	A,(HL)
	LD	(HL),A
	LD	HL,(UG_BLOCK + UGW_T_REM)
	LD	DE,(UG_BLOCK + UGW_TICK_REM)
	ADC	HL,DE
	LD	DE,-1000
	ADD	HL,DE
	LD	A,(UG_BLOCK + UGW_TICK_MS)
	JR	C,.carry		; >= 1000 us: one ms more
	SBC	HL,DE			; CF = 0: back to the remainder
	JR	.store
.carry
	INC	A
.store
	LD	(UG_BLOCK + UGW_T_REM),HL
	LD	HL,UG_BLOCK + UGW_NOW
	ADD	A,(HL)
	LD	(HL),A
	RET	NC
	INC	HL
	INC	(HL)
	RET	NZ
	INC	HL
	INC	(HL)
	RET	NZ
	INC	HL
	INC	(HL)
	RET

UGT_CTC_SAMPLE
	CALL	UGT_PHASE
	JR	NC,.stamp
	LD	HL,UG_BLOCK + UGW_T_MISS
	JP	UGH_INC
.stamp
	LD	DE,(UG_BLOCK + UGW_T_LAST)
	LD	(UG_BLOCK + UGW_T_LAST),HL
	OR	A
	SBC	HL,DE
	JR	NC,.delta
	LD	DE,UGT_PERIOD
	ADD	HL,DE
.delta
	LD	DE,(UG_BLOCK + UGW_COUNT)
	ADD	HL,DE
	LD	(UG_BLOCK + UGW_COUNT),HL
	RET	NC
	LD	HL,(UG_BLOCK + UGW_COUNT + 2)
	INC	HL
	LD	(UG_BLOCK + UGW_COUNT + 2),HL
	RET

; UGT_NOW_CTC: main-loop half of APP_COUNTER (from UG_NOW): the counts
; published since the last call become ms.  Between two calls at most
; 65 535 counts (74 ms; UG_STEP runs every <= 20 ms).  Out: HL, DE = now_ms.
; Clobbers AF, B.
UGT_NOW_CTC
	LD	A,I
	JP	PE,.on
	LD	A,I
.on
	PUSH	AF
	DI
	LD	HL,(UG_BLOCK + UGW_COUNT)	; one 16-bit read under DI
	POP	AF
	JP	PO,.read
	EI
.read
	LD	DE,(UG_BLOCK + UGW_T_LASTC)
	LD	(UG_BLOCK + UGW_T_LASTC),HL
	OR	A
	SBC	HL,DE
	LD	DE,(UG_BLOCK + UGW_T_REM)
	ADD	HL,DE
	LD	DE,UGT_PER_MS
	CALL	UGT_MS
	LD	HL,(UG_BLOCK + UGW_NOW)
	LD	DE,(UG_BLOCK + UGW_NOW + 2)
	RET

; UGT_MS: HL = remainder + elapsed units, DE = units per ms: now_ms +=
; HL / DE, remainder = HL mod DE (main loop, APP_COUNTER: at most 75
; rounds).
UGT_MS
	LD	B,0
.loop
	OR	A
	SBC	HL,DE
	JR	C,.done
	INC	B
	JR	.loop
.done
	ADD	HL,DE
	LD	(UG_BLOCK + UGW_T_REM),HL
	LD	A,B
	OR	A
	RET	Z
	LD	HL,UG_BLOCK + UGW_NOW
	ADD	A,(HL)
	LD	(HL),A
	RET	NC
	INC	HL
	INC	(HL)
	RET	NZ
	INC	HL
	INC	(HL)
	RET	NZ
	INC	HL
	INC	(HL)
	RET

; UGT_PHASE: HL = CTC chain phase 0..17471; CF = 1 when CTC3 changed during
; both reads (no stamp).  Clobbers AF, BC, DE.
UGT_PHASE
	IN	A,(UGT_CTC3)
	LD	B,A
	IN	A,(UGT_CTC2)
	LD	C,A
	IN	A,(UGT_CTC3)
	CP	B
	JR	Z,.phase
.again
	LD	B,A			; one more triple
	IN	A,(UGT_CTC2)
	LD	C,A
	IN	A,(UGT_CTC3)
	CP	B
	SCF
	RET	NZ			; a second change: no stamp
.phase
	LD	H,HIGH UGT_P3_LO	; (156 - CTC3) * 112 from two page tables
	LD	L,B
	LD	E,(HL)
	INC	H
	LD	D,(HL)
	LD	A,UGT_CTC2_N
	SUB	C			; counts into the CTC2 period 0..111
	LD	L,A
	LD	H,0
	ADD	HL,DE			; < 17 472: CF = 0
	RET

; (156 - v) * 112 for a CTC3 value v = 0..156 (0 reads as 156: the reload
; instant), low bytes then high bytes, each in its own 256-byte page.
	ALIGN	256
UGT_P3_LO
	DB	0
.v	= 1
	DUP	UGT_CTC3_N
	DB	LOW ((UGT_CTC3_N - .v) * UGT_CTC2_N)
.v	= .v + 1
	EDUP
	ALIGN	256
UGT_P3_HI
	DB	0
.w	= 1
	DUP	UGT_CTC3_N
	DB	HIGH ((UGT_CTC3_N - .w) * UGT_CTC2_N)
.w	= .w + 1
	EDUP
	ASSERT	HIGH UGT_P3_HI == HIGH UGT_P3_LO + 1
