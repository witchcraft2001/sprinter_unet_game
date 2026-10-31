; profile.inc -- per-card constants published by GET_INFO and enforced by
; INIT_CONFIG.  All timing values are design upper bounds for the turbo
; (21 MHz) profile; they are requirements for the prototype, not
; measurements, until docs/MEASUREMENTS.md says otherwise.

	IFDEF	UGB_HW_ESP
PROF_HW			EQU	UNETG_HW_ESP
PROF_POLL_GAP_US	EQU	2500
PROF_AUTO_GAP_US	EQU	5000
PROF_IRQ_DELIVERY_US	EQU	2000
PROF_MAX_SERVICE_US	EQU	5000	; only with verified RTS/CTS flow control
PROF_CAPS_HW		EQU	UNETG_CAP_POLL | UNETG_CAP_AUTO | UNETG_CAP_FLOW_CONTROL_REQUIRED
PROF_HW_RING_MIN	EQU	UNETG_UART_RING_MIN
PROF_UART_PROFILES	EQU	0x01
PROF_IO_MASK		EQU	0x0007	; 16550 occupies 8 ports
PROF_POLL_EXTRA_US	EQU	0
PROF_DMA_EXTRA_US	EQU	0
	ENDIF
	IFDEF	UGB_HW_RTL
PROF_HW			EQU	UNETG_HW_RTL
PROF_POLL_GAP_US	EQU	2500
PROF_AUTO_GAP_US	EQU	5000
PROF_IRQ_DELIVERY_US	EQU	2000
PROF_MAX_SERVICE_US	EQU	5000
PROF_CAPS_HW		EQU	UNETG_CAP_POLL | UNETG_CAP_AUTO | UNETG_CAP_CHECKSUM_VERIFY
PROF_HW_RING_MIN	EQU	0
PROF_UART_PROFILES	EQU	0
PROF_IO_MASK		EQU	0x001F	; NE2000 block of 32 ports
PROF_POLL_EXTRA_US	EQU	40	; CURR on page 1 + 4-byte header by remote DMA
PROF_DMA_EXTRA_US	EQU	15	; remote DMA programmed for every portion (64-byte header: 231 us)
	ENDIF
	IFDEF	UGB_HW_EL3
PROF_HW			EQU	UNETG_HW_EL3
PROF_POLL_GAP_US	EQU	2500
PROF_AUTO_GAP_US	EQU	5000
PROF_IRQ_DELIVERY_US	EQU	2000
PROF_MAX_SERVICE_US	EQU	5000
PROF_CAPS_HW		EQU	UNETG_CAP_POLL | UNETG_CAP_AUTO | UNETG_CAP_CHECKSUM_VERIFY
PROF_HW_RING_MIN	EQU	0
PROF_UART_PROFILES	EQU	0
PROF_IO_MASK		EQU	0x000F	; 3C509B block of 16 ports
PROF_POLL_EXTRA_US	EQU	0
PROF_DMA_EXTRA_US	EQU	0
	ENDIF
	IFDEF	UGB_HW_LOOP
PROF_HW			EQU	UNETG_HW_LOOP
PROF_POLL_GAP_US	EQU	20000
PROF_AUTO_GAP_US	EQU	20000
PROF_IRQ_DELIVERY_US	EQU	0
PROF_MAX_SERVICE_US	EQU	20000
PROF_CAPS_HW		EQU	UNETG_CAP_POLL | UNETG_CAP_LOOPBACK
PROF_HW_RING_MIN	EQU	0
PROF_UART_PROFILES	EQU	0
PROF_IO_MASK		EQU	0
PROF_POLL_EXTRA_US	EQU	0
PROF_DMA_EXTRA_US	EQU	0
	ENDIF

	IFDEF	UGB_TP_TCP
PROF_TRANSPORTS		EQU	0x01
PROF_CAPS_TP		EQU	UNETG_CAP_TCP
PROF_MAX_PAYLOAD	EQU	UNETG_TCP_MSS
	ENDIF
	IFDEF	UGB_TP_UDP
