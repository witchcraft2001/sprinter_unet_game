; lock.asm -- shared ISA try-lock and the mapped/DI portion bracket.
;
; Every card access is one RUN_PORTION: interrupts off (the caller's IFF2
; is sampled twice for the LD A,I erratum and restored exactly), the shared
; lock byte (INIT_CONFIG.isa_lock_ptr) taken by test-and-set unless the
; gateway pre-acquired it for this call, the ISA window mapped into WIN3
; from the gateway's shadows, the work routine, then the exact previous
; #9FBD/#1FFD/#E2 values and only then the lock released -- all inside one
; DI section.  The core never holds the lock with interrupts enabled, so a
; network ISR never finds the bus held by the call it interrupted.  The
; work routine must be bounded so that the whole bracket stays below
; 200 us (stand: lock + map + unmap + release ~ 30 us).

; RUN_PORTION: run the (P) routine HL with IX = ctx.hwsm, IY = context,
; the card mapped and IFF=0.  The routine may clobber A, BC, DE, HL, IX;
; results go to the context.
; Out: CF=0 when the routine ran; CF=1 (UWK_BUSY, bus_busy counted) when
; another owner holds the bus -- nothing was run.
; Clobbers A, BC, DE, HL, IX.  Stack: 10 + routine.
RUN_PORTION
	PUSH	IY
	POP	IX
	LD	DE,UCTX_HWSM - CTX_BIAS
	ADD	IX,DE			; IX = ctx.hwsm
	EX	DE,HL			; DE = routine
	LD	L,(IY+CX_ISA_LOCK_PTR)
	LD	H,(IY+CX_ISA_LOCK_PTR+1)
	LD	B,UNETG_LOCK_NET_ISR
	BIT	1,(IY+CX_CALL_FLAGS)	; UCF_ISR: IFF=0 already, nothing to restore
	JR	NZ,.locked
	LD	A,I
	JP	PE,.on
	LD	A,I
.on
	PUSH	AF			; P/V = IFF2 of the caller
	DI
	LD	B,UNETG_LOCK_NET_MAIN
	CALL	.locked
	POP	BC			; C = flags of LD A,I
	BIT	2,C			; P/V; BIT keeps CF
	RET	Z			; interrupts were off: keep them off
	EI
	RET
.locked					; IFF=0, HL -> lock byte, B = owner, DE = routine
	BIT	0,(IY+CX_CALL_FLAGS)	; UCF_PREACQ: the gateway holds it for us
	JR	NZ,.held
	LD	A,(HL)
	OR	A
	JR	NZ,.busy		; any owner, even our own ID, is BUS_BUSY
	LD	(HL),B			; test-and-set inside one DI section
	PUSH	HL
	EX	DE,HL
	CALL	ISA_WINDOW
	POP	HL
	LD	(HL),UNETG_LOCK_FREE	; after the mapping and shadows are restored
	OR	A
	RET
.held
	EX	DE,HL
	CALL	ISA_WINDOW
	OR	A
	RET
.busy
	SET	3,(IY+CX_WORK)		; UWK_BUSY
	STAT_INC UNETG_STATS_BUS_BUSY
	SCF
	RET

; ISA_WINDOW: WIN3 -> ISA I/O space of the configured slot, run routine HL,
; then restore the exact previous #9FBD, #1FFD (bit 4 clear first) and #E2.
; IFF=0 required.  Order: save #E2 before touching #1FFD; #1FFD = shadow |
; BLK_R (bit 4); latch #D4/#D6; #9FBD = 0 (A19..A14 = 0, AEN = 0).  The
; #1FFD shadow and the saved #E2 page stay on the stack (nothing changes
; the shadow under DI); #9FBD is restored from its shadow.
; Clobbers A, BC, DE, HL (+ the routine's).  Stack: 4 + routine.
ISA_WINDOW
	PUSH	HL
	LD	L,(IY+CX_SH1FFD_PTR)
	LD	H,(IY+CX_SH1FFD_PTR+1)
	LD	D,(HL)			; D = #1FFD shadow
	LD	BC,0x00E2
	IN	E,(C)			; E = page in WIN3
	POP	HL
	PUSH	DE
	LD	A,D
	OR	0x10
	LD	BC,0x1FFD
	OUT	(C),A
	LD	A,(IY+CX_ISA_SLOT)
	ADD	A,A
	OR	0xD4			; I/O space: #D4 slot 0, #D6 slot 1
	LD	BC,0x00E2
	OUT	(C),A
	XOR	A
	LD	BC,0x9FBD
	OUT	(C),A
	CALL	JP_HL
	LD	L,(IY+CX_SH9FBD_PTR)
	LD	H,(IY+CX_SH9FBD_PTR+1)
	LD	A,(HL)
	LD	BC,0x9FBD
	OUT	(C),A
	POP	DE
	LD	BC,0x1FFD
	OUT	(C),D
	LD	BC,0x00E2
	OUT	(C),E
	RET
JP_HL
	JP	(HL)
