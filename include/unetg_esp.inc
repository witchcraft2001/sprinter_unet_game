; unetg_esp.inc -- SprinterESP layer: TL16C550C registers, ctx.hwsm and
; ctx.tp layouts, AT parser tokens.  Not public ABI.
;
; The ESP builds never use ctx.arp / scratch / txh / arptx (Ethernet only);
; the AT command and line buffers alias them, so abi/ctx.toml and
; ctx_version stay shared by all seven builds.

	IFNDEF	_UNETG_ESP_INC
	DEFINE	_UNETG_ESP_INC

	INCLUDE	"unetg_hwsm.inc"

; ---- TL16C550C at io_base (0x3E8 on SprinterESP), port N = 0xC000 + N ----
U_RBR		EQU	0	; R: receive buffer (DLAB = 0)
U_THR		EQU	0	; W: transmit holding (DLAB = 0)
U_DLL		EQU	0	; divisor low (DLAB = 1)
U_IER		EQU	1	; interrupt enable (DLAB = 0); DLM with DLAB = 1
U_DLM		EQU	1
U_FCR		EQU	2	; W: FIFO control
U_LCR		EQU	3
U_MCR		EQU	4
U_LSR		EQU	5
U_SCR		EQU	7

LCR_8N1		EQU	0x03
LCR_DLAB	EQU	0x80
FCR_ENABLE	EQU	0x01
FCR_RX_RESET	EQU	0x02
FCR_TX_RESET	EQU	0x04
MCR_RTS		EQU	0x02
MCR_AFE		EQU	0x20	; TL16C550C auto flow (auto-RTS with MCR_RTS)
; MCR bits 2 / 3 (OUT1 / OUT2) are the ESP module RESET / PGM lines on
; SprinterESP: the layer only ever writes MCR_RUN or MCR_PAUSE / 0.
MCR_RUN		EQU	MCR_AFE | MCR_RTS
MCR_PAUSE	EQU	MCR_AFE		; RTS off: the module holds its output
LSR_DR		EQU	0x01
LSR_OE		EQU	0x02
LSR_THRE	EQU	0x20

; ---- UART ring (hw_ring_ptr): the first 512 bytes are used --------------
ER_SIZE		EQU	512
ER_MASK		EQU	ER_SIZE - 1
ER_PAUSE_AT	EQU	64	; parser backlog at which RTS is dropped explicitly
ER_RESUME_AT	EQU	24	; backlog below which RTS is raised again
ES_RX_MAX	EQU	16	; RX bytes per main portion (FIFO depth)
ES_TX_MAX	EQU	16	; TX bytes per main portion (written only while THRE)

; ---- ctx.hwsm (IX = hwsm); shared fields in unetg_hwsm.inc ---------------
; The hot fields sit in the first 14 bytes of hwsm, which IY reaches
; directly (EX_* = IY offsets); the layer does not use HS_DL.
ES_FLAGS	EQU	3	; u8  ESF_* (bit operations only: shared with STEP_ISR)
ES_RT		EQU	4	; u16 ring tail: written by the parser (main)
ES_TXN		EQU	6	; u16 TX stream bytes left (main only)
ES_RH		EQU	10	; u16 ring head: written by the pump (any context)
ES_MCR		EQU	12	; u8  last MCR value written
ES_ISRCAP	EQU	13	; u8  STEP_ISR's own RX byte budget: EXP_STEP_ISR
				; (sched.asm) writes min(255, leftover units) here
				; every call on a running card; ISRP_POLL reads it
				; (cap = min(ISRP_RX_MAX, (ES_ISRCAP - reserve) / 4)) to size its own
				; drain.  Was a 1-byte gap before ES_TXP (kept even).
ES_TXP		EQU	14	; u16 TX stream source (main only)
ES_TXKIND	EQU	16	; u8  ETXK_*
ES_RXMAX	EQU	17	; u8  RX bytes the next pump may move
ES_SIZE		EQU	18
	ASSERT	ES_SIZE <= HS_RES
EX_FLAGS	EQU	UCTX_HWSM + ES_FLAGS - CTX_BIAS
EX_RT		EQU	UCTX_HWSM + ES_RT - CTX_BIAS
EX_TXN		EQU	UCTX_HWSM + ES_TXN - CTX_BIAS
EX_RH		EQU	UCTX_HWSM + ES_RH - CTX_BIAS
EX_ESFLAGS	EQU	UCTX_HWSM + ES_FLAGS - CTX_BIAS	; STEP_ISR, through IY
EX_ISRCAP	EQU	UCTX_HWSM + ES_ISRCAP - CTX_BIAS	; STEP_ISR writes, ISRP_POLL reads, both through IY
	ASSERT	EX_ISRCAP <= 127
	ASSERT	EX_ESFLAGS <= 127
	ASSERT	EX_RH + 1 <= 127 && EX_TXN + 1 <= 127 && EX_RT + 1 <= 127

ESF_OVERRUN	EQU	0	; LSR.OE seen: the AT stream lost bytes
ESF_RTSOFF	EQU	1	; RTS dropped: the parser is behind
ESF_GOT		EQU	2	; the last pump moved RX bytes (main)
ESF_UP		EQU	3	; UART programmed: the pump and the parser may run
ESF_SETUP_OK	EQU	4	; AT setup finished (bring-up may end)
ESF_SETUP_BAD	EQU	5	; AT setup failed (module absent / not qualified)

ETXK_NONE	EQU	0
ETXK_CMD	EQU	1	; AT command from the command buffer
ETXK_DATA	EQU	2	; payload of an application TX slot

