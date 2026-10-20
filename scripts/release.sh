#!/usr/bin/env bash
#
# Publish a ClipShot release from this Mac, end to end: checks, signed and
# notarized build, tag, GitHub release, appcast, Homebrew cask.
#
#   scripts/release.sh
#
# Releases run locally; there is no CI on this account. The version is
# MARKETING_VERSION in project.yml, and its notes are release-notes/<version>.md
# (the GitHub release body and the text in Sparkle's update window). Bump both
# on main and commit them before running this.
#
# The release is interactive. The first sign_update reads the shared EdDSA key
# from the login keychain and macOS asks for access; signing with the Developer ID
# key may ask for the keychain password too. Answer them on the Mac.
#
# Everything public happens after every local check has passed: nothing is
# tagged, pushed or uploaded before the signed, notarized, stapled build has been
# verified. If a later step fails, the script says what is already public and
# what to do next.
#
# Environment:
#   NOTARY_PROFILE   notarytool keychain profile (from the gitignored .release.env)
#   TAP_DIR          the Homebrew tap working copy, default ~/Projects/homebrew-clipshot

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [ -f "$REPO_ROOT/.release.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$REPO_ROOT/.release.env"
  set +a
fi

NOTARY_PROFILE="${NOTARY_PROFILE:-viberes-notary}"
REPO="m-moravcik/ClipShot"
TAP_NAME="m-moravcik/clipshot"
TAP_DIR="${TAP_DIR:-$HOME/Projects/homebrew-clipshot}"
CASK="$TAP_DIR/Casks/clipshot.rb"
DERIVED_DATA="$REPO_ROOT/build"
APP="$DERIVED_DATA/Build/Products/Release/ClipShot.app"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# Set once something is public, so a failure says where the release stopped.
PUBLIC_STATE=""
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -n "$PUBLIC_STATE" ]; then
    printf '\n\033[31mrelease stopped after: %s\033[0m\n' "$PUBLIC_STATE" >&2
    echo "Nothing is rolled back. Fix the cause and finish the remaining steps by hand" >&2
    echo "(see the steps below this point in scripts/release.sh)." >&2
  fi
}
trap on_exit EXIT

VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)"
[ -n "$VERSION" ] || die "could not read MARKETING_VERSION from project.yml"
TAG="v$VERSION"
NOTES="release-notes/$VERSION.md"
ASSET="ClipShot-$VERSION.zip"
ZIP="artifacts/$ASSET"

# ---------------------------------------------------------------------------
# 1. Preflight: everything that can fail without anything becoming public.
# ---------------------------------------------------------------------------
step "Preflight ($VERSION)"

for tool in gh git xcodegen brew curl python3 shasum; do
  command -v "$tool" >/dev/null || die "$tool not found"
done

