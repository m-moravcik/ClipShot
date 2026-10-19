#!/usr/bin/env python3
"""Where did each capture land? Joins the capture events of the steps logs with the files that
appeared (first appearance from the spikewatch logs, else the final-location listing).
Usage: placement.py <steps.log>... --watch <watch.log>... --final <captured-files-final-location.txt>
File names carry the capture time (local, UTC+2 on 2026-10-19); a file belongs to an event when
its name time t (1 s resolution) satisfies floor(event) - 1 <= t <= event + 4 s; when several
events qualify, the latest one wins (each file is assigned to exactly one event).
"state" is the last logged pref or kill line before the event; read the event label too, some
pref changes were only described in the label."""
import re, sys
from datetime import datetime, timezone, timedelta

args = sys.argv[1:]
def take(flag):
    if flag not in args: return []
    i = args.index(flag); out = []
    for a in args[i + 1:]:
        if a.startswith('--'): break
        out.append(a)
    return out
steps = [a for a in args[:min([args.index(f) for f in ('--watch', '--final') if f in args] + [len(args)])]]
watch, final = take('--watch'), take('--final')
TZ = timezone(timedelta(hours=2))
name_re = re.compile(r'(Screenshot|Screen Recording) (\d{4}-\d{2}-\d{2}) at (\d{2})\.(\d{2})\.(\d{2})( \(\d+\))?\.(\w+)$')

def name_time(name):
    m = name_re.search(name)
    if not m: return None
    d = datetime.strptime(f"{m.group(2)} {m.group(3)}:{m.group(4)}:{m.group(5)}", "%Y-%m-%d %H:%M:%S").replace(tzinfo=TZ)
    return d.timestamp()

files = {}  # name -> folder of first appearance
for log in watch:
    for line in open(log, errors='replace'):
        m = re.match(r'^\d+ POLL NEW (.*)/([^/]+?) birth=', line)
        if m and not m.group(2).startswith('.') and name_re.search(m.group(2)):
            files.setdefault(m.group(2), m.group(1).replace('/clipshot-spike', '/cs').split('/cs/')[-1] if '/clipshot-spike/' in m.group(1) else m.group(1))
for f in final:
    for line in open(f):
        if line.startswith('#'): continue
        ts, path = line.rstrip('\n').split(' ', 1)
        folder, name = path[2:].rsplit('/', 1)
        files.setdefault(name, folder)

events = []
for s in steps:
    for line in open(s):
        if not re.match(r'^\d+\.\d+ ', line): continue
        ts, rest = line.rstrip('\n').split(' ', 1)
        events.append((float(ts), rest))
events.sort()
CAPTURE = re.compile(r'^(KEY|CAP) |^FLOW .*KEY selection$|^FLOW probe|^REC: clicked Record$|^MISSING: KEY selection$')
caps = [ts for ts, rest in events if CAPTURE.search(rest)]
owner = {}
for n in files:
    t = name_time(n)
    cands = [c for c in caps if int(c) - 1 <= t <= c + 4]
    if cands: owner[n] = max(cands)
state = ''
for ts, rest in events:
    if re.search(r'prefs->|^type=|(?<!-)target|show-thumbnail|killall', rest) and not CAPTURE.search(rest):
        state = (state + ' | ' + rest) if 'killall' in rest else rest
        continue
    if not CAPTURE.search(rest): continue
    hits = sorted(n for n in files if owner.get(n) == ts)
    where = '; '.join(f"{files[n]}/{n}" for n in hits) if hits else 'NO FILE'
    print(f"{ts:.3f} {rest}\n    state: {state}\n    -> {where}")
    if 'killall' in state: state = state.split(' | ')[0]
