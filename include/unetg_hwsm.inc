; unetg_hwsm.inc -- ctx.hwsm fields shared by every card layer (see
; src/core/hwdrv.asm).  The rest of the 56 bytes is laid out by the layer:
; include/unetg_eth.inc (RTL8019AS, 3C509B) or include/unetg_esp.inc (ESP).

	IFNDEF	_UNETG_HWSM_INC
	DEFINE	_UNETG_HWSM_INC

HS_PHASE	EQU	0	; u8  card bring-up phase (card specific)
HS_STEP		EQU	1	; u8  sub-step / table index
HS_CNT		EQU	2	; u8  counter of the current sub-step
HS_DL		EQU	4	; u32 deadline of the current wait
HS_IO		EQU	8	; u16 0xC000 + io_base
HS_RES		EQU	45	; u8  result of the last portion
HS_BDL		EQU	48	; u32 deadline of the whole bring-up
HWSM_BYTES	EQU	56	; ctx.hwsm size (abi/ctx.toml)

; Results of NIC_BRINGUP / NIC_STOP (HS_RES)
NBR_CONTINUE	EQU	0	; more bring-up steps in this STEP
NBR_WAIT	EQU	1	; wait for time (HS_DL) or the card: next STEP
NBR_DONE	EQU	2
NBR_FAULT	EQU	3

	ENDIF
