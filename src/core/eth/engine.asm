; engine.asm -- Ethernet engine shared by the RTL8019AS and 3C509B builds.
;
; HW_STEP (main) drives bring-up, the RX and TX pipelines and the stop
; phase as resumable states in ctx.hwsm; every card access is one bounded
; PORTION (<= NIC_CHUNK bytes) under the shared ISA lock.  Protocol work
; (classification, checksum verdicts, ARP/TCP/UDP) runs between portions
; with interrupts enabled.  STEP_ISR only samples the card status (ISRP_POLL).
;
; Card layer contract (src/hw/<card>): routines marked (P) run inside
; PORTION with IX = ctx.hwsm and must stay within the DI limit.
;   NIC_PREPARE        main: derive HS_IO / MAC source from the context
;   NIC_BRINGUP    (P) one bring-up step; HS_RES = NBR_*
;   NIC_RX_STATUS  (P) CF=1 no frame; else HL = length, A = 0 / 1 (error)
;   NIC_RX_READ    (P) DE = dest, B = 1..64, C = mode (NRX_*); DE advanced
;                      in the stored modes, preserved in NRX_SKIP
;   NIC_RX_LIMIT   (P) B = E = bytes of the next RX_READ (1..NIC_CHUNK): may
;                      lower both (RTL: never across the ring end); clobbers A, HL
;   NIC_RX_DISCARD (P) drop the rest of the current frame (start)
;   NIC_RX_DISC_DONE (P) CF=1 while the drop is in progress
;   NIC_TX_BEGIN   (P) HL = frame length; CF=1 when the card has no room
;   NIC_TX_WRITE   (P) HL = source, B = 1..NIC_CHUNK
;   NIC_TX_END     (P) pad and start transmission
;   NIC_TX_CHECK   (P) A = NTX_PENDING / NTX_OK / NTX_ERROR (recovered)
;   NIC_STOP       (P) one stop step; HS_RES = NBR_*
;   NIC_ISR_POLL   (P) CF=0 when a received frame is waiting

NRX_COPY	EQU	0
NRX_SUM		EQU	1	; copy and add to HS_SUM
NRX_SKIP	EQU	2	; add to HS_SUM only

NTX_PENDING	EQU	0
NTX_OK		EQU	1
NTX_ERROR	EQU	2

; Qualified upper bounds (units, 21 MHz): COST = max(real * 1.1, real + 15)
; rounded up to 5, real = the worst time of the item on the stand over the
; stream scenario at STEP periods of 2/10/20 ms on both cards
; (tools/dev/profile_step.js --items; docs/MEASUREMENTS.md).
; Lock + map + unmap + release ~ 30 us around the card routine.
COST_PORTION	EQU	110	; bracket + a short card step (EL3 poll 94 us)
COST_BRINGUP	EQU	195	; bracket + the longest bring-up step (RTL 177 us)
COST_RX_CHUNK	EQU	COST_PORTION + 3 * NIC_CHUNK + PROF_DMA_EXTRA_US	; 40 bytes read + summed (EL3 200, RTL 221 us)
COST_TX_CHUNK	EQU	COST_PORTION + 2 * NIC_CHUNK + PROF_DMA_EXTRA_US	; 40 bytes written (EL3 164, RTL 185 us)
COST_TX_BEGIN	EQU	250	; TX room check, preamble and a 54-byte header (228 us)
COST_TX_WAIT	EQU	125	; completion check + transport notification (108 us)
COST_CLASSIFY	EQU	205	; Ethernet/ARP/IPv4 checks and the IP header checksum (186 us)
COST_SUM0	EQU	145	; pseudo header + up to 30 segment bytes in scratch (130 us)
COST_ACCEPT	EQU	205	; transport accept: ports, state, header fields (186 us)
COST_STORE	EQU	150	; payload placement in the RX ring (TCP, 133 us)
COST_FINISH	EQU	240	; checksum verdict + transport input incl. ACK processing (219 us)
COST_PREPARE	EQU	70	; NIC_PREPARE + bring-up deadline (58 us)
COST_POLL	EQU	COST_PORTION + PROF_POLL_EXTRA_US	; status poll that may find a frame (RTL 131 us)
COST_ARP_PULL	EQU	125	; ARP frame into ctx.txh (112 us)
COST_TP_PULL	EQU	130	; UDP: IPv4 + UDP header with checksums (113 us)
BRINGUP_MS	EQU	3000	; whole bring-up deadline
TX_TIMEOUT_MS	EQU	50	; transmit completion
	ASSERT	COST_POLL <= PROF_MAX_ITEM_US && COST_BRINGUP <= PROF_MAX_ITEM_US
	ASSERT	COST_RX_CHUNK <= PROF_MAX_ITEM_US && COST_TX_CHUNK <= PROF_MAX_ITEM_US && COST_TX_BEGIN <= PROF_MAX_ITEM_US
	ASSERT	COST_CLASSIFY <= PROF_MAX_ITEM_US && COST_ACCEPT <= PROF_MAX_ITEM_US
	ASSERT	COST_STORE <= PROF_MAX_ITEM_US && COST_FINISH <= PROF_MAX_ITEM_US
	ASSERT	COST_SUM0 <= PROF_MAX_ITEM_US
	ASSERT	COST_TP_PULL <= PROF_MAX_ITEM_US && COST_TX_WAIT <= PROF_MAX_ITEM_US

