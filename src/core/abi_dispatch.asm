; abi_dispatch.asm -- libman hooks, context access and common exits.
;
; Export convention (docs/ABI-TABLE.md): arguments in A/DE/IX/IY, status
; in A, IX and IY preserved.  Inside the core IY = context + CTX_BIAS so
; the first 256 context bytes are reached as (IY+CX_<FIELD>).

; ----------------------------------------------------------------------
; INIT (libman entry 0).  Out: CF=0, A=0 when loaded into window 1/2;
; CF=1, A=STATE in window 3 (the ISA window would page us out).
; The base comes from a relocated label: no stack/self inspection needed.
; ----------------------------------------------------------------------
EXP_INIT
	LD	HL,IMG_ORIGIN
	LD	A,H
	CP	0xC0
	JR	NC,.refuse
	XOR	A
	RET
.refuse
	LD	A,UNETG_STATUS_STATE
	SCF
	RET

; ----------------------------------------------------------------------
; FINI (libman entry 1).  Safe after a failed/partial INIT and without
; INIT_CONFIG: it only forgets the context pointer.  Out: A=0.
; ----------------------------------------------------------------------
EXP_FINI
	LD	HL,0
	LD	(IMG_CTX_PTR),HL
	XOR	A
	RET

; Reserved table entries.
EXP_RESERVED
	LD	A,UNETG_STATUS_STATE
	RET

; ----------------------------------------------------------------------
; CTX_LOAD: IY := context + CTX_BIAS (IMG_CTX_PTR holds that value, 0
; when no context is active; a context never starts at 0xFF80).
; Out: Z when no context is active (IY unchanged), NZ otherwise.
; Clobbers A, HL.  BC and DE preserved (export arguments).  Stack: 2.
; ----------------------------------------------------------------------
CTX_LOAD
	LD	HL,(IMG_CTX_PTR)
	LD	A,H
	OR	L
	RET	Z
	PUSH	HL
	POP	IY
	RET

; CTX_PTR_HL: HL := context + offset in BC (needs IY = ctx + bias).
; Clobbers HL only.  For fields beyond the IY window.
CTX_PTR_HL
	PUSH	IY
	POP	HL
	ADD	HL,BC
	RET

; ----------------------------------------------------------------------
; Common exits for exports that pushed IX, IY.
; ----------------------------------------------------------------------
RET_STATE
	LD	A,UNETG_STATUS_STATE
	JR	RET_A
RET_BADARG
	LD	A,UNETG_STATUS_BAD_ARGUMENT
	JR	RET_A
RET_OK
	XOR	A
RET_A
	POP	IY
	POP	IX
	RET
