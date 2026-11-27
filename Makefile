# Lite build script. No Xcode needed: SwiftPM + Command Line Tools only.
#
#   make            release build → build/Lite.app (ad-hoc signed)
#   make run        build, then run the bundle's binary in this terminal (stdout visible)
#   make open       build, then launch via LaunchServices (like double-clicking)
#   make debug      same as `make` but a debug build
#   make test       run the Swift Testing suite
#   make install    release build, then install to /Applications (works while Lite runs, even from inside it; restart Lite after)
#   make uninstall  remove /Applications/Lite.app (config is kept)
#   make icon       regenerate Resources/AppIcon.icns
#   make clean
#
# SIGN_ID=-  (default) ad-hoc. Set to a self-signed cert name for a stable identity
# so macOS privacy (TCC) grants survive rebuilds.

APP_NAME  := Lite
CONFIG    ?= release
SIGN_ID   ?= -
BUILD_DIR := build
APP       := $(BUILD_DIR)/$(APP_NAME).app
ICON      := Resources/AppIcon.icns
SWIFT_FLAGS := -c $(CONFIG) --arch arm64
INSTALL_DIR ?= /Applications
# CLT-only toolchains ship Swift Testing's macro plugin in a subdirectory SwiftPM doesn't search.
TESTING_PLUGINS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing

# SwiftTerm is a git submodule; fetch it if the repo was cloned without --recurse-submodules.
SWIFTTERM := Vendor/SwiftTerm/Package.swift

.PHONY: all app build run open debug test install uninstall icon clean

all: app

$(SWIFTTERM):
	git submodule update --init --depth 1 Vendor/SwiftTerm

build: $(SWIFTTERM)
	swift build $(SWIFT_FLAGS)

app: build $(ICON)
	@BIN_DIR=$$(swift build $(SWIFT_FLAGS) --show-bin-path) && \
	rm -rf "$(APP)" && \
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" && \
	cp "$$BIN_DIR/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)" && \
	cp Resources/Info.plist "$(APP)/Contents/Info.plist" && \
	cp $(ICON) "$(APP)/Contents/Resources/" && \
	if ls Resources/*.metal >/dev/null 2>&1; then cp Resources/*.metal "$(APP)/Contents/Resources/"; fi && \
	printf 'APPL????' > "$(APP)/Contents/PkgInfo" && \
	codesign --force --sign "$(SIGN_ID)" --timestamp=none "$(APP)" && \
	codesign --verify --strict "$(APP)" && \
	echo "Built $(APP) ($(CONFIG))"

run: app
	"$(APP)/Contents/MacOS/$(APP_NAME)"

open: app
	open "$(APP)"

debug:
	$(MAKE) app CONFIG=debug

test: $(SWIFTTERM)
	swift test $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

install:
	$(MAKE) app CONFIG=release
	scripts/install.sh "$(APP)" "$(INSTALL_DIR)"

uninstall:
	scripts/install.sh --uninstall "$(INSTALL_DIR)"

$(ICON): scripts/make-icon.swift
	@set -e; TMP=$$(mktemp -d); SET="$$TMP/AppIcon.iconset"; mkdir -p "$$SET"; \
	swift scripts/make-icon.swift "$$TMP/1024.png"; \
	for s in 16 32 128 256 512; do \
	  sips -z $$s $$s "$$TMP/1024.png" --out "$$SET/icon_$${s}x$${s}.png" >/dev/null; \
	  d=$$((s * 2)); \
	  sips -z $$d $$d "$$TMP/1024.png" --out "$$SET/icon_$${s}x$${s}@2x.png" >/dev/null; \
	done; \
	iconutil -c icns "$$SET" -o $(ICON); rm -rf "$$TMP"; echo "Generated $(ICON)"

icon:
	rm -f $(ICON) && $(MAKE) $(ICON)

clean:
	rm -rf $(BUILD_DIR) .build
