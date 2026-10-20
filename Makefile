.PHONY: app signed-app signed-app-dry cli install-cli uninstall-cli test l10n guards clean

# DERIVED_DATA=<dir> builds there instead of Xcode's default derived data.
DERIVED_DATA ?=
DERIVED_FLAG := $(if $(DERIVED_DATA),-derivedDataPath $(DERIVED_DATA),)
DERIVED := $(if $(DERIVED_DATA),$(DERIVED_DATA)/Build/Products,$(shell xcodebuild -project ClipShot.xcodeproj -scheme ClipShot -showBuildSettings 2>/dev/null | awk -F= '/ BUILD_DIR =/{print $$2}' | tr -d ' '))
RELEASE := $(DERIVED)/Release
PREFIX  ?= /usr/local

# ENABLE_HARDENED_RUNTIME=NO: library validation would refuse the Developer
# ID-signed Sparkle.framework under an ad-hoc signature. Signed releases keep
# the hardened runtime (scripts/release-signed.sh).
app:
	xcodegen generate
	xcodebuild -project ClipShot.xcodeproj -scheme ClipShot -configuration Release \
		-destination 'platform=macOS' \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
		ENABLE_HARDENED_RUNTIME=NO build

# The command line tool on its own, ad-hoc signed. Releases ship it inside the app
# (Contents/Helpers/clipshot), signed and notarized with it.
cli:
	xcodegen generate
	xcodebuild -project ClipShot.xcodeproj -scheme clipshot-cli -configuration Release \
		-destination 'platform=macOS' $(DERIVED_FLAG) \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build

# On Apple silicon /usr/local/bin may be missing or root's: say what to do rather than
# fail half way (`sudo make` would build as root).
install-cli: cli
	@mkdir -p "$(PREFIX)/bin" 2>/dev/null && [ -w "$(PREFIX)/bin" ] || { \
		echo "$(PREFIX)/bin is missing or not writable. Use make install-cli PREFIX=~/.local," >&2; \
		echo "or first: sudo mkdir -p $(PREFIX)/bin && sudo chown \"$$USER\" $(PREFIX)/bin" >&2; \
		exit 1; }
	@cp -f "$(RELEASE)/clipshot" "$(PREFIX)/bin/clipshot"
	@chmod +x "$(PREFIX)/bin/clipshot"
	@echo "Installed: $(PREFIX)/bin/clipshot"
	@echo "Try: clipshot status"

# Moves the installed tool to the Trash; nothing is deleted.
uninstall-cli:
	@p="$(PREFIX)/bin/clipshot"; \
	if [ -e "$$p" ] || [ -L "$$p" ]; then \
		osascript -e 'on run argv' -e 'set f to POSIX file (item 1 of argv)' \
			-e 'tell application "Finder" to delete f' -e 'end run' "$$p" >/dev/null || exit 1; \
		echo "moved to the Trash: $$p"; \
	else \
		echo "not installed: $$p"; \
	fi

# Developer ID signed, notarized and stapled build.
signed-app:
	./scripts/release-signed.sh

signed-app-dry:
	SKIP_NOTARIZE=1 ./scripts/release-signed.sh

# The test host is a Debug ClipShot.app, which xcodebuild registers with Launch Services:
# unregistered afterwards, pass or fail, so Shortcuts never lists a second ClipShot.
test:
	xcodegen generate
	@products="$$(xcodebuild -project ClipShot.xcodeproj -scheme ClipShot -showBuildSettings 2>/dev/null | awk -F= '/ BUILD_DIR =/{print $$2}' | tr -d ' ')"; \
	xcodebuild -project ClipShot.xcodeproj -scheme ClipShot test $(DERIVED_FLAG) \
		-destination 'platform=macOS' \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO; rc=$$?; \
	if [ -n "$(DERIVED_DATA)" ]; then products="$(DERIVED_DATA)/Build/Products"; fi; \
	./scripts/unregister-debug.sh "$$products/Debug/ClipShot.app"; \
	exit $$rc

l10n:
	./scripts/check-localisation.sh

guards:
	./scripts/guards.sh

# Moves the generated project and the build products to the Trash; nothing is deleted.
clean:
	@for p in "$(CURDIR)/ClipShot.xcodeproj" "$(DERIVED)"; do \
		if [ -n "$$p" ] && [ -e "$$p" ]; then \
			osascript -e 'on run argv' -e 'set f to POSIX file (item 1 of argv)' \
				-e 'tell application "Finder" to delete f' -e 'end run' "$$p" >/dev/null || exit 1; \
			echo "moved to the Trash: $$p"; \
		fi; \
	done