; bring-up phases (HS_PHASE)
EUP_PROBE	EQU	0
EUP_INIT	EQU	1
EUP_AT		EQU	2

; ---- ctx.tp (IX = tp) -------------------------------------------------------
ET_JOB		EQU	0	; u8  EJ_*: what the sequencer is doing
ET_IDX		EQU	1	; u8  step inside the job
ET_CST		EQU	2	; u8  ECS_*: state of the current command
ET_TERM		EQU	3	; u8  terminal token of the finished command
ET_TRY		EQU	4	; u8  retries of the current command
ET_FL		EQU	5	; u8  EF_*
ET_CDL		EQU	6	; u32 command deadline / retry pause
ET_PST		EQU	10	; u8  EPS_*: parser state
ET_LLEN		EQU	11	; u8  bytes in the line buffer (saturates at ES_LINE_MAX)
ET_PLEFT	EQU	12	; u16 payload bytes still expected
ET_PKIND	EQU	14	; u8  EPK_*: where the payload goes
ET_AVAIL	EQU	15	; u16 TCP: bytes the module holds for us (+IPD notice)
ET_REQ		EQU	17	; u16 TCP: bytes asked by the CIPRECVDATA in flight
ET_GOT		EQU	19	; u16 payload length of the current response / datagram
ET_RXDST	EQU	21	; u16 write pointer of the payload
ET_RXSPAN	EQU	23	; u16 TCP: bytes before the RX ring wraps
ET_TXSLOT	EQU	25	; u8  slot of the CIPSEND in flight
ET_N1		EQU	30	; u16 first number of the line
ET_N2		EQU	32	; u16 second number of the line
ET_LINK		EQU	34	; u8  link id prefix of the line (0xFF: none)
ET_TPL		EQU	35	; u16 template of the command being built
ET_BPOS		EQU	37	; u8  template bytes already built
ET_BLEN		EQU	38	; u8  command bytes already in the buffer
ET_CTMO		EQU	39	; u16 deadline of the command being built (ms)
ET_PFAIL	EQU	41	; u8  channel failure to raise (UNETG_EV_*, 0: none)
ET_PFDET	EQU	42	; u8  its detail
ET_PEND		EQU	43	; u8  EPD_*: action left by the parser
ET_SIZE		EQU	44
	ASSERT	ET_SIZE <= 96

EJ_IDLE		EQU	0
EJ_SETUP	EQU	1
EJ_OPEN		EQU	2
EJ_SEND		EQU	3
EJ_RECV		EQU	4
EJ_CLOSE	EQU	5

ECS_NONE	EQU	0	; next command not issued yet
ECS_WAIT	EQU	1	; issued, waiting for its terminal line
ECS_DONE	EQU	2	; terminal in ET_TERM
ECS_PAUSE	EQU	3	; retry after ET_CDL
ECS_BUILD	EQU	4	; command text being built (budgeted pieces)

EF_CONN		EQU	0	; "0,CONNECT" seen for the current CIPSTART / link up
EF_DISCARD	EQU	1	; the channel of the command in flight is gone
EF_REQOPEN	EQU	2	; OPEN requested, CIPSTART not issued yet
EF_READY	EQU	3	; module set up
EF_RESYNC	EQU	4	; parser drops bytes up to the next LF
EF_PROMPT	EQU	5	; CIPSEND: '>' seen, payload streaming
EF_CFAIL	EQU	7	; "CONNECT FAIL" seen for the current CIPSTART

EPD_NONE	EQU	0
EPD_EOL		EQU	1	; a line is complete
EPD_COLON	EQU	2	; ':' after "+..." (+IPD datagram header?)
EPD_COMMA	EQU	3	; ',' after "+..." (+CIPRECVDATA header?)
EPD_PROMPT	EQU	4	; '>' at the line start (CIPSEND)
EPD_PUBLISH	EQU	5	; a UDP datagram's payload just completed (WP2:
				; deferred out of ESP_PAY so a payload round's own cost
				; stays bytes-only, not RXD_PUBLISH's fixed overhead)

EPS_LINE	EQU	0
EPS_PAY		EQU	1

EPK_TCP		EQU	1	; CIPRECVDATA payload into the RX ring (uncommitted)
EPK_UDP		EQU	2	; +IPD datagram into the RX slot being filled
EPK_SINK	EQU	3	; bytes dropped (no slot, too long, protocol error)

; parser tokens (terminal ones are < TK_ASYNC)
TK_NONE		EQU	0
TK_OK		EQU	1
TK_ERROR	EQU	2
TK_FAIL		EQU	3
TK_SENDOK	EQU	4
TK_SENDFAIL	EQU	5
TK_BUSY		EQU	6
TK_ASYNC	EQU	7
TK_CONNECT	EQU	7
TK_CONNFAIL	EQU	8
TK_CLOSED	EQU	9
TK_READY	EQU	10
TK_WIFIOFF	EQU	11
TK_IPD		EQU	12	; +IPD,<link>,<len> (passive notice)
TK_ALREADY	EQU	14
TK_IGNORE	EQU	15	; known noise ("Recv <n> bytes"): stops the table scan

; buffers aliased on the Ethernet-only areas of the context
ES_CMD_OFS	EQU	UCTX_SCRATCH	; u8[64] AT command being sent
ES_CMD_MAX	EQU	64
ES_LINE_OFS	EQU	UCTX_TXH	; u8[40] line being received
ES_LINE_MAX	EQU	40
	ASSERT	UCTX_TXH - UCTX_SCRATCH >= ES_CMD_MAX
	ASSERT	UCTX_ARPTX - UCTX_TXH >= ES_LINE_MAX

	ENDIF
