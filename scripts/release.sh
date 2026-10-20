#!/usr/bin/env bash
#
# Publish a ClipShot release from this Mac, end to end: checks, signed and
# notarized build, tag, GitHub release, appcast, Homebrew cask.
#
#   scripts/release.sh                         a full release
#   scripts/release.sh --resume-from appcast   finish one whose tag and GitHub
#                                              release are already public
#
# Releases run locally; there is no CI on this account. The version is
# MARKETING_VERSION in project.yml, the build number CURRENT_PROJECT_VERSION, and
# the notes are release-notes/<version>.md (the GitHub release body and the text
# in Sparkle's update window). Bump them on main and commit before running this.
#
# The release is interactive. Sparkle's sign_update and generate_keys read the
# shared EdDSA key from the login keychain and macOS asks for access; signing with
# the Developer ID key may ask for the keychain password too. Both Sparkle tools
# are checked against pinned SHA-256 hashes (scripts/sparkle-tools.sh) before they
# run, and the key they find must be the SUPublicEDKey the app ships. Answer them on the Mac. The appcast is
# rehearsed before anything is public, so those prompts, and any appcast or key
# problem, come up while nothing is out yet.
#
# Everything public happens after every local check has passed. If a later step
# fails, the script says what is already public and how to finish or undo.
#
# Environment:
#   NOTARY_PROFILE                  notarytool keychain profile (.release.env)
#   SPARKLE_EDDSA_PRIVATE_KEY_PATH  EdDSA key file instead of the keychain
#   TAP_DIR                         the Homebrew tap working copy,
#                                   default ~/Projects/homebrew-clipshot
#   TEAM_ID                         the Developer ID team releases are signed by

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# shellcheck source=scripts/sparkle-tools.sh
. "$REPO_ROOT/scripts/sparkle-tools.sh"

RESUME=""
case "${1:-}" in
  "") ;;
  --resume-from)
    [ "${2:-}" = "appcast" ] || die "usage: $0 [--resume-from appcast]"
    RESUME="appcast" ;;
  *) die "usage: $0 [--resume-from appcast]" ;;
esac

if [ -f "$REPO_ROOT/.release.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$REPO_ROOT/.release.env"
  set +a
fi
# A release always notarizes, whatever the shell it was started from had set.
unset SKIP_NOTARIZE

NOTARY_PROFILE="${NOTARY_PROFILE:-viberes-notary}"
REPO="m-moravcik/ClipShot"
TAP_NAME="m-moravcik/clipshot"
TAP_DIR="${TAP_DIR:-$HOME/Projects/homebrew-clipshot}"
CASK="$TAP_DIR/Casks/clipshot.rb"
DERIVED_DATA="$REPO_ROOT/build"
APP="$DERIVED_DATA/Build/Products/Release/ClipShot.app"
BUNDLE_ID="sk.moravcik.ClipShot"
# The command line tool's signing identifier (Contents/Helpers/clipshot).
CLI_ID="sk.moravcik.ClipShot.cli"
# The team in the Developer ID certificate that signs ClipShot (and its siblings).
# Fixed here rather than read from the keychain, so a resume on a Mac without the
# certificate still knows whose signature to expect.
TEAM_ID="${TEAM_ID:-7TM9VA58W5}"

# Empty when the key comes from the keychain. Always expanded as
# ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}: /bin/bash on macOS is 3.2, where an empty
# "${SIGN_ARGS[@]}" is an unbound-variable error under `set -u`.
SIGN_ARGS=()
if [ -n "${SPARKLE_EDDSA_PRIVATE_KEY_PATH:-}" ]; then
  [ -f "$SPARKLE_EDDSA_PRIVATE_KEY_PATH" ] || die "key file missing: $SPARKLE_EDDSA_PRIVATE_KEY_PATH"
  SIGN_ARGS=(--ed-key-file "$SPARKLE_EDDSA_PRIVATE_KEY_PATH")
fi

VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)"
BUILD="$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)"
[ -n "$VERSION" ] && [ -n "$BUILD" ] || die "could not read the version numbers from project.yml"
TAG="v$VERSION"
NOTES="release-notes/$VERSION.md"
ASSET="ClipShot-$VERSION.zip"
ZIP="artifacts/$ASSET"

