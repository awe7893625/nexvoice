#!/bin/zsh
# Screenshot the NexVoice main window by CGWindowID.
#
# Capturing by window id (not by screen region) means it works even when the
# window is occluded or on another Space -- a region capture just photographs
# whatever terminal happens to be on top.
#
# Usage: shot-window.sh out.png [minWidth]
set -e
here="${0:A:h}"
out="$1"
minw="${2:-600}"

# window-id is a tiny CGWindowList query; build on first use.
if [[ ! -x "$here/window-id" || "$here/window-id.swift" -nt "$here/window-id" ]]; then
  swiftc -O "$here/window-id.swift" -o "$here/window-id"
fi

info=$("$here/window-id" NexVoice "$minw")
id=${info%% *}
screencapture -x -o -l "$id" "$out"
echo "captured window $id (${info#* }) -> $out"
