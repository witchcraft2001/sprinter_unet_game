; ugnetz.asm -- assembly check of the SDK auto-loader (tools/build_sdk.sh):
; sdk/loader/ugnet.asm with everything it stands on (gateway, time
; adapters, libman, ugload.asm, ugenv.asm), as a game would include them.
; Not run: UG_NETENV / UG_NETFIX / UG_NETNAME run on the Z stand
; (ugenvz.asm), the whole chain in NETDEMO V on the M stand.  The DISPLAY
; lines give the code size a game pays for the auto-loader.

	DEVICE	NOSLOT64K
	INCLUDE	"UNETGAME.INC"
	DEFINE	LIBMAN_MAX_LIBS 1
	DEFINE	LIBMAN_NO_LEGACY_API
	DEFINE	LIBMAN_L0_L1_ONLY
UG_BLOCK	EQU	0x9A00
	DEFINE	UG_DLL_WIN 1
	INCLUDE	"gateway/ugate.inc"

	ORG	0x8100
	INCLUDE	"gateway/ugate.asm"
	INCLUDE	"time/ugtime.asm"
lm_start
	INCLUDE	"libman.asm"
ld_start
	INCLUDE	"loader/ugload.asm"
env_start
	INCLUDE	"loader/ugenv.asm"
net_start
	INCLUDE	"loader/ugnet.asm"
net_end
	DISPLAY	"libman: ", /D, ld_start - lm_start, " ugload: ", /D, env_start - ld_start, " ugenv: ", /D, net_start - env_start, " ugnet: ", /D, net_end - net_start
	ASSERT	net_end <= 0x9A00
