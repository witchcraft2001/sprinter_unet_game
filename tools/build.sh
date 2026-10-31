#!/usr/bin/env bash
# Build the seven UNET-GAME L1 DLLs with sprinter-mkdll and verify them.
# Usage: tools/build.sh [name ...]   (default: all; names like gtcp509b)
set -euo pipefail
cd "$(dirname "$0")/.."

ALL_DLLS=(gtcpesp gudpesp gtcprtl gudprtl gtcp509b gudp509b gloop)
DLLS=("${@:-${ALL_DLLS[@]}}")
[ "$#" -gt 0 ] || DLLS=("${ALL_DLLS[@]}")

if command -v sprinter-mkdll >/dev/null 2>&1; then
  MKDLL=(sprinter-mkdll)
else
  src="${UNETG_LIBMAN_SRC:-../libman/src}"
  [ -f "$src/sprinter_mkdll/cli.py" ] || { echo "error: sprinter-mkdll not found" >&2; exit 1; }
  MKDLL=(env "PYTHONPATH=$src" python3 -m sprinter_mkdll.cli)
fi
command -v sjasmplus >/dev/null 2>&1 || { echo "error: sjasmplus not found" >&2; exit 1; }

python3 tools/gen_abi.py check

version="$(tr -d '[:space:]' < VERSION)"
[[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "error: VERSION must be M.m.r" >&2; exit 1; }
l1_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
date="${UNETG_BUILD_DATE:-$(git log -1 --format=%cs 2>/dev/null || date +%Y-%m-%d)}"

mkdir -p build
for dll in "${DLLS[@]}"; do
  upper="$(printf '%s' "$dll" | tr '[:lower:]' '[:upper:]')"
  name="$upper v$version"
  if [ "${#name}" -gt 15 ]; then name="$upper"; fi
  out="build/$upper.DLL"
  rm -f "$out" "build/$dll.bin" "build/$dll.sym" "build/$dll.lst"
  log="build/$dll.log"
  if ! "${MKDLL[@]}" build "src/dll/$dll.asm" --format l1 --target 1.3 \
      --assembler sjasmplus -I include -I src \
      --name "$name" --version "$l1_version" --date "$date" --no-compress \
      -o "$out" >"$log" 2>&1; then
    cat "$log" >&2
    echo "error: $upper.DLL failed to build" >&2
    exit 1
  fi
  "${MKDLL[@]}" verify "$out" --target 1.3 >>"$log" 2>&1 || { cat "$log" >&2; exit 1; }
  # Same source assembled at ORG 0 for listings/symbols used by the stand.
  sjasmplus --nologo --msg=war -I include -I src --raw="build/$dll.bin" \
    --lst="build/$dll.lst" --sym="build/$dll.sym" "src/dll/$dll.asm" >>"$log" 2>&1 \
    || { cat "$log" >&2; exit 1; }
  echo "built $out ($(grep -o 'image body: [0-9]* bytes' "$log" | head -1))"
done
python3 tools/size_report.py "${DLLS[@]}"
