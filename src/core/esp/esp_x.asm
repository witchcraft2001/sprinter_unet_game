; esp_x.asm -- transparent UDP of GUDPESP (esp_fw = 2; main only).
;
; In command mode (esp_fw = 1) every datagram is an AT exchange: CIPSEND,
; the prompt, the payload, "Recv n bytes", SEND OK; "+IPD,0,n:" before every
; received one -- about 100 UART bytes and two round trips per small
; packet.  In the transparent mode of ESP-AT (AT+CIPMODE=1 after a UDP
; CIPSTART with a fixed peer, then AT+CIPSEND without parameters: OK and
; '>') the module is a byte pipe: what the UART brings goes out as UDP
; packets (cut after 20 ms of silence or 1460 bytes), what arrives is
; written to the UART as it is.  Datagram boundaries are kept by records
; (docs/unet-game-abi.md, tools/harness/net/xrec.js):
;
;   byte 0 = check << 2 | len >> 8      check = (0x2B + lo + hi) & 0x3F
;   byte 1 = len & 0xFF                 len = 0..512 payload bytes
;
; TX: a committed slot becomes one record: the header and up to
; ESP_XHEAD payload bytes are copied into the command buffer (one stream
; for the pump), the rest goes out from the slot itself; TX_DONE once the
; last byte is in the UART (the module sends nothing back).
; RX: the record parser (ESP_XPARSE) replaces the AT line parser while
; the module is in data mode: header, a free RX slot, the payload
; (ESP_PAY), the publication (EPD_PUBLISH).  A header that fails its
; check drops the bytes up to ESP_XSIL_MS of silence (the peer sends one
; record per datagram, so a datagram start follows a pause), counted in
; drop_checksum; a record without a free slot or longer than a slot is
; lost whole (ring_overflow), as a datagram is.
; Leaving the data mode is "+++" between ESP_GUARD_MS of silence on both
; sides and ESP_PPP_MS before the next command (CLOSE: esp_seq.asm
; T_PPP; SHUTDOWN and bring-up: uart.asm, blind, as the module answers
; nothing).  In data mode the module reports no link loss (no CLOSED, no
; WIFI DISCONNECT): the application keeps its own keepalive.

ESP_XHEAD	EQU	ES_CMD_MAX - 2	; payload bytes copied behind the header
ESP_XSIL_MS	EQU	30		; silence that ends a resync
ESP_GUARD_MS	EQU	50		; silence before "+++" (the module: > 20 ms)
ESP_PPP_MS	EQU	1200		; after "+++" (the module: >= 1 s to the next command)
ES_XPARSE_MAX	EQU	64		; bytes per record parser round
ESP_XCUT_MS	EQU	25		; UART silence after which the module has cut its packet
ESP_XAGE_MS	EQU	40		; a record joins a packet being gathered at most this old
COST_XSEND	EQU	115		; a record started: slot, header, gate, stream (+ 1 per byte copied; stand 158 with 62)
COST_XPARSE	EQU	150		; a record parser round (+ 1 per byte)
	ASSERT	COST_XSEND + ESP_XHEAD <= PROF_MAX_ITEM_US && COST_XPARSE + ES_XPARSE_MAX <= PROF_MAX_ITEM_US

; ESP_XCFG: Z when the configuration asks for the transparent mode.
; Clobbers A.
ESP_XCFG
	LD	A,(IY+CX_ESP_FW)
	CP	2
	RET