; ----------------------------------------------------------------------
; ETH_SCHED: the work of a STEP with a running card (sched.asm), in an
; order that lets a frame in progress finish and still polls the card
; once per STEP (ТЗ §4.2) and runs the transport every STEP:
;  1. poll reserve: while the RX pipeline is idle (and STEP_ISR did not
;     just sample the card empty), COST_POLL is set aside for step 5 when
;     the largest item still fits besides it;
;  2. frames in progress: RX and TX continue (who goes first alternates
;     with bit 0 of the STEP counter), at most ETH_CONT_ITEMS items each
;     while the other direction is busy too, never past the frame end;
;  3. the transport step (timers, the next segment);
;  4. TX: ARP / transport pull for an idle pipeline, then its portions
;     while the budget lasts;
;  5. the poll (the reserve is given back first) and a found frame;
;  6. what is left goes to TX again.
; ----------------------------------------------------------------------
ETH_CONT_ITEMS	EQU	3
; HW_RUN (HW_STEP with a running card): sched.asm calls ETH_SCHED instead;
; kept as plain RX + TX for the hardware state machine's dispatch.
HW_RUN
	LD	(IY+CX_SCHED_ITEMS),0xFF
	CALL	ETH_RX_STEP
	LD	(IY+CX_SCHED_ITEMS),0xFF
	JP	ETH_TX_STEP
ETH_SCHED
	XOR	A
	LD	(IY+CX_SCHED_FLAGS),A
	; 1. poll reserve
	LD	A,(IY+EX_RXS)
	OR	A
	JR	NZ,.no_rsvd		; a frame is in progress: no poll this STEP
	LD	A,(IY+CX_ISR_PENDING)
	AND	(1 << UPEND_POLLED) | (1 << UPEND_RX)
	CP	1 << UPEND_POLLED
	JR	Z,.no_rsvd		; STEP_ISR just found the card empty
	; every other STEP (bit 0 of the STEP counter) the poll comes first;
	; otherwise only while the largest item still fits besides it, so a
	; small budget serves the frames and a busy TX does not starve RX
	CALL	ETH_STEP_ODD
	JR	NZ,.rsvd
	LD	L,(IY+CX_UNITS)
	LD	H,(IY+CX_UNITS+1)
	LD	DE,-(COST_POLL + PROF_MAX_ITEM_US)
	ADD	HL,DE
	JR	NC,.no_rsvd
.rsvd
	LD	HL,COST_POLL
	CALL	TAKE
	JR	C,.no_rsvd
	SET	USCH_POLL_RSVD,(IY+CX_SCHED_FLAGS)
.no_rsvd
	; 2. frames in progress
	SET	USCH_CONT,(IY+CX_SCHED_FLAGS)
	CALL	ETH_STEP_ODD
	JR	Z,.tx_cont
	CALL	ETH_RX_CONT
	CALL	ETH_TX_CONT
	JR	.tp
.tx_cont
	CALL	ETH_TX_CONT
	CALL	ETH_RX_CONT
.tp
	RES	USCH_CONT,(IY+CX_SCHED_FLAGS)
	; 3. transport
	CALL	TP_IF_RUNNING
	; 4. TX: a new frame and its portions
	CALL	ETH_TX_PHASE
	; 5. the card poll and a frame it finds (the reserve is given back
	; first: what stopped for lack of budget may fit again)
	BIT	USCH_POLL_RSVD,(IY+CX_SCHED_FLAGS)
	JR	Z,.poll
	LD	A,(IY+CX_SCHED_FLAGS)
	AND	~((1 << USCH_POLL_RSVD) | (1 << USCH_RX_STOP) | (1 << USCH_TX_STOP))
	LD	(IY+CX_SCHED_FLAGS),A
	LD	HL,COST_POLL
	CALL	UNITS_REFUND
.poll
	BIT	USCH_RX_STOP,(IY+CX_SCHED_FLAGS)
	JR	NZ,.rest
	CALL	ETH_AFFORD
	RET	C
	LD	(IY+CX_SCHED_ITEMS),0xFF
	CALL	ETH_RX_STEP
.rest
	; 6. the rest to a frame in progress
	LD	A,(IY+EX_TXS)
	OR	A
	RET	Z
	CP	ETX_WAIT
	RET	Z
ETH_TX_PHASE
	BIT	USCH_TX_STOP,(IY+CX_SCHED_FLAGS)
	RET	NZ			; stopped earlier in this STEP
	CALL	ETH_AFFORD
	RET	C
	LD	(IY+CX_SCHED_ITEMS),0xFF
	CALL	ETH_TX_STEP
	RET	NC
	SET	USCH_TX_STOP,(IY+CX_SCHED_FLAGS)
	RET

; ETH_STEP_ODD: NZ on odd STEPs (bit 0 of steps_total).  Clobbers BC, HL.
ETH_STEP_ODD
	LD	BC,UCTX_STATS - 4 + UNETG_STATS_STEPS_TOTAL - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,BC
	BIT	0,(HL)
	RET

