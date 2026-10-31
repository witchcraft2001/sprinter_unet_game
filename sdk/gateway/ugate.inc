; ugate.inc -- UNET-GAME SDK gateway: block layout, profile, codes, costs.
;
; The SDK is source-included by the application (sjasmplus).  Before
; INCLUDE "ugate.asm" the application defines:
;   UG_BLOCK    EQU  address of the gateway block (UGW_BYTES, permanently
;                    visible RAM below 0xC000; the ISA lock byte is its
;                    first byte, INIT_CONFIG.isa_lock_ptr = UG_BLOCK)
;   UG_DLL_WIN  EQU  1 or 2: the window the DLL was relocated for
; and includes UNETGAME.INC.
;
; Ownership: main writes the block only inside short DI sections (or with
; single-instruction 16-bit stores); the ISR entries run with IFF = 0.  The
; core never reads the block except the lock and the two shadows.

	IFNDEF	UG_DLL_WIN
	DEFINE	UG_DLL_WIN 1
	ENDIF
	IF	UG_DLL_WIN == 1
UG_WINPORT	EQU	0xA2
	ELSE
UG_WINPORT	EQU	0xC2
	ENDIF

; ---- gateway block (offsets from UG_BLOCK) ---------------------------------
UGW_LOCK	EQU	0	; u8  shared ISA try-lock (ABI §1)
UGW_SH1FFD	EQU	1	; u8  shadow of the write-only #1FFD
UGW_SH9FBD	EQU	2	; u8  shadow of the write-only #9FBD
UGW_FLAGS	EQU	3	; u8  UGF_*
UGW_PAGE	EQU	4	; u8  physical page holding the DLL
UGW_BASEH	EQU	5	; u8  high byte of the DLL base (L1 header, 256-aligned)
UGW_HANDLE	EQU	6	; u8  libman handle (0xFF: attached without libman)
UGW_ENV		EQU	7	; u8  UG_ENV_* of the last UG_INIT_ENV
UGW_Q		EQU	8	; u16[4] remaining quota of the period (us), UGQ_*
UGW_QFULL	EQU	16	; u16[4] quota per period
UGW_ACTIVE	EQU	24	; u16 full cost of the main STEP in progress (0: none)
UGW_COST_POLL	EQU	26	; u16 full upper cost of one ISR entry
UGW_COST_STEP	EQU	28	; u16 full upper cost of one admitted STEP
UGW_COST_BUSY	EQU	30	; u16 cost of a busy-bus refusal before the core
UGW_COST_REFUSE	EQU	32	; u16 cost of an admission refusal (service quota)
UGW_ISR_BUDGET	EQU	34	; u16 body budget passed to STEP_ISR
UGW_STEP_BUDGET	EQU	36	; u16 body budget passed to STEP
UGW_PERIOD_TICKS EQU	38	; u8  timer ticks per budget period
UGW_TICK_CNT	EQU	39	; u8  ticks left in the period
UGW_POLL_TICKS	EQU	40	; u8  ticks between guaranteed polls
UGW_POLL_CNT	EQU	41	; u8  ticks left to the next poll
UGW_SPACING	EQU	42	; u8  minimum ticks between admitted STEPs
UGW_STEP_AGE	EQU	43	; u8  ticks since the last admitted STEP (saturating)
UGW_STEP_DE	EQU	44	; u16 last STEP deadline (DE)
UGW_STEP_L	EQU	46	; u8  last STEP flags (L)
UGW_STEP_A	EQU	47	; u8  last STEP status
UGW_ISR_SP	EQU	48	; u16 SP of the interrupted code during an ISR entry
UGW_ISR_TOP	EQU	50	; u16 top of the network ISR stack
UGW_PERIOD_NO	EQU	52	; u16 budget period number
UGW_DEBIT	EQU	54	; u16 debit of the current period (us)
UGW_DEBIT_MAX	EQU	56	; u16 largest debit of a finished period (folded by UG_STEP)
UGW_MASK_PER	EQU	58	; u8  period (low byte) of the last route mask
UGW_ISR_A	EQU	59	; u8  status of the last STEP_ISR
UGW_STATS	EQU	60	; u16 counters, UGS_*
UGW_NOW		EQU	88	; u32 now_ms: tick ISR (FIXED_SCHEDULE) or UG_NOW (APP_COUNTER)
UGW_T_REM	EQU	92	; u16 us (FIXED_SCHEDULE, ISR) or counts (APP_COUNTER, main) below 1 ms
UGW_T_FRAC	EQU	94	; u8  1/256 us (FIXED_SCHEDULE)
UGW_TIMING	EQU	95	; u8  UNETG_TIMING_*
UGW_TICK_US	EQU	96	; u16 tick length, whole us
UGW_TICK_FRAC	EQU	98	; u8  tick length, 1/256 us
UGW_T_LAST	EQU	99	; u16 last CTC phase (APP_COUNTER)
UGW_T_MISS	EQU	101	; u16 phase reads without a stamp (APP_COUNTER)
UGW_SUM		EQU	103	; u16 sum of the quotas computed by UG_INIT_ENV
UGW_FLAGS2	EQU	105	; u8  UGF2_*; 0 = ISR entries allowed
UGW_EP_ISR	EQU	106	; u16 STEP_ISR entry (base + 0x20 + 3 * UNETG_STEP_ISR)
UGW_TICK_MS	EQU	108	; u8  whole ms of a tick (FIXED_SCHEDULE)
UGW_TICK_REM	EQU	109	; u16 us of a tick below the whole ms
UGW_DEBIT_LAST	EQU	111	; u16 debit of the last finished period (main folds the max)
UGW_COUNT	EQU	113	; u32 APP_COUNTER counts (875 kHz), written only by the tick ISR
UGW_T_LASTC	EQU	117	; u16 low word of UGW_COUNT at the last ms conversion (main)
UGW_SCRATCH	EQU	128	; 64 bytes: GET_INFO copy, event sink
UGW_BYTES	EQU	192

