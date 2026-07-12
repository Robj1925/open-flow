APP_NAME    := OpenFlow
BUNDLE_ID   := dev.openflow.OpenFlow
BUILD_DIR   := .build/release
DIST_DIR    := dist
APP_BUNDLE  := $(DIST_DIR)/$(APP_NAME).app

.PHONY: build test cli app run clean

build:
	swift build

test:
	swift run openflow-tests

cli:
	swift build --product openflow-cli
	@echo "→ .build/debug/openflow-cli"

# Assemble a runnable .app bundle from the SPM release binary.
# Ad-hoc signed: macOS permission grants (Mic/Accessibility) reset when the
# binary changes. With a real signing identity, set CODESIGN_ID.
CODESIGN_ID ?= -

app:
	swift build -c release --product $(APP_NAME)
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp App/Info.plist $(APP_BUNDLE)/Contents/
	cp -R App/Resources/ $(APP_BUNDLE)/Contents/Resources/ 2>/dev/null || true
	codesign --force --options runtime \
		--entitlements App/OpenFlow.entitlements \
		--sign "$(CODESIGN_ID)" $(APP_BUNDLE)
	@echo "→ $(APP_BUNDLE)"

run: app
	open $(APP_BUNDLE)

clean:
	swift package clean
	rm -rf $(DIST_DIR)
