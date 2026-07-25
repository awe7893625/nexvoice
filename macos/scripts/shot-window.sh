#!/bin/zsh
# Screenshot a NexVoice window by CGWindowID.
#
# Capturing by window id (not by screen region) means it works even when the
# window is occluded or on another Space -- a region capture just photographs
# whatever terminal happens to be on top.
#
# Usage: shot-window.sh out.png [minWidth] [maxWidth]
#   shot-window.sh main.png                 # main window (>=600pt wide)
#   shot-window.sh hud.png 100 300          # the floating HUD panel (148x80)
#
# Exits non-zero if the capture did not actually produce a usable image, so a
# missing Screen Recording grant fails loudly instead of yielding a black PNG
# that a caller would read as "passed".
set -eu -o pipefail

here="${0:A:h}"

if [[ $# -lt 1 ]]; then
  print -u2 "usage: ${0:t} out.png [minWidth] [maxWidth]"
  exit 64
fi
out="$1"
minw="${2:-600}"
maxw="${3:-}"

# window-id is a tiny CGWindowList query; build on first use.
if [[ ! -x "$here/window-id" || "$here/window-id.swift" -nt "$here/window-id" ]]; then
  swiftc -O "$here/window-id.swift" -o "$here/window-id"
fi

info=$("$here/window-id" NexVoice "$minw" ${maxw:+"$maxw"})
id=${info%% *}
geometry=${info#* }

rm -f "$out"
screencapture -x -o -l "$id" "$out"

# --- the capture is not evidence until it is checked ---------------------
if [[ ! -s "$out" ]]; then
  print -u2 "FAIL: screencapture wrote no file for window $id ($geometry)"
  exit 1
fi

read -r shot_w shot_h <<<"$(sips -g pixelWidth -g pixelHeight "$out" 2>/dev/null \
  | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w, h}')"
if [[ -z "${shot_w:-}" || "$shot_w" -lt 8 || "${shot_h:-0}" -lt 8 ]]; then
  print -u2 "FAIL: $out is not a readable image (${shot_w:-?}x${shot_h:-?})"
  exit 1
fi

# A window captured without Screen Recording permission comes back uniformly
# black; anything genuinely rendered has some spread.
spread=$("$here/window-id" --stddev "$out") || {
  print -u2 "FAIL: could not measure $out"
  exit 1
}
if awk -v s="$spread" 'BEGIN{exit !(s < 0.004)}'; then
  print -u2 "FAIL: $out is effectively a flat image (stddev=$spread) --"
  print -u2 "      usually a missing Screen Recording grant for this terminal."
  exit 1
fi

print "captured window $id ($geometry) ${shot_w}x${shot_h}px stddev=$spread -> $out"
