; none.asm -- hardware layer of builds without a card (GLOOP) and the M1
; placeholder of card builds whose hardware layer is not implemented yet:
; the card is never touched, so the stop phase is immediately safe (and
; STEP_ISR, which polls only a running card, does nothing).

HW_STEP
	LD	A,(IY+CX_HW_STATE)
	CP	UHW_STOP
	RET	NZ
	LD	(IY+CX_HW_STATE),UHW_STOPPED
	RET