; ETH_RX_CONT / ETH_TX_CONT: continue a frame in progress (USCH_CONT), at
; most ETH_CONT_ITEMS items while the other pipeline is busy too.  A
; pipeline that stops (CF) is not tried again in this STEP.
ETH_RX_CONT
	LD	A,(IY+EX_RXS)
	OR	A
	RET	Z			; RX idle
	CALL	ETH_AFFORD
	RET	C
	LD	A,(IY+EX_TXS)
	CALL	ETH_CONT_LIMIT
	CALL	ETH_RX_STEP
	RET	NC
	SET	USCH_RX_STOP,(IY+CX_SCHED_FLAGS)
	RET
ETH_TX_CONT
	LD	A,(IY+EX_TXS)
	OR	A
	RET	Z			; TX idle
	CP	ETX_WAIT
	RET	Z			; on the wire: the completion check is step 4
	CALL	ETH_AFFORD
	RET	C
	LD	A,(IY+EX_RXS)
	CALL	ETH_CONT_LIMIT
	CALL	ETH_TX_STEP
	RET	NC
	SET	USCH_TX_STOP,(IY+CX_SCHED_FLAGS)
	RET
; A = state of the other pipeline: limit this one while that one is busy.
ETH_CONT_LIMIT
	OR	A
	LD	A,0xFF
	JR	Z,.set
	LD	A,ETH_CONT_ITEMS
.set
	LD	(IY+CX_SCHED_ITEMS),A
	RET

; ETH_AFFORD: CF=1 (UWK_YIELD) when not even the cheapest card item is
; left: the phase is skipped instead of refusing item by item.
; Clobbers A, DE, HL.
ETH_MIN_ITEM	EQU	COST_PORTION
ETH_AFFORD
	LD	L,(IY+CX_UNITS)
	LD	H,(IY+CX_UNITS+1)
	LD	DE,-ETH_MIN_ITEM
	ADD	HL,DE
	CCF
	RET	NC
	SET	4,(IY+CX_WORK)		; UWK_YIELD
	RET

; ======================================================================
; RX pipeline
; ======================================================================
ETH_RX_STEP
	; A sample by STEP_ISR since the last STEP that found nothing makes
	; our own status poll redundant (it still runs when nobody polls).
	LD	A,(IY+CX_ISR_PENDING)
	RES	UPEND_POLLED,(IY+CX_ISR_PENDING)
	RES	UPEND_RX,(IY+CX_ISR_PENDING)
	AND	(1 << UPEND_POLLED) | (1 << UPEND_RX)
	CP	1 << UPEND_POLLED
	JR	NZ,.poll_allowed
	HWSM_IX
	LD	A,(IX+HS_RXS)
	OR	A
	RET	Z			; idle and the card was just sampled empty
.poll_allowed
	LD	C,4			; at most four frames per STEP
.next
	PUSH	BC
	CALL	.one			; CF=1: stop; A=1: a frame was finished
	POP	BC
	RET	C			; budget, bus or nothing to do
	DEC	(IY+CX_SCHED_ITEMS)	; ETH_SCHED: items of this phase
	RET	Z
	DEC	A
	JR	NZ,.next
	BIT	USCH_CONT,(IY+CX_SCHED_FLAGS)
	RET	NZ			; continuation ends with the frame
	DEC	C
	JR	NZ,.next
	RET
.one
	HWSM_IX
	LD	A,(IX+HS_RXS)
	OR	A
	JR	Z,.poll
	DEC	A
	JP	Z,.classify
	DEC	A
	JP	Z,.copy
	DEC	A
	JP	Z,.finish
	DEC	A
	JP	Z,.discard
	DEC	A
	JP	Z,.disc_wait
	DEC	A
	JP	Z,.header
	DEC	A
	JR	Z,.accept
	DEC	A
	JP	Z,.store
	; ERX_SUM0: pseudo header + segment bytes in scratch
	LD	HL,COST_SUM0
	CALL	TAKE
	RET	C
	CALL	ETH_SUM0
	XOR	A
	RET
.accept
	; ERX_ACCEPT: the transport decides where the segment goes
	LD	HL,COST_ACCEPT
	CALL	TAKE
	RET	C
	CALL	ETH_ACCEPT
	XOR	A
	RET
.store
	LD	HL,COST_STORE
	CALL	TAKE
	RET	C
	CALL	TP_RX_STORE
	XOR	A
	RET
.disc_wait
	LD	HL,COST_PORTION
	CALL	TAKE
	RET	C
	LD	HL,RXP_DISC_WAIT
	CALL	RUN_PORTION
	RET	C
	HWSM_IX
	LD	A,(IX+HS_RXS)
	OR	A
	SCF
	RET	NZ			; still discarding: next STEP
	LD	A,1			; CF=0 (OR A), one frame finished
	RET
