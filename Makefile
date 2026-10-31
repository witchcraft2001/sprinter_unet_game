# UNET-GAME -- build and checks.  See CLAUDE.md and docs/BUILD.md.
.PHONY: all gen dlls verify size names test-host test-z check clean

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

clean:
	rm -rf build
