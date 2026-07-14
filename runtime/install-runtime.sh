#!/bin/zsh
set -euo pipefail

# Compatibility entry point. Runtime ownership was moved into the signed
# NexVoice App so a KeepAlive LaunchAgent can no longer race the App for 5112.
ROOT="${0:A:h}"
print "NexVoice LaunchAgent mode is retired; preparing the App-owned MLX runtime instead."
exec zsh "$ROOT/setup-runtime.sh"
