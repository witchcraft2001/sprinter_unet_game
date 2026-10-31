; lock.asm -- shared ISA try-lock and the mapped/DI portion bracket.
;
; Every card access runs inside PORTION: interrupts off (the caller's
; IFF2 is sampled twice for the LD A,I erratum and restored exactly), the
; ISA window mapped into WIN3 from the gateway's shadows, the work routine,
; then the exact previous #9FBD/#1FFD/#E2 values.  The work routine must
; be bounded so that the whole bracket stays below 200 us.
; The shared lock byte (INIT_CONFIG.isa_lock_ptr) is taken around each
; portion unless the gateway pre-acquired it for this call.

; ISA_ACQUIRE: Out: CF=0 when this call may use the bus; CF=1 (UWK_BUSY,
; bus_busy counted) when another owner holds it.  Clobbers A, BC, HL.
ISA_ACQUIRE
	BIT	0,(IY+CX_CALL_FLAGS)	; UCF_PREACQ
	JR	Z,.try
	OR	A
	RET
.try
	LD	L,(IY+CX_ISA_LOCK_PTR)
	LD	H,(IY+CX_ISA_LOCK_PTR+1)
	LD	B,UNETG_LOCK_NET_MAIN
	BIT	1,(IY+CX_CALL_FLAGS)	; UCF_ISR
	JR	Z,.owner
	INC	B			; UNETG_LOCK_NET_ISR
.owner
	LD	A,I
	JP	PE,.iff_on
	LD	A,I
.iff_on
	PUSH	AF
	DI
	LD	A,(HL)
	OR	A
	JR	NZ,.busy
	LD	(HL),B			; test-and-set inside one DI section
	POP	AF
	JP	PO,.taken
	EI
.taken
	SET	2,(IY+CX_CALL_FLAGS)	; UCF_ISA_HELD
	OR	A
	RET
.busy
	POP	AF
	JP	PO,.refused
	EI
.refused
	SET	3,(IY+CX_WORK)		; UWK_BUSY
	STAT_INC UNETG_STATS_BUS_BUSY
	SCF
	RET

; ISA_RELEASE: give the lock back if this call took it.  Clobbers A, HL.
ISA_RELEASE
	BIT	2,(IY+CX_CALL_FLAGS)
	RET	Z
	RES	2,(IY+CX_CALL_FLAGS)
	LD	L,(IY+CX_ISA_LOCK_PTR)
	LD	H,(IY+CX_ISA_LOCK_PTR+1)
	LD	(HL),UNETG_LOCK_FREE
	RET

; PORTION: run the routine at HL with the card mapped and IFF=0, then
; restore the mapping, the shadows and the caller's IFF.  The routine gets
; IY = context and may clobber A, BC, DE, HL, IX; results go to the
; context.  Stack: 6 + routine.
PORTION
	LD	A,I
	JP	PE,.on
	LD	A,I
.on
	PUSH	AF			; P/V = IFF2 of the caller
	DI
	PUSH	HL
	CALL	ISA_MAP
	POP	HL
	CALL	JP_HL
	CALL	ISA_UNMAP
	POP	AF
	RET	PO			; interrupts were off: keep them off
	EI
	RET
JP_HL
	JP	(HL)

; ISA_MAP: WIN3 -> ISA I/O space of the configured slot.  DI required.
; Order: save #E2 before touching #1FFD; #1FFD = shadow | BLK_R (bit 4);
; latch #D4/#D6; #9FBD = 0 (A19..A14 = 0, AEN = 0).  Clobbers A, BC, HL.
ISA_MAP
	LD	BC,0x00E2
	IN	A,(C)
	LD	(IY+CX_ISA_E2),A
	LD	L,(IY+CX_SH1FFD_PTR)
	LD	H,(IY+CX_SH1FFD_PTR+1)
	LD	A,(HL)
	OR	0x10
	LD	B,0x1F
	LD	C,0xFD
	OUT	(C),A
	LD	A,(IY+CX_ISA_SLOT)
	ADD	A,A
	OR	0xD4			; I/O space: #D4 slot 0, #D6 slot 1
	LD	BC,0x00E2
	OUT	(C),A
	XOR	A
	LD	BC,0x9FBD
	OUT	(C),A
	RET

; ISA_UNMAP: exact previous #9FBD, #1FFD (bit 4 clear first) and #E2.
; Clobbers A, BC, HL.
ISA_UNMAP
	LD	L,(IY+CX_SH9FBD_PTR)
	LD	H,(IY+CX_SH9FBD_PTR+1)
	LD	A,(HL)
	LD	BC,0x9FBD
	OUT	(C),A
	LD	L,(IY+CX_SH1FFD_PTR)
	LD	H,(IY+CX_SH1FFD_PTR+1)
	LD	A,(HL)
	LD	BC,0x1FFD
	OUT	(C),A
	LD	A,(IY+CX_ISA_E2)
	LD	BC,0x00E2
	OUT	(C),A
	RET
