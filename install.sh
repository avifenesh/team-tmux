#!/usr/bin/env bash
# install.sh - Add team-start, team-send, team-watch to PATH
#
# Creates symlinks in a directory on your PATH.
# Run from the repo root: ./install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Find a writable bin directory on PATH
BIN_DIR=""
for dir in "$HOME/bin" "$HOME/.local/bin" "/usr/local/bin"; do
  if [[ -d "$dir" ]] && echo "$PATH" | tr ':' '\n' | grep -qx "$dir"; then
    BIN_DIR="$dir"
    break
  fi
done

if [[ -z "$BIN_DIR" ]]; then
  # Create ~/bin and advise
  BIN_DIR="$HOME/bin"
  mkdir -p "$BIN_DIR"
  echo "[WARN] $BIN_DIR is not on PATH. Add to your shell profile:"
  echo "  export PATH=\"\$HOME/bin:\$PATH\""
fi

chmod +x "$SCRIPT_DIR/team-start.sh" "$SCRIPT_DIR/team-send.sh" "$SCRIPT_DIR/team-watch.sh"

for cmd in team-start team-send team-watch; do
  ln -sf "$SCRIPT_DIR/$cmd.sh" "$BIN_DIR/$cmd"
done

echo "[OK] Installed: team-start, team-send, team-watch -> $BIN_DIR"
