#!/bin/zsh
# spikecapture.sh <type> <bin-dir> <steps-log>
# Sets com.apple.screencapture `type` (only once screencaptureui has exited, so no refresher is
# needed), then drives a full-screen, a selection and a window capture through real HID input.
type=$1 bin=$2 L=$3
log(){ print -r -- "$(date +%s.%N) $*" | tee -a $L; }
waitgone(){ for i in {1..80}; do pgrep -q screencaptureui || return 0; sleep 0.25; done; log "WARN screencaptureui still running"; }
waitgone
$bin/spikeprefs set type $type >/dev/null; log "type=$type"
log "CAP display $type"; $bin/spikeinput key 20 cmd,shift; sleep 7; waitgone
log "CAP selection $type"; $bin/spikeinput key 21 cmd,shift; sleep 0.8; $bin/spikeinput drag 300 300 700 600 6; sleep 7; waitgone
log "CAP window $type"; $bin/spikeinput key 21 cmd,shift; sleep 0.8; $bin/spikeinput key 49; sleep 0.5; $bin/spikeinput move 880 480; sleep 0.2; $bin/spikeinput move 900 500; sleep 0.4; $bin/spikeinput click 900 500; sleep 7; waitgone
log "done $type"