UGQ_POLL	EQU	0	; timer poll (+ key/frame extra opportunities)
UGQ_CARD	EQU	2	; card IRQ entries
UGQ_MAIN	EQU	4	; STEP from the main loop
UGQ_SERVICE	EQU	6	; refusals, flag processing

UGS_REFUSE	EQU	0	; admission refusals (paid by the service quota)
UGS_BUSY	EQU	2	; busy-bus refusals before the core
UGS_ISR		EQU	4	; reserved (STEP_ISR entries: GET_STATS.isr_calls)
UGS_STEP	EQU	6	; admitted STEPs
UGS_EARLY	EQU	8	; STEP attempts before the spacing (free)
UGS_FRAMES	EQU	10	; frame interrupts seen
UGS_TICKS	EQU	12	; timer ticks
UGS_UNKNOWN	EQU	14	; interrupts without a handler (application counts)
UGS_MASK	EQU	16	; software route masks (MASK_ROUTE or card quota)
UGS_CBL		EQU	18	; CBL flags
UGS_KEY		EQU	20	; key interrupts
UGS_LATE	EQU	22	; a guaranteed poll came due while the previous was not done
UGS_COUNT	EQU	14	; words: UGW_STATS .. UGW_STATS + 2*UGS_COUNT <= UGW_NOW

	ASSERT	UGW_STATS + 2 * UGS_COUNT <= UGW_NOW
	ASSERT	UGW_T_LASTC + 2 <= UGW_SCRATCH
	ASSERT	(UG_BLOCK & 0xFF) == 0, "UG_BLOCK must be 256-aligned"
	ASSERT	UNETG_INFO_BYTES <= 64

; UGW_FLAGS bits
UGF_ATTACHED	EQU	0	; page and base known
UGF_CONFIGURED	EQU	1	; INIT_CONFIG returned OK
UGF_MASKED	EQU	2	; software route mask (no card IRQ entries)
UGF_CBL		EQU	3	; CBL pending flag
UGF_POLL_DUE	EQU	4	; the guaranteed poll of this tick is not done yet
UGF_OVER	EQU	5	; quotas exceed the target (relaxed profile)
UGF_FRAME_PER	EQU	6	; the budget period follows the frame interrupt
UGF_RUN		EQU	7	; ticks running: admission and ISR entries allowed

