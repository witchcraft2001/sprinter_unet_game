; main.inc -- assembles one UNET-GAME DLL from the shared core.
;
; Included by src/dll/g*.asm right after their single `ORG 0x0000`
; (sprinter-mkdll rewrites that ORG to 0x0020 / 0x0120).  The entry file
; defines exactly one UGB_HW_* and one UGB_TP_* symbol (build selectors;
; they must not reuse UNETG_* names, which are ABI constants).
;
; Layout of the image (code starts at header + 0x20):
;   jump table (24 x JP)  ->  IMG_CTX_PTR (the only mutable word)
;   -> constant tables -> code -> IMG_END
; The image holds no BSS: every mutable byte except IMG_CTX_PTR lives in
; the application context (INIT_CONFIG.ctx_ptr).

	INCLUDE	"UNETGAME.INC"
	INCLUDE	"unetg_ctx.inc"
	INCLUDE	"unetg_internal.inc"

; --- exactly one hardware and one transport selection -------------------
_HWCOUNT = 0
	IFDEF UGB_HW_ESP
_HWCOUNT = _HWCOUNT + 1
	ENDIF
	IFDEF UGB_HW_RTL
_HWCOUNT = _HWCOUNT + 1
	ENDIF
	IFDEF UGB_HW_EL3
_HWCOUNT = _HWCOUNT + 1
	ENDIF
	IFDEF UGB_HW_LOOP
_HWCOUNT = _HWCOUNT + 1
	ENDIF
	ASSERT	_HWCOUNT == 1, "define exactly one UGB_HW_*"
_TPCOUNT = 0
	IFDEF UGB_TP_TCP
_TPCOUNT = _TPCOUNT + 1
	ENDIF
	IFDEF UGB_TP_UDP
_TPCOUNT = _TPCOUNT + 1
	ENDIF
	IFDEF UGB_TP_ANY
_TPCOUNT = _TPCOUNT + 1
	ENDIF
	ASSERT	_TPCOUNT == 1, "define exactly one UGB_TP_*"
	IFDEF UGB_HW_RTL
	DEFINE	UGB_HW_ETH
	ENDIF
	IFDEF UGB_HW_EL3
	DEFINE	UGB_HW_ETH
	ENDIF
; RX modes: byte ring over the slots (TCP) and/or whole datagrams (UDP).
	IFDEF UGB_TP_TCP
	DEFINE	UGB_RX_RING
	ENDIF
	IFDEF UGB_TP_UDP
	DEFINE	UGB_RX_DGRAM
	ENDIF
	IFDEF UGB_TP_ANY
	DEFINE	UGB_RX_RING
	DEFINE	UGB_RX_DGRAM
	DEFINE	UGB_RX_DYN
	ENDIF

	INCLUDE	"core/profile.inc"

; ======================================================================
; Image start.  IMG_ORIGIN is the first code byte (header + 0x20); after
; relocation `LD HL,IMG_ORIGIN` yields the runtime address, and because
; libman places images on 256-byte boundaries the header base is
; (IMG_ORIGIN & 0xFF00).
; ======================================================================
IMG_ORIGIN
	INCLUDE	"unetg_jt.inc"
	ASSERT	$ - IMG_ORIGIN == 3 * UNETG_EXPORT_COUNT

; The only mutable bytes of the image: pointer to the active context,
; 0 when no INIT_CONFIG is active.  Published as image_mutable_bytes.
IMG_CTX_PTR
	DW	0

	INCLUDE	"core/abi_dispatch.asm"
	INCLUDE	"core/time.asm"
	INCLUDE	"core/config.asm"
	INCLUDE	"core/info.asm"
	INCLUDE	"core/events.asm"
	INCLUDE	"core/slots.asm"
	INCLUDE	"core/lifecycle.asm"
	INCLUDE	"core/sched.asm"
; --- transport and hardware layer --------------------------------------
	IFDEF	UGB_HW_LOOP
	INCLUDE	"core/loop/loop.asm"
	INCLUDE	"hw/none.asm"
	ENDIF
	IFDEF	UGB_HW_EL3
	INCLUDE	"unetg_eth.inc"
	INCLUDE	"core/lock.asm"
	INCLUDE	"core/eth/csum.asm"
	INCLUDE	"core/eth/engine.asm"
	INCLUDE	"core/eth/arp.asm"
	INCLUDE	"core/eth/ip.asm"
	IFDEF	UGB_TP_TCP
	INCLUDE	"core/eth/tcp.asm"
	ELSE
	INCLUDE	"core/eth/udp.asm"
	ENDIF
	INCLUDE	"hw/el3/el3.asm"
	ENDIF
	IFDEF	UGB_HW_RTL			; M2: RTL8019AS layer not yet in place
	INCLUDE	"core/tp_none.asm"
	INCLUDE	"hw/none.asm"
	ENDIF
	IFDEF	UGB_HW_ESP			; M4: ESP layer not yet in place
	INCLUDE	"core/tp_none.asm"
	INCLUDE	"hw/none.asm"
	ENDIF

IMG_END
; Code body limit: 32 + body + ceil(body/8) <= 16384  =>  body <= 0x38C7.
	DISPLAY	"UNET-GAME image body: ", /D, IMG_END - IMG_ORIGIN, " bytes, free: ", /D, UNETG_IMAGE_MAX_BODY - (IMG_END - IMG_ORIGIN)
	ASSERT	IMG_END - IMG_ORIGIN <= UNETG_IMAGE_MAX_BODY, "image body exceeds 0x38C7 bytes (16 KiB L1 limit)"
