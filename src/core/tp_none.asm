; tp_none.asm -- transport placeholder for card builds before their
; transport exists: OPEN is accepted and, with no peer answering, ends in
; TIMEOUT(OPEN) + CLOSED after connect_timeout_ms, as on a silent network.

TP_OPEN
TP_CLOSE
TP_ABORT
TP_RESET
TP_DEADLINES
	RET

TP_STEP
	LD	A,(IY+CX_CHAN)
	CP	UCH_CLOSING
	RET	NZ
	BIT	1,(IY+CX_CHAN_FLAGS)
	RET	NZ
	LD	A,UTX_DONE_FAILED
	JP	CH_TERMINATE
