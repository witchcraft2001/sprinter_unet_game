#!/bin/sh
# echo_hw.sh -- the host side of the Ж stand: the echo server on the LAN
# address of tools/hw/hw.env (HW_HOST_IP:HW_PORT, TCP + UDP) and the TCP
# server for scenario P that closes after 64 bytes (HW_HOST_IP:HW_PORT_P)
# and the record echo of the transparent ESP mode (HW_HOST_IP:HW_PORT_X,
# echo_server.py --framed), and the game server of NETDEMO F
# (HW_HOST_IP:HW_PORT_G, echo_server.py --game; HW_PORT_GX: with records).
# Logs: build/hw-server/server.log, server_p.log, server_x.log, server_g.log,
# server_gx.log (outside build/hw, which
# make hw-image deletes and zips).  Ctrl-C stops them all.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENV="$ROOT/tools/hw/hw.env"
[ -f "$ENV" ] || ENV="$ROOT/tools/hw/hw.env.example"
# shellcheck disable=SC1090
. "$ENV"
[ -n "${HW_HOST_IP:-}" ] || HW_HOST_IP=$(ipconfig getifaddr en0)
HW_PORT_X=${HW_PORT_X:-7714}
HW_PORT_G=${HW_PORT_G:-7716}
HW_PORT_GX=${HW_PORT_GX:-7718}
mkdir -p "$ROOT/build/hw-server"
python3 "$ROOT/tools/mame/echo_server.py" --host "$HW_HOST_IP" --port "$HW_PORT_P" --close-after 64 --idle-close 10 \
	--log "$ROOT/build/hw-server/server_p.log" &
P=$!
python3 "$ROOT/tools/mame/echo_server.py" --host "$HW_HOST_IP" --port "$HW_PORT_X" --framed --idle-close 10 \
	--log "$ROOT/build/hw-server/server_x.log" &
X=$!
python3 "$ROOT/tools/mame/echo_server.py" --host "$HW_HOST_IP" --port "$HW_PORT_G" --game --idle-close 10 \
	--log "$ROOT/build/hw-server/server_g.log" &
G=$!
python3 "$ROOT/tools/mame/echo_server.py" --host "$HW_HOST_IP" --port "$HW_PORT_GX" --game --framed --idle-close 10 \
	--log "$ROOT/build/hw-server/server_gx.log" &
GX=$!
trap 'kill $P $X $G $GX 2>/dev/null' EXIT INT TERM
echo "echo_hw: $HW_HOST_IP:$HW_PORT (echo), $HW_HOST_IP:$HW_PORT_P (P: close after 64), $HW_HOST_IP:$HW_PORT_X (records), $HW_HOST_IP:$HW_PORT_G (game; records: $HW_PORT_GX)"
python3 "$ROOT/tools/mame/echo_server.py" --host "$HW_HOST_IP" --port "$HW_PORT" --idle-close 10 --log "$ROOT/build/hw-server/server.log"