; ----------------------------------------------------------------------
; ESP_XSEND (ESP_PICK.try_tx in data mode): slot C (COMMITTED) becomes a
; record.  IX = tp.  Out: CF=0 (a job started, or the budget refused it:
; the sequencer stops either way).  Clobbers A, BC, DE, HL.
; ----------------------------------------------------------------------
ESP_XSEND
	PUSH	BC
	CALL	TX_LEN_PTR
	LD	E,(HL)
	INC	HL
	LD	D,(HL)			; DE = length
	PUSH	DE
	LD	HL,ESP_XHEAD
	CALL	MIN_DE_HL		; DE = bytes copied behind the header
	LD	HL,COST_XSEND
	ADD	HL,DE
	CALL	TAKE			; keeps IX
	POP	DE
	POP	BC
	CCF
	RET	NC			; refused: next STEP
	PUSH	DE			; [length]
	CALL	TX_STATE_PTR
	LD	(HL),UTX_SENDING
	LD	(IX+ET_TXSLOT),C
	CALL	TX_BUF			; HL = payload
	EX	(SP),HL			; [payload] HL = length
	EX	DE,HL			; DE = length
	LD	HL,ES_CMD_OFS - CTX_BIAS
	PUSH	IY
	POP	BC
	ADD	HL,BC			; HL = command buffer
	LD	A,E
	ADD	A,D
	ADD	A,0x2B
	AND	0x3F
	RLCA
	RLCA
	OR	D
	LD	(HL),A			; check << 2 | len >> 8
	INC	HL
	LD	(HL),E			; len & 0xFF
	INC	HL
	; k = min(length, ESP_XHEAD) behind the header, the rest from the slot
	PUSH	HL			; [payload][dest]
	EX	DE,HL			; HL = length
	LD	DE,ESP_XHEAD
	OR	A
	SBC	HL,DE			; HL = length - ESP_XHEAD
	JR	NC,.long
	ADD	HL,DE
	EX	DE,HL			; DE = k = length
	LD	HL,0			; nothing left in the slot
.long
	LD	(IX+ET_XREST),L
	LD	(IX+ET_XREST+1),H
	LD	B,D
	LD	C,E			; BC = k
	POP	DE			; [payload] DE = dest
	POP	HL			; payload
	LD	A,B
	OR	C
	JR	Z,.empty
	LDIR
.empty
	LD	(IX+ET_XSRC),L
	LD	(IX+ET_XSRC+1),H
	; the stream: header and k bytes from the command buffer
	LD	A,E
	SUB	LOW (ES_CMD_OFS - CTX_BIAS)
	PUSH	IY
	POP	HL
	SUB	L			; bytes in the buffer (< 64)
	LD	C,A
	LD	A,EJ_SEND
	CALL	ESP_JOB
	LD	(IX+ET_CST),ECS_WAIT
	LD	(IX+ET_TERM),TK_NONE
	CALL	ESP_XGATE		; C = 0: the record waits for the silence
	LD	HL,ES_CMD_OFS - CTX_BIAS
	PUSH	IY
	POP	DE
	ADD	HL,DE
	HWSM_IX
	LD	(IX+ES_TXP),L
	LD	(IX+ES_TXP+1),H
	LD	(IX+ES_TXN),C
	LD	(IX+ES_TXN+1),0
	LD	(IX+ES_TXKIND),ETXK_CMD
	ET_IX
	LD	E,(IY+CX_SEND_STALL_TIMEOUT_MS)
	LD	D,(IY+CX_SEND_STALL_TIMEOUT_MS+1)
	CALL	ET_ARM_CDL
	OR	A
	RET

; ----------------------------------------------------------------------
; ESP_XWAIT (ESP_SEQ, a record being streamed): the rest of the slot once
; the buffer part is in the UART; the result once all of it is.  IX = tp.
; Clobbers A, BC, DE, HL, IX.
; ----------------------------------------------------------------------
ESP_XWAIT
	LD	A,(IX+ET_XHOLD)
	OR	A
	JR	NZ,.held
	CALL	ES_TX_IDLE
	JR	NZ,.busy
	LD	L,(IX+ET_XREST)
	LD	H,(IX+ET_XREST+1)
	LD	A,H
	OR	L
	JR	Z,.done
	XOR	A
	LD	(IX+ET_XREST),A
	LD	(IX+ET_XREST+1),A
	LD	E,(IX+ET_XSRC)
	LD	D,(IX+ET_XSRC+1)
	HWSM_IX
	LD	(IX+ES_TXP),E
	LD	(IX+ES_TXP+1),D
	LD	(IX+ES_TXN),L
	LD	(IX+ES_TXN+1),H
	LD	(IX+ES_TXKIND),ETXK_DATA
	RET
.done
	LD	(IX+ET_TERM),TK_SENDOK
	LD	(IX+ET_CST),ECS_DONE
	JP	ESP_DONE		; its result at once (its own cost)