# ---------------------------------------------------------------------------
# Where the release stands, for the message on a failure.
#   LOCAL_TAG     "commit": the "Release X" commit exists here; "tag": the tag
#                 too. Neither pushed yet.
#   PUBLIC_STATE  the last public step that completed
# ---------------------------------------------------------------------------
LOCAL_TAG=""
PUBLIC_STATE=""
on_exit() {
  local rc=$?
  [ "$rc" -ne 0 ] || return 0
  if [ -n "$LOCAL_TAG" ] && [ -z "$PUBLIC_STATE" ]; then
    printf '\n\033[31mrelease stopped before anything was pushed.\033[0m\n' >&2
    if [ "$LOCAL_TAG" = "tag" ]; then
      echo "The local release commit and tag are still here. Check that origin has neither:" >&2
      echo "  git ls-remote origin refs/tags/$TAG          # expect no output" >&2
      echo "then undo them and run the release again:" >&2
      echo "  git tag -d $TAG" >&2
    else
      echo "The empty \"Release $VERSION\" commit was made, but no tag. Undo it and run the" >&2
      echo "release again:" >&2
    fi
    echo "  git reset --soft HEAD~1                      # drops the empty \"Release $VERSION\" commit" >&2
  elif [ -n "$PUBLIC_STATE" ]; then
    printf '\n\033[31mrelease stopped after: %s\033[0m\n' "$PUBLIC_STATE" >&2
    echo "Nothing public is rolled back." >&2
    case "$PUBLIC_STATE" in
      "tag $TAG pushed")
        echo "Publish the GitHub release, then finish with --resume-from appcast:" >&2
        echo "  gh release create $TAG $ZIP --repo $REPO --verify-tag --title \"ClipShot $VERSION\" --notes-file $NOTES" >&2
        echo "  scripts/release.sh --resume-from appcast" >&2 ;;
      *)
        echo "Fix the cause, then finish with:" >&2
        echo "  scripts/release.sh --resume-from appcast" >&2 ;;
    esac
  fi
}
trap on_exit EXIT

# sign_update and generate_keys ship inside Sparkle's SwiftPM artifact. A fresh
# checkout (a resume on another Mac) resolves the package first, only at the
# revision the committed Package.resolved pins; that downloads, it builds
# nothing. Either way each binary must match its pinned hash before it runs.
SIGN_UPDATE=""
GENERATE_KEYS=""
find_sparkle_tools() {
  if [ -z "$(find "$DERIVED_DATA/SourcePackages/artifacts" -name sign_update -type f -print -quit 2>/dev/null || true)" ]; then
    xcodegen generate >/dev/null
    xcodebuild -resolvePackageDependencies -project ClipShot.xcodeproj -scheme ClipShot \
      -derivedDataPath "$DERIVED_DATA" -onlyUsePackageVersionsFromResolvedFile \
      -disableAutomaticPackageResolution >/dev/null
  fi
  SIGN_UPDATE="$(sparkle_tool sign_update "$DERIVED_DATA")"
  GENERATE_KEYS="$(sparkle_tool generate_keys "$DERIVED_DATA")"
}

