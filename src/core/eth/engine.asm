; engine.asm -- Ethernet engine shared by the RTL8019AS and 3C509B builds.
;
; HW_STEP (main) drives bring-up, the RX and TX pipelines and the stop
; phase as resumable states in ctx.hwsm; every card access is one bounded
; PORTION (<= NIC_CHUNK bytes) under the shared ISA lock.  Protocol work
; (classification, checksum verdicts, ARP/TCP/UDP) runs between portions
; with interrupts enabled.  HW_ISR only samples the card status.
;
; Card layer contract (src/hw/<card>): routines marked (P) run inside
; PORTION with IX = ctx.hwsm and must stay within the DI limit.
;   NIC_PREPARE        main: derive HS_IO / MAC source from the context
;   NIC_BRINGUP    (P) one bring-up step; HS_RES = NBR_*
;   NIC_RX_STATUS  (P) CF=1 no frame; else HL = length, A = 0 / 1 (error)
;   NIC_RX_READ    (P) DE = dest, B = 1..NIC_CHUNK, C = mode (NRX_*)
;   NIC_RX_DISCARD (P) drop the rest of the current frame (start)
;   NIC_RX_DISC_DONE (P) CF=1 while the drop is in progress
;   NIC_TX_BEGIN   (P) HL = frame length; CF=1 when the card has no room
;   NIC_TX_WRITE   (P) HL = source, B = 1..NIC_CHUNK
;   NIC_TX_END     (P) pad and start transmission
;   NIC_TX_CHECK   (P) A = NTX_PENDING / NTX_OK / NTX_ERROR (recovered)
;   NIC_STOP       (P) one stop step; HS_RES = NBR_*
;   NIC_ISR_POLL   (P) CF=0 when a received frame is waiting

NBR_CONTINUE	EQU	0	; more bring-up steps in this STEP
NBR_WAIT	EQU	1	; wait for time (HS_DL) or the card: next STEP
NBR_DONE	EQU	2
NBR_FAULT	EQU	3

NRX_COPY	EQU	0
NRX_SUM		EQU	1	; copy and add to HS_SUM
NRX_SKIP	EQU	2	; add to HS_SUM only

NTX_PENDING	EQU	0
NTX_OK		EQU	1
NTX_ERROR	EQU	2

; Qualified upper bounds (units, 21 MHz).  Stand-calibrated in M2/M3.
; Measured on the stand (21 MHz, isaWaitT 8): lock + map + unmap +
; release = 49 us around the card routine.
COST_PORTION	EQU	110	; bracket + a short card step (<= 35 us)
COST_BRINGUP	EQU	190	; bracket + the longest bring-up step (16 ID bytes)
COST_CHUNK	EQU	COST_PORTION + 3 * NIC_CHUNK	; 40-byte card copy with sum (stand: 216 us)
COST_TX_BEGIN	EQU	250	; TX room check, preamble and a 54-byte header
COST_TX_WAIT	EQU	150	; completion check + transport notification
COST_CLASSIFY	EQU	200	; Ethernet/ARP/IPv4 checks and the IP header checksum
COST_ACCEPT	EQU	290	; transport accept: ports, state, header fields
COST_STORE	EQU	170	; payload placement in the RX ring (TCP)
COST_FINISH	EQU	260	; checksum verdict + transport input (TCP/UDP)
COST_PREPARE	EQU	60	; NIC_PREPARE + bring-up deadline
COST_ARP_PULL	EQU	110	; ARP frame into ctx.txh
COST_TP_PULL	EQU	230	; IPv4 + TCP/UDP header with checksums
BRINGUP_MS	EQU	3000	; whole bring-up deadline
TX_TIMEOUT_MS	EQU	50	; transmit completion

; IX = ctx.hwsm
	MACRO	HWSM_IX
	PUSH	DE			; preserves DE
	LD	DE,UCTX_HWSM - CTX_BIAS
	PUSH	IY
	POP	IX
	ADD	IX,DE
	POP	DE
	ENDM

; HS_FIELD: HL = address of ctx.hwsm field A.  Preserves BC, DE.
HS_FIELD
	PUSH	DE
	LD	E,A
	LD	D,0
	LD	HL,UCTX_HWSM - CTX_BIAS
	ADD	HL,DE
	PUSH	IY
	POP	DE
	ADD	HL,DE
	POP	DE
	RET

; RUN_PORTION: take the bus and run (P) routine HL.  CF=1 when the bus is
; busy (nothing was run).  Clobbers A, BC, DE, HL, IX.
RUN_PORTION
	PUSH	HL
	CALL	ISA_ACQUIRE
	POP	HL
	RET	C
	PUSH	HL
	HWSM_IX
	POP	HL
	CALL	PORTION
	CALL	ISA_RELEASE
	OR	A
	RET

; ----------------------------------------------------------------------
; HW_STEP: main-loop hardware work of one STEP.
; ----------------------------------------------------------------------
HW_STEP
	LD	A,(IY+CX_HW_STATE)
	OR	A			; UHW_DOWN
	JR	NZ,.state
	LD	A,(IY+CX_STATE)
	CP	UNETG_CTXSTATE_CONFIGURED
	RET	NZ
	LD	HL,COST_PREPARE
	CALL	TAKE
	RET	C
	HWSM_IX
	CALL	NIC_PREPARE
	LD	(IY+CX_HW_STATE),UHW_INIT
	LD	BC,UCTX_HWSM + HS_BDL - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,BC
	LD	DE,BRINGUP_MS
	CALL	DL_SET
	LD	A,UHW_INIT
.state
	CP	UHW_INIT
	JR	Z,HW_BRINGUP
	CP	UHW_RUN
	JR	Z,HW_RUN
	CP	UHW_STOP
	RET	NZ
	; SHUTDOWN: stop the card in portions (t0/deadline are in sched.asm)