.poll
	LD	HL,COST_POLL
	CALL	TAKE
	RET	C
	LD	HL,RXP_POLL
	CALL	RUN_PORTION
	RET	C
	HWSM_IX
	LD	A,(IX+HS_RXS)
	OR	A
	SCF
	RET	Z			; no frame waiting
	SET	0,(IY+CX_WORK)		; UWK_HW
	XOR	A
	RET
.header
	LD	HL,COST_RX_CHUNK
	CALL	TAKE
	RET	C
	LD	HL,RXP_HEADER
	CALL	RUN_PORTION
	RET	C
	XOR	A
	RET
.classify
	LD	HL,COST_CLASSIFY
	CALL	TAKE
	RET	C
	CALL	ETH_CLASSIFY
	XOR	A
	RET
.copy
	LD	HL,COST_RX_CHUNK
	CALL	TAKE
	RET	C
	LD	HL,RXP_COPY
	CALL	RUN_PORTION
	RET	C
	SET	2,(IY+CX_WORK)
	XOR	A
	RET
.finish
	LD	HL,COST_FINISH
	CALL	TAKE
	RET	C
	HWSM_IX
	LD	A,1
	BIT	0,(IX+HS_NOCHK)		; UDP with checksum 0: nothing to verify
	JR	NZ,.verdict
	LD	L,(IX+HS_SUM)
	LD	H,(IX+HS_SUM+1)
	LD	A,H
	AND	L
	INC	A			; Z <=> sum == 0xFFFF
	LD	A,1
	JR	Z,.verdict
	STAT_INC UNETG_STATS_DROP_CHECKSUM
	XOR	A
.verdict
	CALL	TP_RX_COMMIT		; A = 1 valid, 0 corrupt
	HWSM_IX
	LD	(IX+HS_RXS),ERX_DISCARD
	XOR	A
	RET
.discard
	LD	HL,COST_PORTION
	CALL	TAKE
	RET	C
	LD	HL,RXP_DISCARD
	CALL	RUN_PORTION
	RET	C
	XOR	A
	RET

; (P) poll the card; when a frame waits, read its first bytes into scratch.
RXP_POLL
	STAT_INC UNETG_STATS_POLLS_TOTAL
	CALL	NIC_RX_STATUS
	RET	C
	PUSH	HL
	PUSH	AF
	STAT_INC UNETG_STATS_POLLS_USEFUL	; clobbers BC, HL
	POP	AF
	POP	HL
	OR	A
	JR	NZ,.bad
	LD	(IX+HS_RXLEN),L
	LD	(IX+HS_RXLEN+1),H
	LD	(IX+HS_RXS),ERX_HDR_READ
	LD	DE,ETH_HDR + 1
	PUSH	HL
	OR	A
	SBC	HL,DE
	POP	HL
	JR	C,.bad			; shorter than a header
	LD	DE,ETH_MAX_FRAME + 1
	PUSH	HL
	OR	A
	SBC	HL,DE
	POP	HL
	JR	NC,.bad
	RET				; header read in the next portion
.bad
	STAT_INC UNETG_STATS_DROP_SIZE
	LD	(IX+HS_RXS),ERX_DISCARD
	RET

; (P) read the first bytes of the waiting frame into scratch.
RXP_HEADER
	LD	L,(IX+HS_RXLEN)
	LD	H,(IX+HS_RXLEN+1)
	LD	A,H
	OR	A
	LD	B,RX_HDR_BYTES
	JR	NZ,.read
	LD	A,L
	CP	RX_HDR_BYTES
	JR	NC,.read
	LD	B,L
.read
	LD	DE,UCTX_SCRATCH - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,DE
	EX	DE,HL
	LD	C,NRX_COPY
	CALL	NIC_RX_READ
	LD	(IX+HS_RXS),ERX_HDR
	STAT_INC UNETG_STATS_RX_FRAMES
	RET

; (P) one card portion of the accepted segment: header tail (summed),
; payload (stored + summed) or the unwanted rest (summed only).
RXP_COPY
	LD	L,(IX+HS_RXSKIP)
	LD	H,(IX+HS_RXSKIP+1)
	LD	A,H
	OR	L
	JR	Z,.store
	CALL	.chunk_of_hl		; B = min(HL, CHUNK)
	LD	C,NRX_SKIP
	CALL	NIC_RX_READ
	LD	A,(IX+HS_RXSKIP)
	SUB	E
	LD	(IX+HS_RXSKIP),A
	JR	NC,.rem
	DEC	(IX+HS_RXSKIP+1)
	JR	.rem
.store
	LD	L,(IX+HS_RXLIM)
	LD	H,(IX+HS_RXLIM+1)
	LD	A,H
	OR	L
	JR	Z,.tail
	CALL	.chunk_of_hl
	; never cross the end of the RX ring in one portion
	LD	L,(IX+HS_RXSPAN)
	LD	H,(IX+HS_RXSPAN+1)
	LD	A,H
	OR	A
	JR	NZ,.span_ok
	LD	A,L
	CP	B
	JR	NC,.span_ok
	LD	B,A
