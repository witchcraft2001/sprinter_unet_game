# UNET-GAME -- build and checks.  See CLAUDE.md and docs/BUILD.md.
.PHONY: all gen dlls sdk verify size names test-host test-z check profile-check clean mame test-m libman

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

check: dlls sdk verify size names test-host test-z profile-check
	@echo "check: all gates passed"

# STEP profile of every build: 8 KiB stream at STEP periods of 2/10/20 ms,
# no STEP over its budget (tools/dev/profile_step.js, docs/MEASUREMENTS.md)
profile-check: dlls
	node tools/dev/profile_step.js --check

# M stand (MAME): not part of check -- it needs the MAME builds
# (tools/mame/build_holub.sh; 3C509B: the user's ../../../mame/mame, read-only)
# and takes ~10 s per scenario.  Ethernet scenarios need the feth pair
# (sudo tools/mame/net_feth.sh); without it they print SKIP (exit 77).
mame:
	tools/mame/build_holub.sh

# UGTEST (M4: libman l_call) and NETDEMO (M5: the SDK) scenarios; the
# Ethernet cards (M3) run both programs, H (bring-up only) needs no network
M_RUNS = gtcpesp:E gtcpesp:S gtcpesp:P gtcpesp:D gudpesp:E gudpesp:S gudpesp:D \
         gtcprtl:E gtcprtl:S gtcprtl:P gtcprtl:D gudprtl:E gudprtl:S gudprtl:D \
         gtcp509b:E gtcp509b:S gtcp509b:P gtcp509b:D gudp509b:E gudp509b:S gudp509b:D
N_RUNS = gtcpesp:L gtcpesp:E gtcpesp:S gtcpesp:P gtcpesp:D gtcpesp:W \
         gudpesp:L gudpesp:E gudpesp:S gudpesp:D gudpesp:W \
         gtcprtl:H gtcprtl:L gtcprtl:E gtcprtl:S gtcprtl:P gtcprtl:D gtcprtl:W \
         gudprtl:H gudprtl:E gudprtl:S gudprtl:D gudprtl:W \
         gtcp509b:H gtcp509b:L gtcp509b:E gtcp509b:S gtcp509b:P gtcp509b:D gtcp509b:W \
         gudp509b:H gudp509b:E gudp509b:S gudp509b:D gudp509b:W
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
	done; exit $$fail

clean:
	rm -rf build