.busy
	CALL	ET_CDL_DUE
	RET	NC
	JP	ESP_TIMEOUT
.held
	; the record waits for the module to cut its packet (ESP_XGATE)
	CALL	ESP_XQUIET
	RET	NC
	LD	C,(IX+ET_XHOLD)
	LD	(IX+ET_XHOLD),0
	CALL	ESP_XNEW
	HWSM_IX
	LD	(IX+ES_TXN),C		; the stream starts (ES_TXP, ES_TXKIND set)
	RET

; ----------------------------------------------------------------------
; ESP_XGATE (ESP_XSEND, inside its item): may the record start now?
; The module cuts a UDP packet after 20 ms of UART silence (MAME's
; esp8266_at; ESP-AT documents "20 ms" without saying from which byte),
; or at 1460 bytes.  Records closer than that grow one packet: at one
; STEP a frame a record over 17 bytes takes two STEPs (one FIFO load per
; STEP), and inputs every 40 ms never left 20 ms of silence -- a packet
; of 1460 bytes, inputs 2.7 s late.  A record joins the packet being
; gathered only while that is at most ESP_XAGE_MS old; otherwise it is
; held (ET_XHOLD) until ESP_XCUT_MS of silence since the last TX write
; (ES_XLAST, stamped by the pumps; now_ms has the application's tick:
; 20 ms plus the FIFO drain plus one 2 ms tick), and ESP_XWAIT starts
; it.  In: C = bytes of the stream, IX = tp.  Out: C = bytes to stream
; now.  Clobbers A, DE, HL.
; ----------------------------------------------------------------------
ESP_XGATE
	LD	(IX+ET_XHOLD),0
	BIT	EXF_PKT,(IY+EX_XFL)
	JR	Z,ESP_XNEW		; the first record of the data mode
	CALL	ESP_XQUIET
	JR	C,ESP_XNEW		; the module has sent what it gathered
	LD	L,(IY+CX_NOW_MS)
	LD	H,(IY+CX_NOW_MS+1)
	LD	E,(IX+ET_XT0)
	LD	D,(IX+ET_XT0+1)
	OR	A
	SBC	HL,DE			; age of the packet being gathered
	LD	DE,-(ESP_XAGE_MS + 1)
	ADD	HL,DE
	RET	NC			; young enough: the record joins it
	LD	(IX+ET_XHOLD),C		; held
	LD	C,0
	RET
; ESP_XNEW: the record starts a packet of the module.  Clobbers A.
ESP_XNEW
	LD	A,(IY+CX_NOW_MS)
	LD	(IX+ET_XT0),A
	LD	A,(IY+CX_NOW_MS+1)
	LD	(IX+ET_XT0+1),A
	SET	EXF_PKT,(IY+EX_XFL)
	RET
; ESP_XQUIET: CF=1 when the UART has been silent ESP_XCUT_MS since the
; last TX write.  Clobbers A, DE, HL.
ESP_XQUIET
	LD	L,(IY+CX_NOW_MS)
	LD	H,(IY+CX_NOW_MS+1)
	LD	E,(IY+EX_XLAST)
	LD	D,(IY+EX_XLAST+1)
	OR	A
	SBC	HL,DE
	LD	DE,-ESP_XCUT_MS
	ADD	HL,DE
	RET

; ----------------------------------------------------------------------
; ESP_XPARSE (ESP_PARSE in data mode): record parser rounds, one per call
; (a second one after the ring end).  IX = tp.  Clobbers A, BC, DE, HL, IX.
; ----------------------------------------------------------------------
ESP_XPARSE
	CALL	.one			; CF=0: the round reached the ring end
	RET	C
	ET_IX
.one
	LD	A,(IX+ET_PEND)
	OR	A
	SCF
	RET	NZ			; the publication first
	LD	A,(IY+CX_UNITS+1)
	OR	A
	JR	NZ,.sizing
	LD	A,(IY+CX_UNITS)
	CP	COST_XPARSE + 1
	JR	NC,.sizing
	SET	4,(IY+CX_WORK)		; UWK_YIELD
	SCF
	RET