[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || die "not on main"
[ -z "$(git status --porcelain)" ] || die "the working tree is not clean"
git fetch --quiet origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
  || die "main is not the same commit as origin/main; push or pull first"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then die "tag $TAG exists locally"; fi
if [ -n "$(git ls-remote --tags origin "refs/tags/$TAG")" ]; then die "tag $TAG exists on origin"; fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then die "GitHub release $TAG exists"; fi

[ -s "$NOTES" ] || die "no release notes at $NOTES"
if grep -q $'\xe2\x80\x94' "$NOTES"; then die "$NOTES contains an em dash"; fi

# Sparkle carries no GitHub credentials: on a private repository the feed and the
# asset answer 404 and every update check fails quietly.
[ "$(gh repo view "$REPO" --json visibility --jq .visibility)" = "PUBLIC" ] \
  || die "$REPO is not public; updates cannot reach the feed or the asset"

[ -f "$CASK" ] || die "no cask at $CASK (TAP_DIR=$TAP_DIR)"
[ -z "$(git -C "$TAP_DIR" status --porcelain)" ] || die "the tap working copy is not clean: $TAP_DIR"
git -C "$TAP_DIR" remote get-url origin >/dev/null 2>&1 || die "the tap has no origin remote: $TAP_DIR"

make test l10n guards

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notarytool profile '$NOTARY_PROFILE' is not usable (see scripts/release-signed.sh)"

# ---------------------------------------------------------------------------
# 2. Build, sign, notarize, staple, package.
# ---------------------------------------------------------------------------
step "Build, sign and notarize"

NOTARY_PROFILE="$NOTARY_PROFILE" scripts/release-signed.sh
[ -f "$ZIP" ] || die "release-signed.sh produced no $ZIP"

# ---------------------------------------------------------------------------
# 3. Verify what will be published: the built app, and the app inside the ZIP.
# ---------------------------------------------------------------------------
step "Verify the artifact"

ARCHS="$(lipo -archs "$APP/Contents/MacOS/ClipShot")"
[ "$ARCHS" = "x86_64 arm64" ] || die "not universal: lipo -archs says '$ARCHS'"
echo "lipo: $ARCHS"

if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  die "the app carries get-task-allow"
fi
echo "entitlements: no get-task-allow"

UNPACKED="$(mktemp -d "${TMPDIR:-/tmp}/clipshot-release.XXXXXX")"
ditto -x -k "$ZIP" "$UNPACKED"
for app in "$APP" "$UNPACKED/ClipShot.app"; do
  # Captured, not piped into grep -q: under pipefail an early grep exit would fail
  # the pipeline through SIGPIPE although the line was there.
  assessment="$(spctl -a -vv "$app" 2>&1 || true)"
  printf '%s\n' "$assessment"
  printf '%s\n' "$assessment" | grep -q "source=Notarized Developer ID" \
    || die "Gatekeeper does not see $app as notarized Developer ID"
  xcrun stapler validate "$app" || die "no valid stapled ticket on $app"
done

# ---------------------------------------------------------------------------
# 4. Tag and push. From here on, things are public.
# ---------------------------------------------------------------------------
step "Tag $TAG"

# The tree is clean, so the release commit is empty: it marks what was built.
git commit --allow-empty -m "Release $VERSION"
git tag -a "$TAG" -m "ClipShot $VERSION"
# Atomic: the release commit lands on main together with its tag, or neither does.
git push --atomic origin main "refs/tags/$TAG"
PUBLIC_STATE="tag $TAG pushed"

# ---------------------------------------------------------------------------
# 5. GitHub release with the stapled ZIP.
# ---------------------------------------------------------------------------
step "GitHub release"

gh release create "$TAG" "$ZIP" --repo "$REPO" --verify-tag \
  --title "ClipShot $VERSION" --notes-file "$NOTES"
PUBLIC_STATE="GitHub release $TAG published"

# ---------------------------------------------------------------------------
# 6. Appcast from the asset as GitHub serves it.
# ---------------------------------------------------------------------------
step "Appcast"

DOWNLOAD="$(mktemp -d "${TMPDIR:-/tmp}/clipshot-asset.XXXXXX")"
gh release download "$TAG" --repo "$REPO" --pattern "$ASSET" --dir "$DOWNLOAD"
PUBLISHED="$DOWNLOAD/$ASSET"
cmp -s "$PUBLISHED" "$ZIP" || die "the downloaded asset differs from $ZIP"

scripts/make-appcast.sh "$PUBLISHED"

SIGN_UPDATE="$(find "$DERIVED_DATA/SourcePackages/artifacts" -name sign_update -type f -perm +111 | head -1)"
[ -n "$SIGN_UPDATE" ] || die "sign_update not found under $DERIVED_DATA"
FEED_SIG="$(python3 -I -c 'import re,sys; print(re.search(r"sparkle:edSignature=\"([^\"]+)\"", open(sys.argv[1]).read()).group(1))' appcast.xml)"
"$SIGN_UPDATE" --verify "$PUBLISHED" "$FEED_SIG" \
  || die "the appcast signature does not verify against the published asset"
echo "appcast signature verifies against the published asset"

step "Publish the appcast"

git add appcast.xml
git commit -m "Publish appcast for $VERSION"
git push origin main
PUBLIC_STATE="appcast for $VERSION pushed to main"

# ---------------------------------------------------------------------------
# 7. Smoke check: fetch the feed and the asset the way a user's copy of
#    ClipShot will, and verify the pairing. Everything before tested our own
#    bytes; this tests what GitHub serves. (Ported from VibeRes's release.yml.)
# ---------------------------------------------------------------------------
step "Smoke-check the published feed"

FEED=""
for attempt in 1 2 3 4 5 6; do
  FEED="$(curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/appcast.xml?$(date +%s)" || true)"
  printf '%s' "$FEED" | grep -q "$ASSET" && break
  echo "feed not updated yet (attempt $attempt); raw.githubusercontent caches briefly"
  sleep 10
done
printf '%s' "$FEED" | grep -q "$ASSET" || die "the published feed does not reference $VERSION"

SIG="$(printf '%s' "$FEED" | python3 -I -c 'import re,sys; print(re.search(r"sparkle:edSignature=\"([^\"]+)\"", sys.stdin.read()).group(1))')"
LEN="$(printf '%s' "$FEED" | python3 -I -c 'import re,sys; print(re.search(r"length=\"(\d+)\"", sys.stdin.read()).group(1))')"

PUBLIC_ZIP="$DOWNLOAD/public-$ASSET"
curl -fsSL -o "$PUBLIC_ZIP" "https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"
ACTUAL="$(stat -f%z "$PUBLIC_ZIP")"
[ "$ACTUAL" = "$LEN" ] || die "the feed says $LEN bytes, the asset is $ACTUAL"
"$SIGN_UPDATE" --verify "$PUBLIC_ZIP" "$SIG" \
  || die "the public feed does not verify against the public asset"
echo "public feed and public asset agree ($LEN bytes)"

# ---------------------------------------------------------------------------
# 8. Homebrew cask: version and sha256, audit, push.
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
git -C "$TAP_DIR" commit -m "clipshot ${VERSION}"

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
