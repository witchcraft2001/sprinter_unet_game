# UNET-GAME -- build and checks.  See CLAUDE.md and docs/BUILD.md.
.PHONY: all gen dlls sdk verify size names test-host test-z check profile-check clean mame test-m libman hw-image

# A check piped into `tail` must still fail the recipe: bash and, in every
# such line, `set -o pipefail` (GNU make 3.81 of macOS has no .SHELLFLAGS).
# Until 2026-11-22 the piped lines of profile-check could not fail.
SHELL := /bin/bash
PF := set -o pipefail;

all: dlls sdk

gen:
	python3 tools/gen_abi.py gen

dlls:
	tools/build.sh

# SDK: the Z application stand program (build/ugz.bin) and the SDK example
sdk:
	tools/build_sdk.sh

verify: dlls
	@for f in build/G*.DLL; do sprinter-mkdll verify $$f --target 1.3 >/dev/null && echo "verify OK $$f"; done

size:
	python3 tools/size_report.py

names:
	python3 tools/check_names.py

test-host: dlls
	python3 -m unittest discover -s tests/host

test-z: dlls sdk
	node --test 'tests/z/**/*.test.js'
	# the Ethernet card scenarios again with UDP records on the UDP builds
	UG_RECORDS=1 node --test tests/z/hw/rtl/m2_rtl.test.js tests/z/hw/el3/m3_el3.test.js

check: dlls sdk verify size names test-host test-z profile-check
	@echo "check: all gates passed"

# STEP profile of every build: 8 KiB stream at STEP periods of 2/10/20 ms.
# In units (the stand without memory waits, where the costs are measured):
# at 500 units, at the published minimum, at 812 units (2000 us, the game
# profile) and at 1218 units (3000 us, the largest budget INIT_CONFIG
# accepts since 2026-11-22) -- no STEP over its budget, publication rules
# held (tools/dev/profile_step.js, docs/MEASUREMENTS.md).
# In the real time of the board (--real: memory waits): at the minimum,
# 1231 us (500 units), 2000 and 3000 us -- no STEP longer than its budget.
# The same rules over streams in small pieces (the Ethernet builds; pieces
# of 1..64 bytes: padding, a datagram whole in the first 64 bytes or just
# not, the short path of GUDP509B) at the minimum, 500, 732, 812 and 1218
# units, and in real time at 2000 and 3000 us (tools/dev/profile_small.sh);
# the SprinterESP builds at the budgets of their fat STEP (732: just on,
# 812 and 1218); GUDPESP in its transparent mode (esp_fw = 2) at 500, the
# minimum, 812 and 1218 units and in real time at the minimum, 2000 and
# 3000 us.
# The unit accounting again over foreign broadcast traffic, SHUTDOWN in a
# send and a lone send (tools/dev/scenario_budget.js)
SCEN_ETH = gtcprtl gudprtl gtcp509b gudp509b
SCEN_CARD = $(SCEN_ETH) gtcpesp gudpesp
REC_ETH = gudprtl gudp509b
profile-check: dlls
	node tools/dev/profile_step.js --check
	node tools/dev/profile_step.js --check --budget min
	$(PF) node tools/dev/profile_step.js --check --budget 812 | tail -1
	$(PF) node tools/dev/profile_step.js --check --budget 1218 | tail -1
	$(PF) node tools/dev/profile_step.js --check --real --budget min | tail -1
	$(PF) node tools/dev/profile_step.js --check --real | tail -1
	$(PF) node tools/dev/profile_step.js --check --real --budget 2000 | tail -1
	$(PF) node tools/dev/profile_step.js --check --real --budget 3000 | tail -1
	tools/dev/profile_small.sh $(SCEN_ETH)
	PIECES="16 40 64" BUDGETS="732 812 1218" tools/dev/profile_small.sh gtcpesp gudpesp
	@$(PF) for b in 500 min 812 1218; do node tools/dev/profile_step.js gudpesp --esp-fw 2 --check --budget $$b | tail -1 || exit 1; done
	@$(PF) for b in min 2000 3000; do node tools/dev/profile_step.js gudpesp --esp-fw 2 --check --real --budget $$b | tail -1 || exit 1; done
	@$(PF) for d in $(SCEN_ETH); do node tools/dev/scenario_budget.js $$d broadcast --check | tail -1 || exit 1; done
	@# UDP records (UNETG_CFGF_UDP_RECORDS) on the Ethernet UDP builds
	@$(PF) for b in 500 min 812 1218; do UG_RECORDS=1 node tools/dev/profile_step.js $(REC_ETH) --check --budget $$b | tail -1 || exit 1; done
	@$(PF) for b in min 2000 3000; do UG_RECORDS=1 node tools/dev/profile_step.js $(REC_ETH) --check --real --budget $$b | tail -1 || exit 1; done
	UG_RECORDS=1 tools/dev/profile_small.sh $(REC_ETH)
	@$(PF) for d in $(REC_ETH); do for sc in broadcast shutdown lone; do UG_RECORDS=1 node tools/dev/scenario_budget.js $$d $$sc --check | tail -1 || exit 1; done; done
	@$(PF) for d in $(SCEN_CARD); do for sc in shutdown lone; do node tools/dev/scenario_budget.js $$d $$sc --check | tail -1 || exit 1; done; done
	@# SHUTDOWN in a send at 500 units too: on ESP the stop lets the CIPSEND
	@# end (ESP_SEND_LIVE) with more work per STEP than at the minimum
	@$(PF) for d in $(SCEN_CARD); do node tools/dev/scenario_budget.js $$d shutdown 500 --check | tail -1 || exit 1; done

