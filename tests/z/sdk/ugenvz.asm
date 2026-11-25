; ugenvz.asm -- the Z stand program of sdk/loader/ugenv.asm
; (tests/z/sdk/m5_netenv.test.js, tools/harness/dss.js).
;
; One entry per routine; the stand sets the registers, starts at the
; entry with SP in WIN2 and reads the registers at ugv_stop.  DSS ENVIRON
; (#46) is the stand's trap at #0010.  Placed at 0xB000, above the core
; regions of stand.js (they end below 0x9D00), so the block it fills can
; go to a real DLL's INIT_CONFIG in the same machine.

	DEVICE	NOSLOT64K
	INCLUDE	"UNETGAME.INC"

	ORG	0xB000
ugv_env					; A = transport, IX = block
	CALL	UG_NETENV
	JR	ugv_stop
ugv_fix					; IX = block
	CALL	UG_NETFIX
	JR	ugv_stop
ugv_name				; IX = block, DE = buffer
	CALL	UG_NETNAME
	JR	ugv_stop
ugv_var					; A = UGN_V_*
	CALL	UG_NETVAR
ugv_stop
	JR	ugv_stop

	INCLUDE	"loader/ugenv.asm"
ugv_end
	DISPLAY	"ugenv.asm: ", /D, UGE_SIZE, " bytes"
	SAVEBIN	"ugenvz.bin", 0xB000, ugv_end - 0xB000
