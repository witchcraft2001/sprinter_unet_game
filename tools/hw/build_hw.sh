#!/bin/sh
# build_hw.sh -- the Ж stand (real Sprinter) file set: make hw-image.
#
# Reads tools/hw/hw.env (or hw.env.example when there is none) and builds
# into build/hw/:
#   UGT<card><T|U>.EXE    UGTEST, UG_HW (scenario on the command line:
#                         E, S, D, K <minutes>), peer HW_HOST_IP:HW_PORT
#   UGT<card>TP.EXE       the same for TCP scenario P, peer port HW_PORT_P
#                         (the echo server that closes after 64 bytes)
#   N<card><T|U><s>.EXE   NETDEMO, UG_HW, one per scenario s (-DSCEN)
#   UGTESPX.EXE, NESPX<s>.EXE  GUDPESP in its transparent mode (esp_fw = 2,
#                         records), peer HW_HOST_IP:HW_PORT_X (echo_hw.sh
#                         runs echo_server.py --framed there)
#   N<card>UF.EXE, NESPXF.EXE  NETDEMO F (game flow, UDP builds), peer
#                         HW_PORT_G / HW_PORT_GX (echo_server.py --game)
#   UGPROBE.EXE           platform probe (argument E, R or 3)
#   G*.DLL                the seven libraries
#   UGRUN<card>.BAT       the run sequence of one card
#   README.TXT            the operator's checklist (ASCII)
#   unetgame_hw.img       the same files on a 1.44 MB FAT12 image
#   UGHW.ZIP              the same files in one flat zip archive
# card = ESP, RTL or 509.  Every program writes its report next to itself
# (<prog letter><card><T|U><scen>.TXT, PROBE<c>.TXT); bring those back and
# run tools/measure/parse_hw.py on them.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENV="$ROOT/tools/hw/hw.env"
[ -f "$ENV" ] || ENV="$ROOT/tools/hw/hw.env.example"
echo "build_hw: configuration $ENV"
# shellcheck disable=SC1090
. "$ENV"
[ -n "${HW_HOST_IP:-}" ] || HW_HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || true)
[ -n "$HW_HOST_IP" ] || { echo "build_hw: HW_HOST_IP empty and en0 has no address" >&2; exit 1; }
HW_PORT_X=${HW_PORT_X:-7714}
HW_PORT_G=${HW_PORT_G:-7716}
HW_PORT_GX=${HW_PORT_GX:-7718}
echo "build_hw: echo server $HW_HOST_IP:$HW_PORT (P: $HW_PORT_P, records: $HW_PORT_X, game: $HW_PORT_G / $HW_PORT_GX)"
# ISA slots are 0 and 1 (#E2 = #D4 / #D6, the `-s` of the old drivers):
# INIT_CONFIG answers BAD_CONFIG to any other isa_slot (the first Ж runs
# of the 3C509B failed exactly so with HW_SLOT_EL3=2).
for v in HW_SLOT_ESP HW_SLOT_RTL HW_SLOT_EL3; do
	eval "x=\${$v}"
	case "$x" in
	0|1) ;;
	*) echo "build_hw: $v=$x in $ENV: the ISA slot is 0 or 1" >&2; exit 1;;
	esac
done

OUT="$ROOT/build/hw"
WORK="$ROOT/build/hw-work"
LIBMAN="$ROOT/third_party/libman/libman"
rm -rf "$OUT" "$WORK"
mkdir -p "$OUT" "$WORK"
for d in GTCPESP GUDPESP GTCPRTL GUDPRTL GTCP509B GUDP509B GLOOP; do
	[ -f "$ROOT/build/$d.DLL" ] || { echo "build_hw: build/$d.DLL missing (make dlls)" >&2; exit 1; }
	cp "$ROOT/build/$d.DLL" "$OUT/"
done

asm() {	# asm <work dir> <source> <defines...>
	w=$1; src=$2; shift 2
	(cd "$w" && sjasmplus --nologo -I "$ROOT/include" -I "$ROOT/sdk" -I "$ROOT/sdk/example" -I "$w" \
		-I "$LIBMAN" "$@" "$src" >"$w/asm.log" 2>&1) || { cat "$w/asm.log" >&2; exit 1; }
}