# M stand (MAME): not part of check -- it needs the MAME builds
# (tools/mame/build_holub.sh; 3C509B: the user's ../../../mame/mame, read-only)
# and takes ~10 s per scenario.  Ethernet scenarios need the feth pair
# (sudo tools/mame/net_feth.sh); without it they print SKIP (exit 77).
mame:
	tools/mame/build_holub.sh

# UGTEST (M4: libman l_call) and NETDEMO (M5: the SDK) scenarios; the
# Ethernet cards (M3) run both programs, H (bring-up only) needs no network;
# V: the SDK auto-loader (environment -> DLL -> INIT_CONFIG) on every card
M_RUNS = gtcpesp:E gtcpesp:S gtcpesp:P gtcpesp:D gudpesp:E gudpesp:S gudpesp:D \
         gtcprtl:E gtcprtl:S gtcprtl:P gtcprtl:D gudprtl:E gudprtl:S gudprtl:D \
         gtcp509b:E gtcp509b:S gtcp509b:P gtcp509b:D gudp509b:E gudp509b:S gudp509b:D
N_RUNS = gtcpesp:L gtcpesp:E gtcpesp:S gtcpesp:P gtcpesp:D gtcpesp:W gtcpesp:T gtcpesp:Q gtcpesp:A gtcpesp:B gtcpesp:C gtcpesp:G gtcpesp:R gtcpesp:V \
         gudpesp:L gudpesp:E gudpesp:S gudpesp:D gudpesp:W gudpesp:T gudpesp:Q gudpesp:A gudpesp:B gudpesp:C gudpesp:G gudpesp:R gudpesp:F gudpesp:V \
         gtcprtl:H gtcprtl:L gtcprtl:E gtcprtl:S gtcprtl:P gtcprtl:D gtcprtl:W gtcprtl:T gtcprtl:Q gtcprtl:A gtcprtl:B gtcprtl:C gtcprtl:G gtcprtl:R gtcprtl:V \
         gudprtl:H gudprtl:E gudprtl:S gudprtl:D gudprtl:W gudprtl:T gudprtl:Q gudprtl:A gudprtl:B gudprtl:C gudprtl:G gudprtl:R gudprtl:F gudprtl:V \
         gtcp509b:H gtcp509b:L gtcp509b:E gtcp509b:S gtcp509b:P gtcp509b:D gtcp509b:W gtcp509b:T gtcp509b:Q gtcp509b:A gtcp509b:B gtcp509b:C gtcp509b:G gtcp509b:R gtcp509b:V \
         gudp509b:H gudp509b:E gudp509b:S gudp509b:D gudp509b:W gudp509b:T gudp509b:Q gudp509b:A gudp509b:B gudp509b:C gudp509b:G gudp509b:R gudp509b:F gudp509b:V
# GUDPESP in the transparent mode (esp_fw = 2: records, echo_server.py --framed)
X_RUNS = E S D
XN_RUNS = E S D W C G R F V
M_ONE = r=$$?; if [ $$r = 0 ]; then echo "M PASS $$p $$d $$s"; elif [ $$r = 77 ]; then echo "M SKIP $$p $$d $$s (no feth0)"; \
	else echo "M FAIL $$p $$d $$s ($$log)"; fail=1; fi
test-m: dlls libman
	@fail=0; for r in $(M_RUNS); do \
	  d=$${r%%:*}; s=$${r##*:}; p=ugtest; log=build/mame-$$d-$$s.log; \
	  tools/mame/run_m.py $$d $$s --evidence >$$log 2>&1; $(M_ONE); \
	done; \
	for r in $(N_RUNS); do \
	  d=$${r%%:*}; s=$${r##*:}; p=netdemo; log=build/mame-netdemo-$$d-$$s.log; \
	  tools/mame/run_m.py --prog netdemo $$d $$s --evidence >$$log 2>&1; $(M_ONE); \
	done; \
	d=gudpesp; for s in $(X_RUNS); do \
	  p=ugtest-x; log=build/mame-x-$$s.log; \
	  tools/mame/run_m.py --esp-fw 2 $$d $$s --evidence >$$log 2>&1; $(M_ONE); \
	done; \
	for s in $(XN_RUNS); do \
	  p=netdemo-x; log=build/mame-netdemo-x-$$s.log; \
	  tools/mame/run_m.py --prog netdemo --esp-fw 2 $$d $$s --evidence >$$log 2>&1; $(M_ONE); \
	done; exit $$fail

# Ж stand (real Sprinter): build/hw/ = UGTEST/NETDEMO (UG_HW), UGPROBE, the
# DLLs, run BATs and README.TXT for tools/hw/hw.env (hw.env.example when
# absent), plus build/hw/unetgame_hw.img; host side: tools/hw/echo_hw.sh
hw-image: dlls
	tools/hw/build_hw.sh
	python3 tools/check_names.py

clean:
	rm -rf build
