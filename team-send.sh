#!/usr/bin/env bash
# team-send <to> <from> <message> [REPO_ROOT]
#
# Atomically drops a JSON message into an agent's inbox.
# team-watch picks it up and wakes the agent.
#
# REPO_ROOT defaults to $PWD. Run from your project directory,
# or pass the repo path as the 4th argument.
#
# Examples:
#   team-send worker-1 manager "Implement the executor module"
#   team-send manager worker-1 "Done. cargo test passes."
#   team-send worker-2 you "Review the PR" /path/to/project

set -euo pipefail

show_help() {
  cat <<'EOF'
team-send - Send a message to an agent's inbox

Usage:
  team-send <to> <from> <message> [REPO_ROOT]

Arguments:
  to          Target agent: manager, worker-1, worker-2, worker-3
  from        Sender name: manager, worker-N, you, or any string
  message     Message body (quote it)
  REPO_ROOT   Project directory (default: $PWD)

Examples:
  team-send manager you "Implement the auth module"
  team-send worker-1 manager "Handle the database layer"
  team-send manager worker-1 "Done. All tests pass."
  team-send worker-2 you "Review the PR" /path/to/project

Related commands:
  team-start   Start a team session
  team-stop    Stop the team session
EOF
  exit 0
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && show_help

TO="${1:?Usage: team-send <to> <from> <message> [REPO_ROOT]}"
FROM="${2:?Usage: team-send <to> <from> <message> [REPO_ROOT]}"
BODY="${3:?Usage: team-send <to> <from> <message> [REPO_ROOT]}"
REPO_ROOT="${4:-$PWD}"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

INBOX="$REPO_ROOT/.coordination/mailbox/inbox/$TO"
mkdir -p "$INBOX"

# python3 handles timestamp, unique ID, JSON encoding, and atomic write
# Avoids date -Iseconds (GNU-only, fails on macOS) and date +%s%N (no nanoseconds on macOS/Windows)
python3 -c "
import json, sys, time, os
from datetime import datetime, timezone

inbox = sys.argv[1]
msg = json.dumps({
    'from': sys.argv[2],
    'to': sys.argv[3],
    'ts': datetime.now(timezone.utc).astimezone().isoformat(),
    'body': sys.argv[4]
})

uid = f'{time.time_ns()}_{os.urandom(4).hex()}'
tmp = os.path.join(inbox, f'.tmp-{uid}.json')
final = os.path.join(inbox, f'msg-{uid}.json')

with open(tmp, 'w') as f:
    f.write(msg)
os.rename(tmp, final)
" "$INBOX" "$FROM" "$TO" "$BODY"

echo "[team-send] $FROM -> $TO: $BODY"
