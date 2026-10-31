# Таблица ABI UNET-GAME v1.0

Файл сгенерирован `tools/gen_abi.py` из `abi/unetgame_abi.toml`; не редактировать.
Нормативный текст — [unet-game-abi.md](unet-game-abi.md).

## Экспорты

Адрес входа = `image_base + 0x20 + 3 × N`, где `image_base` — адрес заголовка L1.
Через `l_call` гарантированно передаются только A, DE, IX, IY; дополнительные
выходы (HL, байт флагов) дублируются в контексте.

| N | Экспорт | Вход | Выход |
|---:|---|---|---|
| 0 | `INIT` | libman | CF=1 on refusal (window 3); A=0 on success |
| 1 | `FINI` | libman | A=0 |
| 2 | `INIT_CONFIG` | IX=config block | A=status |
| 3 | `SHUTDOWN` | - | A=status (OK, WORK, DEVICE_FAULT) |
| 4 | `STEP` | DE=budget_us, IX=now_ms[15:0], IY=now_ms[31:16], A bit0=ISA pre-acquired by gateway | A=status, DE=next protocol deadline ms (0 due, <=0xFFFE, 0xFFFF none), L=flags (ctx copy) |
| 5 | `STEP_ISR` | A=source | 0x80 if ISA pre-acquired, DE=budget_us | A=status, L=flags (ctx copy) |
| 6 | `OPEN` | IX=0 (peer from config) or IX=peer {ip[4], port u16} | A=status |
| 7 | `CLOSE` | - | A=status |
| 8 | `ABORT` | - | A=status |
| 9 | `TX_RESERVE` | DE=n bytes | A=status, HL=buffer (ctx copy), E=slot, D=0 |
| 10 | `TX_COMMIT` | A=slot, DE=used, IX=tag | A=status |
| 11 | `TX_UNRESERVE` | A=slot | A=status |
| 12 | `RX_PEEK` | - | A=status, HL=data (ctx copy), DE=length, slot in ctx |
| 13 | `RX_RELEASE` | - | A=status |
| 14 | `NEXT_EVENT` | IX=8-byte buffer | A=status (OK, EMPTY) |
| 15 | `GET_INFO` | IX=buffer, DE=buffer size | A=status |
| 16 | `GET_STATS` | IX=buffer, DE=buffer size | A=status |
| 17–23 | резерв | — | A = STATE |

## Константы

**status:** `OK`=0x00, `WORK`=0x01, `YIELD`=0x02, `IDLE`=0x03, `BUS_BUSY`=0x04, `WOULD_BLOCK`=0x05, `STATE`=0x06, `EMPTY`=0x07, `BAD_CONFIG`=0x08, `UNSUPPORTED_TIMING`=0x09, `BAD_ARGUMENT`=0x0A, `DEVICE_FAULT`=0x0B

**flag:** `MASK_ROUTE`=0x01

**src:** `CARD_IRQ`=0x01, `TIMER`=0x02, `FRAME`=0x03, `KEY`=0x04, `CBL`=0x05, `OTHER_IRQ`=0x06

**src_flag:** `PREACQ`=0x80, `STEP_PREACQ`=0x01

**ev:** `CONNECTED`=0x01, `RX_READY`=0x02, `TX_DONE`=0x03, `PEER_CLOSED`=0x04, `RESET`=0x05, `RETRY_EXHAUSTED`=0x06, `LINK_LOST`=0x07, `CONFIG_EXPIRED`=0x08, `CLOSED`=0x09, `MODE_CHANGED`=0x0A, `STREAM_ERROR`=0x0B, `TIMEOUT`=0x0C

**txdone:** `OK`=0x00, `CANCEL`=0x01, `FAILED`=0x02

**timeout:** `OPEN`=0x01, `TX`=0x02, `CLOSE`=0x03

**stream:** `UART_OVERRUN`=0x01, `PARSER`=0x02, `LENGTH`=0x03, `FRAMING`=0x04

**fallback:** `NONE`=0x00, `NO_ROUTE`=0x01, `PROBE_TIMEOUT`=0x02, `PROBE_UNSAFE`=0x03, `TWO_OBSERVATIONS`=0x04, `DELIVERY_TIMEOUT`=0x05, `QUOTA`=0x06, `SPURIOUS`=0x07

**hw:** `ESP`=0x01, `RTL`=0x02, `EL3`=0x03, `LOOP`=0x04

**transport:** `TCP`=0x01, `UDP`=0x02

**mode:** `POLL`=0x01, `AUTO`=0x02, `IRQ`=0x03

