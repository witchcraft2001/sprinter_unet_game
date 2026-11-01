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
COST_PORTION	EQU	100	; bracket + a short card step (EL3 poll 82, discard 59 us)
COST_STOP	EQU	COST_BRINGUP	; a stop-table portion (EL3 144 us)
COST_BRINGUP	EQU	190	; bracket + the longest bring-up step (RTL 173 us)
COST_RX_CHUNK	EQU	COST_PORTION + NIC_CHUNK_RX * 5 / 2 + 2 * PROF_DMA_EXTRA_US	; NIC_CHUNK_RX bytes read + summed (RTL 181, EL3 176 us)
COST_RX_HEADER	EQU	185 + PROF_DMA_EXTRA_US * 4 / 3	; the first RX_HDR_BYTES copied (RTL 184, EL3 166 us)
COST_TX_CHUNK	EQU	COST_PORTION + NIC_CHUNK * 3 / 2 + PROF_DMA_EXTRA_US + 5	; 56 bytes written (RTL 178, EL3 158 us)
COST_TX_BEGIN	EQU	105	; TX room check and the 3C509B preamble (EL3 88 us)
COST_TX_END	EQU	135	; padding to 60 bytes and the start (RTL 117, EL3 91 us)
COST_TX_WAIT	EQU	140	; completion check + transport notification (125 us)
COST_CLASSIFY	EQU	125	; Ethernet/ARP/IPv4 checks and the IP header checksum (109 us)
COST_SUM0	EQU	140	; pseudo header + up to 30 segment bytes in scratch (123 us)
COST_ACCEPT	EQU	200	; transport accept: ports, state, header fields (179 us)
COST_STORE	EQU	150	; payload placement in the RX ring (TCP, 131 us)
COST_FINISH	EQU	175	; checksum verdict + transport input: payload over RX slots, FIN (156 us; TCP ACK: ERX_TCPACK)
COST_PREPARE	EQU	75	; NIC_PREPARE + bring-up deadline (58 us)
COST_POLL	EQU	COST_PORTION + PROF_POLL_EXTRA_US	; status poll that may find a frame (RTL 131 us)
COST_ARP_PULL	EQU	125	; ARP frame into ctx.txh (109 us)
COST_TP_PULL	EQU	130	; UDP: IPv4 + UDP header with checksums (110 us)
BRINGUP_MS	EQU	3000	; whole bring-up deadline
TX_TIMEOUT_MS	EQU	50	; transmit completion
	ASSERT	COST_POLL <= PROF_MAX_ITEM_US && COST_BRINGUP <= PROF_MAX_ITEM_US
	ASSERT	COST_RX_CHUNK <= PROF_MAX_ITEM_US && COST_TX_CHUNK <= PROF_MAX_ITEM_US && COST_TX_BEGIN <= PROF_MAX_ITEM_US
	ASSERT	COST_RX_HEADER <= PROF_MAX_ITEM_US && COST_TX_END <= PROF_MAX_ITEM_US
	ASSERT	COST_CLASSIFY <= PROF_MAX_ITEM_US && COST_ACCEPT <= PROF_MAX_ITEM_US
	ASSERT	COST_STORE <= PROF_MAX_ITEM_US && COST_FINISH <= PROF_MAX_ITEM_US
	ASSERT	COST_SUM0 <= PROF_MAX_ITEM_US
	ASSERT	COST_TP_PULL <= PROF_MAX_ITEM_US && COST_TX_WAIT <= PROF_MAX_ITEM_US

