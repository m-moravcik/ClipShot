#!/usr/bin/env bash
#
# Build, sign, notarize and staple ClipShot.app, then package the *stapled* bundle
# as the release ZIP. Ported from VibeRes's scripts/release-signed.sh.
#
# This is deliberately a separate path from `make app`. The ad-hoc signed build
# stays the default for development; only releases go through here.
#
# A Developer ID signature matters for more than distribution. An ad-hoc
# signature is identified by the binary's code directory hash, so every rebuild
# looks like a different program to TCC and macOS asks for folder access again.
# A Developer ID signature is a stable identity: the grant is given once.
#
# ---------------------------------------------------------------------------
# Required: a "Developer ID Application" certificate in the keychain.
#   Xcode -> Settings -> Accounts -> Manage Certificates -> + -> Developer ID
#   Application. Requires the Account Holder or Admin role on the team.
#
# Notarization credentials, one of:
#
#   A) A stored notarytool keychain profile (what this repo uses):
#        NOTARY_PROFILE       profile name, defaults to "viberes-notary", the
#                             profile the sibling apps share. Put it in the
#                             gitignored .release.env.
#      Create it once, interactively, in Terminal:
#        xcrun notarytool store-credentials viberes-notary \
#          --key ~/Downloads/AuthKey_XXXXXXXX.p8 \
#          --key-id XXXXXXXX --issuer <issuer-uuid>
#
#   B) An App Store Connect API key:
#        AC_API_KEY_PATH      path to the AuthKey_XXXXXXXX.p8 file
#        AC_API_KEY_ID        the key ID (the XXXXXXXX part)
#        AC_API_ISSUER_ID     the issuer UUID from App Store Connect
#
# Optional environment:
#   DEVELOPMENT_TEAM   Team ID. Derived from the certificate when unset.
#   SIGN_IDENTITY      Defaults to "Developer ID Application", which codesign
#                      resolves against the keychain. Set the full name or the
#                      SHA-1 hash when more than one such certificate exists.
#   SKIP_NOTARIZE=1    Sign and verify only, no Apple round trip. Use this to
#                      confirm the certificate works before spending a
#                      submission (`make signed-app-dry`).
#   OUTPUT_DIR         Where the ZIP lands. Defaults to ./artifacts.
#   DERIVED_DATA       Build directory. Defaults to ./build.
#
# Signing requires network access: --timestamp contacts Apple's timestamp
# authority, and a signature without a secure timestamp fails notarization.
# The first signature after a reboot may ask for the login keychain password
# to use the Developer ID key; answer it on the Mac, it is not scriptable.
# ---------------------------------------------------------------------------

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Local, gitignored: the notarytool profile name, which is personal to whoever
# signs and has no business in a public repository. Values already in the
# environment win.
if [ -f "$REPO_ROOT/.release.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$REPO_ROOT/.release.env"
  set +a
fi

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-viberes-notary}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/artifacts}"
# Apple's notary service is usually under five minutes but has no SLA; queues of
# an hour do happen. Wait long rather than fail a release on their backlog.
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-90m}"
DERIVED_DATA="${DERIVED_DATA:-$REPO_ROOT/build}"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Preflight: fail before spending a build on a broken configuration.
# ---------------------------------------------------------------------------
step "Preflight"

command -v xcodegen >/dev/null || die "xcodegen not found. brew install xcodegen"

VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)"
[ -n "$VERSION" ] || die "could not read MARKETING_VERSION from project.yml"
echo "Version: $VERSION"

# Resolve the signing certificate up front. An ambiguous identity makes
# xcodebuild fail deep inside the build log.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
MATCHES="$(printf '%s\n' "$IDENTITIES" | grep -c "Developer ID Application" || true)"
if [ "$MATCHES" -eq 0 ]; then
  printf '%s\n' "$IDENTITIES" >&2
  die "no 'Developer ID Application' certificate in the keychain.
  Create one: Xcode -> Settings -> Accounts -> Manage Certificates -> + ->
  Developer ID Application."
fi
if [ "$MATCHES" -gt 1 ] && [ "$SIGN_IDENTITY" = "Developer ID Application" ]; then
  printf '%s\n' "$IDENTITIES" >&2
  die "$MATCHES Developer ID Application certificates found, so the identity is
  ambiguous. Set SIGN_IDENTITY to the full name or SHA-1 hash from the list above."
fi

CERT_LINE="$(printf '%s\n' "$IDENTITIES" | grep "Developer ID Application" | head -1)"
echo "Certificate: ${CERT_LINE#*\"}"

