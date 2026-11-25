; ugenv.asm -- UNET-GAME SDK: the card fields of INIT_CONFIG from the DSS
; environment the system network bring-up tools publish (NETUP for the
; SprinterESP, NETCFG / IFUP for the RTL8019AS, the 3C509B kit), and the
; delivery name of the matching DLL.  No ISA probing: finding the card,
; DHCP and the Wi-Fi association are the bring-up tools' job; a card that
; is not there is reported by the core itself (hw_state).
;
; DSS only (ENVIRON #46, before IM 2); no libman, no own memory: the value
; buffer is the context region of the block, which is free until
; INIT_CONFIG (CFG_COMMIT clears it).  GLOOP is never chosen: it is a Z / M
; stand library only.  Value ranges (slot, base alignment, ID port) are
; INIT_CONFIG's checks; this file checks the syntax.
;
; Variables (docs/SDK.md «Автозагрузка по окружению DSS»):
;   NET            WIFI / ESP / RTL / 509B (any case)   -> hw_profile
;   NET_ESP_HW / NET_RTL_HW / NET_HW   S/#HHH (slot 0/1, hex base)
;                                                       -> isa_slot, io_base
;   NET_IDPORT     #HHH, default #110 (3C509B)          -> id_port
;   NET_IP, NET_MASK   dotted quad (Ethernet)           -> local_ip, netmask
;   NET_GW         dotted quad, default 0.0.0.0         -> gateway_ip
;   NET_MAC        aa:bb:cc:dd:ee:ff, default 0 (PROM)  -> mac
;   NET_BAUD       decimal, default 115200 (ESP)        -> uart_divisor
;   NET_ESP_FLOW   3 (ESP: NETUP set RTS/CTS on both sides)
;                                  -> uart_flow 1, esp_flow 3, FLOW_VERIFIED

UGN_OK		EQU	0
UGN_E_CFG	EQU	1		; block unusable: ctx region < 256 bytes or ctx_ptr > #BF00,
					; or hw_profile not ESP / RTL / 3C509B (UG_NETNAME)
UGN_E_NONET	EQU	2		; NET absent or not a card of this SDK
UGN_E_ENV	EQU	3		; B = UGN_V_* of a missing or malformed variable
UGN_E_FLOW	EQU	4		; ESP without NET_ESP_FLOW=3 (NETUP did not verify RTS/CTS)
UGN_E_LOAD	EQU	5		; ugnet.asm: B = UG_LD_*, C = LIBMAN.l_reason
UGN_E_DLL	EQU	6		; ugnet.asm: the file is not the DLL of this card / transport
UGN_E_INIT	EQU	7		; ugnet.asm: B = UG_INIT_ENV / INIT_CONFIG status

UGN_V_NET	EQU	0		; variable indices (UG_NETVAR)
UGN_V_ESP_HW	EQU	1		; = UNETG_HW_ESP
UGN_V_RTL_HW	EQU	2		; = UNETG_HW_RTL
UGN_V_HW	EQU	3		; = UNETG_HW_EL3
UGN_V_IDPORT	EQU	4
UGN_V_IP	EQU	5
UGN_V_MASK	EQU	6
UGN_V_GW	EQU	7
UGN_V_MAC	EQU	8
UGN_V_BAUD	EQU	9
UGN_V_ESP_FLOW	EQU	10

UGN_CPU_KHZ	EQU	21000		; the Sprinter runs at one speed
UGN_RX_TRIGGER	EQU	8		; ugnet.asm: the ESP game profiles' FIFO trigger
UGE_DSS		EQU	0x10
UGE_ENV_GET	EQU	0x0146		; B = 1 (get), C = ENVIRON #46
UGE_ID_PORT	EQU	0x0110		; 3C509B ID port when NET_IDPORT is absent
UGE_BAUD_K	EQU	9216		; 14.7456 MHz / 16 / 100: divisor = UGE_BAUD_K / (baud / 100)
UGE_OPT		EQU	0x80		; list item: the variable may be absent
UGE_END		EQU	0xFF		; end of a list

	ASSERT	UNETG_HW_ESP == UGN_V_ESP_HW && UNETG_HW_RTL == UGN_V_RTL_HW && UNETG_HW_EL3 == UGN_V_HW
	ASSERT	UNETG_CFG_IO_BASE == UNETG_CFG_ISA_SLOT + 1
	ASSERT	UNETG_CFG_ESP_FLOW == UNETG_CFG_UART_FLOW + 1

; ----------------------------------------------------------------------
; UG_NETENV: the card fields of the INIT_CONFIG block from the environment.
; In:  A = UNETG_TRANSPORT_TCP / _UDP; IX = INIT_CONFIG block whose regions
;      (ctx_ptr / ctx_len among them), timeouts, peers, ports and flags the
;      game has filled.
; Writes transport, cpu_khz (21000) and hw_profile; then the fields of the
; card NET names: isa_slot, io_base; ESP: uart_divisor, uart_flow,
; esp_flow, FLOW_VERIFIED in flags; RTL and 3C509B: local_ip, netmask,
; gateway_ip, mac; 3C509B: id_port.  The first 256 bytes of the context
; region hold the last value read.  Nothing else is written.
; Out: CF = 0, A = UGN_OK; CF = 1, A = UGN_E_CFG / UGN_E_NONET /
;      UGN_E_ENV (B = UGN_V_*) / UGN_E_FLOW (B = UGN_V_ESP_FLOW); after an
;      error the card fields are undefined.
; Main loop, IM1 (DSS #46).  Preserves IX, IY.  Clobbers BC, DE, HL.
; Stack: 14 bytes + DSS.  Cost: 11 ENVIRON calls at most.
; ----------------------------------------------------------------------
UG_NETENV
	PUSH	IY
	LD	(IX+UNETG_CFG_TRANSPORT),A
	LD	(IX+UNETG_CFG_CPU_KHZ),LOW UGN_CPU_KHZ
	LD	(IX+UNETG_CFG_CPU_KHZ+1),HIGH UGN_CPU_KHZ
	; DSS copies a value of up to 255 characters + 0 and maps the
	; environment into WIN3: 256 bytes of buffer below #C000
	LD	A,(IX+UNETG_CFG_CTX_LEN+1)
	OR	A
	JR	Z,.cfg
	LD	L,(IX+UNETG_CFG_CTX_PTR)
	LD	H,(IX+UNETG_CFG_CTX_PTR+1)
	LD	DE,0x10000 - 0xBF01
	ADD	HL,DE
	JR	C,.cfg
	XOR	A			; UGN_V_NET
	CALL	UGE_GET
	JR	Z,.nonet
	LD	DE,UGE_NETS
.net
	LD	A,(DE)
	OR	A
	JR	Z,.nonet
	PUSH	HL
	CALL	UGE_SAME
	POP	HL
	LD	A,(DE)			; UNETG_HW_* of the entry
	INC	DE
	JR	NZ,.net
	LD	(IX+UNETG_CFG_HW_PROFILE),A
	ADD	A,A
	LD	L,A
	LD	H,0
	LD	DE,UGE_LISTS - 2
	ADD	HL,DE
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	PUSH	DE			; [list]
	LD	HL,UGE_I_HW		; the card's own S/#HHH first
	CALL	UGE_ITEM
	POP	DE
	JR	C,.bad
	EX	DE,HL
.item
	LD	A,(HL)
	INC	A			; UGE_END
	JR	Z,.ok
	CALL	UGE_ITEM
	JR	C,.bad
	LD	DE,4
	ADD	HL,DE
	JR	.item
.ok
	POP	IY
	XOR	A			; UGN_OK, CF = 0
	RET
.bad
	CALL	UGE_VAR
	LD	B,A
	CP	UGN_V_ESP_FLOW
	LD	A,UGN_E_FLOW
	JR	Z,.fail
	LD	A,UGN_E_ENV
	JR	.fail
.cfg
	LD	A,UGN_E_CFG
	JR	.fail
.nonet
	LD	A,UGN_E_NONET
.fail
	POP	IY
	SCF
	RET

; One list item (HL): read its variable, then its parser with HL = value,
; DE = IX + field.  Out: CF = 1 when a required variable is absent or the
; parser refused the value.  Preserves HL, IX.  Clobbers AF, BC, DE, IY.
UGE_ITEM
	PUSH	HL			; [item]
	CALL	UGE_VAR
	CALL	UGE_GET			; HL = value, Z = empty
	POP	DE
	PUSH	DE			; DE = item
	JR	NZ,.have
	LD	A,(DE)
	RLCA				; CF = UGE_OPT
	CCF
	JR	C,.out			; required and absent
.have
	EX	DE,HL			; HL = item, DE = value
	INC	HL
	LD	C,(HL)
	INC	HL
	LD	B,(HL)			; BC = parser
	INC	HL
	LD	A,(HL)			; field offset
	PUSH	BC
	POP	IY
	PUSH	IX
	POP	HL
	ADD	A,L
	LD	L,A
	ADC	A,H
	SUB	L
	LD	H,A			; HL = IX + field
	EX	DE,HL			; HL = value, DE = field
	CALL	UGE_JPIY
.out
	POP	HL
	RET
UGE_JPIY
	JP	(IY)

; A = the variable of the item at HL (UGN_V_*; 0 = the card's NET_*_HW).
UGE_VAR
	LD	A,(HL)
	AND	0x7F
	RET	NZ
	LD	A,(IX+UNETG_CFG_HW_PROFILE)
	RET

; UGE_GET: A = UGN_V_* -> HL = its value (ASCIIZ in the context region,
; empty when absent), Z = absent or empty.  Clobbers AF, BC, DE.
UGE_GET
	CALL	UG_NETVAR
	LD	E,(IX+UNETG_CFG_CTX_PTR)
	LD	D,(IX+UNETG_CFG_CTX_PTR+1)
	PUSH	DE
	PUSH	IX
	LD	BC,UGE_ENV_GET
	RST	UGE_DSS
	POP	IX
	POP	HL
	JR	C,.none
	INC	A			; #FF = found
	JR	NZ,.none
	LD	A,(HL)
	OR	A
	RET
.none
	XOR	A
	LD	(HL),A
	RET

; ----------------------------------------------------------------------
; UG_NETVAR: A = UGN_V_* -> HL = the variable's ASCIIZ name (for a message
; after UGN_E_ENV).  Clobbers AF, B.
; ----------------------------------------------------------------------
UG_NETVAR
	LD	HL,UGE_NAMES
; HL = strings, A = index -> HL = the A-th string.  Clobbers AF, B.
UGE_NTH
	LD	B,A
	INC	B
	JR	.next
.skip
	LD	A,(HL)
	INC	HL
	OR	A
	JR	NZ,.skip
.next
	DJNZ	.skip
	RET

; Z when the string at HL equals the upper-case entry at DE, any case;
; DE ends past the entry's 0 either way.  Clobbers AF, HL.
UGE_SAME
	LD	A,(HL)
	CP	'a'
	JR	C,.up
	CP	'z' + 1
	JR	NC,.up
	AND	0xDF
.up
	EX	DE,HL
	CP	(HL)
	EX	DE,HL
	JR	NZ,.skip
	INC	HL
	INC	DE
	OR	A
	JR	NZ,UGE_SAME
	RET
.skip
	LD	A,(DE)
	INC	DE
	OR	A
	JR	NZ,.skip
	INC	A			; NZ
	RET

; ---- parsers: HL = value (empty = absent optional), DE = field;
;      CF = 1 on bad syntax.  Clobber AF, BC, DE, HL.
; "S/#HHH": slot digit 0 / 1, then the hex base.
UGE_H_HW
	LD	A,(HL)
	SUB	'0'
	CP	2
	JR	NC,UGE_BAD
	LD	(DE),A			; isa_slot
	INC	DE
	INC	HL
	LD	A,(HL)
	CP	'/'
	JR	NZ,UGE_BAD
	INC	HL
	JR	UGE_HEXF
; "#HHH" or absent (#110).
UGE_H_ID
	LD	A,(HL)
	OR	A
	JR	NZ,UGE_HEXF
	EX	DE,HL
	LD	(HL),LOW UGE_ID_PORT
	INC	HL
	LD	(HL),HIGH UGE_ID_PORT
	RET
UGE_HEXF
	PUSH	DE
	CALL	UGE_HEX
	POP	HL
	RET	C
	LD	(HL),E
	INC	HL
	LD	(HL),D
	RET
; Dotted quad, or absent (0.0.0.0).
UGE_H_IP
	LD	A,(HL)
	OR	A
	LD	B,4
	JR	Z,UGE_ZERO
	EX	DE,HL			; DE = text, HL = field
.octet
	PUSH	HL
	CALL	UGE_DEC			; HL = number, A = the character after it
	LD	C,A
	JR	C,.bad
	LD	A,H
	OR	A
	JR	NZ,.bad
	LD	A,L
	POP	HL
	LD	(HL),A
	INC	HL
	LD	A,C
	DEC	B
	JR	Z,UGE_ENDA
	CP	'.'
	JR	Z,.octet
	JR	UGE_BAD
.bad
	POP	HL
	JR	UGE_BAD
; aa:bb:cc:dd:ee:ff, or absent (zeros: the card's own address).
UGE_H_MAC
	LD	A,(HL)
	OR	A
	LD	B,6
	JR	Z,UGE_ZERO
.byte
	CALL	UGE_XDIG
	RET	C
	INC	HL
	RLCA
	RLCA
	RLCA
	RLCA
	LD	C,A
	CALL	UGE_XDIG
	RET	C
	INC	HL
	OR	C
	LD	(DE),A
	INC	DE
	LD	A,(HL)
	INC	HL
	DEC	B
	JR	Z,UGE_ENDA
	CP	':'
	JR	Z,.byte
	JR	UGE_BAD
; B bytes of zero at DE (A = 0, CF = 0).
UGE_ZERO
	LD	(DE),A
	INC	DE
	DJNZ	UGE_ZERO
	RET
; CF = 0 when A = 0 (the end of the value).
UGE_ENDA
	OR	A
	RET	Z
UGE_BAD
	SCF
	RET
; NETUP's decimal baud rate, or absent (115200): divisor 921600 / baud,
; exact (230400 4, 115200 8, 57600 16, 38400 24, 19200 48, 9600 96).
UGE_H_BAUD
	LD	BC,8
	LD	A,(HL)
	OR	A
	JR	Z,.put
	PUSH	DE			; [field]
	LD	D,H
	LD	E,L			; DE = text
	LD	C,B			; C = length + 1
.end
	LD	A,(HL)
	INC	HL
	INC	C
	OR	A
	JR	NZ,.end
	LD	A,C
	CP	4
	JR	C,.bad			; fewer than 3 characters, or 255
	DEC	HL
	DEC	HL
	LD	A,'0'			; "..00": the number of hundreds
	CP	(HL)
	JR	NZ,.bad
	DEC	HL
	CP	(HL)
	JR	NZ,.bad
	LD	(HL),0
	CALL	UGE_DEC			; HL = baud / 100
	JR	C,.bad
	OR	A
	JR	NZ,.bad
	LD	A,H
	OR	L
	JR	Z,.bad
	EX	DE,HL
	LD	HL,UGE_BAUD_K
	LD	BC,0
.div
	INC	BC
	SBC	HL,DE			; CF = 0 on entry and on every turn
	JR	Z,.got
	JR	NC,.div
.bad
	POP	DE
	JR	UGE_BAD
.got
	POP	DE
.put
	EX	DE,HL
	LD	(HL),C
	INC	HL
	LD	(HL),B
	RET				; CF = 0
; Exactly "3": RTS/CTS on the UART and in the module.
UGE_H_FLOW
	LD	A,(HL)
	CP	'3'
	JR	NZ,UGE_BAD
	INC	HL
	LD	A,(HL)
	OR	A
	JR	NZ,UGE_BAD
	EX	DE,HL
	LD	(HL),1			; uart_flow: AFE RTS/CTS
	INC	HL
	LD	(HL),3			; esp_flow: AT+UART_CUR RTS/CTS
	LD	A,(IX+UNETG_CFG_FLAGS)
	OR	UNETG_CFGF_FLOW_VERIFIED
	LD	(IX+UNETG_CFG_FLAGS),A
	RET				; CF = 0

; "#" and 1..4 hex digits, then the end of the value -> DE.  Clobbers AF, B, HL.
UGE_HEX
	LD	A,(HL)
	CP	'#'
	JR	NZ,UGE_BAD
	INC	HL
	LD	DE,0
	LD	B,4
	CALL	UGE_XDIG
	RET	C
.digit
	EX	DE,HL
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,HL
	OR	L
	LD	L,A
	EX	DE,HL
	INC	HL
	CALL	UGE_XDIG
	JR	C,.end
	DJNZ	.digit
	SCF				; a fifth digit
	RET
.end
	LD	A,(HL)
	JP	UGE_ENDA
; A = the hex digit at HL (any case), CF = 1 when it is none.  HL kept.
UGE_XDIG
	LD	A,(HL)
	SUB	'0'
	CP	10
	CCF
	RET	NC
	AND	0xDF
	SUB	'A' - '0'
	CP	6
	CCF
	RET	C
	ADD	A,10
	RET
; Decimal number at DE (at least one digit, < 65536) -> HL; A = the
; character after it, DE past that character.  CF = 1 on no digit or
; overflow.  Preserves BC.
UGE_DEC
	LD	HL,0
	LD	A,(DE)
	SUB	'0'
	CP	10
	CCF
	RET	C
.digit
	PUSH	BC
	LD	B,H
	LD	C,L
	ADD	HL,HL
	JR	C,.over
	ADD	HL,HL
	JR	C,.over
	ADD	HL,BC
	JR	C,.over
	ADD	HL,HL
	JR	C,.over
	LD	C,A
	LD	B,0
	ADD	HL,BC
.over
	POP	BC
	RET	C
	INC	DE
	LD	A,(DE)
	SUB	'0'
	CP	10
	JR	C,.digit
	LD	A,(DE)
	INC	DE
	RET				; CF = 0

; ----------------------------------------------------------------------
; UG_NETFIX: the fields a card needs and a game need not know about
; (used by UG_NETUP, ugnet.asm).  IX = block with hw_profile, transport
; and flags set.  Not ESP: hw_ring_ptr / hw_ring_len = 0 (only the ESP
; builds take a UART ring).  ESP: esp_fw 0 -> 1, or 2 with
; CFGF_UDP_RECORDS (the records are the transparent mode's format);
; uart_rx_trigger 0 -> 8.  Clobbers AF.
; ----------------------------------------------------------------------
UG_NETFIX
	LD	A,(IX+UNETG_CFG_HW_PROFILE)
	CP	UNETG_HW_ESP
	JR	Z,.esp
	XOR	A
	LD	(IX+UNETG_CFG_HW_RING_PTR),A
	LD	(IX+UNETG_CFG_HW_RING_PTR+1),A
	LD	(IX+UNETG_CFG_HW_RING_LEN),A
	LD	(IX+UNETG_CFG_HW_RING_LEN+1),A
	RET
.esp
	LD	A,(IX+UNETG_CFG_ESP_FW)
	OR	A
	JR	NZ,.trigger
	LD	A,(IX+UNETG_CFG_FLAGS)
	AND	UNETG_CFGF_UDP_RECORDS
	LD	A,1
	JR	Z,.fw
	INC	A
.fw
	LD	(IX+UNETG_CFG_ESP_FW),A
.trigger
	LD	A,(IX+UNETG_CFG_UART_RX_TRIGGER)
	OR	A
	RET	NZ
	LD	(IX+UNETG_CFG_UART_RX_TRIGGER),UGN_RX_TRIGGER
	RET

; ----------------------------------------------------------------------
; UG_NETNAME: the delivery name of the DLL for the block's hw_profile and
; transport: "G" + TCP / UDP + ESP / RTL / 509B + ".DLL" (libman 1.4 looks
; for a bare name in the EXE's directory first).
; In:  IX = block; DE = buffer of 13 bytes.
; Out: CF = 0, the ASCIIZ name at the buffer, DE at its 0; CF = 1 when
;      hw_profile is not ESP / RTL / 3C509B (nothing written).
; Clobbers AF, B, DE, HL.
; ----------------------------------------------------------------------
UG_NETNAME
	LD	A,(IX+UNETG_CFG_HW_PROFILE)
	DEC	A
	CP	3
	CCF
	RET	C
	PUSH	AF			; [hw - 1]
	LD	A,'G'
	LD	(DE),A
	INC	DE
	LD	A,(IX+UNETG_CFG_TRANSPORT)
	CP	UNETG_TRANSPORT_TCP
	LD	A,0			; "TCP"
	JR	Z,.tp
	INC	A			; "UDP"
.tp
	CALL	.put
	POP	AF
	ADD	A,2			; "ESP" / "RTL" / "509B"
	CALL	.put
	LD	A,5			; ".DLL"
.put
	LD	HL,UGE_PARTS
	CALL	UGE_NTH
.copy
	LD	A,(HL)
	LD	(DE),A
	OR	A
	RET	Z			; CF = 0
	INC	HL
	INC	DE
	JR	.copy

; ---- tables ----------------------------------------------------------
	MACRO	UGE_ITEM_ var, parser, field
	DB	var
	DW	parser
	DB	field
	ENDM

UGE_NETS
	DB	"WIFI",0,UNETG_HW_ESP
	DB	"ESP",0,UNETG_HW_ESP
	DB	"RTL",0,UNETG_HW_RTL
	DB	"509B",0,UNETG_HW_EL3
	DB	0
UGE_LISTS				; by UNETG_HW_* - 1
	DW	UGE_L_ESP, UGE_L_RTL, UGE_L_EL3
UGE_I_HW
	UGE_ITEM_ 0, UGE_H_HW, UNETG_CFG_ISA_SLOT
UGE_L_ESP
	UGE_ITEM_ UGN_V_BAUD | UGE_OPT, UGE_H_BAUD, UNETG_CFG_UART_DIVISOR
	UGE_ITEM_ UGN_V_ESP_FLOW, UGE_H_FLOW, UNETG_CFG_UART_FLOW
	DB	UGE_END
UGE_L_EL3
	UGE_ITEM_ UGN_V_IDPORT | UGE_OPT, UGE_H_ID, UNETG_CFG_ID_PORT
UGE_L_RTL
	UGE_ITEM_ UGN_V_IP, UGE_H_IP, UNETG_CFG_LOCAL_IP
	UGE_ITEM_ UGN_V_MASK, UGE_H_IP, UNETG_CFG_NETMASK
	UGE_ITEM_ UGN_V_GW | UGE_OPT, UGE_H_IP, UNETG_CFG_GATEWAY_IP
	UGE_ITEM_ UGN_V_MAC | UGE_OPT, UGE_H_MAC, UNETG_CFG_MAC
	DB	UGE_END
UGE_NAMES				; by UGN_V_*
	DB	"NET",0
	DB	"NET_ESP_HW",0
	DB	"NET_RTL_HW",0
	DB	"NET_HW",0
	DB	"NET_IDPORT",0
	DB	"NET_IP",0
	DB	"NET_MASK",0
	DB	"NET_GW",0
	DB	"NET_MAC",0
	DB	"NET_BAUD",0
	DB	"NET_ESP_FLOW",0
UGE_PARTS
	DB	"TCP",0,"UDP",0,"ESP",0,"RTL",0,"509B",0,".DLL",0
UGE_SIZE	EQU	$ - UG_NETENV
	ASSERT	UGE_SIZE <= 860, "ugenv.asm grew"
