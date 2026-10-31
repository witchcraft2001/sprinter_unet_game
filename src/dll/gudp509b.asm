; GUDP509B.DLL -- UNET-GAME profile 3C509B/UDP.
; One of the seven builds of the shared core; see src/core/main.inc.
; This file must contain the only ORG of the image (sprinter-mkdll
; rewrites the first ORG to 0x0020 and 0x0120 for its two passes).

	DEFINE	UGB_HW_EL3
	DEFINE	UGB_TP_UDP

	ORG	0x0000
	INCLUDE	"core/main.inc"
