# Сборка и проверки UNET-GAME

## Инструменты

- `sjasmplus` 1.22 и `sprinter-mkdll` (libman) в `PATH`; при отсутствии
  `sprinter-mkdll` сборка берёт `third_party/libman/src` (переменная `UNETG_LIBMAN_SRC`).
- libman — git-сабмодуль `third_party/libman`
  (`https://github.com/witchcraft2001/sprinter-libman.git`, закреплённый коммит):
  после клонирования выполнить `git submodule update --init`.
- `python3` ≥ 3.11 (нужен `tomllib`), `node` ≥ 20 (стенд Z, `node:test`).
- Стенд M: MAME из `https://github.com/holub/mame` с картой Sprinter-WiFi
  (`make mame`), `mtools` (`mformat`, `mcopy`), libman из сабмодуля
  `third_party/libman/libman` (переменная `LIBMAN_DIR`), образы и ROM из `mame_images/mame_release_v306_25.05.2025`
  (переменная `MAME_ASSETS`).

## Команды

| Команда | Что делает |
|---|---|
| `make gen` | Генерирует `include/UNETGAME.INC`, `include/unetg_ctx.inc`, `include/unetg_jt.inc`, `include/unetg_version.inc`, `tools/harness/abi.json`, `docs/ABI-TABLE.md` из `abi/*.toml` и `VERSION` |
| `make all` | Собирает семь DLL в `build/` (`tools/build.sh`) и программу стенда приложения (`make sdk`) |
| `make sdk` | `tools/build_sdk.sh`: `build/ugz.bin` и `build/ugz.sym` (стенд приложения Z, `tests/z/sdk/ugz.asm`) |
| `make verify` | `sprinter-mkdll verify --target 1.3` для каждой DLL |
| `make size` | Отчёт размеров (`tools/size_report.py`, `build/size-report.json`) |
| `make names` | Проверка имён поставки (`tools/check_names.py`) |
| `make test-host` | Python: согласованность ABI, раскладки блоков, релокация L1 = прямая сборка по адресу, пин вендорных файлов |
| `make test-z` | Стенд Z (Node): векторы ABI на всех семи сборках, сценарии карт 3C509B, RTL8019AS и SprinterESP, цели ТЗ по скорости |
| `make profile-check` | Профиль STEP всех сборок на потоке 8 КиБ при шаге 2, 10 и 20 мс (`tools/dev/profile_step.js --check`): ни одного STEP сверх бюджета |
| `make check` | Всё перечисленное; обязательный шлюз перед сдачей |
| `make mame` | Стенд M: клон holub/mame в `../../../mame-holub`, патч `tools/mame/patches/sprinter_esp.patch`, сборка драйвера Sprinter (`tools/mame/build_holub.sh`) |
| `make test-m` | Стенд M: сценарии UGTEST и NETDEMO шести сборок с картами в MAME (`tools/mame/run_m.py`), отчёты в `docs/evidence/m4_esp/`, `docs/evidence/m5_sdk/` и `docs/evidence/m3_eth/`; сетевые сценарии Ethernet требуют пары feth (`sudo tools/mame/net_feth.sh`), без неё — `M SKIP`; в `make check` не входит |

Собственное дерево MAME разработчика (`../../../mame`) стенд M не трогает:
клон holub собирается в отдельном каталоге (`MAME_HOLUB_DIR`).

Одна DLL вручную: `tools/build.sh gtcp509b`. Входные файлы `src/dll/*.asm`
пересоздаёт `tools/mkentries.sh`. Переходы `JR`, вышедшие за диапазон после
роста кода, переписывает `tools/fix_jr.py`.

## Отчёт размеров