; ----------------------------------------------------------------------
; ETH_SCHED: the work of a STEP with a running card (sched.asm), in an
; order that lets a frame in progress finish and still polls the card
; once per STEP (ТЗ §4.2) and runs the transport every STEP:
;  1. the poll, while the RX pipeline is idle (and STEP_ISR did not just
;     sample the card empty): on odd STEPs at once, as its own item (a
;     frame it finds continues in step 2); on even ones COST_POLL is set
;     aside for step 5 when the largest item still fits besides it;
;  2. frames in progress: RX and TX continue (who goes first alternates
;     with bit 0 of the STEP counter), at most ETH_CONT_ITEMS items each
;     while the other direction is busy too, never past the frame end;
;  3. the transport step (timers, the next segment);
;  4. TX: ARP / transport pull for an idle pipeline, then its portions
;     while the budget lasts;
;  5. the poll (the reserve is given back first; skipped after step 1)
;     and a found frame;
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
	; sched_flags: EXP_STEP cleared it (only USCH_ODD / USCH_ODD2 set)
	; 1. poll first (odd STEPs) or poll reserve
	LD	A,(IY+EX_RXS)
	OR	A
	JR	NZ,.no_rsvd		; a frame is in progress: no poll this STEP
	LD	A,(IY+CX_ISR_PENDING)
	AND	(1 << UPEND_POLLED) | (1 << UPEND_RX)
	CP	1 << UPEND_POLLED
	JR	Z,.no_rsvd		; STEP_ISR just found the card empty
	; every other STEP (bit 0 of the STEP counter) the poll comes first,
	; as an item of its own (a frame it finds continues in step 2);
	; otherwise it is reserved while the largest item still fits besides
	; it, so a small budget serves the frames and a busy TX does not
	; starve RX
	BIT	USCH_ODD,(IY+CX_SCHED_FLAGS)
	JR	NZ,.poll_first
	LD	L,(IY+CX_UNITS)
	LD	H,(IY+CX_UNITS+1)
	LD	DE,-(COST_POLL + PROF_MAX_ITEM_US)
	ADD	HL,DE
	JR	NC,.no_rsvd
.rsvd
	; units -= COST_POLL inline (always given back in step 5: no item)
	LD	A,(IY+CX_UNITS)
	SUB	COST_POLL
	LD	L,A
	LD	A,(IY+CX_UNITS+1)
	SBC	A,0
	JR	C,.no_rsvd
	LD	(IY+CX_UNITS),L
	LD	(IY+CX_UNITS+1),A
	SET	USCH_POLL_RSVD,(IY+CX_SCHED_FLAGS)
	JR	.no_rsvd
.poll_first
	; no reserve: the phases below see the budget the poll left
	LD	(IY+CX_SCHED_ITEMS),1
	CALL	ETH_RX_STEP
	SET	USCH_POLLED,(IY+CX_SCHED_FLAGS)
.no_rsvd
	; 2. frames in progress
	SET	USCH_CONT,(IY+CX_SCHED_FLAGS)
	BIT	USCH_ODD,(IY+CX_SCHED_FLAGS)
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
	LD	A,(IY+CX_UNITS)		; units += COST_POLL
	ADD	A,COST_POLL
	LD	(IY+CX_UNITS),A
	JR	NC,.poll
	INC	(IY+CX_UNITS+1)
.poll
	BIT	USCH_RX_STOP,(IY+CX_SCHED_FLAGS)
	JR	NZ,.rest
	BIT	USCH_POLLED,(IY+CX_SCHED_FLAGS)
	JR	Z,.poll_rx
	LD	A,(IY+EX_RXS)
	OR	A
	JR	Z,.rest			; polled in step 1, nothing found
.poll_rx
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
	LD	A,(IY+EX_TXS)
	OR	A
	JR	NZ,.busy		; the dispatcher checks the item's cost itself
	LD	E,ETH_MIN_ITEM		; idle: the cheapest pull must fit
	CALL	ETH_AFFORD_E
	RET	C
.busy
	LD	(IY+CX_SCHED_ITEMS),0xFF
	CALL	ETH_TX_STEP
	RET	NC
	SET	USCH_TX_STOP,(IY+CX_SCHED_FLAGS)
	RET

