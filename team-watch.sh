#!/usr/bin/env bash
# team-watch <agent> <tmux-pane-id> [REPO_ROOT]
#
# Watches the agent's inbox and injects messages into its tmux pane.
# On first message, prepends the role brief from .coordination/prompts/<agent>.md.
#
# REPO_ROOT defaults to $PWD.
# Called automatically by team-start - not usually invoked directly.

set -euo pipefail

AGENT="${1:?Usage: team-watch <agent> <tmux-pane-id> [REPO_ROOT]}"
PANE="${2:?Usage: team-watch <agent> <tmux-pane-id> [REPO_ROOT]}"
REPO_ROOT="${3:-$PWD}"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

INBOX="$REPO_ROOT/.coordination/mailbox/inbox/$AGENT"
INIT_FLAG="$REPO_ROOT/.coordination/initialized/$AGENT"
PROMPTS="$REPO_ROOT/.coordination/prompts"
mkdir -p "$INBOX" "$(dirname "$INIT_FLAG")"

type_text() {
  local pane="$1"
  local text="$2"
  # Scale wait time by message length so the TUI has time to process
  local len=${#text}
  local wait_secs=1
  (( len > 500  )) && wait_secs=2
  (( len > 1500 )) && wait_secs=3
  tmux send-keys -t "$pane" -l "$text"
  sleep "$wait_secs"
  # $'\r' (carriage return) is more reliable than the Enter keyword for TUI clients
  # like Claude Code that use readline - Enter can fail if readline remaps CR->LF
  tmux send-keys -t "$pane" $'\r'
}

inject() {
  local file="$1"
  local from body

  # Single python3 call: from on line 1, body on remaining lines
  local parsed
  if parsed="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get('from','?'))
print(d.get('body',''),end='')
" "$file" 2>/dev/null)"; then
    from="${parsed%%$'\n'*}"
    body="${parsed#*$'\n'}"
  else
    from="?"
    body="$(cat "$file")"
  fi
  rm -f "$file"

  # On first message: send role brief as a separate submission first
  if [[ ! -f "$INIT_FLAG" ]]; then
    touch "$INIT_FLAG"
    local brief_file="$PROMPTS/$AGENT.md"
    if [[ -f "$brief_file" ]]; then
      # Strip markdown headers per-line (before collapsing), then collapse to single line
      local brief
      brief="$(sed -E 's/^#+[[:space:]]*//' "$brief_file" | tr '\n' ' ' | sed 's/  */ /g')"
      echo "[watch:$AGENT] sending role brief"
      type_text "$PANE" "$brief"
      sleep 2
    fi
  fi

  echo "[watch:$AGENT] injecting from=$from"
  type_text "$PANE" "Message from ${from}: ${body}"
}

# inotifywait (Linux) or fswatch (macOS) for event-driven watching
if command -v inotifywait &>/dev/null; then
  echo "[watch:$AGENT] ready (inotifywait)"
  # moved_to fires after the atomic mv tmp->msg - correct for our maildir pattern
  inotifywait -m -q -e moved_to --format '%f' "$INBOX" |
  while IFS= read -r fname; do
    [[ "$fname" == msg-*.json ]] || continue
    inject "$INBOX/$fname"
  done
  exit 0
fi

if command -v fswatch &>/dev/null; then
  echo "[watch:$AGENT] ready (fswatch)"
  fswatch -0 --event Created --event Renamed "$INBOX" |
  while IFS= read -r -d '' fpath; do
    fname="$(basename "$fpath")"
    [[ "$fname" == msg-*.json ]] || continue
    inject "$fpath"
  done
  exit 0
fi

# Poll fallback (1s) - Windows (Git Bash), WSL on Windows FS, or missing tools
echo "[watch:$AGENT] ready (poll)"
while true; do
  for f in "$INBOX"/msg-*.json; do
    [[ -f "$f" ]] || continue
    inject "$f"
  done
  sleep 1
done
