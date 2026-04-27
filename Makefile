REPO  := $(shell pwd)
DEVKIT := $(REPO)/devkit

.PHONY: help test test-temple lint dev-temple down boot disk install setup vm

help:
	@echo "make setup           fetch TempleOS ISO into devkit/vendor/templeos/"
	@echo "make disk            create a fresh 4G qcow2 install disk"
	@echo "make install         interactive TempleOS installer (one-time)"
	@echo "make dev-temple      boot TempleOS in QEMU, autonomous (auto-press 1, zoom 1.5x)"
	@echo "make test            push src/ + tests/T_*.ZC and report PASS/FAIL"
	@echo "make lint            host-side static lint of every .ZC under src/ and tests/"
	@echo "make down            stop the running TempleOS VM cleanly"
	@echo
	@echo "  T=Foo   filter test-temple battery to T_*Foo*.ZC"

setup:
	$(MAKE) -C $(DEVKIT) setup-temple

disk:
	$(MAKE) -C $(DEVKIT) disk-temple

install:
	$(MAKE) -C $(DEVKIT) install-temple

dev-temple:
	$(MAKE) -C $(DEVKIT) dev-temple

# `test-temple` boots TempleOS only if no VM is running; otherwise reuse the
# live one. Either way, push our src/ + tests/ via temple-run.py.
test test-temple:
	SRC_DIR=$(REPO)/src TEST_DIR=$(REPO)/tests \
	$(MAKE) -C $(DEVKIT) test-temple T="$(T)"

lint:
	python3 $(DEVKIT)/scripts/holyc-lint.py $(REPO)/src/*.ZC $(REPO)/tests/T_*.ZC

down:
	@if [ -S $(DEVKIT)/build/qemu-temple.sock ]; then \
		echo 'quit' | nc -U $(DEVKIT)/build/qemu-temple.sock >/dev/null 2>&1 || true; \
	fi
	@pkill -f 'qemu-system-x86_64.*templeos' 2>/dev/null || true
	@echo "VM stopped."