# Everything a published app must be, checked on one bundle; refuses on any
# mismatch. Output is captured and then matched, never piped into `grep -q`:
# under pipefail an early grep exit fails the pipeline through SIGPIPE.
verify_app() {
  local app="$1" archs info entitlements assessment plist value cli cli_archs
  [ -d "$app" ] || die "no app at $app"
  # Sparkle installs whatever bundle in the archive carries ClipShot's name or
  # bundle id, and does not compare versions: pin all three.
  plist="$app/Contents/Info.plist"
  value="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null || true)"
  [ "$value" = "$BUNDLE_ID" ] || die "$app has bundle id '$value', expected $BUNDLE_ID"
  value="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null || true)"
  [ "$value" = "$VERSION" ] || die "$app is version '$value', expected $VERSION"
  value="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist" 2>/dev/null || true)"
  [ "$value" = "$BUILD" ] || die "$app is build '$value', expected $BUILD"
  # The key installed copies will trust from this version on: the one checked
  # against the signing key in the preflight.
  value="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$plist" 2>/dev/null || true)"
  [ "$value" = "$(shipped_public_key)" ] || die "$app ships SUPublicEDKey '$value', expected $(shipped_public_key)"
  archs="$(lipo -archs "$app/Contents/MacOS/ClipShot" 2>&1 || true)"
  [ "$archs" = "x86_64 arm64" ] || die "$app is not universal: lipo -archs says '$archs'"
  info="$(codesign -dv --verbose=4 "$app" 2>&1 || true)"
  grep -qx "TeamIdentifier=$TEAM_ID" <<<"$info" \
    || die "$app is not signed by team $TEAM_ID: $(grep '^TeamIdentifier=' <<<"$info" || echo 'no team')"
  entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
  if [[ "$entitlements" == *get-task-allow* ]]; then die "$app carries get-task-allow"; fi
  assessment="$(spctl -a -vv "$app" 2>&1 || true)"
  printf '%s\n' "$assessment"
  [[ "$assessment" == *"source=Notarized Developer ID"* ]] \
    || die "Gatekeeper does not see $app as notarized Developer ID"
  xcrun stapler validate "$app" || die "no valid stapled ticket on $app"
  # The command line tool inside: the same team, its own identifier, the hardened
  # runtime, universal, and the app's version. Checked before it is run.
  cli="$app/Contents/Helpers/clipshot"
  [ -f "$cli" ] || die "$app has no command line tool at Contents/Helpers/clipshot"
  cli_archs="$(lipo -archs "$cli" 2>&1 || true)"
  [ "$cli_archs" = "x86_64 arm64" ] || die "clipshot in $app is not universal: lipo -archs says '$cli_archs'"
  codesign --verify --strict "$cli" 2>/dev/null || die "clipshot in $app does not verify"
  info="$(codesign -dv --verbose=4 "$cli" 2>&1 || true)"
  grep -qx "TeamIdentifier=$TEAM_ID" <<<"$info" \
    || die "clipshot in $app is not signed by team $TEAM_ID: $(grep '^TeamIdentifier=' <<<"$info" || echo 'no team')"
  grep -qx "Identifier=$CLI_ID" <<<"$info" || die "clipshot in $app is not signed as $CLI_ID"
  grep -q "flags=.*runtime" <<<"$info" || die "clipshot in $app lacks the hardened runtime"
  grep -q "^Authority=Developer ID Application" <<<"$info" || die "clipshot in $app has no Developer ID authority"
  entitlements="$(codesign -d --entitlements - --xml "$cli" 2>/dev/null || true)"
  if [[ "$entitlements" == *get-task-allow* ]]; then die "clipshot in $app carries get-task-allow"; fi
  value="$("$cli" --version 2>/dev/null || true)"
  [ "$value" = "$VERSION" ] || die "clipshot in $app says version '$value', expected $VERSION"
  echo "verified: $BUNDLE_ID $VERSION ($BUILD), $archs, team $TEAM_ID, EdDSA key, no get-task-allow, notarized and stapled; clipshot $value signed as $CLI_ID"
}

# A release archive: unpacked into a temp folder, its top level must be exactly
# ClipShot.app (ditto --keepParent writes nothing else, so anything more, a
# __MACOSX folder included, is refused), and that app must pass verify_app.
verify_archive() {
  local zip="$1" dir entries
  dir="$(mktemp -d "${TMPDIR:-/tmp}/clipshot-archive.XXXXXX")"
  ditto -x -k "$zip" "$dir" || die "could not unpack $zip"
  entries="$(ls -A "$dir")"
  [ "$entries" = "ClipShot.app" ] \
    || die "$zip must hold exactly ClipShot.app at its top level, it holds: $(tr '\n' ' ' <<<"$entries")"
  verify_app "$dir/ClipShot.app"
}