# cfg <prog> <dll> <out.inc> <peer port> [mkcfg options]: INIT_CONFIG of the board
cfg() {
	prog=$1; dll=$2; inc=$3; port=$4; shift 4
	case $dll in
	*esp) slot=$HW_SLOT_ESP; io=$HW_IO_ESP; extra="--trigger $HW_UART_TRIGGER";;
	*rtl) slot=$HW_SLOT_RTL; io=$HW_IO_RTL; extra="";;
	*) slot=$HW_SLOT_EL3; io=$HW_IO_EL3; extra="--id-port $HW_ID_PORT";;
	esac
	lport=$HW_LOCAL_PORT
	[ "$dll" = gudpesp ] && lport=$HW_LOCAL_PORT_ESP_UDP
	# shellcheck disable=SC2086
	node "$ROOT/tools/mame/mkcfg.js" --prog "$prog" --slot "$slot" --io-base "$io" $extra \
		--local-ip "$HW_SPR_IP" --netmask "$HW_MASK" --gateway "$HW_GW" \
		--peer "$HW_HOST_IP" --port "$port" --local-port "$lport" "$@" "$dll" "$inc"
}

# netdemo_profile <scen> <card code>: the latency scenarios with their own
# quota (tools/mame/run_m.py LAT_PROFILE): STEPs per period, STEP budget in
# real us (0 = the minimum), polls and the poll budget
netdemo_profile() {
	steps=$HW_STEPS; budget=0; polls=1; isr=0
	case $1 in Q) steps=2;; A) steps=2; budget=1500;; B) steps=2; budget=2000;; C) steps=1; budget=2000;; G) steps=1; budget=2000; polls=10; [ "$2" = ESP ] && isr=341;; R) steps=1; budget=3000; polls=10; [ "$2" = ESP ] && isr=341;;
	F) steps=1; budget=3000; polls=10; [ "$2" = ESP ] && { polls=5; isr=341; };; esac
	return 0	# the last && list fails on the other cards (set -e)
}

code_of() { case $1 in *esp) echo ESP;; *rtl) echo RTL;; *) echo 509;; esac; }
tp_of() { case $1 in gtcp*) echo T;; *) echo U;; esac; }

for dll in gtcpesp gudpesp gtcprtl gudprtl gtcp509b gudp509b; do
	code=$(code_of $dll); tp=$(tp_of $dll)
	# UGTEST: one EXE, the scenario on the command line
	w="$WORK/ugtest_$dll"; mkdir -p "$w"
	cfg ugtest $dll "$w/ugcfg.inc" "$HW_PORT"
	asm "$w" "$ROOT/sdk/example/ugtest.asm" -DUG_HW=1 -DSCEN=69
	cp "$w/ugtest.exe" "$OUT/UGT$code$tp.EXE"
	if [ "$tp" = T ]; then
		w="$WORK/ugtest_${dll}_p"; mkdir -p "$w"
		cfg ugtest $dll "$w/ugcfg.inc" "$HW_PORT_P"
		asm "$w" "$ROOT/sdk/example/ugtest.asm" -DUG_HW=1 -DSCEN=80
		cp "$w/ugtest.exe" "$OUT/UGT${code}TP.EXE"
	fi
	# NETDEMO: one EXE per scenario
	scens="L E S D W T Q A B C"
	[ "$tp" = T ] && scens="$scens P"
	scens="$scens G R"
	[ "$tp" = U ] && scens="$scens F"
	[ "$code" != ESP ] && scens="H $scens"
	for s in $scens; do
		port=$HW_PORT; [ "$s" = P ] && port=$HW_PORT_P; [ "$s" = F ] && port=$HW_PORT_G
		w="$WORK/netdemo_${dll}_$s"; mkdir -p "$w"
		cfg netdemo $dll "$w/ugcfg.inc" "$port"
		ord=$(printf '%d' "'$s")
		netdemo_profile $s $code
		asm "$w" "$ROOT/sdk/example/netdemo.asm" -DUG_HW=1 -DSCEN="$ord" -DUG_STEPS="$steps" -DUG_STEP_BUDGET="$budget" -DUG_POLL_TICKS="$polls" -DUG_ISR_BUDGET="$isr"
		cp "$w/netdemo.exe" "$OUT/N$code$tp$s.EXE"
	done
done

# GUDPESP in the transparent mode: transport letter X (mkcfg.js UG_HWPFX)
w="$WORK/ugtest_gudpesp_x"; mkdir -p "$w"
cfg ugtest gudpesp "$w/ugcfg.inc" "$HW_PORT_X" --esp-fw 2
asm "$w" "$ROOT/sdk/example/ugtest.asm" -DUG_HW=1 -DSCEN=69
cp "$w/ugtest.exe" "$OUT/UGTESPX.EXE"
for s in E S D W C G R F; do
	w="$WORK/netdemo_gudpesp_x_$s"; mkdir -p "$w"
	port=$HW_PORT_X; [ "$s" = F ] && port=$HW_PORT_GX
	cfg netdemo gudpesp "$w/ugcfg.inc" "$port" --esp-fw 2
	netdemo_profile $s ESP
	asm "$w" "$ROOT/sdk/example/netdemo.asm" -DUG_HW=1 -DSCEN="$(printf '%d' "'$s")" -DUG_STEPS="$steps" -DUG_STEP_BUDGET="$budget" -DUG_POLL_TICKS="$polls" -DUG_ISR_BUDGET="$isr"
	cp "$w/netdemo.exe" "$OUT/NESPX$s.EXE"
