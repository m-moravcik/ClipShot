#!/usr/bin/env bash
#
# Static guards. Fails on:
#   - removeItem / unlink( anywhere under ClipShot/ or ClipShotCLI/ (files leave the folder only
#     through trashItem; the control socket replaces a stale socket by rename)
#   - Text("...") literals outside #Preview blocks (user-facing strings must be localised keys)
#   - the em dash (U+2014) in any text file of the repository
#   - Sparkle's version, revision pin and release-tool hashes out of step

set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

fail=0
report() { printf '\033[31mguard failed:\033[0m %s\n' "$1" >&2; fail=1; }

if grep -rnE 'removeItem|unlink\(' ClipShot ClipShotCLI --include='*.swift'; then
  report "removeItem/unlink found under ClipShot/ or ClipShotCLI/"
fi

# Tests must not create preference files (removePersistentDomain leaves the plist behind).
if grep -rnE 'UserDefaults\(suiteName|UserDefaults\.standard' ClipShotTests --include='*.swift'; then
  report "tests use real UserDefaults; use InMemoryPreferenceStore"
fi

python3 - <<'PY' || fail=1
import glob, re, sys
bad = []
for path in glob.glob('ClipShot/**/*.swift', recursive=True):
    skip_depth = None
    depth = 0
    for n, line in enumerate(open(path, encoding='utf-8'), 1):
        if skip_depth is None and re.match(r'\s*#Preview\b', line):
            skip_depth = depth
        if skip_depth is None and re.search(r'\bText\(\s*"', line):
            bad.append(f"{path}:{n}: {line.strip()}")
        depth += line.count('{') - line.count('}')
        if skip_depth is not None and depth <= skip_depth and '}' in line:
            skip_depth = None
if bad:
    print('\n'.join(bad), file=sys.stderr)
    print('guard failed: Text("...") literal outside #Preview', file=sys.stderr)
    sys.exit(1)
PY

# Sparkle: project.yml's exactVersion, the committed Package.resolved, the generated
# project's copy and the pinned release tools (scripts/sparkle-tools.sh) all name
# the same release, so a version bump cannot leave the revision pin or the tool
# hashes behind.
python3 - <<'PY' || fail=1
import json, os, re, sys
errors = []
spec = open('project.yml', encoding='utf-8').read()
m = re.search(r'Sparkle:\n(?:\s+#.*\n|\s+url:.*\n)*\s+exactVersion:\s*([0-9.]+)', spec)
version = m.group(1) if m else None
tools = re.search(r'^SPARKLE_TOOLS_VERSION="([0-9.]+)"', open('scripts/sparkle-tools.sh', encoding='utf-8').read(), re.M)
def pin(path):
    pins = [p for p in json.load(open(path, encoding='utf-8'))['pins'] if p['identity'] == 'sparkle']
    return (pins[0]['state'].get('version'), pins[0]['state'].get('revision')) if pins else (None, None)
committed = pin('Package.resolved') if os.path.exists('Package.resolved') else (None, None)
if version is None: errors.append('project.yml: no Sparkle exactVersion')
if committed[0] != version: errors.append(f'Package.resolved pins Sparkle {committed[0]}, project.yml says {version}')
if not re.fullmatch(r'[0-9a-f]{40}', committed[1] or ''): errors.append('Package.resolved: no Sparkle revision')
if not tools or tools.group(1) != version: errors.append(f'scripts/sparkle-tools.sh pins tools of {tools and tools.group(1)}, project.yml says {version}')
generated = 'ClipShot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
if os.path.exists(generated) and pin(generated) != committed:
    errors.append(f'{generated} pins {pin(generated)}, the committed Package.resolved {committed}')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    print('guard failed: Sparkle pins disagree', file=sys.stderr)
    sys.exit(1)
PY

# No em dash anywhere: code, comments, docs, scripts and resources alike. Every text
# file git tracks or would add (untracked, not ignored); -I skips binaries such as the
# PNGs, where the same bytes can occur by chance.
if git grep -n -I --untracked $'\xe2\x80\x94'; then
  report "em dash (U+2014) found in the repository"
fi

[ "$fail" -eq 0 ] && echo "guards: OK"
exit "$fail"
