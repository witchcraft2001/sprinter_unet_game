; ugnet.asm -- UNET-GAME SDK: one call from the DSS environment to a loaded
; and configured DLL.  Glue over ugenv.asm (the card fields), ugload.asm
; (libman) and the gateway's UG_INIT_ENV; the game includes those first.
;
;	CALL	UG_GW_INIT		; A, E = shadows of #1FFD, #9FBD
;	LD	A,UNETG_TRANSPORT_UDP	; or _TCP: GUDP<card> / GTCP<card>
;	LD	IX,net_cfg		; regions, timeouts, peer, ports, flags
;	LD	HL,net_profile		; UGP_* profile of the gateway
;	CALL	UG_NETAUTO
;	JR	C,no_network		; A = UGN_E_*, B / C = details

; ----------------------------------------------------------------------
; UG_NETAUTO: UG_NETENV, then UG_NETUP.
; In: A = UNETG_TRANSPORT_*; IX = INIT_CONFIG block; HL = profile.
; Out: as UG_NETENV on its errors, else as UG_NETUP.
; ----------------------------------------------------------------------
UG_NETAUTO
	PUSH	HL
	CALL	UG_NETENV
	POP	HL
	RET	C
; ----------------------------------------------------------------------
; UG_NETUP: load the DLL the block names and configure it.
; In:  IX = INIT_CONFIG block with the card fields (UG_NETENV, or the
;      game's own form: hw_profile, transport, isa_slot, io_base, ...);
;      HL = profile (UGP_*).
; Does: UG_NETFIX; the name (UG_NETNAME) into the context region; UG_LOAD;
;      GET_INFO must report the block's card and transport; UG_INIT_ENV
;      (INIT_CONFIG clears the context itself).
; Out: CF = 0, A = UGN_OK: loaded and configured.  CF = 1, nothing loaded:
;      A = UGN_E_CFG (no such card), UGN_E_LOAD (B = UG_LD_*, C =
;      LIBMAN.l_reason for UG_LD_LIBMAN), UGN_E_DLL (another card's or
;      transport's file under this name), UGN_E_INIT (B = the status of
;      UG_INIT_ENV; UGW_ENV says which check).
; Main loop, IM1, after UG_GW_INIT and before IM 2.  Preserves IX, IY.
; Clobbers BC, DE, HL.
; ----------------------------------------------------------------------
UG_NETUP
	PUSH	HL			; [profile]
	CALL	UG_NETFIX
	LD	E,(IX+UNETG_CFG_CTX_PTR)
	LD	D,(IX+UNETG_CFG_CTX_PTR+1)
	PUSH	DE
	CALL	UG_NETNAME
	POP	HL
	LD	A,UGN_E_CFG
	JR	C,.fail
	CALL	UG_LOAD
	JR	NC,.info
	LD	C,B
	LD	B,A
	LD	A,UGN_E_LOAD
	JR	.fail
.info
	; UG_LOAD's scratch ends with the L1 header: GET_INFO again
	PUSH	IX
	LD	IX,UG_BLOCK + UGW_SCRATCH
	LD	DE,UNETG_INFO_BYTES
	LD	B,UNETG_GET_INFO
	CALL	UG_CALL
	POP	IX
	OR	A
	JR	NZ,.dll
	LD	A,(UG_BLOCK + UGW_SCRATCH + UNETG_INFO_HW_PROFILE)
	CP	(IX+UNETG_CFG_HW_PROFILE)
	JR	NZ,.dll
	LD	A,(UG_BLOCK + UGW_SCRATCH + UNETG_INFO_TRANSPORTS)
	AND	(IX+UNETG_CFG_TRANSPORT)	; TCP = bit 0, UDP = bit 1
	JR	Z,.dll
	POP	HL
	PUSH	HL
	CALL	UG_INIT_ENV
	OR	A
	JR	Z,.ok
	LD	B,A
	LD	A,UGN_E_INIT
	JR	.free
.dll
	LD	A,UGN_E_DLL
.free
	PUSH	AF
	PUSH	BC
	CALL	UG_FREE
	POP	BC
	POP	AF
.fail
	POP	HL
	SCF
	RET
.ok
	POP	HL
	RET				; A = UGN_OK, CF = 0
	ASSERT	UNETG_TRANSPORT_TCP == 1 && UNETG_TRANSPORT_UDP == 2
UGN_UP_SIZE	EQU	$ - UG_NETAUTO
	ASSERT	UGN_UP_SIZE <= 128, "ugnet.asm grew"