.span_ok
	LD	E,(IX+HS_RXDST)
	LD	D,(IX+HS_RXDST+1)
	PUSH	BC
	LD	C,NRX_SUM
	CALL	NIC_RX_READ		; DE advanced
	POP	BC
	LD	(IX+HS_RXDST),E
	LD	(IX+HS_RXDST+1),D
	LD	E,B
	LD	D,0
	LD	L,(IX+HS_RXLIM)
	LD	H,(IX+HS_RXLIM+1)
	OR	A
	SBC	HL,DE
	LD	(IX+HS_RXLIM),L
	LD	(IX+HS_RXLIM+1),H
	LD	L,(IX+HS_RXSPAN)
	LD	H,(IX+HS_RXSPAN+1)
	OR	A
	SBC	HL,DE
	JR	NZ,.span_left
	; wrapped: continue at the start of the RX slots
	LD	A,(IY+CX_RX_SLOTS_PTR)
	LD	(IX+HS_RXDST),A
	LD	A,(IY+CX_RX_SLOTS_PTR+1)
	LD	(IX+HS_RXDST+1),A
	LD	L,(IY+CX_RX_TOTAL)
	LD	H,(IY+CX_RX_TOTAL+1)
.span_left
	LD	(IX+HS_RXSPAN),L
	LD	(IX+HS_RXSPAN+1),H
	JR	.rem
.tail
	LD	L,(IX+HS_RXREM)
	LD	H,(IX+HS_RXREM+1)
	CALL	.chunk_of_hl
	LD	C,NRX_SKIP
	CALL	NIC_RX_READ
.rem
	; HS_RXREM -= E (bytes of this portion, kept in E by .chunk_of_hl)
	LD	A,(IX+HS_RXREM)
	SUB	E
	LD	(IX+HS_RXREM),A
	LD	A,(IX+HS_RXREM+1)
	SBC	A,0
	LD	(IX+HS_RXREM+1),A
	OR	(IX+HS_RXREM)
	RET	NZ
	LD	(IX+HS_RXS),ERX_FINISH
	RET
.chunk_of_hl				; B = E = min(HL, NIC_CHUNK), HL > 0
	LD	A,H
	OR	A
	LD	A,NIC_CHUNK
	JR	NZ,.c_set
	LD	A,L
	CP	NIC_CHUNK
	JR	C,.c_set
	LD	A,NIC_CHUNK
.c_set
	LD	B,A
	LD	E,A
	JP	NIC_RX_LIMIT		; the card may shorten it (ring end)

; ----------------------------------------------------------------------
; NIC_PORT_READ (P): read B bytes (1..64) from the card data port HL into
; DE (NRX_COPY), into DE adding to HS_SUM (NRX_SUM) or only into HS_SUM
; (NRX_SKIP).  The checksum lanes follow HS_PAR (odd offset = high lane);
; DE is advanced for the stored modes.  Shared by every card whose data
; port is one fixed address.  ~28 T per byte + ISA waits.
; ----------------------------------------------------------------------
NIC_PORT_READ
	LD	A,C
	OR	A
	JR	NZ,.summed
.copy
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	DJNZ	.copy
	RET
.summed
	PUSH	IX
	PUSH	AF			; mode
	LD	A,B
	LD	C,(IX+HS_SUM)
	LD	B,(IX+HS_SUM+1)
	BIT	0,(IX+HS_PAR)
	LD	IXL,A			; IXL = bytes left (IX is saved)
	JR	Z,.even
	; odd start: one byte into the high lane
	POP	AF
	PUSH	AF
	LD	A,(HL)
	CALL	.store
	ADD	A,B
	LD	B,A
	LD	A,0
	ADC	A,C
	LD	C,A
	JR	NC,.par0
	INC	B
.par0
	DEC	IXL
	JR	Z,.even_end
.even
	LD	A,IXL
	SRL	A
	JR	Z,.tail			; no whole pairs
	LD	IXH,A
	POP	AF
	PUSH	AF
	CP	NRX_SKIP
	JR	Z,.pairs_skip
	OR	A			; CF = 0
.pairs_copy
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	ADC	A,C
	LD	C,A
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	ADC	A,B
	LD	B,A
	DEC	IXH
	JR	NZ,.pairs_copy
	JR	.fold
.pairs_skip
	OR	A
.pairs_skip_loop
	LD	A,(HL)
	ADC	A,C
	LD	C,A
	LD	A,(HL)
	ADC	A,B
	LD	B,A
	DEC	IXH
	JR	NZ,.pairs_skip_loop
.fold
	LD	A,0
	ADC	A,C
	LD	C,A
	LD	A,0
	ADC	A,B
	LD	B,A
	JR	NC,.tail
	INC	BC
.tail
	LD	A,IXL
	AND	1
	JR	Z,.even_end
	; one byte left: low lane, the next segment byte is odd
	POP	AF
	PUSH	AF
	LD	A,(HL)
	CALL	.store
	ADD	A,C
	LD	C,A
	LD	A,0
	ADC	A,B
	LD	B,A
	JR	NC,.par1
	INC	BC
.par1
	POP	AF
	POP	IX
	LD	(IX+HS_PAR),1
	JR	.save
.even_end
	POP	AF
	POP	IX
	LD	(IX+HS_PAR),0
.save
	LD	(IX+HS_SUM),C
	LD	(IX+HS_SUM+1),B
	RET