; ETH_RX_CONT / ETH_TX_CONT: continue a frame in progress (USCH_CONT), at
; most ETH_CONT_ITEMS items while the other pipeline is busy too.  A
; pipeline that stops (CF) is not tried again in this STEP.
ETH_RX_CONT
	LD	A,(IY+EX_RXS)
	OR	A
	RET	Z			; RX idle (the dispatcher checks the item's cost)
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

; ETH_AFFORD_E: CF=1 (UWK_YIELD) when the cost E (< 256) does not fit.
; The dispatchers check the cost of the pipeline's next item (RX_TAB /
; TX_TAB) before their TAKE, so a phase that cannot afford it stops
; without a refused TAKE (a refused attempt costs base time too); an idle
; TX pipeline needs the cheapest pull (ETH_MIN_ITEM).  Clobbers A.
ETH_MIN_ITEM	EQU	COST_PORTION
ETH_AFFORD_E
	LD	A,(IY+CX_UNITS+1)
	OR	A
	RET	NZ			; >= 256 units: any item fits (CF=0)
	LD	A,(IY+CX_UNITS)
	CP	E
	RET	NC
	SET	4,(IY+CX_WORK)		; UWK_YIELD (SET keeps CF)
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
	LD	A,(IY+EX_RXS)
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
	; Table dispatch (RX_ENTRY): the state's cost is taken by TAKE, which
	; returns straight into the state routine; every routine starts with
	; RET C (refused: back to .next with CF=1) and sets its own IX after
	; it (TAKE clobbers A, DE, HL).
	CALL	RX_ENTRY		; HL -> {cost, routine}
	LD	E,(HL)
	CALL	ETH_AFFORD_E		; a refusal without the dispatch and TAKE
	RET	C
	INC	HL
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A
	PUSH	HL			; the state routine is TAKE's return address
	EX	DE,HL
	LD	H,0
	JP	TAKE
.sum0
	; ERX_SUM0: pseudo header + segment bytes in scratch
	RET	C
	CALL	ETH_SUM0
	XOR	A
	RET
.accept
	; ERX_ACCEPT: the transport decides where the segment goes
	RET	C
	CALL	ETH_ACCEPT
	XOR	A
	RET
.store
	RET	C
	CALL	TP_RX_STORE
	XOR	A
	RET
.disc_wait
	RET	C
	LD	HL,RXP_DISC_WAIT
	CALL	RUN_PORTION
	RET	C
	LD	A,(IY+EX_RXS)
	OR	A
	SCF
	RET	NZ			; still discarding: next STEP
	LD	A,1			; CF=0 (OR A), one frame finished
	RET
.poll
	RET	C
	LD	HL,RXP_POLL
	CALL	RUN_PORTION
	RET	C
	LD	A,(IY+EX_RXS)
	OR	A
	SCF
	RET	Z			; no frame waiting
	SET	0,(IY+CX_WORK)		; UWK_HW
	XOR	A
	RET
.header
	RET	C
	LD	HL,RXP_HEADER
	CALL	RUN_PORTION
	RET	C
	XOR	A
	RET
.classify
	RET	C
	CALL	ETH_CLASSIFY
	XOR	A
	RET
.copy
	RET	C
	LD	HL,RXP_COPY
	CALL	RUN_PORTION
	RET	C
	SET	2,(IY+CX_WORK)
	XOR	A
	RET
.finish
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
	LD	(IY+EX_RXS),ERX_DISCARD	; TCP may continue with ERX_TCPACK
	CALL	TP_RX_COMMIT		; A = 1 valid, 0 corrupt
	XOR	A
	RET
.tcpack
	; TCP: the ACK of the committed segment as its own item (its TC_RX*
	; fields live until the next ACCEPT: the frame is still on the card)
	RET	C
	LD	(IY+EX_RXS),ERX_DISCARD
	CALL	TP_RX_ACK
	XOR	A
	RET
.discard
	RET	C
	LD	HL,RXP_DISCARD
	CALL	RUN_PORTION
	RET	C
	XOR	A
	RET
; per ERX_* state: cost of its item (units), routine
.tab
	DB	COST_POLL
	DW	.poll			; ERX_IDLE
	DB	COST_CLASSIFY
	DW	.classify		; ERX_HDR
	DB	COST_RX_CHUNK
	DW	.copy			; ERX_COPY
	DB	COST_FINISH
	DW	.finish			; ERX_FINISH
	DB	COST_PORTION
	DW	.discard		; ERX_DISCARD
	DB	COST_PORTION
	DW	.disc_wait		; ERX_DISC_WAIT
	DB	COST_RX_HEADER
	DW	.header			; ERX_HDR_READ
	DB	COST_ACCEPT
	DW	.accept			; ERX_ACCEPT
	DB	COST_STORE
	DW	.store			; ERX_STORE
	DB	COST_SUM0
	DW	.sum0			; ERX_SUM0
	DB	COST_TP_ACK
	DW	.tcpack			; ERX_TCPACK
	ASSERT	ERX_TCPACK == 10 && COST_TP_ACK < 256
	ASSERT	ERX_IDLE == 0 && ERX_HDR == 1 && ERX_COPY == 2 && ERX_FINISH == 3 && ERX_DISCARD == 4
	ASSERT	ERX_DISC_WAIT == 5 && ERX_HDR_READ == 6 && ERX_ACCEPT == 7 && ERX_STORE == 8 && ERX_SUM0 == 9
	; (COST_POLL < 256: also the inline poll reserve of ETH_SCHED)
	ASSERT	COST_POLL < 256 && COST_CLASSIFY < 256 && COST_RX_CHUNK < 256 && COST_FINISH < 256
	ASSERT	COST_RX_HEADER < 256
	ASSERT	COST_PORTION < 256 && COST_ACCEPT < 256 && COST_STORE < 256 && COST_SUM0 < 256