# The highest sparkle:version in a feed file, or nothing when it has no items.
highest_build() {
  python3 -I -c '
import re, sys
found = [int(v) for v in re.findall(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>", open(sys.argv[1]).read())]
print(max(found) if found else "")
' "$1"
}

# ---------------------------------------------------------------------------
# 1. Preflight: everything that can fail without anything becoming public.
# ---------------------------------------------------------------------------
step "Preflight ($VERSION, build $BUILD${RESUME:+, resuming from the appcast})"

for tool in gh git xcodegen brew curl python3 shasum; do
  command -v "$tool" >/dev/null || die "$tool not found"
done
[[ "$BUILD" =~ ^[0-9]+$ ]] || die "CURRENT_PROJECT_VERSION must be a whole number for Sparkle, not '$BUILD'"

[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || die "not on main"
[ -z "$(git status --porcelain)" ] || die "the working tree is not clean"
git fetch --quiet origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
  || die "main is not the same commit as origin/main; push or pull first"

[ -s "$NOTES" ] || die "no release notes at $NOTES"
if grep -q $'\xe2\x80\x94' "$NOTES"; then die "$NOTES contains an em dash"; fi

# Sparkle carries no GitHub credentials: on a private repository the feed and the
# asset answer 404 and every update check fails quietly.
[ "$(gh repo view "$REPO" --json visibility --jq .visibility)" = "PUBLIC" ] \
  || die "$REPO is not public; updates cannot reach the feed or the asset"

[ -f "$CASK" ] || die "no cask at $CASK (TAP_DIR=$TAP_DIR)"
[ -z "$(git -C "$TAP_DIR" status --porcelain)" ] || die "the tap working copy is not clean: $TAP_DIR"
git -C "$TAP_DIR" remote get-url origin >/dev/null 2>&1 || die "the tap has no origin remote: $TAP_DIR"

PUBLISHED_BUILD=""
[ -f appcast.xml ] && PUBLISHED_BUILD="$(highest_build appcast.xml)"

if [ -z "$RESUME" ]; then
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then die "tag $TAG exists locally"; fi
  if [ -n "$(git ls-remote --tags origin "refs/tags/$TAG")" ]; then die "tag $TAG exists on origin"; fi
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then die "GitHub release $TAG exists"; fi

  # Sparkle offers an update only when its build number is higher than the one
  # installed. A build number that did not go up publishes an update nobody gets.
  if [ -n "$PUBLISHED_BUILD" ] && [ "$BUILD" -le "$PUBLISHED_BUILD" ]; then
    die "CURRENT_PROJECT_VERSION $BUILD is not above build $PUBLISHED_BUILD in appcast.xml"
  fi

  make test l10n guards

  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "notarytool profile '$NOTARY_PROFILE' is not usable (see scripts/release-signed.sh)"
else
  # Resuming: the tag and the release must already be public, with the asset.
  [ -n "$(git ls-remote --tags origin "refs/tags/$TAG")" ] || die "tag $TAG is not on origin; run a full release"
  ASSETS="$(gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name' 2>/dev/null || true)"
  grep -qx "$ASSET" <<<"$ASSETS" || die "GitHub release $TAG has no $ASSET; publish it first"
  if [ -n "$PUBLISHED_BUILD" ] && [ "$BUILD" -lt "$PUBLISHED_BUILD" ]; then
    die "appcast.xml already has build $PUBLISHED_BUILD, above this release's $BUILD"
  fi
  PUBLIC_STATE="GitHub release $TAG published (resumed)"
fi

find_sparkle_tools
# Before anything is built or public: the key that will sign is the key every
# installed copy checks updates against.
check_signing_key

if [ -z "$RESUME" ]; then
  # -------------------------------------------------------------------------
  # 2. Build, sign, notarize, staple, package.
  # -------------------------------------------------------------------------
  step "Build, sign and notarize"

  NOTARY_PROFILE="$NOTARY_PROFILE" scripts/release-signed.sh
  [ -f "$ZIP" ] || die "release-signed.sh produced no $ZIP"
  find_sparkle_tools

  # -------------------------------------------------------------------------
  # 3. Verify what will be published: the built app, and the app inside the ZIP.
  #    Output is captured and then matched, never piped into `grep -q`: under
  #    pipefail an early grep exit fails the pipeline through SIGPIPE.
  # -------------------------------------------------------------------------
  step "Verify the artifact"

  verify_app "$APP"
  verify_archive "$ZIP"

  # -------------------------------------------------------------------------
  # 4. Rehearse the appcast on the local ZIP. The asset GitHub serves later is
  #    compared byte for byte with this ZIP, so a feed that builds and verifies
  #    here will build and verify then. Keychain prompts come up now, and
  #    make-appcast.sh checks the signing key against SUPublicEDKey again.
  # -------------------------------------------------------------------------
  step "Rehearse the appcast"

  REHEARSAL="$(mktemp -d "${TMPDIR:-/tmp}/clipshot-appcast.XXXXXX")"
  scripts/make-appcast.sh "$ZIP" "$REHEARSAL/appcast.xml"
  echo "rehearsal feed and enclosure verify; nothing is public yet"

  # -------------------------------------------------------------------------
  # 5. Tag and push. From here on, things are public.
  # -------------------------------------------------------------------------
  step "Tag $TAG"

  # The tree is clean, so the release commit is empty: it marks what was built.
  git commit --allow-empty -m "Release $VERSION"
  LOCAL_TAG="commit"
  git tag -a "$TAG" -m "ClipShot $VERSION"
  LOCAL_TAG="tag"
  # Atomic: the release commit lands on main together with its tag, or neither does.
  git push --atomic origin main "refs/tags/$TAG"
  PUBLIC_STATE="tag $TAG pushed"

  # -------------------------------------------------------------------------
  # 6. GitHub release with the stapled ZIP.
  # -------------------------------------------------------------------------
  step "GitHub release"

  gh release create "$TAG" "$ZIP" --repo "$REPO" --verify-tag \
    --title "ClipShot $VERSION" --notes-file "$NOTES"
  PUBLIC_STATE="GitHub release $TAG published"
fi

# ---------------------------------------------------------------------------
# 7. Appcast from the asset as GitHub serves it.
# ---------------------------------------------------------------------------
step "Appcast"

DOWNLOAD="$(mktemp -d "${TMPDIR:-/tmp}/clipshot-asset.XXXXXX")"
gh release download "$TAG" --repo "$REPO" --pattern "$ASSET" --dir "$DOWNLOAD"
PUBLISHED="$DOWNLOAD/$ASSET"
# Nothing is signed into the feed unverified. In every mode the asset GitHub
# serves is unpacked and checked in full (verify_archive). When the local ZIP is
# still here, it must also be byte for byte that ZIP: an extra check, never a
# replacement.
verify_archive "$PUBLISHED"
if [ -f "$ZIP" ]; then
  cmp -s "$PUBLISHED" "$ZIP" || die "the downloaded asset differs from $ZIP"
  echo "the published asset is byte for byte the local ZIP"
fi

# Builds the feed from the published bytes, signs it, and verifies the enclosure
# signature against the asset and the feed's own signature.
scripts/make-appcast.sh "$PUBLISHED"

step "Publish the appcast"

git add appcast.xml
if git diff --cached --quiet; then
  echo "appcast.xml unchanged"
else
  git commit -m "Publish appcast for $VERSION"
fi
git push origin main
PUBLIC_STATE="appcast for $VERSION pushed to main"

# ---------------------------------------------------------------------------
# 8. Smoke check: fetch the feed and the asset the way a user's copy of
#    ClipShot will, and verify the pairing and the feed signature. Everything
#    before tested our own bytes; this tests what GitHub serves. (Ported from
#    VibeRes's release.yml.)
# ---------------------------------------------------------------------------
step "Smoke-check the published feed"

PUBLIC_FEED="$DOWNLOAD/public-appcast.xml"
found=""
for attempt in 1 2 3 4 5 6; do
  if curl -fsSL -o "$PUBLIC_FEED" "https://raw.githubusercontent.com/${REPO}/main/appcast.xml?$(date +%s)" \
    && grep -q "$ASSET" "$PUBLIC_FEED"; then
    found="yes"
    break
  fi
  echo "feed not updated yet (attempt $attempt); raw.githubusercontent caches briefly"
  sleep 10
done
[ -n "$found" ] || die "the published feed does not reference $VERSION"

"$SIGN_UPDATE" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} --verify "$PUBLIC_FEED" \
  || die "the published feed's own signature does not verify"

SIG="$(python3 -I -c 'import re,sys; print(re.search(r"sparkle:edSignature=\"([^\"]+)\"", open(sys.argv[1]).read()).group(1))' "$PUBLIC_FEED")"
LEN="$(python3 -I -c 'import re,sys; print(re.search(r"length=\"(\d+)\"", open(sys.argv[1]).read()).group(1))' "$PUBLIC_FEED")"

