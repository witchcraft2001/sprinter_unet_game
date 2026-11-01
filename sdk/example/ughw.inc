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

DSS_CREATE	EQU	0x0A		; HL = name; out A = handle, CF = 1 error
DSS_WRITE	EQU	0x14		; A = handle, HL = buffer, DE = length
DSS_CLOSE	EQU	0x12		; A = handle
DSS_PUTCHAR	EQU	0x5B		; A = char, straight to the screen

; hw_args: fill scen_char / hw_argnum from the DSS command line.
; Clobbers A, B, C, D, E, H, L, IX.
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

s_hw_savefail	DB	"SAVE FAIL ",0
s_hw_crlf	DB	13,10,0
s_hw_full	DB	"REPORT FULL", 13, 10
s_hw_full_end	EQU	$
		DB	0
s_txtext	DB	".TXT", 0
hw_fname_pfx	UG_HWPFX

cmdline_ptr	DW	0
hw_argbuf	DS	64
hw_argbuf_end	EQU	$
scen_char	DB	0
hw_argnum	DW	0
hw_fh		DB	0
hw_len		DW	0
hw_fname	DS	16, 0
