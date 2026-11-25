; ugat.inc -- the answer of an AT command in a stand program's report
; (UGTEST, NETDEMO and UGPROBE at_cmd; needs the program's rp_char).
;
; A module may pour what a past session left in it into the answer: the
; held data of a soak's last reads, +IPD datagrams that waited behind RTS.
; On the board (the first ESP series, 2026-11-24) such an answer filled
; NETDEMO's report ("REPORT FULL") and a 'K' inside the binary data ended
; the answer early.  The report gets printable bytes only, at most
; AT_ECHO_MAX of them per answer, and the answer ends at "OK".

AT_ECHO_MAX	EQU	48

; at_start: a new answer.  Clobbers A.
at_start
	LD	A,AT_ECHO_MAX
	LD	(at_cap),A
	XOR	A
	LD	(at_prev),A
	RET

; at_answer: byte A of the answer.  Out: Z when it completes "OK".
; Clobbers A, BC, HL.
at_answer
	LD	HL,at_prev
	LD	C,(HL)			; C = the byte before
	LD	(HL),A
	LD	B,A
	CP	' '
	JR	C,.end			; CR, LF, NUL, binary: not in the report
	CP	0x7F
	JR	NC,.end
	LD	HL,at_cap
	LD	A,(HL)
	OR	A
	JR	Z,.end
	DEC	(HL)
	LD	A,B
	CALL	rp_char
.end
	LD	A,C
	CP	'O'
	RET	NZ
	LD	A,B
	CP	'K'
	RET

at_cap		DB	0
at_prev		DB	0
