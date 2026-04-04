#!/usr/bin/env bash
# team-start - Start a 1-manager + 3-worker agent team in tmux
#
# Usage:
#   team-start                              # claude, default model, in $PWD
#   team-start /path/to/project             # claude in specific repo
#   team-start --model opus                 # claude with specific model for all agents
#   team-start --bedrock                    # claude via Bedrock (Opus manager, Sonnet workers)
#   team-start --codex                      # codex instead of claude
#   team-start --codex --model o4-mini      # codex with specific model
#   team-start --resume                     # re-attach existing session
#
# REPO_ROOT defaults to $PWD.
# SESSION defaults to $(basename REPO_ROOT)-team, or set via $SESSION env var.
# Role briefs are injected by team-watch on first message.

set -euo pipefail

show_help() {
  cat <<'EOF'
team-start - Start a 1-manager + 3-worker agent team in tmux

Usage:
  team-start                              Claude, default model, in $PWD
  team-start /path/to/project             Claude in specific repo
  team-start --model opus                 Claude with specific model for all agents
  team-start --bedrock                    Claude via Bedrock (Opus manager, Sonnet workers)
  team-start --codex                      Codex instead of Claude
  team-start --codex --model o4-mini      Codex with specific model
  team-start --resume                     Re-attach existing session
  team-start --help                       Show this help

Environment variables:
  SESSION          Override tmux session name (default: <dirname>-team)
  MANAGER_MODEL    Bedrock manager model ID
  WORKER_MODEL     Bedrock worker model ID

Project setup:
  Create .coordination/prompts/ in your project with role briefs:
    manager.md              Manager role brief
    worker-template.md      Template with {{WORKER_ID}} and {{WORKER_NUM}} placeholders

Related commands:
  team-send    Send a message to an agent
  team-stop    Stop the team session
EOF
  exit 0
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && show_help

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse args
REPO_ROOT=""
USE_BEDROCK=0
USE_CODEX=0
RESUME=0
MODEL=""
SKIP_NEXT=0
ARGS=("$@")
for i in "${!ARGS[@]}"; do
  [[ "$SKIP_NEXT" == "1" ]] && SKIP_NEXT=0 && continue
  arg="${ARGS[$i]}"
  case "$arg" in
    --bedrock) USE_BEDROCK=1 ;;
    --codex)   USE_CODEX=1 ;;
    --resume)  RESUME=1 ;;
    --model)   MODEL="${ARGS[$((i+1))]:-}"; SKIP_NEXT=1 ;;
    *)         [[ -d "$arg" ]] && REPO_ROOT="$(cd "$arg" && pwd)" ;;
  esac
done
REPO_ROOT="${REPO_ROOT:-$PWD}"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

SESSION="${SESSION:-$(basename "$REPO_ROOT")-team}"
INBOX_ROOT="$REPO_ROOT/.coordination/mailbox/inbox"

if [[ "$RESUME" == "1" ]]; then
  tmux attach -t "$SESSION" 2>/dev/null || { echo "[ERROR] No session: $SESSION"; exit 1; }
  exit 0
fi

# Guards
if ! command -v tmux &>/dev/null; then
  echo "[ERROR] tmux not found" >&2; exit 1
fi
if ! command -v python3 &>/dev/null; then
  echo "[ERROR] python3 not found" >&2; exit 1
fi

# Bedrock model IDs (cross-region inference profiles)
MANAGER_MODEL="${MANAGER_MODEL:-us.anthropic.claude-opus-4-6-20250514-v1:0}"
WORKER_MODEL="${WORKER_MODEL:-us.anthropic.claude-sonnet-4-6-20250514-v1:0}"

# Reset - kill old watchers and session
for pidfile in "$REPO_ROOT/.coordination/pids/"*.pid; do
  [[ -f "$pidfile" ]] || continue
  pid="$(cat "$pidfile" 2>/dev/null)" || continue
  kill "$pid" 2>/dev/null || true
  rm -f "$pidfile"
done
tmux kill-session -t "$SESSION" 2>/dev/null || true
for agent in manager worker-1 worker-2 worker-3; do
  mkdir -p "$INBOX_ROOT/$agent"
