#!/usr/bin/env bash
# build_holub.sh -- build the M stand: holub/mame master + the Sprinter-WiFi
# ISA card (tools/mame/patches/sprinter_esp.patch), Sprinter driver only.
#
# The tree lives apart from the developer's own MAME checkout so that this
# stand never changes it:  MAME_HOLUB_DIR (default ../../../mame-holub,
# i.e. /Users/dmitry/dev/zx/sprinter/mame-holub).  Result: $MAME_HOLUB_DIR/sprinter (the SUBTARGET binary).
#
#   tools/mame/build_holub.sh            clone (if absent), patch, build
#   JOBS=8 tools/mame/build_holub.sh     parallel jobs (default: CPU count - 2)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
MAME_HOLUB_DIR="${MAME_HOLUB_DIR:-$(cd "$repo_root/../.." && pwd)/mame-holub}"
MAME_HOLUB_URL="${MAME_HOLUB_URL:-https://github.com/holub/mame.git}"
MAME_HOLUB_REF="${MAME_HOLUB_REF:-master}"
patch="$script_dir/patches/sprinter_esp.patch"
jobs="${JOBS:-$(( $(sysctl -n hw.ncpu 2>/dev/null || nproc) - 2 ))}"

if [[ ! -d "$MAME_HOLUB_DIR/.git" ]]; then
  git clone --depth 1 --branch "$MAME_HOLUB_REF" "$MAME_HOLUB_URL" "$MAME_HOLUB_DIR"
fi
cd "$MAME_HOLUB_DIR"
if [[ ! -f src/devices/bus/isa/sprinter_esp.cpp ]]; then
  git apply "$patch"
fi
grep -q 'sprinter_esp' src/devices/bus/isa/isa_cards.cpp || { echo "card not registered" >&2; exit 1; }
# NS16550 transmit FIFO: 16 characters, as the chip has (MAME's ring of 16
# with head == tail for "empty" held 15: the 16th written while the shift
# register was busy wrapped it to "empty", the characters were lost and
# THRE never came back -- the "lost CIPSEND" of GUDPESP UGTEST S, flaky for
# months, and every command of 17 bytes of the fat STEP).
if ! grep -q 'the FIFO holds 16 characters' src/devices/machine/ins8250.cpp; then
  git apply "$script_dir/patches/ns16550_txfifo.patch"
fi

make -j"$jobs" SUBTARGET=sprinter SOURCES=src/mame/sinclair/sprinter.cpp \
  NOWERROR=1 TOOLS=0 SYMBOLS=0 OPTIMIZE=2

slots="$(./sprinter sprinter -listslots)"
devices="$(./sprinter sprinter -isa1 sprinter_esp -listdevices)"
grep -q sprinter_esp <<< "$slots" || { echo "sprinter_esp slot option missing" >&2; exit 1; }
grep -q esp8266_at <<< "$devices" || { echo "esp8266_at module missing" >&2; exit 1; }
echo "built $MAME_HOLUB_DIR/sprinter (git $(git rev-parse --short HEAD))"
