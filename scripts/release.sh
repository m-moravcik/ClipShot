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
# The release is interactive. sign_update reads the shared EdDSA key from the
# login keychain and macOS asks for access; signing with the Developer ID key may
# ask for the keychain password too. Answer them on the Mac. The appcast is
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

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

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
#   LOCAL_TAG     the "Release X" commit and the tag exist here, not yet pushed
#   PUBLIC_STATE  the last public step that completed
# ---------------------------------------------------------------------------
LOCAL_TAG=""
PUBLIC_STATE=""
on_exit() {
  local rc=$?
  [ "$rc" -ne 0 ] || return 0
  if [ -n "$LOCAL_TAG" ] && [ -z "$PUBLIC_STATE" ]; then
    printf '\n\033[31mrelease stopped before anything was pushed.\033[0m\n' >&2
    echo "The local release commit and tag are still here. Check that origin has neither:" >&2
    echo "  git ls-remote origin refs/tags/$TAG          # expect no output" >&2
    echo "then undo them and run the release again:" >&2
    echo "  git tag -d $TAG" >&2
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

# sign_update ships inside Sparkle's SwiftPM artifact. A fresh checkout (a resume
# on another Mac) resolves the package first; that downloads, it builds nothing.
SIGN_UPDATE=""
find_sign_update() {
  SIGN_UPDATE="$(find "$DERIVED_DATA/SourcePackages/artifacts" -name sign_update -type f -perm +111 -print -quit 2>/dev/null || true)"
  if [ -z "$SIGN_UPDATE" ]; then
    xcodegen generate >/dev/null
    xcodebuild -resolvePackageDependencies -project ClipShot.xcodeproj -scheme ClipShot \
      -derivedDataPath "$DERIVED_DATA" >/dev/null
    SIGN_UPDATE="$(find "$DERIVED_DATA/SourcePackages/artifacts" -name sign_update -type f -perm +111 -print -quit 2>/dev/null || true)"
  fi
  [ -n "$SIGN_UPDATE" ] || die "sign_update not found under $DERIVED_DATA"
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

find_sign_update

if [ -z "$RESUME" ]; then
  # -------------------------------------------------------------------------
  # 2. Build, sign, notarize, staple, package.
  # -------------------------------------------------------------------------
  step "Build, sign and notarize"

  NOTARY_PROFILE="$NOTARY_PROFILE" scripts/release-signed.sh
  [ -f "$ZIP" ] || die "release-signed.sh produced no $ZIP"
  find_sign_update

  # -------------------------------------------------------------------------
  # 3. Verify what will be published: the built app, and the app inside the ZIP.
  #    Output is captured and then matched, never piped into `grep -q`: under
  #    pipefail an early grep exit fails the pipeline through SIGPIPE.
  # -------------------------------------------------------------------------
  step "Verify the artifact"

  ARCHS="$(lipo -archs "$APP/Contents/MacOS/ClipShot")"
  [ "$ARCHS" = "x86_64 arm64" ] || die "not universal: lipo -archs says '$ARCHS'"
  echo "lipo: $ARCHS"

  ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
  if [[ "$ENTITLEMENTS" == *get-task-allow* ]]; then die "the app carries get-task-allow"; fi
  echo "entitlements: no get-task-allow"

  UNPACKED="$(mktemp -d "${TMPDIR:-/tmp}/clipshot-release.XXXXXX")"
  ditto -x -k "$ZIP" "$UNPACKED"
  for app in "$APP" "$UNPACKED/ClipShot.app"; do
    assessment="$(spctl -a -vv "$app" 2>&1 || true)"
    printf '%s\n' "$assessment"
    [[ "$assessment" == *"source=Notarized Developer ID"* ]] \
      || die "Gatekeeper does not see $app as notarized Developer ID"
    xcrun stapler validate "$app" || die "no valid stapled ticket on $app"
  done

  # -------------------------------------------------------------------------
  # 4. Rehearse the appcast on the local ZIP. The asset GitHub serves later is
  #    compared byte for byte with this ZIP, so a feed that builds and verifies
  #    here will build and verify then. Keychain prompts come up now.
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
  git tag -a "$TAG" -m "ClipShot $VERSION"
  LOCAL_TAG="yes"
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
if [ -f "$ZIP" ]; then
  cmp -s "$PUBLISHED" "$ZIP" || die "the downloaded asset differs from $ZIP"
  echo "the published asset is byte for byte the ZIP that was verified"
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
# 9. Homebrew cask: version and sha256, audit, push.
# ---------------------------------------------------------------------------
step "Homebrew cask"

SHA="$(shasum -a 256 "$PUBLIC_ZIP" | awk '{print $1}')"
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