PUBLIC_ZIP="$DOWNLOAD/public-$ASSET"
curl -fsSL -o "$PUBLIC_ZIP" "https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"
ACTUAL="$(stat -f%z "$PUBLIC_ZIP")"
[ "$ACTUAL" = "$LEN" ] || die "the feed says $LEN bytes, the asset is $ACTUAL"
"$SIGN_UPDATE" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} --verify "$PUBLIC_ZIP" "$SIG" \
  || die "the public feed does not verify against the public asset"
echo "public feed signed, and it agrees with the public asset ($LEN bytes)"

# ---------------------------------------------------------------------------
# 9. Homebrew cask: the reference copy with version and sha256, audit, push.
# ---------------------------------------------------------------------------
step "Homebrew cask"

SHA="$(shasum -a 256 "$PUBLIC_ZIP" | awk '{print $1}')"
# The reference copy in Casks/ is the cask: its stanzas (the app, the clipshot
# binary, uninstall and zap) go to the tap as reviewed here, with this release's
# version and sha256 written into them.
cp Casks/clipshot.rb "$CASK"
sed -E -i '' \
  -e "s|^  version \"[^\"]+\"|  version \"${VERSION}\"|" \
  -e "s|^  sha256 \"[a-f0-9]{64}\"|  sha256 \"${SHA}\"|" \
  "$CASK"