RX_TAB	EQU	.tab

; RX_ENTRY: HL -> RX_TAB entry of the current RX state.  Clobbers A.
RX_ENTRY
	LD	A,(IY+EX_RXS)
	LD	L,A
	ADD	A,A
	ADD	A,L
	ADD	A,LOW RX_TAB		; images sit on 256-byte boundaries
	LD	L,A
	LD	A,HIGH RX_TAB
	ADC	A,0
	LD	H,A
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
	LD	A,(IX+HS_RXSPAN+1)
	OR	A
	JR	NZ,.span_ok
	LD	A,(IX+HS_RXSPAN)
	CP	B
	JR	NC,.span_ok
	LD	B,A
.span_ok
	LD	E,(IX+HS_RXDST)
	LD	D,(IX+HS_RXDST+1)
	LD	C,NRX_SUM
	PUSH	BC
	CALL	NIC_RX_READ		; DE advanced
	POP	BC
	LD	(IX+HS_RXDST),E
	LD	(IX+HS_RXDST+1),D
	LD	E,B			; bytes of this portion (also for .rem)
	; HS_RXLIM -= E, HS_RXSPAN -= E (a borrow leaves a non-zero span)
	LD	A,(IX+HS_RXLIM)
	SUB	E
	LD	(IX+HS_RXLIM),A
	JR	NC,.lim_ok
	DEC	(IX+HS_RXLIM+1)
.lim_ok
	LD	A,(IX+HS_RXSPAN)
	SUB	E
	LD	(IX+HS_RXSPAN),A
	JR	NC,.span_low
	DEC	(IX+HS_RXSPAN+1)
	JR	.rem
.span_low
	OR	(IX+HS_RXSPAN+1)
	JR	NZ,.rem
	; wrapped: continue at the start of the RX slots
	LD	A,(IY+CX_RX_SLOTS_PTR)
	LD	(IX+HS_RXDST),A
	LD	A,(IY+CX_RX_SLOTS_PTR+1)
	LD	(IX+HS_RXDST+1),A
	LD	A,(IY+CX_RX_TOTAL)
	LD	(IX+HS_RXSPAN),A
	LD	A,(IY+CX_RX_TOTAL+1)
	LD	(IX+HS_RXSPAN+1),A
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
	JR	NC,.rem_low
	DEC	(IX+HS_RXREM+1)
	RET				; a borrow leaves a non-zero rest
.rem_low
	OR	(IX+HS_RXREM+1)
	RET	NZ
	LD	(IX+HS_RXS),ERX_FINISH
	RET
.chunk_of_hl				; B = E = min(HL, NIC_CHUNK_RX), HL > 0
	LD	A,H
	OR	A
	LD	A,NIC_CHUNK_RX
	JR	NZ,.c_set
	LD	A,L
	CP	NIC_CHUNK_RX
	JR	C,.c_set
	LD	A,NIC_CHUNK_RX
.c_set
	LD	B,A
	LD	E,A
	JP	NIC_RX_LIMIT		; the card may shorten it (ring end)

; NIC_PORT_WRITE (P): write B bytes (1..255) from HL to the card data port
; DE, unrolled four times (~21 T per byte + ISA waits).  HL is advanced.
; Shared by every card whose data port is one fixed address.  Clobbers A, B.
NIC_PORT_WRITE
	DEC	B
	LD	A,B
	AND	3			; (bytes - 1) % 4: 3 enters at .w1
	SRL	B
	SRL	B
	INC	B			; passes = (bytes - 1) / 4 + 1
	OR	A
	JR	Z,.w4
	DEC	A
	JR	Z,.w3
	DEC	A
	JR	Z,.w2