**timing:** `APP_COUNTER`=0x01, `FIXED_SCHEDULE`=0x02

**cfgf:** `HAS_EXPIRY`=0x01, `ALLOW_PROBE`=0x02, `CBL_QUALIFIED`=0x04, `FLOW_VERIFIED`=0x08

**cap:** `POLL`=0x01, `AUTO`=0x02, `IRQ_ROUTE_QUALIFIED`=0x04, `TCP`=0x08, `UDP`=0x10, `LOOPBACK`=0x20, `CHECKSUM_VERIFY`=0x40, `FLOW_CONTROL_REQUIRED`=0x80, `NATIVE_RTO`=0x0100, `PROBE`=0x0200

**route:** `NO_ROUTE`=0x00, `POLL_PRE_PROBE`=0x01, `PROBING`=0x02, `IRQ_ENABLED`=0x03, `IRQ_SUSPECT`=0x04, `POLL_FALLBACK`=0x05, `IRQ_UNCONFIRMED`=0x06

**probe:** `NONE`=0x00, `OK`=0x01, `TIMEOUT`=0x02, `UNAVAILABLE`=0x03

**lock:** `FREE`=0x00, `NET_MAIN`=0x01, `NET_ISR`=0x02, `SOUND`=0x03, `CONTROLLER`=0x04

**ctxstate:** `NONE`=0x00, `CONFIGURED`=0x01, `STOPPING`=0x02, `STOPPED`=0x03, `FAULT`=0x04

**avail:** `MAX_STEP_GAP`=0x01, `MAX_CALL_TIME`=0x02, `MAX_DI`=0x04, `MAX_SERVICE_GAP`=0x08

**limits:** `TCP_MSS`=0x0218, `UDP_MAX`=0x0200, `EVENT_SIZE`=0x08, `SLOTS_MIN`=0x04, `EVENT_EXTRA`=0x04, `UART_RING_MIN`=0x0200, `STEP_BODY_MAX_US`=0x01F4, `ISR_BODY_MAX_US`=0x96, `STACK_MAIN_MAX`=0x0100, `STACK_ISR_MAX`=0x60, `TAG_RESERVED`=0xFFFF, `SLOT_NONE`=0xFF, `CHANNEL_GLOBAL`=0xFF, `DEADLINE_NONE`=0xFFFF, `DEADLINE_MAX`=0xFFFE

## INIT_CONFIG v1.0 (134 байт)

