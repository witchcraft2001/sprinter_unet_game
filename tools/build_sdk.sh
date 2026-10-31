#!/usr/bin/env bash
# Build the SDK test program of the Z application stand (build/ugz.bin +
# build/ugz.sym, tools/harness/appstand.js) and check that the SDK example
# assembles.  Usage: tools/build_sdk.sh
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
