# UNET-GAME -- build and checks.  See CLAUDE.md and docs/BUILD.md.
.PHONY: all gen dlls verify size names test-host test-z check clean mame test-m

all: dlls

gen:
	python3 tools/gen_abi.py gen

dlls:
	tools/build.sh

verify: dlls
	@for f in build/G*.DLL; do sprinter-mkdll verify $$f --target 1.3 >/dev/null && echo "verify OK $$f"; done

size:
	python3 tools/size_report.py

names:
	python3 tools/check_names.py

test-host: dlls
	python3 -m unittest discover -s tests/host

test-z: dlls
	node --test 'tests/z/**/*.test.js'

check: dlls verify size names test-host test-z
	@echo "check: all gates passed"

# M stand (MAME holub + SprinterESP card): not part of check -- it needs the
# MAME build (tools/mame/build_holub.sh) and takes ~10 s per scenario.
mame:
	tools/mame/build_holub.sh

M_RUNS = gtcpesp:E gtcpesp:S gtcpesp:P gtcpesp:D gudpesp:E gudpesp:S gudpesp:D
test-m: dlls
	@fail=0; for r in $(M_RUNS); do \
	  d=$${r%%:*}; s=$${r##*:}; \
	  if tools/mame/run_esp.py $$d $$s --evidence >build/mame-$$d-$$s.log 2>&1; then echo "M PASS $$d $$s"; \
	  else echo "M FAIL $$d $$s (build/mame-$$d-$$s.log)"; fail=1; fi; \
	done; exit $$fail

clean:
	rm -rf build