.sizing
	CALL	ER_HEAD			; HL = waiting, DE = tail
	LD	A,H
	OR	L
	JR	Z,.silent
	PUSH	DE			; [tail]
	LD	B,H
	LD	C,L
	LD	HL,ER_SIZE
	OR	A
	SBC	HL,DE			; bytes up to the ring end
	LD	D,B
	LD	E,C
	CALL	MIN_DE_HL
	LD	HL,ES_XPARSE_MAX
	CALL	MIN_DE_HL		; DE = bytes of this round
	LD	BC,-COST_XPARSE
	XOR	A			; 1 unit per byte
	CALL	PARSE_BUDGET		; BC = bytes
	POP	DE			; tail
	RET	C
	PUSH	DE			; [tail]
	PUSH	BC			; [tail][n]
	LD	L,(IY+CX_HW_RING_PTR)
	LD	H,(IY+CX_HW_RING_PTR+1)
	ADD	HL,DE
	CALL	ESP_XBYTES		; BC = bytes left over
	LD	H,B
	LD	L,C
	CALL	UNITS_REFUND		; (keeps BC)
	POP	HL			; n
	OR	A
	SBC	HL,BC			; consumed
	POP	DE			; tail
	ADD	HL,DE
	LD	A,H
	AND	HIGH ER_MASK
	LD	H,A
	PUSH	HL
	CALL	ER_SET_TAIL
	POP	HL
	LD	A,H
	OR	L
	RET	Z			; CF=0: wrapped to the ring start
	SCF
	RET
.silent
	; nothing waits: a resync ends after ESP_XSIL_MS of it
	LD	A,(IX+ET_PST)
	CP	EPS_XSKIP
	SCF
	RET	NZ
	PUSH	IX
	POP	HL
	LD	BC,ET_XSIL
	ADD	HL,BC
	CALL	DL_LEFT
	CCF
	RET	C			; not yet
	LD	(IX+ET_PST),EPS_LINE
	SCF
	RET

; ESP_XBYTES: HL = first byte, BC = count, IX = tp.  Out: BC = bytes left
; over (the round stopped at a publication).  Clobbers A, DE, HL.
ESP_XBYTES
.loop
	LD	A,B
	OR	C
	RET	Z
	LD	A,(IX+ET_PST)
	CP	EPS_PAY
	JR	Z,.pay
	CP	EPS_XH2
	JR	Z,.h2
	CP	EPS_XSKIP
	JR	Z,.skip
	; the first header byte
	LD	A,(HL)
	LD	(IX+ET_N1),A
	LD	(IX+ET_PST),EPS_XH2
	INC	HL
	DEC	BC
	JR	.loop
.h2
	LD	A,(HL)
	INC	HL
	DEC	BC
	PUSH	HL
	PUSH	BC
	CALL	ESP_XHDR
	POP	BC
	POP	HL
	LD	A,(IX+ET_PEND)
	OR	A
	JR	Z,.loop
	RET				; an empty record's publication first
.skip
	; dropped up to a silence
	ADD	HL,BC
	LD	BC,0
	JP	ESP_XSIL
.pay
	CALL	ESP_PAY			; HL / BC advanced
	LD	A,(IX+ET_PEND)
	OR	A
	JR	Z,.loop
	RET				; the publication first

; ESP_XSIL: a resync waits for ESP_XSIL_MS of silence from now.  IX = tp.
; Keeps BC, IX.  Clobbers A, DE, HL.
ESP_XSIL
	PUSH	BC
	PUSH	IX
	POP	HL
	LD	BC,ET_XSIL
	ADD	HL,BC
	LD	DE,ESP_XSIL_MS
	CALL	DL_ARM
	POP	BC
	RET

; ESP_XHDR: A = the second header byte, ET_N1 = the first.  A record for
; the open channel goes to a free RX slot (EPK_UDP), any other is skipped
; (EPK_SINK); a bad header starts a resync.  IX = tp.  Clobbers A, BC, DE,
; HL.
ESP_XHDR
	LD	E,A			; lo
	LD	A,(IX+ET_N1)
	AND	3
	LD	D,A			; hi
	CP	3
	JR	Z,.bad
	CP	2
	JR	NZ,.len_ok
	LD	A,E
	OR	A
	JR	NZ,.bad			; above 512