.w1
	LD	A,(HL)
	LD	(DE),A
	INC	HL
.w2
	LD	A,(HL)
	LD	(DE),A
	INC	HL
.w3
	LD	A,(HL)
	LD	(DE),A
	INC	HL
.w4
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	DJNZ	.w1
	RET

; one word of the card data port (HL) into BC (byte lanes C low, B high,
; with carry), stored at DE (COPY) or not (SUM); the end-around carry fold
	MACRO	NRX_PAIR_COPY
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
	ENDM
	MACRO	NRX_PAIR_SUM
	LD	A,(HL)
	ADC	A,C
	LD	C,A
	LD	A,(HL)
	ADC	A,B
	LD	B,A
	ENDM
	MACRO	NRX_FOLD
	LD	A,0
	ADC	A,C
	LD	C,A
	LD	A,0
	ADC	A,B
	LD	B,A
	JR	NC,.fold_ok
	INC	BC
.fold_ok
	ENDM
; ----------------------------------------------------------------------
; NIC_PORT_READ (P): read B bytes (1..64) from the card data port HL into
; DE (NRX_COPY), into DE adding to HS_SUM (NRX_SUM) or only into HS_SUM
; (NRX_SKIP).  The checksum lanes follow HS_PAR (odd offset = high lane);
; DE is advanced for the stored modes.  Shared by every card whose data
; port is one fixed address.  Unrolled four times: copy ~24 T per byte,
; copy + sum ~31, sum ~22 (+ ISA waits).
; ----------------------------------------------------------------------
NIC_PORT_READ
	LD	A,C
	OR	A
	JR	NZ,.summed
	; copy: (B + 3) / 4 passes, the first one enters for B % 4 bytes
	LD	A,B
	DEC	A
	LD	C,A
	ADD	A,4
	RRCA
	RRCA
	AND	0x3F
	LD	B,A			; passes
	LD	A,C
	AND	3			; (bytes - 1) % 4: 3 enters at .c1
	JR	Z,.c4
	DEC	A
	JR	Z,.c3
	DEC	A
	JR	Z,.c2
.c1
	LD	A,(HL)
	LD	(DE),A
	INC	DE
.c2
	LD	A,(HL)
	LD	(DE),A
	INC	DE
.c3
	LD	A,(HL)
	LD	(DE),A
	INC	DE
.c4
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	DJNZ	.c1
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
	JP	Z,.even_end
.even
	; pairs: pairs % 4 one by one (their carry folded), then groups of
	; four (bytes >> 3); IXL keeps the byte count for the tail
	POP	AF
	PUSH	AF			; mode
	CP	NRX_SKIP
	JR	Z,.even_skip
	LD	A,IXL
	AND	6
	JR	Z,.c_groups
	RRCA				; pairs % 4, CF = 0
	LD	IXH,A
.c_one
	NRX_PAIR_COPY
	DEC	IXH
	JR	NZ,.c_one
	NRX_FOLD
.c_groups
	LD	A,IXL
	RRCA
	RRCA
	RRCA
	AND	0x1F			; groups, CF = 0
	JP	Z,.tail
	LD	IXH,A
.c_four
	NRX_PAIR_COPY
	NRX_PAIR_COPY
	NRX_PAIR_COPY
	NRX_PAIR_COPY
	DEC	IXH
	JR	NZ,.c_four
	JR	.fold
.even_skip
	LD	A,IXL
	AND	6
	JR	Z,.s_groups
	RRCA
	LD	IXH,A
.s_one
	NRX_PAIR_SUM
	DEC	IXH
	JR	NZ,.s_one
	NRX_FOLD
.s_groups
	LD	A,IXL
	RRCA
	RRCA
	RRCA
	AND	0x1F
	JR	Z,.tail
	LD	IXH,A