# The Team ID is the parenthesised suffix of the certificate common name, e.g.
# "Developer ID Application: Name (ABCDE12345)".
if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
  DEVELOPMENT_TEAM="$(printf '%s\n' "$CERT_LINE" \
    | sed -nE 's/.*\(([A-Z0-9]{10})\)".*/\1/p')"
  [ -n "$DEVELOPMENT_TEAM" ] || die "could not derive the Team ID from the certificate name.
  Set DEVELOPMENT_TEAM explicitly (10 characters, from developer.apple.com -> Membership)."
  echo "Team ID (derived): $DEVELOPMENT_TEAM"
else
  echo "Team ID: $DEVELOPMENT_TEAM"
fi

# Decide how we will talk to the notary service, before building.
NOTARY_ARGS=()
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "Notarization: SKIPPED (SKIP_NOTARIZE=1)"
elif [ -n "${AC_API_KEY_PATH:-}" ]; then
  [ -f "$AC_API_KEY_PATH" ] || die "AC_API_KEY_PATH does not exist: $AC_API_KEY_PATH"
  [ -n "${AC_API_KEY_ID:-}" ] || die "AC_API_KEY_PATH is set but AC_API_KEY_ID is not"
  [ -n "${AC_API_ISSUER_ID:-}" ] || die "AC_API_KEY_PATH is set but AC_API_ISSUER_ID is not"
  NOTARY_ARGS=(--key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID")
  echo "Notarization: App Store Connect API key ($AC_API_KEY_ID)"
else
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "notarytool profile '$NOTARY_PROFILE' not found or not usable.
  Store it once, interactively, in Terminal:
    xcrun notarytool store-credentials $NOTARY_PROFILE \\
      --key AuthKey_XXXXXXXX.p8 --key-id XXXXXXXX --issuer <issuer-uuid>"
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  echo "Notarization: keychain profile '$NOTARY_PROFILE'"
fi

# ---------------------------------------------------------------------------
# 2. Build with the real identity.
#
# Signing during the build rather than re-signing afterwards means the
# signature can never go stale relative to the binary. --timestamp and the
# hardened runtime are both hard requirements for notarization.
#
# CODE_SIGN_STYLE=Manual with no provisioning profile is correct here: a
# Developer ID app that claims no restricted entitlements does not need one.
# ---------------------------------------------------------------------------
step "Build (Release, Developer ID, universal)"

xcodegen generate

BUILD_ARGS=(
  -project ClipShot.xcodeproj
  -scheme ClipShot
  -configuration Release
  -destination 'generic/platform=macOS'
  -derivedDataPath "$DERIVED_DATA"
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY"
  PROVISIONING_PROFILE_SPECIFIER=""
  CODE_SIGNING_REQUIRED=YES
  CODE_SIGNING_ALLOWED=YES
  ENABLE_HARDENED_RUNTIME=YES
  OTHER_CODE_SIGN_FLAGS="--timestamp"
  # Both also pinned in project.yml's Release config, repeated so a release can
  # never be instrumented or carry debug entitlements even if the spec drifts:
  # coverage instrumentation pulls in com.apple.security.get-task-allow, and
  # notarization rejects that outright.
  ENABLE_CODE_COVERAGE=NO
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
  ONLY_ACTIVE_ARCH=NO
)

if command -v xcbeautify >/dev/null; then
  xcodebuild "${BUILD_ARGS[@]}" clean build | xcbeautify
else
  xcodebuild "${BUILD_ARGS[@]}" clean build
fi

APP="$DERIVED_DATA/Build/Products/Release/ClipShot.app"
[ -d "$APP" ] || die "build reported success but $APP does not exist"

# ---------------------------------------------------------------------------
# 2b. Re-sign nested helpers.
#
# Xcode's embed-and-sign phase signs Sparkle.framework itself but leaves its
# contents as shipped: Updater.app, Autoupdate and the two XPC services stay
# ad-hoc, with no team and no secure timestamp (measured on VibeRes). Notarization
# rejects that, and `codesign --verify --deep --strict` does not catch it because
# a valid ad-hoc signature is still a valid signature.
#
# Order matters: innermost first, then the framework, then the app. Signing
# outside-in would seal a hash of contents that are about to change.
# ---------------------------------------------------------------------------
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FRAMEWORK" ]; then
  step "Re-sign nested helpers"

  # Resolve through Versions/Current rather than hardcoding a letter, but refuse
  # anything that resolves outside the framework.
  VERSIONS_DIR="$FRAMEWORK/Versions"
  CURRENT="$(cd "$VERSIONS_DIR/Current" 2>/dev/null && pwd -P || true)"
  [ -n "$CURRENT" ] || die "cannot resolve $VERSIONS_DIR/Current"
  case "$CURRENT" in
    "$(cd "$VERSIONS_DIR" && pwd -P)"/*) : ;;
    *) die "Sparkle version directory resolves outside the framework: $CURRENT" ;;
  esac

  for nested in \
    "$CURRENT/XPCServices/Downloader.xpc" \
    "$CURRENT/XPCServices/Installer.xpc" \
    "$CURRENT/Autoupdate" \
    "$CURRENT/Updater.app" \
    "$CURRENT" \
    "$APP"
  do
    [ -e "$nested" ] || continue
    codesign --force --options runtime --timestamp \
      --sign "$SIGN_IDENTITY" "$nested" \
      || die "failed to re-sign $nested"
    echo "  signed ${nested#"$APP"}"
  done
fi

# ---------------------------------------------------------------------------
# 3. Verify the signature locally. A bad signature costs seconds here and an
#    hour via a rejected notarization.
# ---------------------------------------------------------------------------
step "Verify signature"

codesign --verify --deep --strict --verbose=2 "$APP" \
  || die "codesign verification failed"

# Universal: the cask and the README promise Intel Macs that run macOS 26 too.
ARCHS="$(lipo -archs "$APP/Contents/MacOS/ClipShot")"
[ "$ARCHS" = "x86_64 arm64" ] || die "the app is not universal: lipo -archs says '$ARCHS'"
echo "Architectures: $ARCHS"

# Every signable item, not just the outer bundle: `--verify --deep --strict`
# accepts a valid ad-hoc signature, so it passes locally while Apple rejects the
# upload later.
signable_targets() {
  printf '%s\n' "$APP"
  find "$APP/Contents" \
    \( -name "*.app" -o -name "*.xpc" -o -name "*.framework" \) -print 2>/dev/null
  find "$APP/Contents" -type f -perm -111 ! -name "*.dylib" -print 2>/dev/null \
    | while read -r candidate; do
        # Mach-O only; shell scripts and resources are not separately signed.
        if file -b "$candidate" | grep -q "Mach-O"; then printf '%s\n' "$candidate"; fi
      done
}

checked=0
while IFS= read -r target; do
  [ -n "$target" ] || continue
  label="${target#"$APP"}"
  [ -n "$label" ] || label="ClipShot.app"

  info="$(codesign --display --verbose=4 "$target" 2>&1)" || die "unsigned: $label"

  printf '%s\n' "$info" | grep -q "flags=.*runtime" \
    || die "hardened runtime missing on $label"
  printf '%s\n' "$info" | grep -q "^Timestamp=" \
    || die "no secure timestamp on $label; notarization would reject it"
  printf '%s\n' "$info" | grep -q "^TeamIdentifier=$DEVELOPMENT_TEAM" \
    || die "$label is signed by an unexpected team: $(printf '%s\n' "$info" | grep '^TeamIdentifier=' || echo 'none')
  Upstream frameworks arrive ad-hoc signed; they must be re-signed."
  printf '%s\n' "$info" | grep -q "^Authority=Developer ID Application" \
    || die "$label does not carry a Developer ID Application authority"

  # Debug entitlements are a hard rejection, and the failure arrives minutes
  # later from Apple with no local trace. get-task-allow lets a debugger attach
  # to a signed app and read its memory.
  ents="$(codesign -d --entitlements - --xml "$target" 2>/dev/null || true)"
  for forbidden in \
    com.apple.security.get-task-allow \
    com.apple.security.cs.disable-library-validation \
    com.apple.security.cs.allow-dyld-environment-variables
  do
    if printf '%s' "$ents" | grep -q "$forbidden"; then
      printf '%s' "$ents" | plutil -p - >&2 2>/dev/null || printf '%s\n' "$ents" >&2
      die "$label requests '$forbidden'.
  Notarization rejects this. Check ENABLE_CODE_COVERAGE and
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS for the Release configuration."
    fi
  done

  checked=$((checked + 1))
done <<EOF
$(signable_targets | sort -u)
EOF

[ "$checked" -gt 0 ] || die "no signable targets found under $APP"
codesign --display --verbose=4 "$APP" 2>&1 | grep -E "^(Authority|TeamIdentifier|Timestamp)=|flags=" | head -6
echo "Verified $checked signable target(s): Developer ID, hardened runtime, timestamp, no debug entitlements"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  step "Done (signed, not notarized)"
  echo "App: $APP"
  echo "Re-run without SKIP_NOTARIZE=1 to notarize and package."
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Notarize.
#
# notarytool takes a ZIP for submission, but the ticket is stapled to the .app;
# a ZIP cannot hold one. Hence: zip for submission, staple the app, then zip
# *again* for distribution. Shipping the submission ZIP is the classic mistake:
# it is byte-identical to an unstapled build.
#
# ditto, not zip: it preserves symlinks and resource forks inside the bundle,
# which /usr/bin/zip mangles.
# ---------------------------------------------------------------------------
step "Notarize"

mkdir -p "$OUTPUT_DIR"
SUBMIT_ZIP="$DERIVED_DATA/ClipShot-submit.zip"
# ditto replaces an archive left by an earlier run; nothing is deleted.
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
[ -f "$SUBMIT_ZIP" ] || die "failed to create the submission archive"

set +e
SUBMIT_JSON="$(xcrun notarytool submit "$SUBMIT_ZIP" \
  "${NOTARY_ARGS[@]}" --wait --timeout "$NOTARY_TIMEOUT" --output-format json 2>&1)"
SUBMIT_RC=$?
set -e
printf '%s\n' "$SUBMIT_JSON"

SUBMISSION_ID="$(printf '%s' "$SUBMIT_JSON" \
  | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4)"

# notarytool exits 0 for a *completed* submission even when the verdict is
# Invalid: the exit code reports whether the round trip worked, not whether
# Apple accepted the bundle. Both have to be checked.
SUBMIT_STATUS="$(printf '%s' "$SUBMIT_JSON" \
  | grep -oE '"status"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4)"

if [ "$SUBMIT_RC" -ne 0 ] || [ "$SUBMIT_STATUS" != "Accepted" ]; then
  if [ -n "$SUBMISSION_ID" ]; then
    echo
    echo "--- notarization log for $SUBMISSION_ID ---" >&2
    xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_ARGS[@]}" >&2 || true
  fi
  die "notarization was not accepted (status=${SUBMIT_STATUS:-unknown}, exit $SUBMIT_RC)"
fi
[ -n "$SUBMISSION_ID" ] || die "notarytool succeeded but returned no submission id"
echo "Status: $SUBMIT_STATUS ($SUBMISSION_ID)"

# ---------------------------------------------------------------------------
# 5. Staple and package.
# ---------------------------------------------------------------------------
step "Staple"

xcrun stapler staple "$APP" || die "stapling failed"

# `stapler validate` alone is not proof of stapling: when it finds no ticket in
# the bundle it fetches one from Apple and still reports success. Assert the
# ticket is physically in the bundle (Contents/CodeResources, a CMS blob, not
# Contents/_CodeSignature/CodeResources).
TICKET="$APP/Contents/CodeResources"
[ -s "$TICKET" ] || die "stapler reported success but no ticket at Contents/CodeResources.
  The app would need network access to pass Gatekeeper on first launch."
echo "Ticket embedded: Contents/CodeResources ($(wc -c < "$TICKET" | tr -d ' ') bytes)"

xcrun stapler validate "$APP" || die "stapler validate failed after stapling"

# What Gatekeeper does when a user opens a freshly downloaded app. Only
# meaningful where assessment is enabled; say so rather than imply a check.
if spctl --status 2>&1 | grep -q "assessments enabled"; then
  spctl --assess --type exec --verbose=4 "$APP" || die "Gatekeeper assessment failed"
  echo "Gatekeeper: enforced assessment passed"
else
  spctl --assess --type exec --verbose=4 "$APP" || true
  echo "WARNING: Gatekeeper assessments are disabled on this machine, so the" >&2
  echo "         check above is advisory only." >&2
fi

step "Package"

FINAL_ZIP="$OUTPUT_DIR/ClipShot-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$FINAL_ZIP"
[ -f "$FINAL_ZIP" ] || die "failed to create $FINAL_ZIP"

SHA="$(shasum -a 256 "$FINAL_ZIP" | awk '{print $1}')"

step "Done"
printf 'Artifact  : %s\n' "$FINAL_ZIP"
printf 'Size      : %s\n' "$(du -h "$FINAL_ZIP" | awk '{print $1}')"
printf 'SHA256    : %s\n' "$SHA"
printf 'Submission: %s\n' "$SUBMISSION_ID"