.len_ok
	LD	A,E
	ADD	A,D
	ADD	A,0x2B
	AND	0x3F
	RLCA
	RLCA
	OR	D
	CP	(IX+ET_N1)
	JR	NZ,.bad
	LD	(IX+ET_GOT),E
	LD	(IX+ET_GOT+1),D
	LD	(IX+ET_PLEFT),E
	LD	(IX+ET_PLEFT+1),D
	LD	(IX+ET_PKIND),EPK_SINK
	LD	A,D
	OR	E
	LD	A,EPS_PAY
	JR	NZ,.pst
	XOR	A			; EPS_LINE: an empty record has no payload
.pst
	LD	(IX+ET_PST),A
	LD	A,(IY+CX_CHAN)
	CP	UCH_OPEN
	RET	NZ			; no channel: skipped
	LD	L,(IY+CX_RX_SLOT_SIZE)
	LD	H,(IY+CX_RX_SLOT_SIZE+1)
	OR	A
	SBC	HL,DE
	JR	C,.lost			; longer than a slot: lost whole
	PUSH	IX
	CALL	RXD_TAKE		; HL = buffer
	POP	IX
	JR	C,.lost
	LD	(IX+ET_RXDST),L
	LD	(IX+ET_RXDST+1),H
	LD	(IX+ET_PKIND),EPK_UDP
	LD	A,(IX+ET_PST)
	OR	A
	RET	NZ
	LD	(IX+ET_PEND),EPD_PUBLISH	; an empty datagram
	RET
.lost
	PUSH	IX
	STAT_INC UNETG_STATS_RING_OVERFLOW
	POP	IX
	RET
.bad
	PUSH	IX
	STAT_INC UNETG_STATS_DROP_CHECKSUM
	POP	IX
	LD	(IX+ET_PST),EPS_XSKIP
	JP	ESP_XSIL

; ESP_XOVERRUN (ESP_OVERRUN in data mode): bytes of the record stream are
; lost: the record being received is dropped and the parser resyncs on a
; silence.  The channel stays: a lost datagram is what UDP may do (counted
; in uart_overrun).  IX = tp.
ESP_XOVERRUN
	LD	A,(IX+ET_PST)
	CP	EPS_PAY
	JR	NZ,.skip
	LD	A,(IX+ET_PKIND)
	CP	EPK_UDP
	JR	NZ,.skip
	PUSH	IX
	CALL	RXD_DROP
	POP	IX
.skip
	LD	(IX+ET_PKIND),0
	LD	(IX+ET_PST),EPS_XSKIP
	JP	ESP_XSIL

; ----------------------------------------------------------------------
; ESP_XJOB (ESP_ISSUE): the command of a transparent-mode OPEN or CLOSE
; step.  IX = tp.  Out: A = 0: not one (the command-mode code decides);
; A = 1: HL = template, DE = deadline; A = 2: the silence before "+++" is
; being waited for (ECS_PAUSE).  Clobbers BC, DE, HL.
; ----------------------------------------------------------------------
EXO_START	EQU	2		; OPEN: CIPSTART and on need OK and the link
EXO_SEND	EQU	4		; OPEN: CIPSEND, whose terminal is the prompt
EXC_CLOSE	EQU	2		; CLOSE: the last step (AT+CIPCLOSE)
ESP_XJOB
	CALL	ESP_XCFG
	LD	A,0
	RET	NZ
	LD	A,(IX+ET_JOB)
	LD	HL,ESP_XOPEN_TAB
	CP	EJ_OPEN
	JR	Z,.tab
	LD	HL,ESP_XCLOSE_TAB
	CP	EJ_CLOSE
	LD	A,0
	RET	NZ
.tab
	LD	A,(IX+ET_IDX)
	ADD	A,A
	ADD	A,A			; DW template, DW deadline
	LD	E,A
	LD	D,0
	ADD	HL,DE
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	INC	HL
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A
	EX	DE,HL			; HL = template, DE = deadline
	PUSH	HL
	LD	BC,T_PPP
	OR	A
	SBC	HL,BC
	POP	HL
	LD	A,1
	RET	NZ
	; "+++": only out of the data mode, after a silence
	BIT	EXF_DATA,(IY+EX_XFL)
	JR	NZ,.ppp
	INC	(IX+ET_IDX)		; not in data mode: no escape
	JR	ESP_XJOB