done
rm -f "$REPO_ROOT/.coordination/initialized/"*
mkdir -p "$REPO_ROOT/.coordination/prompts" "$REPO_ROOT/.coordination/initialized" "$REPO_ROOT/.coordination/pids"

# Layout:
#   +------------------+------------------+
#   |     MANAGER      |    WORKER 1      |
#   +------------------+------------------+
#   |    WORKER 2      |    WORKER 3      |
#   +------------------+------------------+
# Capture pane IDs - immune to pane-base-index differences across machines
PANES=()
PANES+=( "$(tmux new-session  -d -s "$SESSION" -n team -x 220 -y 50 -P -F "#{pane_id}")" )
PANES+=( "$(tmux split-window -t "$SESSION:team" -P -F "#{pane_id}")" )
PANES+=( "$(tmux split-window -t "$SESSION:team" -P -F "#{pane_id}")" )
PANES+=( "$(tmux split-window -t "$SESSION:team" -P -F "#{pane_id}")" )
tmux select-layout -t "$SESSION:team" tiled
tmux set -t "$SESSION" mouse on
tmux set -t "$SESSION" set-clipboard external
tmux set -t "$SESSION" pane-border-status top
tmux set -t "$SESSION" pane-border-format " #{pane_title} "
tmux select-pane -t "${PANES[0]}" -T "MANAGER"
tmux select-pane -t "${PANES[1]}" -T "WORKER 1"
tmux select-pane -t "${PANES[2]}" -T "WORKER 2"
tmux select-pane -t "${PANES[3]}" -T "WORKER 3"

# Watcher window (background)
tmux new-window -t "$SESSION" -n watchers
AGENTS=(manager worker-1 worker-2 worker-3)
for i in 0 1 2 3; do
  tmux send-keys -t "$SESSION:watchers" \
    "\"$SCRIPT_DIR/team-watch.sh\" \"${AGENTS[$i]}\" \"${PANES[$i]}\" \"$REPO_ROOT\" &" Enter
done
tmux send-keys -t "$SESSION:watchers" "wait" Enter

# Build agent command
if [[ "$USE_CODEX" == "1" ]]; then
  BASE="codex --dangerously-bypass-approvals-and-sandbox"
  [[ -n "$MODEL" ]] && BASE="$BASE --model \"$MODEL\""
  MGR_CMD="$BASE"
  WRK_CMD="$BASE"
elif [[ "$USE_BEDROCK" == "1" ]]; then
  MGR_CMD="CLAUDE_CODE_USE_BEDROCK=1 claude --dangerously-skip-permissions --model \"$MANAGER_MODEL\""
  WRK_CMD="CLAUDE_CODE_USE_BEDROCK=1 claude --dangerously-skip-permissions --model \"$WORKER_MODEL\""
else
  BASE="claude --dangerously-skip-permissions"
  [[ -n "$MODEL" ]] && BASE="$BASE --model \"$MODEL\""
  MGR_CMD="$BASE"
  WRK_CMD="$BASE"
fi

# Launch agents
tmux send-keys -t "${PANES[0]}" "cd \"$REPO_ROOT\" && $MGR_CMD" Enter
for i in 1 2 3; do
  TEMPLATE="$REPO_ROOT/.coordination/prompts/worker-template.md"
  if [[ -f "$TEMPLATE" ]]; then
    sed "s/{{WORKER_ID}}/worker-$i/g; s/{{WORKER_NUM}}/$i/g" \
      "$TEMPLATE" > "$REPO_ROOT/.coordination/prompts/worker-$i.md"
  fi
  tmux send-keys -t "${PANES[$i]}" "cd \"$REPO_ROOT\" && $WRK_CMD" Enter
done

tmux select-window -t "$SESSION:team"
tmux select-pane   -t "${PANES[0]}"

echo ""
echo "[OK] Team started: $SESSION  (repo: $REPO_ROOT)"
echo "  Attach:  tmux attach -t $SESSION"
echo "  Send:    team-send manager you 'your task here'"
echo "  Resume:  team-start --resume"