.store					; A = byte; (SP+2) = mode
	PUSH	AF
	PUSH	HL
	LD	HL,6
	ADD	HL,SP
	LD	H,(HL)			; saved mode in the high byte of AF
	LD	A,H
	CP	NRX_SKIP
	POP	HL
	JR	Z,.no_store
	POP	AF
	LD	(DE),A
	INC	DE
	RET
.no_store
	POP	AF
	RET


; (P) drop the rest of the frame
RXP_DISCARD
	CALL	NIC_RX_DISCARD
	LD	(IX+HS_RXS),ERX_DISC_WAIT
	RET
RXP_DISC_WAIT
	CALL	NIC_RX_DISC_DONE
	RET	C
	LD	(IX+HS_RXS),ERX_IDLE
	RET

; ----------------------------------------------------------------------
; ETH_CLASSIFY: header of the frame in ctx.scratch (main, no card access).
; ARP is answered/learned here; IPv4 for us goes to the transport, which
; decides where its payload is stored.  Everything else is dropped and
; counted.
; ----------------------------------------------------------------------
ETH_CLASSIFY
	LD	DE,UCTX_SCRATCH - CTX_BIAS
	PUSH	IY
	POP	IX
	ADD	IX,DE			; IX -> frame
	LD	A,(IX+ETH_TYPE)
	CP	0x08
	JP	NZ,.foreign
	LD	A,(IX+ETH_TYPE+1)
	CP	0x06
	JR	NZ,.ip
	CALL	ARP_INPUT
	JR	.discard
.ip
	OR	A			; 0x0800
	JR	NZ,.foreign
	LD	A,(IX+ETH_IP_VIHL)
	CP	0x45			; IPv4 without options
	JR	NZ,.size
	LD	A,(IX+ETH_IP_FRAG)
	AND	0x3F			; MF and the offset high bits
	OR	(IX+ETH_IP_FRAG+1)
	JR	NZ,.fragment
	LD	DE,CX_LOCAL_IP
	CALL	IP_MATCH_DST
	JR	NZ,.foreign
	; header checksum
	PUSH	IX
	POP	HL
	LD	DE,ETH_IP
	ADD	HL,DE
	EX	DE,HL
	LD	HL,0
	LD	BC,IP_HDR
	CALL	CSUM_RAM
	LD	A,H
	AND	L
	INC	A
	JR	NZ,.checksum
	; total length within the frame
	LD	H,(IX+ETH_IP_LEN)
	LD	L,(IX+ETH_IP_LEN+1)
	LD	DE,IP_HDR
	OR	A
	SBC	HL,DE			; HL = segment length
	JR	C,.size
	PUSH	HL
	LD	DE,ETH_HDR + IP_HDR
	ADD	HL,DE
	EX	DE,HL			; DE = frame bytes the datagram needs
	LD	BC,UCTX_HWSM + HS_RXLEN - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,BC
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A			; HL = frame length from the card
	OR	A
	SBC	HL,DE
	POP	BC			; BC = segment length
	JR	C,.size
	; transport accept in the next state (its own budget portion)
	LD	A,(IX+ETH_IP_PROTO)
	PUSH	BC
	HWSM_IX
	POP	BC
	LD	(IX+HS_RXPROTO),A
	LD	(IX+HS_RXSEG),C
	LD	(IX+HS_RXSEG+1),B
	LD	(IX+HS_RXS),ERX_SUM0
	RET
.discard
	CALL	ETH_RX_DROP
	RET
.foreign
	STAT_INC UNETG_STATS_DROP_FOREIGN
	JR	.discard
.size
	STAT_INC UNETG_STATS_DROP_SIZE
	JR	.discard
.fragment
	STAT_INC UNETG_STATS_DROP_FRAGMENT
	JR	.discard
.checksum
	STAT_INC UNETG_STATS_DROP_CHECKSUM
	JR	.discard

; ETH_ACCEPT: hand the classified segment to the transport.
ETH_ACCEPT
	HWSM_IX
	LD	C,(IX+HS_RXSEG)
	LD	B,(IX+HS_RXSEG+1)
	LD	A,(IX+HS_RXPROTO)
	PUSH	AF
	LD	DE,UCTX_SCRATCH - CTX_BIAS
	PUSH	IY
	POP	IX
	ADD	IX,DE			; IX -> frame
	POP	AF
	CALL	TP_RX_ACCEPT		; CF=1: dropped (counted by the transport)
	RET	NC
ETH_RX_DROP
	LD	DE,UCTX_HWSM + HS_RXS - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,DE
	LD	(HL),ERX_DISCARD
	RET

; IP_MATCH_DST: Z when the destination address at (IX+ETH_IP_DST) equals
; the context IPv4 at IY + DE (a CX_* offset).  Clobbers A, B, DE, HL.
IP_MATCH_DST
	PUSH	IX
	POP	HL
	LD	BC,ETH_IP_DST
	ADD	HL,BC			; HL -> destination in the frame
	JP	IP_EQ_CTX		; compare with IY + DE

