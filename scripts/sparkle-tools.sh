# shellcheck shell=bash
#
# Sparkle's release tools, checked before they touch the signing key. Sourced by
# scripts/release.sh and scripts/make-appcast.sh; it expects their `die`.
#
# sign_update and generate_keys come from Sparkle's SwiftPM artifact
# (Sparkle-for-Swift-Package-Manager.zip of 2.10.0). SwiftPM checks that archive
# against the checksum in Sparkle's Package.swift at the revision the committed
# Package.resolved pins; the hashes below pin the two binaries themselves, so a
# moved tag or a swapped artifact is refused before it reads the key. The
# binaries are ad-hoc signed upstream, so their signature proves nothing.
#
# Updating Sparkle: change exactVersion in project.yml, Package.resolved (let
# Xcode resolve, copy the generated file to the repo root) and the two hashes
# here, together, after checking the new release's tools.
# `make guards` refuses a project.yml whose Sparkle version differs from this.
SPARKLE_TOOLS_VERSION="2.10.0"
SPARKLE_SIGN_UPDATE_SHA256="43c249771bafc3aa581228abae00731a012d324691b8292860896635050be76b"
SPARKLE_GENERATE_KEYS_SHA256="c37679f98d9121981cf7b2d18592fdc8b44931bffa604acf10c9e11791b6222e"

# The pinned tool $1 under the derived data folder $2, or the release stops.
sparkle_tool() {
  local name="$1" derived="$2" expected path actual
  case "$name" in
    sign_update) expected="$SPARKLE_SIGN_UPDATE_SHA256" ;;
    generate_keys) expected="$SPARKLE_GENERATE_KEYS_SHA256" ;;
    *) die "no pinned hash for $name" ;;
  esac
  path="$(find "$derived/SourcePackages/artifacts" -name "$name" -type f -perm +111 -print -quit 2>/dev/null || true)"
  [ -n "$path" ] || die "$name not found under $derived"
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  [ "$actual" = "$expected" ] \
    || die "$path is not the pinned Sparkle $SPARKLE_TOOLS_VERSION $name (sha256 $actual, expected $expected)"
  printf '%s\n' "$path"
}

# The EdDSA public key the app ships, from project.yml (Info.plist is generated
# from it).
shipped_public_key() {
  awk '/SUPublicEDKey:/ {print $2; exit}' "$REPO_ROOT/project.yml"
}

# Refuses when the key sign_update will sign with is not the one installed copies
# trust: a mismatch would publish an update every client rejects, and nothing on
# this side would notice. Needs SIGN_UPDATE, GENERATE_KEYS and SIGN_ARGS.
#
# Keychain (the default): generate_keys -p prints the public half of the key in
# the login keychain, the key sign_update uses; macOS may ask for access. Key
# file: sign_update signs a throwaway challenge with it, and the signature is
# checked against the shipped key (scripts/ed25519-verify.swift, CryptoKit).
check_signing_key() {
  local expected actual challenge signature
  expected="$(shipped_public_key)"
  [ -n "$expected" ] || die "no SUPublicEDKey in project.yml"
  if [ "${#SIGN_ARGS[@]}" -eq 0 ]; then
    actual="$("$GENERATE_KEYS" -p | tr -d '[:space:]')" \
      || die "generate_keys -p could not read the signing key from the keychain"
    [ "$actual" = "$expected" ] \
      || die "the keychain's signing key ($actual) is not the key ClipShot ships ($expected)"
  else
    challenge="$(mktemp "${TMPDIR:-/tmp}/clipshot-key-check.XXXXXX")"
    head -c 64 /dev/urandom >"$challenge"
    signature="$("$SIGN_UPDATE" "${SIGN_ARGS[@]}" -p "$challenge")" || die "sign_update could not sign a test file"
    xcrun swift "$REPO_ROOT/scripts/ed25519-verify.swift" "$expected" "$challenge" "$signature" \
      || die "the key in $SPARKLE_EDDSA_PRIVATE_KEY_PATH is not the key ClipShot ships ($expected)"
  fi
  echo "signing key matches the shipped SUPublicEDKey"
}
