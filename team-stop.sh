#!/usr/bin/env bash
# team-stop - Kill the agent team tmux session and clean up
#
# Usage:
#   team-stop                    # stop team for $PWD
#   team-stop /path/to/project   # stop team for specific repo
#   team-stop --all              # stop all team sessions

set -euo pipefail

if [[ "${1:-}" == "--all" ]]; then
  # Kill all sessions ending in -team
  KILLED=0
  for s in $(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep '\-team$'); do
    tmux kill-session -t "$s" && echo "  Stopped $s" && KILLED=$((KILLED + 1))
  done
  if [[ "$KILLED" -gt 0 ]]; then
    echo "[OK] Stopped $KILLED team session(s)"
  else
    echo "[INFO] No team sessions running"
  fi
  exit 0
fi

REPO_ROOT="${1:-$PWD}"
[[ -d "$REPO_ROOT" ]] && REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
SESSION="${SESSION:-$(basename "$REPO_ROOT")-team}"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux kill-session -t "$SESSION"
  echo "[OK] Stopped: $SESSION"
else
  echo "[INFO] No session: $SESSION"
fi