; ETH_SUM0 (ERX_SUM0): start the segment checksum with the pseudo header
; and the segment bytes already in scratch; HS_RXREM = card bytes of the
; segment.  Independent of the transport, so it is its own budget item.
ETH_SUM0
	HWSM_IX
	LD	C,(IX+HS_RXSEG)
	LD	B,(IX+HS_RXSEG+1)
	LD	A,(IX+HS_RXPROTO)
	LD	DE,UCTX_SCRATCH - CTX_BIAS
	PUSH	IY
	POP	IX
	ADD	IX,DE			; IX -> frame (addresses of the pseudo header)
	PUSH	BC
	LD	D,B
	LD	E,C
	LD	C,A
	CALL	CSUM_PSEUDO		; HL = pseudo-header sum
	POP	BC
	CALL	SEG_IN_SCRATCH		; DE = bytes in scratch
	PUSH	BC			; segment length
	PUSH	DE
	LD	B,D
	LD	C,E
	PUSH	HL
	LD	HL,UCTX_SCRATCH + ETH_L4 - CTX_BIAS
	PUSH	IY
	POP	DE
	ADD	HL,DE
	EX	DE,HL			; DE -> segment in scratch
	POP	HL
	CALL	CSUM_RAM
	POP	DE			; DE = bytes in scratch
	POP	BC			; BC = segment length
	HWSM_IX
	LD	(IX+HS_SUM),L
	LD	(IX+HS_SUM+1),H
	LD	H,B
	LD	L,C
	OR	A
	SBC	HL,DE			; card bytes of the segment
	LD	(IX+HS_RXREM),L
	LD	(IX+HS_RXREM+1),H
	LD	(IX+HS_RXS),ERX_ACCEPT
	RET

; SEG_IN_SCRATCH: DE = min(BC, L4_IN_SCRATCH).  Preserves BC, HL.
SEG_IN_SCRATCH
	LD	DE,L4_IN_SCRATCH
	LD	A,B
	OR	A
	RET	NZ
	LD	A,C
	CP	E
	RET	NC
	LD	E,C
	RET

; ETH_SEG_START: called by TP_RX_ACCEPT for an accepted segment (HS_SUM
; and HS_RXREM were set by ETH_SUM0).  In: BC = segment length, IX ->
; frame.  Sets HS_RXSKIP / HS_RXLIM (= 0), HS_NOCHK, HS_PAR and HS_RXS =
; COPY or FINISH; the transport then sets HS_RXSKIP / HS_RXLIM /
; HS_RXDST / HS_RXSPAN for the card part.  Out: DE = segment bytes in
; scratch.  Preserves BC, IX.
ETH_SEG_START
	PUSH	IX
	HWSM_IX
	XOR	A
	LD	(IX+HS_RXSKIP),A
	LD	(IX+HS_RXSKIP+1),A
	LD	(IX+HS_RXLIM),A
	LD	(IX+HS_RXLIM+1),A
	LD	(IX+HS_NOCHK),A
	LD	(IX+HS_PAR),A		; the card part starts on an even offset
	LD	A,(IX+HS_RXREM)
	OR	(IX+HS_RXREM+1)
	LD	A,ERX_COPY
	JR	NZ,.state
	LD	A,ERX_FINISH
.state
	LD	(IX+HS_RXS),A
	POP	IX
	JP	SEG_IN_SCRATCH

; ======================================================================
; TX pipeline
; ======================================================================
ETH_TX_STEP
	HWSM_IX
	LD	A,(IX+HS_TXS)
	OR	A
	JR	NZ,.busy
	; idle: ARP first (replies keep the peer able to reach us), then data
	CALL	ARP_TX_PULL
	LD	A,ETK_ARP
	JR	NC,.ready
	LD	A,(IY+CX_STATE)
	CP	UNETG_CTXSTATE_CONFIGURED
	RET	NZ
	CALL	TP_TX_PULL
	RET	C
	LD	A,ETK_TP
.ready
	HWSM_IX
	LD	(IX+HS_TXKIND),A
	LD	(IX+HS_TXS),ETX_BEGIN
	LD	A,ETX_BEGIN
.busy
	CP	ETX_WAIT
	JR	Z,.wait
	LD	HL,COST_TX_CHUNK
	HWSM_IX
	LD	A,(IX+HS_TXS)
	CP	ETX_BEGIN
	JR	NZ,.cost
	LD	HL,COST_TX_BEGIN
.cost
	CALL	TAKE
	RET	C
	HWSM_IX
	LD	A,(IX+HS_TXS)
	LD	HL,TXP_BEGIN
	CP	ETX_BEGIN
	JR	Z,.run
	LD	HL,TXP_DATA
	CP	ETX_DATA
	JR	Z,.run
	LD	HL,TXP_END
.run
	CALL	RUN_PORTION
	RET	C
	LD	A,(IY+EX_TXS)
	CP	ETX_BEGIN
	RET	Z			; the card has no room: next STEP (no spinning)
	SET	2,(IY+CX_WORK)
	CP	ETX_WAIT
	RET	Z			; started: the completion is checked next STEP
	DEC	(IY+CX_SCHED_ITEMS)	; ETH_SCHED: items of this phase
	RET	Z
	JP	ETH_TX_STEP		; continue while the budget lasts
