#!/usr/bin/env bash
# Regenerate the seven src/dll/*.asm entry files (they differ only in defines).
set -euo pipefail
cd "$(dirname "$0")/.."
while read -r name hw tp desc; do
  up=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
  cat > "src/dll/$name.asm" <<EOF
; $up.DLL -- UNET-GAME profile $desc.
; One of the seven builds of the shared core; see src/core/main.inc.
; This file must contain the only ORG of the image (sprinter-mkdll
; rewrites the first ORG to 0x0020 and 0x0120 for its two passes).

	DEFINE	UGB_HW_$hw
	DEFINE	UGB_TP_$tp

	ORG	0x0000
	INCLUDE	"core/main.inc"
EOF
done <<'LIST'
gtcpesp ESP TCP SprinterESP/TCP
gudpesp ESP UDP SprinterESP/UDP
gtcprtl RTL TCP RTL8019AS/TCP
gudprtl RTL UDP RTL8019AS/UDP
gtcp509b EL3 TCP 3C509B/TCP
gudp509b EL3 UDP 3C509B/UDP
gloop LOOP ANY loopback
LIST
