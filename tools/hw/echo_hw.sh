#!/bin/sh
# echo_hw.sh -- the host side of the Ж stand: the echo server on the LAN
# address of tools/hw/hw.env (HW_HOST_IP:HW_PORT, TCP + UDP) and the TCP
# server for scenario P that closes after 64 bytes (HW_HOST_IP:HW_PORT_P).
# Logs: build/hw/server.log, build/hw/server_p.log.  Ctrl-C stops both.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENV="$ROOT/tools/hw/hw.env"
[ -f "$ENV" ] || ENV="$ROOT/tools/hw/hw.env.example"
# shellcheck disable=SC1090
. "$ENV"
[ -n "${HW_HOST_IP:-}" ] || HW_HOST_IP=$(ipconfig getifaddr en0)
mkdir -p "$ROOT/build/hw"
python3 "$ROOT/tools/mame/echo_server.py" --host "$HW_HOST_IP" --port "$HW_PORT_P" --close-after 64 \
	--log "$ROOT/build/hw/server_p.log" &
P=$!
trap 'kill $P 2>/dev/null' EXIT INT TERM
echo "echo_hw: $HW_HOST_IP:$HW_PORT (echo), $HW_HOST_IP:$HW_PORT_P (P: close after 64)"
python3 "$ROOT/tools/mame/echo_server.py" --host "$HW_HOST_IP" --port "$HW_PORT" --log "$ROOT/build/hw/server.log"
