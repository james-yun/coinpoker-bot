# make            build the engine from src/
# make install    build, then link pokerbot into ~/.local/bin
# make test       self-tests (logic, card reader, decider)
# make dist       a prebuilt release: dist/pokerbot-<version>-macos.tar.gz (universal, macOS 14+)
SOURCES := $(wildcard src/*.swift)
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
NAME    := pokerbot-$(VERSION)
STAGE   := dist/$(NAME)
# what a release carries: everything pokerbot needs at run time, plus the self-tests
SHIP    := pokerbot decide.sh decide.py shadow_report.py cards.txt preflop_charts.json README.md \
           bench/run.py bench/add.py bench/compare.py bench/common.py prompts tests

engine: $(SOURCES)
	swiftc -O $(SOURCES) -o engine

install: engine
	mkdir -p $(HOME)/.local/bin && ln -sf $(CURDIR)/pokerbot $(HOME)/.local/bin/pokerbot

test: engine
	./pokerbot test

build/engine-%: $(SOURCES)
	@mkdir -p build
	swiftc -O -target $*-apple-macos14 $(SOURCES) -o $@

dist: build/engine-arm64 build/engine-x86_64
	rm -rf $(STAGE) && mkdir -p $(STAGE)/bench
	lipo -create $^ -output $(STAGE)/engine
	codesign --force --sign - $(STAGE)/engine
	rsync -aR $(SHIP) $(STAGE)/
	cp dist-install.sh $(STAGE)/install.sh
	echo $(VERSION) > $(STAGE)/VERSION
	find $(STAGE) -name __pycache__ -prune -exec rm -rf {} + -o -name .DS_Store -delete
	tar -C dist -czf dist/$(NAME)-macos.tar.gz $(NAME)
	cd dist && shasum -a 256 $(NAME)-macos.tar.gz > $(NAME)-macos.tar.gz.sha256
	@echo "dist/$(NAME)-macos.tar.gz"

clean:
	rm -rf build dist engine

.PHONY: install test dist clean