| Смещение | Поле | Тип | Примечание |
|---:|---|---|---|
| 0 | `abi_version` | u16 | 0x0100 |
| 2 | `size` | u16 | bytes of this block |
| 4 | `hw_profile` | u8 | UNETG_HW_* |
| 5 | `transport` | u8 | UNETG_TRANSPORT_* |
| 6 | `mode` | u8 | UNETG_MODE_POLL / AUTO |
| 7 | `flags` | u8 | UNETG_CFGF_* |
| 8 | `cpu_khz` | u16 | 7000 or 21000 (cost table selection) |
| 10 | `timing_mode` | u8 | UNETG_TIMING_* |
| 11 | `isa_slot` | u8 | 0 or 1 |
| 12 | `io_base` | u16 | card I/O base (RTL 0x300, EL3 0x200..0x3E0, ESP 0x3E8) |
| 14 | `id_port` | u16 | 3C509B ID port (0x110); 0 otherwise |
| 16 | `mac` | mac6 | all zero = use the card PROM/EEPROM address |
| 22 | `route_present` | u8 | 0 = no qualified IRQ route |
| 23 | `route_pio_bit` | u8 | PIO B input bit (0 = PB0, 1 = PB1) |
| 24 | `route_vector` | u8 | IM2 vector low byte reserved for the card |
| 25 | `route_flags` | u8 | reserved, 0 |
| 26 | `irq_delivery_us` | u16 | observation window D for the probe |
| 28 | `local_ip` | ip4 | network order |
| 32 | `netmask` | ip4 | network order |
| 36 | `gateway_ip` | ip4 | network order, 0.0.0.0 = none |
| 40 | `peer_ip` | ip4 | network order |
| 44 | `peer_port` | u16 | little-endian |
| 46 | `local_port` | u16 | little-endian, 0 = ephemeral |
| 48 | `expires_ms` | u32 | absolute now_ms deadline if HAS_EXPIRY |
| 52 | `uart_divisor` | u16 | 16550 divisor (8 = 115200 at 14.7456 MHz) |
| 54 | `uart_flow` | u8 | local 16550: 0 none, 1 AFE RTS/CTS |
| 55 | `esp_flow` | u8 | ESP side: 0 none, 3 RTS/CTS (AT+UART_CUR) |
| 56 | `esp_fw` | u8 | 1 = ESP-AT 2.2.2 passive TCP profile |
| 57 | `uart_rx_trigger` | u8 | FIFO trigger: 1, 4, 8, 14 |
| 58 | `connect_timeout_ms` | u16 | 5000 |
| 60 | `retry_count` | u8 | 4; schedule length = retry_count + 1 <= 8 |
| 61 | `reserved0` | u8 | 0 |
| 62 | `retry_wait_ms` | u16[8] | 500,1000,2000,2000,2000 |
| 78 | `send_stall_timeout_ms` | u16 | 7500 |
| 80 | `close_timeout_ms` | u16 | 2000 |
| 82 | `arp_ttl_ms` | u16 | neighbour entry lifetime |
| 84 | `worst_poll_gap_us` | u16 | guaranteed worst interval of useful polls |
| 86 | `worst_step_gap_ms` | u16 | guaranteed worst interval of STEP calls |
| 88 | `step_budget_us` | u16 | body budget the gateway passes to STEP |
| 90 | `isr_budget_us` | u16 | body budget the gateway passes to STEP_ISR |
| 92 | `time_read_cost_us` | u16 | adapter clock read + publish cost |
| 94 | `ctx_ptr` | u16 | context area |
| 96 | `ctx_len` | u16 | >= GET_INFO.ctx_size |
| 98 | `tx_slots_ptr` | u16 | tx_slot_count * tx_slot_size bytes |
| 100 | `tx_slot_size` | u16 | >= transport payload limit |
| 102 | `tx_slot_count` | u8 | >= 4 |
| 103 | `rx_slot_count` | u8 | >= 4 |
| 104 | `rx_slots_ptr` | u16 | rx_slot_count * rx_slot_size bytes |
| 106 | `rx_slot_size` | u16 | >= transport payload limit |
| 108 | `event_ptr` | u16 | event_cap * 8 bytes |
| 110 | `event_cap` | u8 | power of two, >= tx_slot_count + 4 + 1 (sentinel) |
| 111 | `reserved1` | u8 | 0 |
| 112 | `hw_ring_ptr` | u16 | ESP UART software ring; 0 for other cards |
| 114 | `hw_ring_len` | u16 | ESP: 512 |
| 116 | `isa_lock_ptr` | u16 | shared ISA try-lock byte |
| 118 | `shadow_1ffd_ptr` | u16 | gateway shadow of write-only port #1FFD |
| 120 | `shadow_9fbd_ptr` | u16 | gateway shadow of write-only port #9FBD |
| 122 | `gw_ptr` | u16 | gateway code/data/IM2 region (overlap check only) |
| 124 | `gw_len` | u16 |  |
| 126 | `main_stack_ptr` | u16 | lowest byte of the main stack region |
| 128 | `main_stack_len` | u16 |  |
| 130 | `isr_stack_ptr` | u16 | lowest byte of the network ISR stack region |
| 132 | `isr_stack_len` | u16 |  |

## GET_INFO v1.0 (62 байт)

| Смещение | Поле | Тип | Примечание |
|---:|---|---|---|
| 0 | `abi_version` | u16 | 0x0100 |
| 2 | `size` | u16 | bytes of this block |
| 4 | `hw_profile` | u8 | UNETG_HW_* |
| 5 | `transports` | u8 | bit0 TCP, bit1 UDP |
| 6 | `image_version` | u16 | (major << 8) | minor |
| 8 | `caps` | u16 | UNETG_CAP_* |
| 10 | `profile_cpu_khz` | u16 | clock the timing fields below are valid for |
| 12 | `min_useful_budget_us` | u16 | smaller budgets only YIELD |
| 14 | `max_atomic_us` | u16 | longest indivisible operation |
| 16 | `min_return_us` | u16 | cost of the cheapest return path |
| 18 | `empty_poll_us` | u16 | <= 100 |
| 20 | `bus_busy_us` | u16 | <= 25 |
| 22 | `poll_gap_us` | u16 | POLL and unverified AUTO |
| 24 | `auto_fallback_gap_us` | u16 | verified AUTO backup poll |
| 26 | `irq_delivery_us` | u16 | probe observation window |
| 28 | `max_service_gap_us` | u16 | physical limit of the profile |
| 30 | `max_step_gap_ms` | u16 | 20 for the game profile |
| 32 | `step_body_max_us` | u16 | 500 |
| 34 | `isr_body_max_us` | u16 | 150 |
| 36 | `stack_main_max` | u16 | bytes, all branches |
| 38 | `stack_isr_max` | u16 | bytes, all branches |
| 40 | `ctx_size` | u16 | required context bytes |
| 42 | `ctx_version` | u16 | context layout version |
| 44 | `tx_max_payload` | u16 | 536 TCP / 512 UDP |
| 46 | `rx_max_payload` | u16 | 536 TCP / 512 UDP |
| 48 | `tx_slots_min` | u8 | 4 |
| 49 | `rx_slots_min` | u8 | 4 |
| 50 | `event_size` | u8 | 8 |
| 51 | `event_extra` | u8 | useful events >= tx slots + this |
| 52 | `hw_ring_min` | u16 | ESP 512, others 0 |
| 54 | `timing_modes` | u8 | bit0 APP_COUNTER, bit1 FIXED_SCHEDULE |
| 55 | `uart_profiles` | u8 | ESP: bit0 115200/flow, bit1 115200/no flow |
| 56 | `image_mutable_bytes` | u8 | 2 (IMG_CTX_PTR) |
| 57 | `reserved0` | u8 | 0 |
| 58 | `image_base` | u16 | address of the relocated L1 header; jump N at +0x20+3N |
| 60 | `image_size` | u16 | code_size including the 32-byte header |