if ! grep -q "version \"${VERSION}\"" "$CASK" || ! grep -q "sha256 \"${SHA}\"" "$CASK"; then
  die "could not update version and sha256 in $CASK"
fi
git -C "$TAP_DIR" add Casks/clipshot.rb
if git -C "$TAP_DIR" diff --cached --quiet; then
  echo "the cask is already at $VERSION"
else
  git -C "$TAP_DIR" commit -m "clipshot ${VERSION}"
fi

# brew audits casks by name only, from a tapped copy. Tap the working copy (or
# bring an existing tap up to it), audit, then point the tap back at GitHub.
TAPPED="$(brew --repository)/Library/Taps/m-moravcik/homebrew-clipshot"
if [ -d "$TAPPED" ]; then
  git -C "$TAPPED" pull --ff-only "$TAP_DIR" main
else
  brew tap "$TAP_NAME" "$TAP_DIR"
fi
# Not --new: that adds homebrew/cask's notability rule (75 stars and the like),
# which a personal tap fails by design. --online still downloads the asset and
# checks it against the sha256 just written.
brew audit --cask --strict --online "$TAP_NAME/clipshot"
brew style --cask "$TAP_NAME/clipshot"

git -C "$TAP_DIR" push origin main
git -C "$TAPPED" remote set-url origin "https://github.com/m-moravcik/homebrew-clipshot"
PUBLIC_STATE="cask clipshot ${VERSION} pushed"

step "Done"
echo "ClipShot $VERSION is out:"
echo "  https://github.com/${REPO}/releases/tag/${TAG}"
echo "  brew install --cask ${TAP_NAME}/clipshot"
echo
echo "Check it as a user would:"
echo "  brew update && brew install --cask ${TAP_NAME}/clipshot"
echo "  spctl -a -vv /Applications/ClipShot.app    # source=Notarized Developer ID"
