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
; PROF_STEP_BASE_US covers the "needed base reserve" of the build: the
; STEP time not bought by budget items (prologue, clock, timer cache,
; scheduler, dispatch, refused attempts, flush, deadlines) -- the largest
; over the 8 KiB stream at STEP periods of 2/10/20 ms and the budgets 500
; and min (tools/dev/profile_step.js; make profile-check fails above it).
; Stand: GTCPRTL 199, GTCP509B 190, GUDPRTL 178, GUDP509B 174, GTCPESP
; 189 (ESP 2 KiB/s stage, WP1: HW_RUN's joint RX/TX sizing), GUDPESP 172,
; GLOOP 57 us.  PROF_MIN_RETURN_US stays on top of it.
	IFDEF	UGB_HW_LOOP
PROF_STEP_BASE_US	EQU	140
	ELSE
	IFDEF	UGB_HW_ESP
PROF_STEP_BASE_US	EQU	195
	ELSE
	IFDEF	UGB_TP_TCP
	IFDEF	UGB_HW_RTL
PROF_STEP_BASE_US	EQU	200	; the RTL8019AS poll (140) leaves less to the transport
	ELSE
PROF_STEP_BASE_US	EQU	195
	ENDIF
	ELSE
PROF_STEP_BASE_US	EQU	190
	ENDIF
	ENDIF
	ENDIF
; A useful STEP must afford the fixed path plus the most expensive
; indivisible item, otherwise a pipeline waiting for that item never moves
; (every cost is asserted against PROF_MAX_ITEM_US; no item chains two
; costs).  At 7 MHz this exceeds the 500 us STEP body limit: v1 needs
; turbo.
	IFDEF	UGB_HW_ETH
	IFDEF	UGB_TP_TCP
PROF_MAX_ITEM_US	EQU	215	; COST_TP_ACK (TCP_ACKED, stand 193 us)
	ELSE
PROF_MAX_ITEM_US	EQU	210	; COST_RX_CHUNK of the RTL8019AS (stand 181 us)
	ENDIF
	ELSE
	IFDEF	UGB_HW_LOOP
PROF_MAX_ITEM_US	EQU	230	; COST_LOOP_ITER + COST_LOOP_FIXED + a 16-byte portion (60 + 150 + 16)
	ELSE
PROF_MAX_ITEM_US	EQU	220	; ESP: COST_BRINGUP / a full line round (COST_PARSE + bytes)
	ENDIF
	ENDIF
PROF_MIN_USEFUL_US	EQU	PROF_STEP_BASE_US + PROF_MAX_ITEM_US + PROF_MIN_RETURN_US
; STEP_ISR (stand, 21 MHz, tools/dev/isr_profile.js): fixed path (entry,
; checks, budget, counters) 23 us; the card sample (lock.asm ISR_PORTION:
; polls_total, try-lock, map, status, unmap, release; no per-call field)
; 26 us (RTL: one ISR read); empty poll RTL 49.0, 3C509B 49.0, ESP 48.0
; (pre-acquired -4.3), loopback 20 us; BUS_BUSY 24.5 us (decided before
; any write but the counters); budget refusal 13.4 us.  Published empty
; poll = worst + 5, rounded up to 5.
	IFDEF	UGB_HW_LOOP
PROF_ISR_BASE_US	EQU	25	; no card: checks, budget, counters
PROF_ISR_POLL_US	EQU	0	; nothing to poll
	ELSE
PROF_ISR_BASE_US	EQU	25	; entry, checks, budget, counters, return
PROF_ISR_POLL_US	EQU	30	; ISR_PORTION: lock + map + status + unmap + release
	ENDIF
PROF_MIN_RETURN_US	EQU	10
PROF_ISR_MIN_US		EQU	PROF_ISR_BASE_US + PROF_ISR_POLL_US + PROF_MIN_RETURN_US
; max_atomic_us: the longest indivisible (DI) section any export may start
; (ТЗ §5.1: an indivisible operation is refused if it and its return do not
; fit).  Stale at 60 since before this stage; the stand's hard DI <= 200 us
; rule was passing regardless, so nothing enforced this number against
; reality.  Stand worst DI over the 8 KiB stream (all budgets/DT, all
; cards): GTCPRTL 160, GUDPRTL 159, GTCP509B 151, GUDP509B 150, GUDPESP
; 152, GTCPESP 121 us (tools/dev/profile_step.js).  Published = worst * 1.1
; rounded up to 5 (ESP 2 KiB/s stage, WP5).
PROF_MAX_ATOMIC_US	EQU	180
PROF_EMPTY_POLL_US	EQU	PROF_ISR_BASE_US + PROF_ISR_POLL_US
PROF_BUS_BUSY_US	EQU	25	; stand 24.8 us: lock byte read before any per-call write
PROF_MAX_STEP_GAP_MS	EQU	20
PROF_TIME_READ_MAX_US	EQU	20
PROF_TIMING_MODES	EQU	0x03
PROF_MUTABLE_BYTES	EQU	2