## GET_STATS v1.0 (80 байт)

| Смещение | Поле | Тип | Примечание |
|---:|---|---|---|
| 0 | `abi_version` | u16 | 0x0100 |
| 2 | `size` | u16 | bytes of this block |
| 4 | `mode_actual` | u8 | UNETG_MODE_POLL / IRQ |
| 5 | `route_state` | u8 | UNETG_ROUTE_* |
| 6 | `fallback_reason` | u8 | UNETG_FALLBACK_* |
| 7 | `probe_result` | u8 | UNETG_PROBE_* |
| 8 | `avail` | u16 | UNETG_AVAIL_*: which maxima below are valid |
| 10 | `timing_mode` | u8 | active timing mode |
| 11 | `ctx_state` | u8 | UNETG_CTXSTATE_* |
| 12 | `irq_count` | u16 | STEP_ISR calls with source CARD_IRQ |
| 14 | `isr_calls` | u16[6] | STEP_ISR calls by source 1..6 |
| 26 | `polls_total` | u16 | hardware status checks |
| 28 | `polls_useful` | u16 | checks that found work |
| 30 | `steps_total` | u16 |  |
| 32 | `steps_useful` | u16 | STEP calls that advanced protocol time |
| 34 | `budget_yields` | u16 |  |
| 36 | `bus_busy` | u16 |  |
| 38 | `max_call_us` | u16 | not measured by the core: avail bit clear |
| 40 | `max_di_us` | u16 | not measured by the core: avail bit clear |
| 42 | `max_service_gap_us` | u16 | not measured by the core: avail bit clear |
| 44 | `max_step_gap_ms` | u16 | max_observed_step_gap_ms |
| 46 | `deadline_misses` | u16 |  |
| 48 | `uart_overrun` | u16 |  |
| 50 | `ring_overflow` | u16 | software rings and RX slots |
| 52 | `hw_overflow` | u16 | card ring/FIFO overflow |
| 54 | `tcp_retransmits` | u16 |  |
| 56 | `drop_size` | u16 |  |
| 58 | `drop_checksum` | u16 |  |
| 60 | `drop_foreign` | u16 | foreign address/port/peer |
| 62 | `drop_fragment` | u16 |  |
| 64 | `arp_requests` | u16 |  |
| 66 | `tx_frames` | u16 |  |
| 68 | `rx_frames` | u16 |  |
| 70 | `tx_bytes` | u32 | payload bytes |
| 74 | `rx_bytes` | u32 | payload bytes |
| 78 | `stream_errors` | u16 |  |

## Event (8 bytes) (8 байт)

| Смещение | Поле | Тип | Примечание |
|---:|---|---|---|
| 0 | `type` | u8 | UNETG_EV_* |
| 1 | `channel` | u8 | 0, or 0xFF for a global event |
| 2 | `tag` | u16 | 0xFFFF without a tag |
| 4 | `status` | u8 | TX_DONE: UNETG_TXDONE_* |
| 5 | `slot` | u8 | 0xFF without a slot |
| 6 | `detail` | u16 | 0 without detail |

## OPEN peer argument (6 байт)

| Смещение | Поле | Тип | Примечание |
|---:|---|---|---|
| 0 | `ip` | ip4 | network order |
| 4 | `port` | u16 | little-endian |

Размер внутреннего контекста v0x0002: 675 байт (публикуется в GET_INFO.ctx_size).
