; ugbase.inc -- the stand programs' common base, shared by UGTEST
; (sdk/example/ugtest.asm) and UGPROBE (tools/measure/ugprobe.asm): the IM1
; frame hook and now_ms, CTC2 -> CTC3 durations and their calibration
; against the frame, millisecond deadlines and the in-memory text report
; ("UGTREP1" block that tools/mame/ugstand.lua collects).
;
; The includer defines UG_REPORT / UG_REPORT_LEN (the report block) and
; includes this file inside its ORG'd EXE image.  Labels are global: the
; M stand (ugstand.lua) reads ticks, now_ms and UG_REPORT by symbol.

P_CTC2		EQU	0x12
P_CTC3		EQU	0x13
RP_STATUS	EQU	8		; report: "UGTREP1",0, status ('R' running, 'P', 'F'), reason
RP_TEXT		EQU	16
CTC_CHAIN	EQU	0x57		; counter mode, constant follows, reset, no interrupt

; ----------------------------------------------------------------------
; Time.  now_ms = frame ticks x 20: an IM1 hook counts the 50 Hz frame
; interrupts (DSS lets a program replace the JP target at #0039).
; Durations: CTC2 in timer mode (prescaler 16, /256) -> CTC3 counting its
; zero counts (/256): a phase in units of 16 CTC clocks, calibrated against
; the frame tick at start (cal_ctc = counts per frame, cal_loop = loops of
; a 35-T loop per frame: the CPU speed).
; ----------------------------------------------------------------------
IM1_VECTOR	EQU	0x0039
tick_install
	DI
	LD	HL,(IM1_VECTOR)
	LD	(im1_old),HL
	LD	HL,im1_tick
	LD	(IM1_VECTOR),HL
	EI
	RET
tick_remove
	DI
	LD	HL,(im1_old)
	LD	(IM1_VECTOR),HL
	EI
	RET
im1_tick
	PUSH	HL
	LD	HL,(ticks)
	INC	HL
	LD	(ticks),HL
	POP	HL
	DB	0xC3			; JP to the DSS handler
im1_old	DW	0

ctc_init
	DI
	LD	A,0x07			; timer, prescaler 16, constant follows, reset
	OUT	(P_CTC2),A
	XOR	A			; 256
	OUT	(P_CTC2),A
	LD	A,CTC_CHAIN		; counter of CTC2 zero counts
	OUT	(P_CTC3),A
	XOR	A
	OUT	(P_CTC3),A
	EI
	RET
ctc_stop
	LD	A,0x03			; channel reset
	OUT	(P_CTC2),A
	OUT	(P_CTC3),A
	RET

; ctc_phase: HL = elapsed counts (16 CTC clocks) in the CTC3 period
; (CTC3, CTC2, CTC3 again, as Worms ctcnow.inc).  Clobbers A, BC.
ctc_phase
.retry
	IN	A,(P_CTC3)
	LD	B,A
	IN	A,(P_CTC2)
	LD	C,A
	IN	A,(P_CTC3)
	CP	B
	JR	NZ,.retry
	XOR	A
	SUB	B
	LD	H,A
	XOR	A
	SUB	C
	LD	L,A
	RET

wait_tick
	LD	A,(ticks)
	LD	B,A
.w
	LD	A,(ticks)
	CP	B
	JR	Z,.w
	RET

calibrate
	CALL	wait_tick
	CALL	ctc_phase
	LD	(cal_p0),HL
	CALL	wait_tick
	CALL	ctc_phase
	LD	DE,(cal_p0)
	OR	A
	SBC	HL,DE
	LD	(cal_ctc),HL
	CALL	wait_tick
	LD	DE,0
	LD	HL,(ticks)
.loop
	INC	DE			; 6 + 13 + 4 + 12 = 35 T
	LD	A,(ticks)
	CP	L
	JR	Z,.loop
	LD	(cal_loop),DE
	RET

; clk_update: now_ms = ticks x 20.  Clobbers A, BC, DE, HL.
clk_update
	LD	HL,(ticks)		; one instruction: no torn read
	XOR	A
	ADD	HL,HL
	ADC	A,A			; x2
	ADD	HL,HL
	ADC	A,A			; x4
	PUSH	AF
	PUSH	HL
	ADD	HL,HL
	ADC	A,A			; x8
	ADD	HL,HL
	ADC	A,A			; x16
	POP	DE
	POP	BC			; B = high byte of x4
	ADD	HL,DE
	ADC	A,B			; x20
	LD	(now_ms),HL
	LD	(now_ms + 2),A
	XOR	A
	LD	(now_ms + 3),A
	RET

; dl_set: deadline = now + HL ms (16-bit horizon is enough here)
dl_set
	PUSH	HL
	CALL	clk_update
	POP	HL
	LD	DE,(now_ms)
	ADD	HL,DE
	LD	(deadline),HL
	RET
; dl_due: CF=1 when the deadline is reached
dl_due
	CALL	clk_update
	LD	HL,(deadline)
	LD	DE,(now_ms)
	OR	A
	SBC	HL,DE
	BIT	7,H
	SCF
	RET	NZ			; past
	LD	A,H
	OR	L
	SCF
	RET	Z
	OR	A
	RET

; ----------------------------------------------------------------------
; Report: "UGTREP1",0 / status / text (CR LF lines, zero-terminated)
; ----------------------------------------------------------------------
rep_init
	LD	HL,UG_REPORT
	LD	DE,UG_REPORT + 1
	LD	BC,UG_REPORT_LEN - 1
	LD	(HL),0
	LDIR
	LD	HL,s_magic
	LD	DE,UG_REPORT
	LD	BC,8
	LDIR
	LD	A,'R'
	LD	(UG_REPORT + RP_STATUS),A
	LD	HL,UG_REPORT + RP_TEXT
	LD	(rp_ptr),HL
	RET
; rp_char: append A (kept).  Clobbers nothing else.
rp_char
	PUSH	HL
	PUSH	DE
	LD	HL,(rp_ptr)
	LD	DE,UG_REPORT + UG_REPORT_LEN - 2
	PUSH	HL
	OR	A
	SBC	HL,DE
	POP	HL
	JR	NC,.full
	LD	(HL),A
	INC	HL
	LD	(HL),0
	LD	(rp_ptr),HL
.full
	POP	DE
	POP	HL
	RET
rp_str
	LD	A,(HL)
	OR	A
	RET	Z
	CALL	rp_char
	INC	HL
	JR	rp_str
rp_nl
	LD	HL,s_crlf
	JR	rp_str
rp_hex16
	LD	A,H
	CALL	rp_hex8
	LD	A,L
rp_hex8
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
	CP	'9' + 1
	JR	C,.d
	ADD	A,7
.d
	CALL	rp_char
	POP	AF
	RET
; rp_dump: label HL, then B bytes from DE in hex, one line
rp_dump
	PUSH	DE
	PUSH	BC
	CALL	rp_str
	POP	BC
	POP	DE
.b
	LD	A,(DE)
	CALL	rp_hex8
	INC	DE
	DJNZ	.b
	JP	rp_nl

s_magic		DB	"UGTREP1", 0
s_crlf		DB	13, 10, 0
now_ms		DD	0
ticks		DW	0
cal_p0		DW	0
cal_ctc		DW	0
cal_loop	DW	0
deadline	DW	0
rp_ptr		DW	0
