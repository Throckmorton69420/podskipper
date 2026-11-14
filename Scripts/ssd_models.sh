#!/bin/zsh
# Pass 64: fill the external drive with PodSkipper's models (and compile Core AI
# ones for the iPhone on this Mac). A copy sits on the drive beside Models/.
# Usage: ssd_models.sh [--dry-run] [--only gguf,mlx,coreai] [--models id,…] [--compile needed|all|none]
HERE=${0:A:h}
if [ -f "$HERE/ssd_models.py" ]; then exec python3 -I "$HERE/ssd_models.py" "$@"; fi
exec python3 -I ~/Developer/podskipper/Scripts/ssd_models.py "$@"