done

# UGPROBE
w="$WORK/ugprobe"; mkdir -p "$w"
cat >"$w/probecfg.inc" <<EOT
; generated by tools/hw/build_hw.sh from $(basename "$ENV") -- do not edit
PR_SLOT_ESP	EQU	$HW_SLOT_ESP
PR_SLOT_RTL	EQU	$HW_SLOT_RTL
PR_SLOT_EL3	EQU	$HW_SLOT_EL3
PR_IO_ESP	EQU	$HW_IO_ESP
PR_IO_RTL	EQU	$HW_IO_RTL
PR_IO_EL3	EQU	$HW_IO_EL3
PR_ID_PORT	EQU	$HW_ID_PORT
EOT
asm "$w" "$ROOT/tools/measure/ugprobe.asm"
cp "$w/ugprobe.exe" "$OUT/UGPROBE.EXE"

# run sequences, one BAT per card (DSS BAT: CR LF, Estex-DSS/BAT.md)
bat() {	# bat <card code>
	code=$1
	{
		echo "@echo off"
		echo "rem UNET-GAME hardware runs, card $code (README.TXT)"
		echo "rem host: tools/hw/echo_hw.sh must be running on $HW_HOST_IP"
		case $code in ESP) echo "UGPROBE E";; RTL) echo "UGPROBE R";; *) echo "UGPROBE 3";; esac
		for tp in T U; do
			echo "UGT$code$tp E"
			echo "UGT$code$tp S"
			[ "$tp" = T ] && echo "UGT${code}TP P"
			echo "UGT$code$tp D"
			echo "UGT$code$tp K 10"
			for sc in L H E S P D W T Q A B C G R F; do
				[ -f "$OUT/N$code$tp$sc.EXE" ] && echo "N$code$tp$sc"
			done
		done
		if [ "$code" = ESP ]; then
			# the transparent mode (records): UGTESPX, NESPX<s>
			for sc in E S D; do echo "UGTESPX $sc"; done
			for sc in E S D W C G R F; do echo "NESPX$sc"; done
		fi
		# what the series left to the system stack (STATA<c>.TXT)
		case $code in ESP) echo "UGPROBE E 1";; RTL) echo "UGPROBE R 1";; *) echo "UGPROBE 3 1";; esac
		echo "echo UNET-GAME $code runs done: copy the .TXT files back"
	} | sed 's/$/\r/' >"$OUT/UGRUN$code.BAT"
}
bat ESP; bat RTL; bat 509

sed 's/$/\r/' >"$OUT/README.TXT" <<EOT
UNET-GAME hardware stand (Zh) -- operator checklist
===================================================
Built $(date +%Y-%m-%d) from $(basename "$ENV"); echo server $HW_HOST_IP:$HW_PORT,
P server $HW_HOST_IP:$HW_PORT_P, record echo $HW_HOST_IP:$HW_PORT_X,
game server $HW_HOST_IP:$HW_PORT_G (records: $HW_PORT_GX).  Sprinter (Ethernet): $HW_SPR_IP/$HW_MASK gw $HW_GW.
Slots: ESP $HW_SLOT_ESP (I/O $HW_IO_ESP), RTL $HW_SLOT_RTL (I/O $HW_IO_RTL),
3C509B $HW_SLOT_EL3 (I/O $HW_IO_EL3, ID $HW_ID_PORT).  UART trigger $HW_UART_TRIGGER.
ISA slots are numbered 0 and 1 (as -s of the old drivers).

Before the runs
 1. Host: tools/hw/echo_hw.sh (both servers; logs build/hw-server/).
 2. Copy this folder to the Sprinter (any directory, 8.3 names as is),
    or UGHW.ZIP and unpack it there (flat: no subdirectories).
 3. ESP: the module is already on Wi-Fi with ESP-AT 2.2.x (NETUP / your
    usual tools); the programs only send AT and AT+UART_CUR.
    Ethernet: the cable is in, the card is in the slot written above.
 4. Turbo is switched on by every program itself (21 MHz).
 5. Every report starts with "SLOT c mm u": the configured slot, the slots
    that answer as the card (01 = slot 0, 02 = slot 1, 00 = none) and the
    slot used.  UGPROBE first: c <> u means hw.env names the wrong slot
    (the programs still run in slot u -- fix hw.env and rebuild);
    mm = 00 means the card is not found (UGPROBE: RESULT: FAIL S).

