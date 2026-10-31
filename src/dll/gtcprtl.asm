; GTCPRTL.DLL -- UNET-GAME profile RTL8019AS/TCP.
; One of the seven builds of the shared core; see src/core/main.inc.
; This file must contain the only ORG of the image (sprinter-mkdll
; rewrites the first ORG to 0x0020 and 0x0120 for its two passes).

	DEFINE	UGB_HW_RTL
	DEFINE	UGB_TP_TCP

	ORG	0x0000
	INCLUDE	"core/main.inc"