.stop
	SET	2,(IY+CX_WORK)		; UWK_MORE until the card is safe
	LD	HL,COST_PORTION
	CALL	TAKE
	RET	C
	LD	HL,NIC_STOP
	CALL	RUN_PORTION
	RET	C
	CALL	HS_RESULT
	CP	NBR_CONTINUE
	JR	Z,.stop
	CP	NBR_DONE
	RET	NZ			; WAIT / FAULT: the stop deadline decides
	LD	(IY+CX_HW_STATE),UHW_STOPPED
	RES	2,(IY+CX_WORK)
	RET

HW_BRINGUP
	SET	2,(IY+CX_WORK)		; UWK_MORE until the card runs
	LD	BC,UCTX_HWSM + HS_BDL - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,BC
	CALL	DL_LEFT
	JR	NC,.portion
.fault
	LD	(IY+CX_HW_STATE),UHW_FAULT
	RES	2,(IY+CX_WORK)
	RET
.portion
	LD	HL,COST_BRINGUP
	CALL	TAKE
	RET	C
	LD	HL,NIC_BRINGUP
	CALL	RUN_PORTION
	RET	C
	CALL	HS_RESULT
	CP	NBR_CONTINUE
	JR	Z,.portion
	CP	NBR_WAIT
	RET	Z
	CP	NBR_FAULT
	JR	Z,.fault
	LD	(IY+CX_HW_STATE),UHW_RUN
	RET

; HS_RESULT: A = HS_RES.  Clobbers BC, HL.
HS_RESULT
	LD	BC,UCTX_HWSM + HS_RES - CTX_BIAS
	PUSH	IY
	POP	HL
	ADD	HL,BC
	LD	A,(HL)
	RET

HW_RUN
	CALL	ETH_TX_STEP
	JP	ETH_RX_STEP

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
	DEC	A
	JR	NZ,.next
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
	JP	NZ,.store
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
	LD	HL,COST_PORTION
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
	LD	HL,COST_CHUNK
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
	LD	HL,COST_CHUNK
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
	LD	(IX+HS_RXS),ERX_ACCEPT
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

; ETH_SEG_START: called by TP_RX_ACCEPT for an accepted segment.
; In: BC = segment length, A = protocol, IX -> frame.  Starts the checksum
; with the pseudo header and the segment bytes already in scratch and sets
; HS_RXREM / HS_RXSKIP (= 0) / HS_RXLIM (= 0) / HS_RXS = COPY or FINISH.
; The transport then sets HS_RXSKIP / HS_RXLIM / HS_RXDST / HS_RXSPAN for
; the card part.  Out: DE = segment bytes in scratch.
ETH_SEG_START
	PUSH	BC
	LD	D,B
	LD	E,C
	LD	C,A
	CALL	CSUM_PSEUDO		; HL = pseudo-header sum
	POP	BC
	LD	A,B
	OR	A
	JR	NZ,.full
	LD	A,C
	CP	L4_IN_SCRATCH
	JR	C,.n
.full
	LD	A,L4_IN_SCRATCH
.n
	PUSH	BC			; segment length
	LD	C,A
	LD	B,0
	PUSH	BC			; bytes in scratch
	PUSH	IX
	POP	DE
	PUSH	HL
	LD	HL,ETH_L4
	ADD	HL,DE
	EX	DE,HL			; DE -> segment in scratch
	POP	HL
	CALL	CSUM_RAM
	POP	DE			; DE = bytes in scratch
	POP	BC			; BC = segment length
	PUSH	IX			; frame
	PUSH	DE
	HWSM_IX
	POP	DE
	LD	(IX+HS_SUM),L
	LD	(IX+HS_SUM+1),H
	LD	H,B
	LD	L,C
	OR	A
	SBC	HL,DE			; card bytes of the segment
	LD	(IX+HS_RXREM),L
	LD	(IX+HS_RXREM+1),H
	XOR	A
	LD	(IX+HS_RXSKIP),A
	LD	(IX+HS_RXSKIP+1),A
	LD	(IX+HS_RXLIM),A
	LD	(IX+HS_RXLIM+1),A
	LD	(IX+HS_NOCHK),A
	LD	(IX+HS_PAR),A		; the card part starts on an even offset
	LD	A,H
	OR	L
	LD	A,ERX_COPY
	JR	NZ,.state
	LD	A,ERX_FINISH
.state
	LD	(IX+HS_RXS),A
	POP	IX
	RET

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
	LD	HL,COST_CHUNK
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
	SET	2,(IY+CX_WORK)
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
	JP	DL_SET

; (P) completion check
TXP_CHECK
	CALL	NIC_TX_CHECK
	LD	(IX+HS_RES),A
	RET

; ----------------------------------------------------------------------
; HW_ISR: STEP_ISR body -- only a status sample: a waiting frame sets
; UPEND_RX for the next STEP.  No protocol work, no events.
; ----------------------------------------------------------------------
HW_ISR
	LD	A,(IY+CX_HW_STATE)
	CP	UHW_RUN
	RET	NZ
	LD	HL,PROF_EMPTY_POLL_US
	CALL	TAKE
	RET	C
	LD	HL,ISRP_POLL
	CALL	RUN_PORTION
	RET
ISRP_POLL
	STAT_INC UNETG_STATS_POLLS_TOTAL
	SET	UPEND_POLLED,(IY+CX_ISR_PENDING)
	CALL	NIC_ISR_POLL
	RET	C
	SET	UPEND_RX,(IY+CX_ISR_PENDING)
	SET	0,(IY+CX_WORK)
	RET
