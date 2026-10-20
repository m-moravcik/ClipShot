#!/bin/zsh
# spikedump.sh <file>... - record the capture metadata the spike needs for each file.
for f in "$@"; do
  print -r -- "=== ${f:t}"
  print -r -- "--- stat -f '%FB %Fm %Fc %z'"
  stat -f "%FB %Fm %Fc %z" "$f"
  print -r -- "--- xattr -l"
  xattr -l "$f" | LC_ALL=C sed 's/[^[:print:]\t]/./g'
  print -r -- "--- mdls"
  mdls -name kMDItemIsScreenCapture -name kMDItemScreenCaptureType -name kMDItemScreenCaptureGlobalRect -name kMDItemContentType "$f"
  print
done
