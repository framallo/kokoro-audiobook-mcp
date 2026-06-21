.PHONY: build install release clean test synth
PREFIX ?= /usr/local

build:
	swift build -c release

install: build
	install -d $(PREFIX)/bin
	install -m 0755 .build/release/kab $(PREFIX)/bin/kab
	@echo "installed: $(PREFIX)/bin/kab"

# Build the Kokoro synthesizer backend (KokoroSwift / MLX).
synth:
	cd tools/kokoro-say && swift build -c release
	@echo "synth: tools/kokoro-say/.build/release/kokoro-say"
	@echo "wire it: kab config set synthCmd $$(pwd)/tools/kokoro-say/.build/release/kokoro-say"

release:
	swift build -c release
	@echo "binary: .build/release/kab"

test:
	swift test

clean:
	swift package clean
	rm -rf .build tools/kokoro-say/.build