.wait
	LD	HL,COST_TX_WAIT
	CALL	TAKE
	RET	C
	LD	HL,TXP_CHECK
	CALL	RUN_PORTION
	RET	C
	HWSM_IX
	LD	A,(IX+HS_RES)
	CP	NTX_PENDING
	JR	NZ,.complete
	LD	DE,HS_DL
	PUSH	IX
	POP	HL
	ADD	HL,DE
	CALL	DL_LEFT
	RET	NC			; not yet: next STEP
	LD	A,NTX_ERROR		; no completion in time (the card recovers
					; at the next TXP_BEGIN)
.complete
	HWSM_IX
	LD	(IX+HS_TXS),ETX_IDLE
	CP	NTX_OK
	JR	NZ,.failed
	STAT_INC UNETG_STATS_TX_FRAMES
	LD	A,1
	JR	.notify
.failed
	XOR	A
.notify
	LD	B,A
	HWSM_IX
	LD	A,(IX+HS_TXKIND)
	CP	ETK_TP
	LD	A,B
	JP	Z,TP_TX_DONE		; A = 1 sent, 0 failed
	RET

; ETH_TX_COPYING: CF=1 while the TX pipeline still reads the payload of a
; transport frame out of an application TX slot (EV_FLUSH then holds the
; TX_DONE outcomes, so no slot is handed back to the application before
; its bytes are on the card).  A card that is not running copies nothing
; any more (SHUTDOWN stopped it mid-frame): no hold.  Clobbers A, DE, HL.
ETH_TX_COPYING
	LD	A,(IY+CX_HW_STATE)
	CP	UHW_RUN
	JR	NZ,.no
	LD	DE,UCTX_HWSM + HS_TXKIND - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,DE
	LD	A,(HL)
	CP	ETK_TP
	JR	NZ,.no
	LD	DE,HS_TXS - HS_TXKIND
	ADD	HL,DE
	LD	A,(HL)
	CP	ETX_BEGIN
	JR	C,.no			; idle
	CP	ETX_END			; BEGIN / DATA: CF=1
	RET
.no
	OR	A
	RET

; (P) start the frame and write its header from ctx.txh
TXP_BEGIN
	LD	L,(IX+HS_TXLEN)
	LD	H,(IX+HS_TXLEN+1)
	CALL	NIC_TX_BEGIN
	RET	C			; no room yet: retry next portion
	LD	L,(IX+HS_TXHSRC)
	LD	H,(IX+HS_TXHSRC+1)
	LD	B,(IX+HS_TXHDR)
	CALL	NIC_TX_WRITE
	LD	A,(IX+HS_TXREM)
	OR	(IX+HS_TXREM+1)
	LD	(IX+HS_TXS),ETX_DATA
	RET	NZ
	LD	(IX+HS_TXS),ETX_END
	RET

; (P) one payload portion
TXP_DATA
	LD	L,(IX+HS_TXREM)
	LD	H,(IX+HS_TXREM+1)
	LD	A,H
	OR	A
	LD	B,NIC_CHUNK
	JR	NZ,.n
	LD	A,L
	CP	NIC_CHUNK
	JR	NC,.n
	LD	B,L
.n
	LD	E,B
	LD	D,0
	OR	A
	SBC	HL,DE
	LD	(IX+HS_TXREM),L
	LD	(IX+HS_TXREM+1),H
	LD	L,(IX+HS_TXSRC)
	LD	H,(IX+HS_TXSRC+1)
	PUSH	HL
	ADD	HL,DE
	LD	(IX+HS_TXSRC),L
	LD	(IX+HS_TXSRC+1),H
	POP	HL
	CALL	NIC_TX_WRITE
	LD	A,(IX+HS_TXREM)
	OR	(IX+HS_TXREM+1)
	RET	NZ
	LD	(IX+HS_TXS),ETX_END
	RET

; (P) pad, start, arm the completion deadline
TXP_END
	CALL	NIC_TX_END
	LD	(IX+HS_TXS),ETX_WAIT
	PUSH	IX
	POP	HL
	LD	DE,HS_DL
	ADD	HL,DE
	LD	DE,TX_TIMEOUT_MS
	JP	DL_ARM

; (P) completion check
TXP_CHECK
	CALL	NIC_TX_CHECK
	LD	(IX+HS_RES),A
	RET

; ----------------------------------------------------------------------
; ISRP_POLL (P): the STEP_ISR body of a running card (sched.asm) -- only a
; status sample: a waiting frame sets UPEND_RX for the next STEP.  No
; protocol work, no events.
; ----------------------------------------------------------------------
ISRP_POLL
	STAT_INC UNETG_STATS_POLLS_TOTAL
	SET	UPEND_POLLED,(IY+CX_ISR_PENDING)
	CALL	NIC_ISR_POLL
	RET	C
	SET	UPEND_RX,(IY+CX_ISR_PENDING)
	LD	A,(IY+CX_WORK)
	OR	UWK_HW | UWK_MORE	; STEP_ISR returns WORK: main has a frame to read
	LD	(IY+CX_WORK),A
	RET
