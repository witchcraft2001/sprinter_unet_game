#!/usr/bin/env bash
# Build the SDK test programs of the Z stand: build/ugz.bin + build/ugz.sym
# (the application stand, tools/harness/appstand.js) and build/ugenvz.bin +
# build/ugenvz.sym (the environment reader sdk/loader/ugenv.asm,
# tests/z/sdk/m5_netenv.test.js); check that the auto-loader
# sdk/loader/ugnet.asm assembles with libman (tests/z/sdk/ugnetz.asm) and
# print the sizes a game pays for it.  Usage: tools/build_sdk.sh
set -euo pipefail
cd "$(dirname "$0")/.."
command -v sjasmplus >/dev/null 2>&1 || { echo "error: sjasmplus not found" >&2; exit 1; }
mkdir -p build
log=build/ugz.log
if ! sjasmplus --nologo --msg=war -I include -I sdk --outprefix=build/ \
    --lst=build/ugz.lst --sym=build/ugz.sym tests/z/sdk/ugz.asm >"$log" 2>&1; then
  cat "$log" >&2
  echo "error: ugz.bin failed to build" >&2
  exit 1
fi
[ -s build/ugz.bin ] || { echo "error: build/ugz.bin missing" >&2; exit 1; }
echo "built build/ugz.bin ($(wc -c < build/ugz.bin | tr -d ' ') bytes)"
LIBMAN=${LIBMAN_DIR:-third_party/libman/libman}
log=build/ugenvz.log
if ! sjasmplus --nologo --msg=war -I include -I sdk --outprefix=build/ \
    --lst=build/ugenvz.lst --sym=build/ugenvz.sym tests/z/sdk/ugenvz.asm >"$log" 2>&1; then
  cat "$log" >&2
  echo "error: ugenvz.bin failed to build" >&2
  exit 1
fi
[ -s build/ugenvz.bin ] || { echo "error: build/ugenvz.bin missing" >&2; exit 1; }
log=build/ugnetz.log
if ! sjasmplus --nologo --msg=war -I include -I sdk -I "$LIBMAN" --outprefix=build/ \
    --lst=build/ugnetz.lst tests/z/sdk/ugnetz.asm >"$log" 2>&1; then
  cat "$log" >&2
  echo "error: the auto-loader (ugnetz.asm) failed to assemble" >&2
  exit 1
fi
echo "built build/ugenvz.bin; auto-loader bytes: $(sed -n 's/^> //p' "$log")"
