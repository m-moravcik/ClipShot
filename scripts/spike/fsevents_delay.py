#!/usr/bin/env python3
"""FSEvents delivery delay: for each FSE 'Created' event, seconds between the poller's first
sighting of that path and the FSEvents callback. Usage: fsevents_delay.py <spikewatch log>"""
import re, sys
first, delays = {}, []
lines = open(sys.argv[1], errors='replace').read().splitlines()
for l in lines:
    m = re.match(r'^(\d+) POLL NEW (.*?) birth=', l)
    if m: first.setdefault(m.group(2), int(m.group(1)))
for l in lines:
    m = re.match(r'^(\d+) FSE \d+ (\S+) (.*)$', l)
    if m and m.group(3) in first and 'Created' in m.group(2):
        delays.append((int(m.group(1)) - first[m.group(3)]) / 1e9)
delays.sort()
print(f"{len(delays)} Created events; min {delays[0]:.1f} s, median {delays[len(delays)//2]:.1f} s, max {delays[-1]:.1f} s")
print("all:", ", ".join(f"{d:.1f}" for d in delays))
