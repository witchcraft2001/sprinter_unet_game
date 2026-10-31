# UNET-GAME -- build and checks.  See CLAUDE.md and docs/BUILD.md.
.PHONY: all gen dlls sdk verify size names test-host test-z check clean mame test-m libman

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

check: dlls sdk verify size names test-host test-z
	@echo "check: all gates passed"

# M stand (MAME holub + SprinterESP card): not part of check -- it needs the
# MAME build (tools/mame/build_holub.sh) and takes ~10 s per scenario.
mame:
	tools/mame/build_holub.sh

# UGTEST (M4: libman l_call) and NETDEMO (M5: the SDK) scenarios
M_RUNS = gtcpesp:E gtcpesp:S gtcpesp:P gtcpesp:D gudpesp:E gudpesp:S gudpesp:D
N_RUNS = gtcpesp:L gtcpesp:E gtcpesp:S gtcpesp:P gtcpesp:D gtcpesp:W \
         gudpesp:L gudpesp:E gudpesp:S gudpesp:D gudpesp:W
test-m: dlls libman
	@fail=0; for r in $(M_RUNS); do \
	  d=$${r%%:*}; s=$${r##*:}; \
	  if tools/mame/run_esp.py $$d $$s --evidence >build/mame-$$d-$$s.log 2>&1; then echo "M PASS ugtest $$d $$s"; \
	  else echo "M FAIL ugtest $$d $$s (build/mame-$$d-$$s.log)"; fail=1; fi; \
	done; \
	for r in $(N_RUNS); do \
	  d=$${r%%:*}; s=$${r##*:}; \
	  if tools/mame/run_esp.py --prog netdemo $$d $$s --evidence >build/mame-netdemo-$$d-$$s.log 2>&1; then echo "M PASS netdemo $$d $$s"; \
	  else echo "M FAIL netdemo $$d $$s (build/mame-netdemo-$$d-$$s.log)"; fail=1; fi; \
	done; exit $$fail

clean:
	rm -rf build