.ppp
	BIT	EXF_GUARD,(IY+EX_XFL)
	JR	NZ,.send
	SET	EXF_GUARD,(IY+EX_XFL)
	LD	(IX+ET_CST),ECS_PAUSE
	LD	DE,ESP_GUARD_MS
	CALL	ET_ARM_CDL
	LD	A,2
	RET
.send
	; from here on the module talks AT again: the line parser takes over
	; (a record cut short is lost)
	PUSH	HL
	PUSH	DE
	LD	A,(IY+EX_XFL)
	AND	~((1 << EXF_DATA) | (1 << EXF_GUARD)) & 0xFF
	LD	(IY+EX_XFL),A
	LD	A,(IX+ET_PST)
	CP	EPS_PAY
	JR	NZ,.lines
	LD	A,(IX+ET_PKIND)
	CP	EPK_UDP
	JR	NZ,.lines
	PUSH	IX
	CALL	RXD_DROP
	POP	IX
.lines
	XOR	A
	LD	(IX+ET_PST),A
	LD	(IX+ET_PKIND),A
	LD	(IX+ET_LLEN),A
	POP	DE
	POP	HL
	LD	A,1
	RET

; OPEN: out of a data mode left over, the link closed, the UDP link with
; its fixed peer, the transparent mode on, the data mode (the prompt).
ESP_XOPEN_TAB
	DW	T_PPP, ESP_PPP_MS
	DW	T_CLOSEX, ESP_CMD_MS
	DW	T_STARTX, ESP_START_MS
	DW	T_MODE1, ESP_CMD_MS
	DW	T_SENDX, ESP_CMD_MS
; CLOSE: out of the data mode, the transparent mode off, the link closed.
ESP_XCLOSE_TAB
	DW	T_PPP, ESP_PPP_MS
	DW	T_MODE0, ESP_CMD_MS
	DW	T_CLOSEX, ESP_IO_MS
	ASSERT	(ESP_XCLOSE_TAB - ESP_XOPEN_TAB) / 4 == EXO_SEND + 1

; Templates of the transparent mode (esp_seq.asm: code 14 = no CR LF).
T_PPP		DB	"+++", 14, 0
T_CLOSEX	DB	"AT+CIPCLOSE", 0
T_MUX0		DB	"AT+CIPMUX=0", 0
T_MODE0		DB	"AT+CIPMODE=0", 0
T_MODE1		DB	"AT+CIPMODE=1", 0
T_SENDX		DB	"AT+CIPSEND", 0
T_STARTX	DB	"AT+CIPSTART=", 15, 0x22, "UDP", 0x22, ",", 0x22, 8, ".", 9, ".", 10, ".", 11, 0x22, ",", 1, ",", 2, ",0", 0

; Set-up of the transparent profile: one link (CIPMUX=0), the transparent
; mode off until OPEN; the links of either mode closed first.
ESP_SETUP_XTAB
	DW	T_AT
	DB	0
	DW	T_ATE0
	DB	0
	DW	T_CLOSE5
	DB	1
	DW	T_CLOSEX
	DB	1
	DW	T_MUX0
	DB	0
	DW	T_MODE0
	DB	0
	DW	T_RECVMODE
	DB	1
	DW	T_DINFO0
	DB	1
ESP_SETUP_XEND
ESP_SETUP_XN	EQU	(ESP_SETUP_XEND - ESP_SETUP_XTAB) / 3

; ----------------------------------------------------------------------
; Blind escapes (card layer portions, IX = hwsm): the module may be left
; in its data mode by a session that ended without CLOSE (the Sprinter
; was reset) and must be left out of it after SHUTDOWN (the system stack
; talks AT).  Nothing is parsed: fixed pauses, the module's answers are
; read and dropped.
; ----------------------------------------------------------------------
ESP_XSTOP_MS	EQU	100		; between the commands after "+++"

; X_DL: HL -> ES_XDL.  Clobbers BC.
X_DL
	PUSH	IX
	POP	HL
	LD	BC,ES_XDL
	ADD	HL,BC
	RET