`make size` печатает для каждой DLL размер образа L1 (поле `code_size`,
включая 32-байтовый заголовок), размер таблицы релокаций, их сумму, размер
префикса L1 и запас до предельного тела 0x38C7 = 14 535 байт. Сборка падает,
если сумма или префикс больше 16 384 байт, если тело больше 0x38C7 или если
за образом L1 есть хвост (оверлеи запрещены ТЗ §2). Кроме того, каждый образ
проверяет предел `ASSERT` во время ассемблирования.

Состояние на 31.10.2026 (вехи M0–M2, прототип M3, M4, M5). Колонка «Образ»
включает 32-байтный заголовок L1:

| DLL | Образ | Релокации | Сумма | Префикс | Свободно до 0x38C7 |
|---|---:|---:|---:|---:|---:|
| GTCPESP | 9813 | 1223 | 11036 | 11036 | 4754 |
| GUDPESP | 9468 | 1180 | 10648 | 10648 | 5099 |
| GTCPRTL | 12720 | 1586 | 14306 | 14306 | 1847 |
| GUDPRTL | 10198 | 1271 | 11469 | 11469 | 4369 |
| GTCP509B | 12698 | 1584 | 14282 | 14282 | 1869 |
| GUDP509B | 10176 | 1268 | 11444 | 11444 | 4391 |
| GLOOP | 5395 | 671 | 6066 | 6066 | 9172 |

M5 добавил в ядро 68–75 байт на сборку: STEP_ISR сохраняет поля прерванного
STEP, остановленная карта не держит результаты TX. SDK живёт в программе
игры, а не в DLL: NETDEMO.EXE вместе с libman и SDK — 6,5 КБ.

Все карточные сборки содержат полное ядро, общий драйвер аппаратного
автомата (`src/core/hwdrv.asm`) и слой своей карты. Сборки RTL8019AS и
3C509B добавляют Ethernet-движок, ARP и TCP или UDP. Сборки ESP добавляют
слой UART (`src/hw/esp`), парсер и секвенсор ESP-AT (`src/core/esp`).
Самая тяжёлая сборка — GTCPRTL. Она помещается в 16 КБ без холодного
оверлея (ТЗ §2, §8.4 п.1): до предельного тела остаётся 1847 байт.

## Отладочные сценарии стенда

| Сценарий | Назначение |
|---|---|
| `node tools/dev/e2e.js gtcp509b` | Сквозной прогон карточной сборки: подъём (ESP: настройка модуля), OPEN, эхо, CLOSE; `BUDGET=` задаёт бюджет |
| `node tools/dev/sdk_rate.js` | Эхо через шлюз SDK на стенде приложения по числу STEP за период (`--steps 2,5,10`) |
| `node tools/dev/esp_costs.js gtcpesp` | Время подпрограмм слоя ESP на потоке 8 КиБ (калибровка `COST_*`), `DUMP=1` — состояние в конце |
| `node tools/dev/trace.js gtcp509b 20 send` | Пошаговая трасса состояний и всех списаний бюджета |
| `node tools/dev/audit.js gtcp509b` | Ревизия бюджета: реальная работа после каждого `TAKE` против резерва |
| `node tools/dev/sweep_loop.js` | Перебор бюджетов и размеров на GLOOP, код возврата 1 при превышении |
| `node tools/dev/watch.js ev_tmp,chan` | Наблюдение за записью в поля контекста с указанием подпрограммы |
| `SCEN=stream node tools/dev/overrun.js gtcprtl` | Превышения бюджета и нужный резерв базы (`ITEMS=1`, `AT=n`, `PROFILE=1`, `DT=` период STEP в мс) |
| `node tools/dev/portions.js gtcprtl gtcp509b` | Время порций карты и подпрограмм слоя карты |
| `node tools/dev/di_find.js gtcprtl 180` | Шаги, где DI-секция длиннее заданной |
| `node tools/dev/throughput.js` | Пропускная способность эха и задержка ACK при шаге 2 мс |
| `node tools/dev/tcpcheck.js gtcprtl` | Сверка каждой передаваемой полезной нагрузки TCP с данными приложения |
