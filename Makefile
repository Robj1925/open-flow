APP_NAME    := OpenFlow
BUNDLE_ID   := dev.openflow.OpenFlow
BUILD_DIR   := .build/release
DIST_DIR    := dist
APP_BUNDLE  := $(DIST_DIR)/$(APP_NAME).app

.PHONY: build test cli app install release run clean

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
# An ad-hoc signature's default designated requirement is the binary's cdhash,
# so TCC sees every rebuild as a different app and drops the grants. Pinning
# the requirement to the bundle identifier instead lets the grants survive.
ifeq ($(CODESIGN_ID),-)
CODESIGN_REQ := --requirements '=designated => identifier "$(BUNDLE_ID)"'
endif
LSREGISTER  := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

app:
	swift build -c release --product $(APP_NAME)
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp App/Info.plist $(APP_BUNDLE)/Contents/
	cp -R App/Resources/ $(APP_BUNDLE)/Contents/Resources/ 2>/dev/null || true
	codesign --force --options runtime $(CODESIGN_REQ) \
		--entitlements App/OpenFlow.entitlements \
		--sign "$(CODESIGN_ID)" $(APP_BUNDLE)
	# Launch Services must see the bundle for its NSServices entry (the
	# "Read Aloud with OpenFlow" context-menu item) to appear in other apps.
	$(LSREGISTER) -f $(abspath $(APP_BUNDLE))
	/System/Library/CoreServices/pbs -flush
	@echo "→ $(APP_BUNDLE)"

# Replace the copy in /Applications. Quit the running app first: overwriting
# a running binary in place makes macOS kill it (Code Signature Invalid) and
# `open` then fails with error -600.
install: app
	-osascript -e 'quit app "$(APP_NAME)"' >/dev/null 2>&1
	-pkill -x $(APP_NAME) >/dev/null 2>&1
	@for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x $(APP_NAME) >/dev/null || break; sleep 0.3; done
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP_BUNDLE) /Applications/
	open /Applications/$(APP_NAME).app

# Zip the assembled bundle the way the GitHub release expects it
# (OpenFlow.app at the archive root, resource forks sequestered).
release: app
	rm -f $(DIST_DIR)/OpenFlow.zip
	ditto -c -k --sequesterRsrc --keepParent $(APP_BUNDLE) $(DIST_DIR)/OpenFlow.zip
	@echo "→ $(DIST_DIR)/OpenFlow.zip"

run: app
	open $(APP_BUNDLE)

clean:
	swift package clean
	rm -rf $(DIST_DIR)