; UGW_FLAGS2 bits
UGF2_NOISR	EQU	0	; no new STEP_ISR entries (SHUTDOWN, exit)

; ---- application profile for UG_INIT_ENV (offsets) -------------------------
UGP_TICK_US	EQU	0	; u16 timer tick, whole us (CTC1: 256*const/cpu_MHz)
UGP_TICK_FRAC	EQU	2	; u8  timer tick, 1/256 us
UGP_PERIOD_TICKS EQU	3	; u8  ticks per budget period (10 for 2 ms / 20 ms)
UGP_POLL_TICKS	EQU	4	; u8  ticks between guaranteed polls (1)
UGP_STEPS	EQU	5	; u8  STEPs per period from the main quota
UGP_STEP_GAP_MS	EQU	6	; u8  guaranteed worst gap between STEP calls
UGP_CARD_N	EQU	7	; u8  card IRQ entries per period (0: no route)
UGP_STEP_BUDGET	EQU	8	; u16 STEP body budget (0: GET_INFO.min_useful)
UGP_ISR_BUDGET	EQU	10	; u16 STEP_ISR body budget (0: empty poll + return)
UGP_Q_SERVICE	EQU	12	; u16 service quota per period
UGP_TARGET	EQU	14	; u16 network target per period (ТЗ §5: 2000)
UGP_OTHER_ISR	EQU	16	; u16 longest other interrupt handler (us)
UGP_FLAGS	EQU	18	; u8  UGPF_*
UGP_MODE	EQU	19	; u8  UNETG_MODE_POLL / AUTO
UGP_TIMING	EQU	20	; u8  UNETG_TIMING_*
UGP_BYTES	EQU	21

UGPF_RELAXED	EQU	0x01	; accept quotas above the target (reported)
UGPF_FRAME_PER	EQU	0x02	; budget period from the frame interrupt

; ---- results ----------------------------------------------------------------
UG_ENV_OK	EQU	0	; quotas within the target
UG_ENV_OVER	EQU	1	; above the target, accepted (relaxed profile)
UG_ENV_REFUSED	EQU	2	; above the target, refused
UG_ENV_GAP	EQU	3	; the poll schedule misses GET_INFO.poll_gap_us
UG_ENV_BUDGET	EQU	4	; STEP / STEP_ISR budget outside the published bounds
UG_ENV_INFO	EQU	5	; GET_INFO failed
UG_ENV_CONFIG	EQU	6	; INIT_CONFIG refused (A = its status)
UG_ENV_PROFILE	EQU	7	; inconsistent profile (zero ticks, steps)

UG_ST_EARLY	EQU	0x80	; UG_STEP: before the spacing, nothing debited
UG_ST_REFUSED	EQU	0x81	; UG_STEP: main quota exhausted (service paid)
UG_ST_OFF	EQU	0x82	; UG_STEP: gateway not running

; ---- gateway costs (us at 21 MHz) -------------------------------------------
; Upper bounds of the gateway's own path around a core call, measured on the
; Z application stand (tests/z/sdk, docs/MEASUREMENTS.md).  The full debit of
; an admitted entry is body budget + overhead; refusals before the core pay
; their own path.
UG_OVH_ISR_US	EQU	35	; UG_ISR_NET around STEP_ISR (admission, lock, SP, page); stand 29.1
UG_OVH_STEP_US	EQU	50	; UG_STEP around STEP (admission, clock, page); stand 46.1
UG_BUSY_PATH_US	EQU	22	; UG_ISR_NET refused by a held ISA lock; stand 19.6
UG_REFUSE_US	EQU	15	; admission refused for lack of quota
UG_FLAG_US	EQU	5	; processing a CBL pending flag
UG_DI_MARGIN_US	EQU	200	; ТЗ §5.1: longest DI section of the network
