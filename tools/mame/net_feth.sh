#!/bin/sh
# net_feth.sh -- the host network of the M stand for the Ethernet cards
# (tools/mame/run_m.py): a macOS feth pair, MAME captures on feth0 (pcap),
# the host end feth1 carries 192.168.7.1/24 where echo_server.py listens.
# Needs root once per boot:  sudo tools/mame/net_feth.sh   (down: ... down)
set -eu
HOST_IP=${MAME_NET_HOST:-192.168.7.1}
if [ "${1:-up}" = down ]; then
	ifconfig feth0 destroy 2>/dev/null || true
	ifconfig feth1 destroy 2>/dev/null || true
	exit 0
fi
ifconfig feth0 create 2>/dev/null || true
ifconfig feth1 create 2>/dev/null || true
ifconfig feth0 peer feth1
ifconfig feth0 up
ifconfig feth1 inet "$HOST_IP" netmask 255.255.255.0 up
ifconfig feth0
ifconfig feth1
