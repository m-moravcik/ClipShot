.PHONY: app signed-app signed-app-dry test l10n guards clean

DERIVED := $(shell xcodebuild -project ClipShot.xcodeproj -scheme ClipShot -showBuildSettings 2>/dev/null | awk -F= '/ BUILD_DIR =/{print $$2}' | tr -d ' ')

# ENABLE_HARDENED_RUNTIME=NO: library validation would refuse the Developer
# ID-signed Sparkle.framework under an ad-hoc signature. Signed releases keep
# the hardened runtime (scripts/release-signed.sh).
app:
	xcodegen generate
	xcodebuild -project ClipShot.xcodeproj -scheme ClipShot -configuration Release \
		-destination 'platform=macOS' \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
		ENABLE_HARDENED_RUNTIME=NO build

# Developer ID signed, notarized and stapled build.
signed-app:
	./scripts/release-signed.sh

signed-app-dry:
	SKIP_NOTARIZE=1 ./scripts/release-signed.sh

test:
	xcodegen generate
	xcodebuild -project ClipShot.xcodeproj -scheme ClipShot test \
		-destination 'platform=macOS' \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO

l10n:
	./scripts/check-localisation.sh

guards:
	./scripts/guards.sh

clean:
	rm -rf ClipShot.xcodeproj
	rm -rf "$(DERIVED)"
