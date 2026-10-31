; ugload.asm -- UNET-GAME SDK loader: libman (git submodule third_party/
; libman) places and relocates the L1 image and calls INIT; the SDK takes
; the DLL's physical page and base for its direct calls (ТЗ §2) and checks
; them against the library itself (ТЗ §8: l_load / l_info / l_free compared
; with the addresses the SDK uses).
;
; The application includes "libman.asm" (LIBMAN_DIR) with LIBMAN_L0_L1_ONLY
; and LIBMAN_NO_LEGACY_API before this file, and ugate.inc / ugate.asm.
; DSS calls only: before the game switches to IM2 and after it is back in
; IM1.  libman's lib_table layout (busy, DSS block id, base high byte, end
; high byte per handle) is internal: the version is pinned below.

	ASSERT	LIBMAN.VERSION == 0x0104, "ugload.asm reads the libman 1.4 lib_table"

UG_DSS		EQU	0x10
UG_DSS_SETWIN1	EQU	0x39		; A = block id, B = page of the block

UG_LD_OK	EQU	0
UG_LD_LIBMAN	EQU	1		; l_load refused (B = LIBMAN.l_reason)
UG_LD_BASE	EQU	2		; GET_INFO.image_base differs from libman's base
UG_LD_HEADER	EQU	3		; l_info differs from the header at the base

; ----------------------------------------------------------------------
; UG_LOAD: HL = ASCIIZ file name.  libman loads the DLL for window
; UG_DLL_WIN (INIT included); the gateway is attached to its page and base.
; Out: CF = 0, A = UG_LD_OK; CF = 1, A = UG_LD_* (B = l_reason for
;      UG_LD_LIBMAN; the DLL is freed again on a mismatch).
; Main loop, IM1 (DSS).  Preserves IX, IY.  Clobbers BC, DE, HL.
; ----------------------------------------------------------------------
UG_LOAD
	PUSH	IX
	PUSH	IY
	LD	A,UG_DLL_WIN
	CALL	LIBMAN.l_load
	JR	NC,.loaded
	LD	A,(LIBMAN.l_reason)
	LD	B,A
	LD	A,UG_LD_LIBMAN
	JP	.fail
.loaded
	LD	A,L
	LD	(UG_BLOCK + UGW_HANDLE),A
	ADD	A,A
	ADD	A,A
	LD	E,A
	LD	D,0
	LD	HL,LIBMAN.lib_table + 1
	ADD	HL,DE
	LD	E,(HL)			; DSS block id of the DLL page
	INC	HL
	LD	H,(HL)			; base high byte (header at base)
	PUSH	HL
	; the physical page: map the block (SetWin1), read the window port,
	; put the previous page back
	IN	A,(UG_WINPORT)
	PUSH	AF			; [previous page]
	LD	A,E			; A = block id, B = its first page
	LD	B,0
	LD	C,UG_DSS_SETWIN1 + UG_DLL_WIN - 1
	RST	UG_DSS
	IN	A,(UG_WINPORT)
	LD	E,A			; the DLL's page
	POP	AF
	OUT	(UG_WINPORT),A
	POP	HL
	LD	A,E
	CALL	UG_ATTACH		; A = page, H = base high byte
	; check 1: GET_INFO.image_base (the core's own IMG_ORIGIN - 0x20)
	LD	IX,UG_BLOCK + UGW_SCRATCH
	LD	DE,UNETG_INFO_BYTES
	LD	B,UNETG_GET_INFO
	CALL	UG_CALL
	LD	HL,(UG_BLOCK + UGW_SCRATCH + UNETG_INFO_IMAGE_BASE)
	LD	A,(UG_BLOCK + UGW_BASEH)
	CP	H
	JR	NZ,.base
	LD	A,L
	OR	A
	JR	NZ,.base
	; check 2: l_info == the 32 header bytes at the base
	LD	A,(UG_BLOCK + UGW_HANDLE)
	LD	L,A
	LD	H,0
	LD	DE,UG_BLOCK + UGW_SCRATCH
	CALL	LIBMAN.l_info
	DI				; the DLL page in its window only for the compare
	IN	A,(UG_WINPORT)
	LD	C,A
	LD	A,(UG_BLOCK + UGW_PAGE)
	OUT	(UG_WINPORT),A
	LD	A,(UG_BLOCK + UGW_BASEH)
	LD	H,A
	LD	L,0
	LD	DE,UG_BLOCK + UGW_SCRATCH
	LD	B,32
.cmp
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.diff
	INC	HL
	INC	DE
	DJNZ	.cmp
.diff
	LD	A,C
	OUT	(UG_WINPORT),A
	EI
	LD	A,B
	OR	A
	JR	NZ,.header
	POP	IY
	POP	IX
	XOR	A			; UG_LD_OK, CF = 0
	RET
.base
	LD	B,UG_LD_BASE
	JR	.free
.header
	LD	B,UG_LD_HEADER
.free
	PUSH	BC
	CALL	UG_FREE
	POP	BC
	LD	A,B
	LD	B,0
.fail
	POP	IY
	POP	IX
	SCF
	RET

; ----------------------------------------------------------------------
; UG_FREE: libman calls FINI and frees the page (after UG_SHUTDOWN returned
; OK and the game is back in IM1).  Clobbers AF, BC, DE, HL.
; ----------------------------------------------------------------------
UG_FREE
	LD	A,(UG_BLOCK + UGW_HANDLE)
	CP	0xFF
	RET	Z
	LD	L,A
	LD	H,0
	PUSH	IX
	PUSH	IY
	CALL	LIBMAN.l_free
	POP	IY
	POP	IX
	LD	A,0xFF
	LD	(UG_BLOCK + UGW_HANDLE),A
	LD	HL,UG_BLOCK + UGW_FLAGS
	RES	UGF_ATTACHED,(HL)
	RET