PROF_TRANSPORTS		EQU	0x02
PROF_CAPS_TP		EQU	UNETG_CAP_UDP
PROF_MAX_PAYLOAD	EQU	UNETG_UDP_MAX
	ENDIF
	IFDEF	UGB_TP_ANY
PROF_TRANSPORTS		EQU	0x03
PROF_CAPS_TP		EQU	UNETG_CAP_TCP | UNETG_CAP_UDP
PROF_MAX_PAYLOAD	EQU	UNETG_TCP_MSS	; UDP datagrams stay <= 512
	ENDIF

; Common design bounds (ТЗ §3, §5.1). Revised after the M0 measurements.
PROF_CPU_KHZ		EQU	21000
; Fixed STEP path (prologue, clock, flush, deadlines, return), measured
; on the stand: 129 us loopback, +26 us transport/ARP deadlines on cards.
; Fixed STEP path incl. a full deadline recomputation (stand: loopback
; 129 us; Ethernet 117 us idle, ~200 us with due timers and a refused
; transport step).
; Ethernet: the reserve must cover the fixed path plus the dispatch and
; refused attempts around the items (SCEN=stream tools/dev/overrun.js,
; "needed base reserve": 218 us worst on the stand).
	IFDEF	UGB_HW_LOOP
PROF_STEP_BASE_US	EQU	140
	ELSE
	IFDEF	UGB_HW_ESP
PROF_STEP_BASE_US	EQU	190	; ESP: no ARP / TCP timers (stand: "needed base reserve")
	ELSE
PROF_STEP_BASE_US	EQU	220
	ENDIF
	ENDIF
; A useful STEP must afford the fixed path plus the most expensive
; indivisible item, otherwise a pipeline waiting for that item never moves
; (every *_COST of the Ethernet engine and transports is asserted against
; PROF_MAX_ITEM_US).  At 7 MHz this exceeds the 500 us STEP body limit:
; v1 needs turbo.
	IFDEF	UGB_HW_ETH
	IFDEF	UGB_TP_TCP
PROF_MAX_ITEM_US	EQU	270	; TCP idle step + SYN template (60 + 210)
	ELSE
PROF_MAX_ITEM_US	EQU	250	; COST_TX_BEGIN; UDP idle step + template (80 + 170)
	ENDIF
	ELSE
	IFDEF	UGB_HW_LOOP
PROF_MAX_ITEM_US	EQU	210	; COST_LOOP_ITER + COST_LOOP_FIXED + a 16-byte portion
	ELSE
PROF_MAX_ITEM_US	EQU	300	; ESP: transport entry + job start + first command piece (90 + 70 + 140)
	ENDIF
	ENDIF
PROF_MIN_USEFUL_US	EQU	PROF_STEP_BASE_US + PROF_MAX_ITEM_US + PROF_MIN_RETURN_US
; STEP_ISR (stand, 21 MHz): fixed path 60 us, card status portion 67 us,
; refused try-lock 73..76 us in all.  These miss the ТЗ §5.1 targets (empty
; poll <= 100 us, BUS_BUSY <= 25 us); they are published as measured.
PROF_ISR_BASE_US	EQU	65	; prologue, budget, statistics, return
	IFDEF	UGB_HW_LOOP
PROF_ISR_POLL_US	EQU	0	; no card: nothing to poll
	ELSE
PROF_ISR_POLL_US	EQU	70	; lock + map + card status (ESP: one RX byte) + unmap + release
	ENDIF
PROF_MIN_RETURN_US	EQU	10
PROF_ISR_MIN_US		EQU	PROF_ISR_BASE_US + PROF_ISR_POLL_US + PROF_MIN_RETURN_US
PROF_MAX_ATOMIC_US	EQU	60
PROF_EMPTY_POLL_US	EQU	PROF_ISR_BASE_US + PROF_ISR_POLL_US
PROF_BUS_BUSY_US	EQU	80
PROF_MAX_STEP_GAP_MS	EQU	20
PROF_TIME_READ_MAX_US	EQU	20
PROF_TIMING_MODES	EQU	0x03
PROF_MUTABLE_BYTES	EQU	2
