; ughw.inc -- DSS-only helpers for the UG_HW (real-hardware stand, Ж)
; build of UGTEST/NETDEMO.  Included only as `IFDEF UG_HW \ INCLUDE
; "ughw.inc" \ ENDIF` from the host program: the M-stand build (plain
; UGTEST.EXE/NETDEMO.EXE under ugstand.lua) never defines UG_HW and never
; assembles this file, so its DSS calls never reach the gateway/core model.
;
; Assumes the including file already defines DSS (RST #10 selector),
; DSS_PCHARS, DSS_EXIT, RP_TEXT and the report routines (rp_ptr, rp_char,
; ...) as sdk/example/ugtest.asm and netdemo.asm do, and has saved the
; command-line pointer DSS passes in IX at entry into `cmdline_ptr`
; *before* anything else overwrites IX (sprinter_ai_doc 05_dss_exe.md
; "Командная строка": IX = load-#80 at entry, [IX+0] = argument string
; length, text from [IX+1], space-separated, 0-terminated -- DSS_APPINFO
; #47 B=0 does not return this on this DSS, only the IX buffer does).
;
; hw_args   -- the DSS command line (cmdline_ptr) into hw_argbuf;
;              scen_char = its first non-space byte, upper case (0 if
;              empty),
;              hw_argnum = the first decimal integer in the next
;              space-separated token (0 if none, e.g. for "K 10" on
;              UGTEST's soak scenario).
; hw_save   -- write the in-memory report (UG_REPORT, the bytes rp_ptr
;              has actually filled) to an 8.3 ASCIIZ file name in HL via
;              DSS CREATE/WRITE/CLOSE (CREATE #0A truncates an existing
;              file: a repeated run overwrites its report; #0B would
;              refuse).  Best-effort: a CREATE or WRITE error prints
;              "SAVE FAIL xx" to the screen and returns without failing
;              the run -- the report stays on screen for a manual photo.
;              A report that filled UG_REPORT (rp_char stops silently)
;              gets a "REPORT FULL" line in the file and on the screen.
; hw_exit   -- DSS EXIT (B=0) instead of UGTEST/NETDEMO's own .spin, so a
;              BAT file can chain scenario runs without a manual reset
;              (`finish` has already printed the report).
; hw_show   -- print the report text added since the last hw_show to the
;              screen (DSS PCHARS): the operator sees what is running
;              before the run ends, the final call prints the rest.
;              Not between the first STEP and SHUTDOWN (a DSS print
;              takes milliseconds), and never after IM 2 (NETDEMO).
; hw_lport  -- a local port of this run's own for an INIT_CONFIG block
;              whose local_port is 0 (line "LPORT xxxx").  The core's
;              ephemeral port comes from now_ms at OPEN, and a stand
;              program's now_ms starts at 0: every run would use nearly
;              the same port, and after a run that leaves its connection
;              open on the host (scenario D: v1 sends no RST) the next SYN
;              from that port gets no SYN-ACK (the Zh failure of NETDEMO W
;              after D; the M stand passes its own port, run_m.py).
; hw_find   -- which of the two ISA slots answers as the program's card
;              (presence signatures below); hw_slot adds the slot to use
;              and the report line "SLOT c mm u".  A stand program calls
;              it before its first own ISA access and before INIT_CONFIG:
;              a wrong HW_SLOT_* in tools/hw/hw.env (the slots are 0 and
;              1, as #E2 = #D4 / #D6 and the `-s` of the old drivers)
;              would otherwise end in BAD_CONFIG or in a probe of nothing.
;              Needs SH_1FFD / SH_9FBD (the DSS values of #1FFD / #9FBD
;              while no ISA window is open) and UG_CARD ('E', 'R', '3':
;              only that card's test is assembled -- NETDEMO has no room
;              for the others; 0 = all three, UGPROBE) from the including
;              file.

DSS_CREATE	EQU	0x0A		; HL = name; out A = handle, CF = 1 error
DSS_WRITE	EQU	0x14		; A = handle, HL = buffer, DE = length
DSS_CLOSE	EQU	0x12		; A = handle
DSS_PUTCHAR	EQU	0x5B		; A = char, straight to the screen
DSS_SYSTIME	EQU	0x21		; out H:L:B = hours, minutes, seconds (clobbers IX)
DSS_SCANKEY	EQU	0x31		; ZF = 1: no key; else A = its code (consumed)

HWF_EL3_MFG	EQU	0x6D50		; 3C509B EEPROM word 7: 3Com manufacturer ID
HWF_EL3_EEW7	EQU	0x87		; ID port: read EEPROM word 7
HWF_EL3_RESET	EQU	0xC0		; ID port: global reset (UNET509B DISCOVER)

; hw_args: fill scen_char / hw_argnum from the DSS command line.
; Clobbers A, B, C, D, E, H, L, IX.  Assembled only for a program that
; calls it (UGTEST, UGPROBE): NETDEMO keeps -DSCEN and has no room for it.
	IFUSED	hw_args
hw_args
	LD	IX,(cmdline_ptr)
	LD	A,(IX+0)		; argument text length
	CP	hw_argbuf_end - hw_argbuf
	JR	C,.len_ok
	LD	A,hw_argbuf_end - hw_argbuf - 1
.len_ok
	LD	C,A
	LD	B,0
	LD	DE,hw_argbuf
	OR	A
	JR	Z,.no_args
	PUSH	IX
	POP	HL
	INC	HL
	LDIR
.no_args
	XOR	A
	LD	(DE),A			; ASCIIZ terminator
	LD	(scen_char),A
	LD	HL,0
	LD	(hw_argnum),HL
	LD	IX,hw_argbuf
.skip_sp
	LD	A,(IX+0)
	OR	A
	RET	Z
	CP	' '
	JR	NZ,.got_scen
	INC	IX
	JR	.skip_sp
.got_scen
	CP	'a'
	JR	C,.upper
	CP	'z'+1
	JR	NC,.upper
	SUB	'a'-'A'
.upper
	LD	(scen_char),A
	INC	IX
.skip_tok
	LD	A,(IX+0)
	OR	A
	RET	Z
	CP	' '
	JR	Z,.after_tok
	INC	IX
	JR	.skip_tok
.after_tok
	INC	IX
.num_skip_sp
	LD	A,(IX+0)
	OR	A
	RET	Z
	CP	' '
	JR	NZ,.num
	INC	IX
	JR	.num_skip_sp
.num
	LD	HL,0
.num_loop
	LD	A,(IX+0)
	CP	'0'
	JR	C,.num_done
	CP	'9'+1
	JR	NC,.num_done
	SUB	'0'
	PUSH	AF
	LD	D,H
	LD	E,L
	ADD	HL,HL		; *2
	ADD	HL,HL		; *4
	ADD	HL,DE		; *5
	ADD	HL,HL		; *10
	POP	AF
	LD	E,A
	LD	D,0
	ADD	HL,DE
	INC	IX
	JR	.num_loop
.num_done
	LD	(hw_argnum),HL
	RET
	ENDIF

; hw_save: HL = ASCIIZ 8.3 file name.  Saves the printable text only (from
; UG_REPORT + RP_TEXT, the same start report_text() in ugstand.lua uses),
; not the 16-byte magic/status header.  Clobbers A, BC, DE, HL.
hw_save
	PUSH	HL
	LD	HL,(rp_ptr)
	LD	DE,UG_REPORT + RP_TEXT
	OR	A
	SBC	HL,DE
	LD	(hw_len),HL
	POP	HL
	LD	C,DSS_CREATE
	RST	DSS
	JR	C,.fail
	LD	(hw_fh),A
	LD	HL,UG_REPORT + RP_TEXT
	LD	DE,(hw_len)
	LD	C,DSS_WRITE
	RST	DSS
	JR	C,.wfail
	CALL	hw_full
	JR	NC,.close
	LD	A,(hw_fh)
	LD	HL,s_hw_full
	LD	DE,s_hw_full_end - s_hw_full
	LD	C,DSS_WRITE
	RST	DSS
	JR	C,.wfail
.close
	LD	A,(hw_fh)
	LD	C,DSS_CLOSE
	RST	DSS
	CALL	hw_full
	RET	NC
	LD	HL,s_hw_full
	LD	C,DSS_PCHARS
	RST	DSS
	RET
.wfail
	PUSH	AF
	LD	A,(hw_fh)
	LD	C,DSS_CLOSE
	RST	DSS
	POP	AF
.fail
	LD	HL,s_hw_savefail
	LD	C,DSS_PCHARS
	RST	DSS
	CALL	hw_scr_hex8
	LD	HL,s_hw_crlf
	LD	C,DSS_PCHARS
	RST	DSS
	RET

; hw_show: print UG_REPORT from where the last hw_show stopped (the
; report is always 0-terminated at rp_ptr).  Clobbers A, BC, DE, HL.
hw_show
	LD	HL,(hw_shown)
	LD	A,H
	OR	L
	JR	NZ,.from
	LD	HL,UG_REPORT + RP_TEXT
.from
	LD	DE,(rp_ptr)
	LD	(hw_shown),DE
	LD	C,DSS_PCHARS
	RST	DSS
	RET

; hw_bring: the card has just reached UHW_RUN.  In: HL = ms spent in the
; bring-up.  Reports "BRING tttt pp": the time and the card scratch byte
; hwsm[43] (unetg_eth.inc HS_TMP; on the 3C509B it is el3.asm HS_PASS
; until the first frame: 00 = attached, 01 = the bring-up had to use the
; ID-port global reset, which drops the link for seconds).  The seventh
; 3C509B series had 4 runs of 28 with 4..5 ARP requests and nothing in
; the reports to tell a reset from a lost answer.  Clobbers A, DE, HL.
; UGPROBE has no context: assembled only when called.
	IFUSED	hw_bring
hw_bring
	PUSH	HL
	LD	HL,hw_s_bring
	CALL	rp_str
	POP	HL
	CALL	rp_hex16
	LD	A,' '
	CALL	rp_char
	LD	A,(UG_CTX + UCTX_HWSM + 43)
	CALL	rp_hex8
	JP	rp_nl
hw_s_bring	DB	"BRING ", 0
	ENDIF

; hw_lport: HL -> the u16 local_port of an INIT_CONFIG block.  A zero
; port becomes 0xC000 + (minutes x 60 + seconds) x 4 + 2 bits of R: one
; port per run for an hour (the RTC), the R bits in case the RTC stands
; still.  Reports "LPORT xxxx".  Clobbers A, BC, DE, HL; keeps IX.
	IFUSED	hw_lport
hw_lport
	LD	A,(HL)
	INC	HL
	OR	(HL)
	RET	NZ			; a configured port stays
	PUSH	HL
	PUSH	IX
	LD	C,DSS_SYSTIME
	RST	DSS
	POP	IX
	LD	H,0			; L = minutes: x 60 = x 64 - x 4
	ADD	HL,HL
	ADD	HL,HL
	LD	D,H
	LD	E,L
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,HL
	OR	A
	SBC	HL,DE
	LD	E,B			; + seconds
	LD	D,0
	ADD	HL,DE
	ADD	HL,HL
	ADD	HL,HL			; x 4: <= 14396
	LD	A,R
	AND	3
	OR	L
	LD	E,A
	LD	A,H
	OR	0xC0
	LD	D,A
	POP	HL			; -> the high byte of the field
	LD	(HL),D
	DEC	HL
	LD	(HL),E
	PUSH	DE
	LD	HL,s_hw_lport
	CALL	rp_str
	POP	HL
	CALL	rp_hex16
	JP	rp_nl
s_hw_lport	DB	"LPORT ",0
	ENDIF

; hw_full: CF = 1 when the report reached rp_char's limit (the last
; byte it would still write; anything after it was dropped).
; Clobbers A, DE, HL.
hw_full
	LD	HL,(rp_ptr)
	LD	DE,UG_REPORT + UG_REPORT_LEN - 2
	OR	A
	SBC	HL,DE
	CCF
	RET

; hw_scr_hex8: print A in hex straight to the screen (rp_hex8 is for the
; in-memory report).  Clobbers A, C.
hw_scr_hex8
	PUSH	AF
	RRA
	RRA
	RRA
	RRA
	CALL	.nib
	POP	AF
.nib
	PUSH	AF
	AND	0x0F
	ADD	A,'0'
	CP	'9'+1
	JR	C,.d
	ADD	A,7
.d
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	AF
	RET

; hw_exit: does not return.
hw_exit
	LD	B,0
	LD	C,DSS_EXIT
	RST	DSS
.spin					; DSS EXIT does not return either, but just in case
	JR	.spin

; hw_build_fname: hw_fname = ["B:" if UG_HW_MTEST] + hw_fname_pfx
; (UG_HWPFX, 5 bytes) + scen_char + ".TXT" + 0.  UG_HW_MTEST is the M
; stand's own --hw run (run_m.py): the DSS session's current directory is
; not the B: floppy holding the EXE/DLL, so the saved report would miss
; the disk run_m.py later mcopy's from; real Ж builds never set it, and
; save wherever the launched program's own directory already is.
; Clobbers A, BC, DE, HL.
hw_build_fname
	LD	HL,hw_fname
	IFDEF	UG_HW_MTEST
	LD	(HL),'B'
	INC	HL
	LD	(HL),':'
	INC	HL
	LD	(HL),'\'
	INC	HL
	ENDIF
	EX	DE,HL
	LD	HL,hw_fname_pfx
	LD	BC,5
	LDIR
	LD	A,(scen_char)
	LD	(DE),A
	INC	DE
	LD	HL,s_txtext
	LD	BC,5
	LDIR
	RET

; ----------------------------------------------------------------------
; hw_find: which ISA slots answer as card A.
; In:  A = card -- 'E' SprinterESP's TL16C550C (IER bits 7..4 read 0, the
;      scratch register at io+7 keeps 0x55 and 0xAA: esplib UART_FIND),
;      'R' RTL8019AS (page-0 8019ID0/1 at io+0x0A/+0x0B read 'P','p';
;      CR = 0x21 -- stop, page 0 -- is written first in the configured
;      slot only, the other slot is only read), '3' 3C509B (ID sequence
;      on the ID port, EEPROM word 7 = 0x6D50 through the ID port; a
;      second pass after an ID-port global reset, as UNET509B DISCOVER,
;      for a card an earlier driver left activated; the card stays
;      un-activated: the core's bring-up starts with the ID sequence);
;      HL = 0xC000 + io base, DE = 0xC000 + ID port (3C509B), C = the
;      configured slot (0 or 1).
; Out: A = hwf_mask: bit s set = slot s answered.
; Every access group runs in its own short DI section with the window
; opened and restored as the core does (#E2 saved, #1FFD | #10, #E2 =
; #D4 | slot << 1, #9FBD = 0; back to SH_9FBD, SH_1FFD, the saved #E2),
; then EI; the 3C509B EEPROM wait (>= 162 us; ~5 ms here) is outside.
; Clobbers everything but IX, IY.  Cost: ~25 ms worst (3C509B, 2 slots x
; 2 passes).
hw_find
	LD	(hwf_card),A
	LD	(hwf_io),HL
	LD	(hwf_id),DE
	LD	A,C
	LD	(hwf_cfg),A
	XOR	A
	LD	(hwf_mask),A
	LD	(hwf_slot),A
	CALL	hwf_one
	LD	A,1
	LD	(hwf_slot),A
	CALL	hwf_one
	LD	A,(hwf_mask)
	RET

; hwf_one: test slot hwf_slot, set its bit in hwf_mask when it answers.
HWF_E	EQU	UG_CARD == 0 || UG_CARD == 'E'
HWF_R	EQU	UG_CARD == 0 || UG_CARD == 'R'
HWF_3	EQU	UG_CARD == 0 || UG_CARD == '3'
hwf_one
	IF	UG_CARD == 0
	LD	A,(hwf_card)
	CP	'R'
	JR	Z,.rtl
	CP	'3'
	JR	Z,.el3
	CALL	hwf_esp
	JR	.got
.rtl
	CALL	hwf_rtl
	JR	.got
.el3
	CALL	hwf_el3
.got
	ELSE
	IF	HWF_E
	CALL	hwf_esp
	ENDIF
	IF	HWF_R
	CALL	hwf_rtl
	ENDIF
	IF	HWF_3
	CALL	hwf_el3
	ENDIF
	ENDIF
	RET	NC
	LD	A,(hwf_slot)
	INC	A			; slot 0 -> bit 0 (1), slot 1 -> bit 1 (2)
	LD	B,A
	LD	A,(hwf_mask)
	OR	B
	LD	(hwf_mask),A
	RET

; hwf_esp / hwf_rtl / hwf_el3: CF = 1 when slot hwf_slot answers.
	IF	HWF_E
hwf_esp
	CALL	hwf_open
	LD	HL,(hwf_io)
	INC	HL			; +1 IER: bits 7..4 always read 0
	LD	A,(HL)
	AND	0xF0
	JR	NZ,hwf_no
	LD	DE,6
	ADD	HL,DE			; +7 SCR
	LD	(HL),0x55
	LD	A,(HL)
	CP	0x55
	JR	NZ,hwf_no
	LD	(HL),0xAA
	LD	A,(HL)
	CP	0xAA
	JR	NZ,hwf_no
	ENDIF
hwf_yes
	CALL	hwf_close
	SCF
	RET
hwf_no
	CALL	hwf_close
	OR	A
	RET

	IF	HWF_R
hwf_rtl
	CALL	hwf_open
	LD	A,(hwf_cfg)
	LD	B,A
	LD	A,(hwf_slot)
	CP	B
	JR	NZ,.read		; not the configured slot: read only
	LD	HL,(hwf_io)
	LD	(HL),0x21		; CR: stop, page 0, abort remote DMA
	LD	B,16
.settle
	DJNZ	.settle			; write-to-read recovery (UNETRTL IS_REALTEK)
.read
	LD	HL,(hwf_io)
	LD	DE,0x0A
	ADD	HL,DE
	LD	A,(HL)
	CP	'P'
	JR	NZ,hwf_no
	INC	HL
	LD	A,(HL)
	CP	'p'
	JR	NZ,hwf_no
	JR	hwf_yes
	ENDIF

	IF	HWF_3
hwf_el3
	XOR	A
	LD	(hwf_pass),A
.pass
	CALL	hwf_idseq
	LD	A,(hwf_pass)
	OR	A
	JR	Z,.read
	LD	A,HWF_EL3_RESET
	CALL	hwf_idw
	LD	B,4
.rwait
	PUSH	BC
	CALL	hwf_wait
	POP	BC
	DJNZ	.rwait
	CALL	hwf_idseq
.read
	LD	A,HWF_EL3_EEW7
	CALL	hwf_idw
	CALL	hwf_wait
	CALL	hwf_open
	LD	HL,(hwf_id)
	LD	DE,0
	LD	B,16
.bit
	SLA	E
	RL	D
	LD	A,(HL)
	AND	1
	OR	E
	LD	E,A
	DJNZ	.bit
	CALL	hwf_close		; keeps DE
	LD	HL,HWF_EL3_MFG
	OR	A
	SBC	HL,DE
	JR	NZ,.miss
	SCF
	RET
.miss
	LD	A,(hwf_pass)
	OR	A
	RET	NZ			; CF = 0: both passes missed
	INC	A
	LD	(hwf_pass),A
	JR	.pass

; hwf_idseq: two zero bytes, then the 255 LFSR bytes (0xFF, poly 0xCF) on
; the ID port, under one DI (~260 ISA writes).
hwf_idseq
	CALL	hwf_open
	LD	HL,(hwf_id)
	XOR	A
	LD	(HL),A
	LD	(HL),A
	LD	A,0xFF
	LD	B,255
.l
	LD	(HL),A
	ADD	A,A
	JR	NC,.n
	XOR	0xCF
.n
	DJNZ	.l
	JR	hwf_close

; hwf_idw: write A to the ID port.
hwf_idw
	LD	(hwf_tmp),A
	CALL	hwf_open
	LD	HL,(hwf_id)
	LD	A,(hwf_tmp)
	LD	(HL),A
	JR	hwf_close

	ENDIF

	IF	HWF_3
; hwf_wait: ~5 ms at 21 MHz (4096 x 26 T), longer at 7 MHz.  Clobbers A, BC.
hwf_wait
	LD	BC,4096
.l
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.l
	RET
	ENDIF

; hwf_open: DI, the ISA I/O window of slot hwf_slot.  Clobbers A, BC.
hwf_open
	DI
	IN	A,(0xE2)
	LD	(hwf_e2),A
	LD	BC,0x1FFD
	LD	A,SH_1FFD | 0x10
	OUT	(C),A
	LD	A,(hwf_slot)
	ADD	A,A
	OR	0xD4
	LD	BC,0x00E2
	OUT	(C),A
	XOR	A
	LD	BC,0x9FBD
	OUT	(C),A
	RET
; hwf_close: exact restore, EI.  Clobbers A, BC; keeps DE, HL.
hwf_close
	LD	BC,0x9FBD
	LD	A,SH_9FBD
	OUT	(C),A
	LD	BC,0x1FFD
	LD	A,SH_1FFD
	OUT	(C),A
	LD	A,(hwf_e2)
	LD	BC,0x00E2
	OUT	(C),A
	EI
	RET

; hw_slot: hw_find (same inputs), then the slot to use -- the configured
; one, unless only the other slot answered (then that one: the run still
; measures the card, and the report says hw.env is wrong) -- and the
; report line "SLOT c mm u" (configured, hwf_mask in hex, used).
; Out: A = the slot to use (0 or 1).  Clobbers everything but IX, IY.
hw_slot
	CALL	hw_find
	LD	B,A
	LD	A,(hwf_cfg)
	LD	C,A
	INC	A			; the configured slot's bit
	AND	B
	LD	A,C
	JR	NZ,.use
	LD	A,B
	OR	A
	LD	A,C
	JR	Z,.use			; nothing answered: keep the configuration
	XOR	1
.use
	LD	(hwf_used),A
	LD	HL,s_hw_slot
	CALL	rp_str
	LD	A,(hwf_cfg)
	ADD	A,'0'
	CALL	rp_char
	LD	A,' '
	CALL	rp_char
	LD	A,(hwf_mask)
	CALL	rp_hex8
	LD	A,' '
	CALL	rp_char
	LD	A,(hwf_used)
	ADD	A,'0'
	CALL	rp_char
	CALL	rp_nl
	LD	A,(hwf_used)
	RET

s_hw_slot	DB	"SLOT ",0
s_hw_savefail	DB	"SAVE FAIL ",0
s_hw_crlf	DB	13,10,0
s_hw_full	DB	"REPORT FULL", 13, 10
s_hw_full_end	EQU	$
		DB	0
s_txtext	DB	".TXT", 0
hw_fname_pfx	UG_HWPFX

cmdline_ptr	DW	0
	IFUSED	hw_args
hw_argbuf	DS	64
hw_argbuf_end	EQU	$
	ENDIF
scen_char	DB	0
hw_argnum	DW	0
hw_fh		DB	0
hw_len		DW	0
hw_fname	DS	16, 0
hw_shown	DW	0
hwf_card	DB	0
hwf_io		DW	0
hwf_id		DW	0
hwf_cfg		DB	0
hwf_slot	DB	0
hwf_mask	DB	0
hwf_used	DB	0
hwf_pass	DB	0
hwf_tmp		DB	0
hwf_e2		DB	0