.s_four
	NRX_PAIR_SUM
	NRX_PAIR_SUM
	NRX_PAIR_SUM
	NRX_PAIR_SUM
	DEC	IXH
	JR	NZ,.s_four
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
	LD	A,(IY+EX_TXS)
	OR	A
	JR	NZ,.busy
	; idle: ARP first (replies keep the peer able to reach us), then data
	; (both pulls set their own IX)
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
.busy
	; table dispatch as in ETH_RX_STEP: TAKE returns into the routine
	CALL	TX_ENTRY		; HL -> {cost, routine}
	LD	E,(HL)
	CALL	ETH_AFFORD_E		; a refusal without the dispatch and TAKE
	RET	C
	INC	HL
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A
	PUSH	HL
	EX	DE,HL
	LD	H,0
	JP	TAKE
.begin
	RET	C
	LD	HL,TXP_BEGIN
	JR	.run
.data
	RET	C
	LD	HL,TXP_DATA
	JR	.run
.end
	RET	C
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
; per ETX_* state from ETX_BEGIN: cost of its item (units), routine
.tab
	DB	COST_TX_BEGIN
	DW	.begin			; ETX_BEGIN
	DB	COST_TX_CHUNK
	DW	.data			; ETX_DATA
	DB	COST_TX_END
	DW	.end			; ETX_END
	DB	COST_TX_WAIT
	DW	.wait			; ETX_WAIT
	ASSERT	ETX_BEGIN == 1 && ETX_DATA == 2 && ETX_END == 3 && ETX_WAIT == 4
	ASSERT	COST_TX_BEGIN < 256 && COST_TX_CHUNK < 256 && COST_TX_WAIT < 256 && COST_TX_END < 256
TX_TAB	EQU	.tab - 3		; indexed from ETX_IDLE

; TX_ENTRY: HL -> TX_TAB entry of the current (busy) TX state.  Clobbers A.
TX_ENTRY
	LD	A,(IY+EX_TXS)
	LD	L,A
	ADD	A,A
	ADD	A,L
	ADD	A,LOW TX_TAB		; images sit on 256-byte boundaries
	LD	L,A
	LD	A,HIGH TX_TAB
	ADC	A,0
	LD	H,A
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

; (P) start the frame: room on the card (and the 3C509B preamble); the
; header follows as DATA portions
TXP_BEGIN
	LD	L,(IX+HS_TXLEN)
	LD	H,(IX+HS_TXLEN+1)
	CALL	NIC_TX_BEGIN
	RET	C			; no room yet: retry next portion
	LD	(IX+HS_TXS),ETX_DATA	; HS_TXREM >= the header (> 0)
	RET

; (P) one portion of the frame: header bytes from HS_TXHSRC first, then
; the payload from HS_TXSRC, at most NIC_CHUNK each (a portion never
; mixes the two: one remote DMA per portion)
TXP_DATA
	LD	A,(IX+HS_TXHDR)
	OR	A
	JR	Z,.payload
	LD	B,NIC_CHUNK
	CP	B
	JR	NC,.hdr_n
	LD	B,A
.hdr_n
	SUB	B
	LD	(IX+HS_TXHDR),A
	LD	L,(IX+HS_TXHSRC)
	LD	H,(IX+HS_TXHSRC+1)
	LD	A,L
	ADD	A,B
	LD	(IX+HS_TXHSRC),A
	LD	A,H
	ADC	A,0
	LD	(IX+HS_TXHSRC+1),A
	JR	.write
.payload
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
	LD	L,(IX+HS_TXSRC)
	LD	H,(IX+HS_TXSRC+1)
	LD	A,L
	ADD	A,B
	LD	(IX+HS_TXSRC),A
	LD	A,H
	ADC	A,0
	LD	(IX+HS_TXSRC+1),A
.write
	; HS_TXREM -= B before the write (the RTL8019AS takes its card
	; address from HS_TXLEN - HS_TXREM - B)
	LD	A,(IX+HS_TXREM)
	SUB	B
	LD	(IX+HS_TXREM),A
	JR	NC,.rem_ok
	DEC	(IX+HS_TXREM+1)
.rem_ok
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
; ISRP_POLL: the STEP_ISR body of a running card (lock.asm ISR_PORTION)
; is the card layer's NIC_ISR_POLL -- only a status sample, CF=0 when the
; next STEP has receive work.  The card is mapped, IFF=0, IY = context; IX
; is the caller's (ctx.hwsm is read through IY).  Clobbers A, HL;
; preserves BC, DE, IX.  No per-call field, no protocol work, no events.
; ----------------------------------------------------------------------
ISRP_POLL	EQU	NIC_ISR_POLL
