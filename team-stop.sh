#!/usr/bin/env bash
# team-stop - Stop the agent team and optionally clean up coordination files
#
# Usage:
#   team-stop                    # stop team for $PWD
#   team-stop /path/to/project   # stop team for specific repo
#   team-stop --clean            # stop and remove .coordination/
#   team-stop --all              # stop all team sessions
#   team-stop --help             # show help

set -euo pipefail

show_help() {
  cat <<'EOF'
team-stop - Stop the agent team tmux session

Usage:
  team-stop                    Stop team for current directory
  team-stop /path/to/project   Stop team for specific repo
  team-stop --clean            Stop and remove .coordination/ (inbox, flags, prompts)
  team-stop --all              Stop all *-team sessions
  team-stop --help             Show this help

What it kills:
  - Watcher processes (via PID files, then SIGTERM)
  - The tmux session (all 4 agent panes + watcher window)
  - With --clean: also removes .coordination/ directory

What it keeps (without --clean):
  - .coordination/prompts/     Role briefs for next run
  - .coordination/mailbox/     Any undelivered messages
EOF
  exit 0
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && show_help

# Kill watcher processes for a repo via PID files
kill_watchers() {
  local repo="$1"
  local piddir="$repo/.coordination/pids"
  [[ -d "$piddir" ]] || return 0
  for pidfile in "$piddir"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    local pid
    pid="$(cat "$pidfile" 2>/dev/null)" || continue
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  done
}

if [[ "${1:-}" == "--all" ]]; then
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

CLEAN=0
REPO_ROOT=""
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    *)       [[ -d "$arg" ]] && REPO_ROOT="$(cd "$arg" && pwd)" ;;
  esac
done
REPO_ROOT="${REPO_ROOT:-$PWD}"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
SESSION="${SESSION:-$(basename "$REPO_ROOT")-team}"

# Kill watchers first - they run as background processes and may survive session kill
kill_watchers "$REPO_ROOT"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux kill-session -t "$SESSION"
  echo "[OK] Stopped: $SESSION"
else
  echo "[INFO] No session: $SESSION"
fi

if [[ "$CLEAN" == "1" ]]; then
  COORD="$REPO_ROOT/.coordination"
  if [[ -d "$COORD" ]]; then
    rm -rf "$COORD"
    echo "[OK] Removed $COORD"
  fi
fi