Runs (one card at a time, the others may stay in their slots)
    UGRUNESP.BAT   UGRUNRTL.BAT   UGRUN509.BAT
 or by hand, from this directory:
    UGPROBE E|R|3          platform costs (CPU, ISA, CTC, UART for E);
                           its head: the card registers and the NET*
                           variables of DSS as they are before the runs
    UGPROBE E|R|3 1        the same head only, saved as STATA<c>.TXT: what
                           the runs left to the system network stack
    UGT<card><T|U> E       echo 300 bytes
    UGT<card><T|U> S       8 KiB stream
    UGT<card>TP P          TCP: the peer closes (P server)
    UGT<card><T|U> D       SHUTDOWN while open
    UGT<card><T|U> K 10    10 minute soak (two-way stream): the screen
                           shows "soak: ..." and then only a dot a minute
                           until it ends (it counts video frames: allow
                           up to 15 minutes); Esc stops it early
    N<card><T|U><s>        NETDEMO scenario s: L H E S P D W T Q A B C G R F
                           (T: packet latency under the quota, line
                           LATMS; Q: the same at 2 STEPs per period;
                           A, B, C: with a larger STEP budget, real
                           us: 2 x 1500, 2 x 2000, 1 x 2000 per period;
                           G: 1 x 2000 with one card poll per period,
                           the game profile; on ESP the poll moves
                           UART bytes; R: the same with 1 x 3000;
                           F: UDP builds only, the flow of a real-time
                           game for 10 s with R's profile (ESP: two
                           polls): an input of 20 bytes every 40 ms up,
                           a state of 88 bytes every 100 ms down from
                           the game server; line FLOW)
  card = ESP, RTL or 509; T = TCP build, U = UDP build.
    UGTESPX E|S|D, NESPX<s> (s = E S D W C G R F)
                           GUDPESP in the transparent UDP mode of ESP-AT
                           (AT+CIPMODE=1, every datagram a record with a
                           2-byte header; the record echo server).  If a
                           run is cut off, the module may stay in that
                           mode: the next program leaves it with "+++"
                           (bring-up about 2 s longer); NETUP / the system
                           stack then sees a module that answers AT.

After the runs
 Every program prints the head of its report at once (name, SCEN, SLOT),
 the rest when it ends, and saves it here as <name>.TXT
 (e.g. UESPTS.TXT, NRTLUE.TXT, PROBEE.TXT); "SAVE FAIL xx" on the screen
 means the file could not be written: take a photo of the screen instead.
 (unetgame_hw.img holds the same files for a floppy, UGHW.ZIP in one
 archive: do not copy them over together with the folder.)
 Bring all .TXT files back and on the host run
    python3 tools/measure/parse_hw.py <folder with the .TXT files>
 Note the board, card revisions, ESP-AT version (AT+GMR in PROBEE.TXT),
 slots and anything unusual (hangs, resets) for the report.

The system network stack after the runs
 Every program stops the card with SHUTDOWN (also when a run fails): RX/TX
 off, window 0 -- as the system driver leaves it; no program resets the
 card.  If FTP / PING of the system stack fails right after the runs:
 write down its exact message, run the same command once more BEFORE
 netcfg / ifup, and send both results with STATA<c>.TXT.
EOT

# the same set on a floppy image (a side product: the folder is the artefact)
IMG="$OUT/unetgame_hw.img"
mformat -C -i "$IMG" -f 1440 ::
for f in "$OUT"/*; do
	[ "$f" = "$IMG" ] || mcopy -i "$IMG" "$f" "::$(basename "$f")"
done
# and in one archive for the trip to the Sprinter: flat (no directories,
# unpacks into the current one), 8.3 name, plain deflate, no macOS extra
# fields; neither the image nor the archive itself goes in
ZIP="$OUT/UGHW.ZIP"
(cd "$OUT" && ls | grep -v -e '^unetgame_hw\.img$' -e '^UGHW\.ZIP$' | zip -q -X -D -j "$ZIP" -@)
n=$(ls "$OUT" | wc -l | tr -d ' ')
echo "build_hw: $n files in build/hw/ (image unetgame_hw.img, archive UGHW.ZIP: $(unzip -Z1 "$ZIP" | wc -l | tr -d ' ') files)"
