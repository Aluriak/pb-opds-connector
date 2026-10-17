# Platform enum in build.zig
PLATFORMS := allwinner rk3566
# Mountpoint of the reader device
DEVICE ?= /Volumes/PB710
# Extra options for the production builds, e.g. ZIGFLAGS="-Dchannel=nightly -Dcommit=..."
ZIGFLAGS ?=
# Applicaton name, see build.zig
APP := OPDS Connector.app

## help: print this help message
.PHONY: help
help:
	@echo 'Usage:'
	@sed -n 's/^##//p' ${MAKEFILE_LIST} | column -t -s ':' | sed -e 's/^/ /'

## build-all: build production executables for every platform into zig-out/<platform>/bin
.PHONY: build-all
build-all:
	@for platform in $(PLATFORMS); do \
		echo "zig build -Doptimize=ReleaseSmall -Dplatform=$$platform $(ZIGFLAGS) --prefix zig-out/$$platform"; \
		zig build -Doptimize=ReleaseSmall -Dplatform=$$platform $(ZIGFLAGS) --prefix zig-out/$$platform || exit 1; \
	done

## build-rk3566: build production executable for Rockchip RK3566 readers
.PHONY: build-rk3566
build-rk3566:
	zig build -Doptimize=ReleaseSmall -Dplatform=rk3566 --prefix zig-out/rk3566

## build: build production executable
.PHONY: build
build:
	zig build -Doptimize=ReleaseSmall

## build-dev: build develop/debug executable
.PHONY: build-dev
build-dev:
	zig build

## fmt-check: check zig code format
.PHONY: fmt-check
fmt-check:
	zig fmt --check src build.zig stubs

## fmt-fix: fix zig code format
.PHONY: fmt-fix
fmt-fix:
	zig fmt src build.zig stubs

## test: run the unit tests
.PHONY: test
test:
	zig build test --summary all

## install: copy the executable from zig-out/bin to the connected reader and unmount it
.PHONY: install
install:
	@test -d "$(DEVICE)/applications" || { echo "No reader found at $(DEVICE)"; exit 1; }
	cp -X "zig-out/bin/$(APP)" "$(DEVICE)/applications/$(APP)"
	@rm -f "$(DEVICE)/applications/._$(APP)"
	diskutil unmount "$(DEVICE)"
