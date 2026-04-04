#!/usr/bin/env bash
# uninstall.sh - Remove team-start/team-send/team-watch from PATH

set -euo pipefail

CMDS=(team-start team-send team-watch team-stop)
REMOVED=0

for cmd in "${CMDS[@]}"; do
  for dir in "$HOME/bin" "$HOME/.local/bin" "/usr/local/bin"; do
    target="$dir/$cmd"
    if [[ -L "$target" || -f "$target" ]]; then
      rm -f "$target"
      echo "  Removed $target"
      REMOVED=$((REMOVED + 1))
    fi
  done
done

if [[ "$REMOVED" -gt 0 ]]; then
  echo "[OK] Uninstalled $REMOVED commands"
else
  echo "[INFO] Nothing to remove"
fi