; X_ARM: ES_XDL = now + DE.  Clobbers A, BC, HL.
X_ARM
	CALL	X_DL
	JP	DL_ARM
; X_DUE: CF=1 when ES_XDL is reached.  Clobbers A, BC, DE, HL.
X_DUE
	CALL	X_DL
	JP	DL_LEFT
; X_PUT: B bytes from DE to THR (the FIFO is empty: the last write was
; long ago).  Clobbers A, B, DE, HL.
X_PUT
	LD	A,U_THR
	CALL	UREG
.put
	LD	A,(DE)
	LD	(HL),A
	INC	DE
	DJNZ	.put
	RET
; X_DRAIN: up to ES_RX_MAX bytes of the module dropped.  Clobbers A, B, HL.
X_DRAIN
	LD	B,ES_RX_MAX
.byte
	LD	A,U_LSR
	CALL	UREG
	BIT	0,(HL)			; LSR_DR
	RET	Z
	LD	A,U_RBR
	CALL	UREG
	LD	A,(HL)
	DJNZ	.byte
	RET

; NIC_XESC (NIC_BRINGUP phase EUP_XESC, esp_fw = 2): ESP_GUARD_MS of
; silence (armed by .init), "+++", ESP_PPP_MS, then the AT set-up.  A
; module in command mode takes "+++AT" for a bad command: the set-up's AT
; is retried.
NIC_XESC
	LD	(IX+HS_RES),NBR_WAIT
	CALL	X_DUE
	RET	NC
	LD	A,(IX+ES_XSTG)
	OR	A
	JR	NZ,.after
	LD	DE,S_XPPP
	LD	B,3
	CALL	X_PUT
	INC	(IX+ES_XSTG)
	LD	DE,ESP_PPP_MS
	JP	X_ARM
.after
	LD	(IX+ES_XSTG),0
	LD	(IX+HS_PHASE),EUP_AT
	RET

; NIC_XSTOP (NIC_STOP in data mode): the rest of a record dropped,
; ESP_GUARD_MS of silence, "+++", ESP_PPP_MS, AT+CIPMODE=0, AT+CIPCLOSE,
; then the plain stop.  Out: HS_RES = NBR_WAIT, or CF=1: go on with the
; plain stop.  Needs close_timeout_ms of about 1.5 s.
NIC_XSTOP
	CALL	X_DRAIN
	LD	(IX+HS_RES),NBR_WAIT
	LD	A,(IX+ES_XSTG)
	OR	A
	JR	NZ,.wait
	XOR	A
	LD	(IX+ES_TXN),A
	LD	(IX+ES_TXN+1),A
	INC	(IX+ES_XSTG)
	LD	DE,ESP_GUARD_MS
	JP	X_ARM
.wait
	CALL	X_DUE
	RET	NC			; not yet (CF=0: wait)
	LD	A,(IX+ES_XSTG)
	INC	(IX+ES_XSTG)
	DEC	A
	JR	NZ,.mode
	LD	DE,S_XPPP
	LD	B,3
	CALL	X_PUT
	LD	DE,ESP_PPP_MS
	CALL	X_ARM
	OR	A
	RET
.mode
	DEC	A
	JR	NZ,.close
	LD	DE,S_XMODE0
	LD	B,S_XMODE0_N
	CALL	X_PUT
	LD	DE,ESP_XSTOP_MS
	CALL	X_ARM
	OR	A
	RET
.close
	DEC	A
	JR	NZ,.done
	LD	DE,S_XCLOSE
	LD	B,S_XCLOSE_N
	CALL	X_PUT
	LD	DE,ESP_XSTOP_MS
	CALL	X_ARM
	OR	A
	RET
.done
	LD	(IX+ES_XSTG),0
	RES	EXF_DATA,(IX+ES_XFL)
	SCF
	RET
S_XPPP		DB	"+++"
S_XMODE0	DB	"AT+CIPMODE=0", 13, 10
S_XMODE0_N	EQU	$ - S_XMODE0
S_XCLOSE	DB	"AT+CIPCLOSE", 13, 10
S_XCLOSE_N	EQU	$ - S_XCLOSE
	ASSERT	S_XMODE0_N <= 16 && S_XCLOSE_N <= 16
