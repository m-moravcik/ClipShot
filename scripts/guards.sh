#!/usr/bin/env bash
#
# Static guards. Fails on:
#   - removeItem / unlink( anywhere under ClipShot/ (user files only go through trashItem)
#   - Text("...") literals outside #Preview blocks (user-facing strings must be localised keys)
#   - the em dash (U+2014) in user-facing resources and docs

set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail=0
report() { printf '\033[31mguard failed:\033[0m %s\n' "$1" >&2; fail=1; }

if grep -rnE 'removeItem|unlink\(' ClipShot --include='*.swift'; then
  report "removeItem/unlink found under ClipShot/"
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

paths=()
for p in ClipShot/Resources README.md DEVELOPMENT.md release-notes; do
  [ -e "$p" ] && paths+=("$p")
done
if [ "${#paths[@]}" -gt 0 ] && grep -rn $'\xe2\x80\x94' "${paths[@]}"; then
  report "em dash (U+2014) found in user-facing files"
fi

[ "$fail" -eq 0 ] && echo "guards: OK"
exit "$fail"
