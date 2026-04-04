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
  team-start --resume                     Re-attach if session exists, or restart agents
                                         with their previous conversation context
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
  # If tmux session is still alive, just re-attach
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux attach -t "$SESSION"
    exit 0
  fi
  # Session is dead - restart agents with their previous conversation context
  echo "[INFO] Session gone. Restarting agents with previous context..."
  # Fall through to normal startup - build_cmd will add resume flags
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
  # Write launcher script instead of interpolating paths into send-keys
  LAUNCHER="$REPO_ROOT/.coordination/pids/watch-${AGENTS[$i]}.sh"
  cat > "$LAUNCHER" <<WATCHEOF
#!/usr/bin/env bash
exec "$SCRIPT_DIR/team-watch.sh" "${AGENTS[$i]}" "${PANES[$i]}" "$REPO_ROOT"
WATCHEOF
  chmod +x "$LAUNCHER"
  tmux send-keys -t "$SESSION:watchers" -l "\"$LAUNCHER\" &"
  tmux send-keys -t "$SESSION:watchers" Enter
done
tmux send-keys -t "$SESSION:watchers" -l "wait"
tmux send-keys -t "$SESSION:watchers" Enter

# Build agent command as an array - no string interpolation
# $1 = bedrock model ID (only used with --bedrock)
# $2 = agent name (manager, worker-1, etc.) - used for --name / --resume
build_cmd() {
  local bedrock_model="$1" agent_name="$2"
  local -a cmd=()

  if [[ "$USE_CODEX" == "1" ]]; then
    cmd=(codex --dangerously-bypass-approvals-and-sandbox)
    [[ -n "$MODEL" ]] && cmd+=(--model "$MODEL")
    # Codex doesn't support named sessions - resume not available
  elif [[ "$USE_BEDROCK" == "1" ]]; then
    cmd=(claude --dangerously-skip-permissions --model "$bedrock_model")
    if [[ "$RESUME" == "1" ]]; then
      cmd+=(--resume "$agent_name")
    else
      cmd+=(--name "$agent_name")
    fi
  else
    cmd=(claude --dangerously-skip-permissions)
    [[ -n "$MODEL" ]] && cmd+=(--model "$MODEL")
    if [[ "$RESUME" == "1" ]]; then
      cmd+=(--resume "$agent_name")
    else
      cmd+=(--name "$agent_name")
    fi
  fi
  printf '%q ' "${cmd[@]}"
}

MGR_CMD="$(build_cmd "$MANAGER_MODEL" manager)"
WRK_CMDS=("")
for i in 1 2 3; do
  WRK_CMDS+=("$(build_cmd "$WORKER_MODEL" "worker-$i")")
done

# Prepend CLAUDE_CODE_USE_BEDROCK env var for bedrock mode
if [[ "$USE_BEDROCK" == "1" ]]; then
  MGR_CMD="CLAUDE_CODE_USE_BEDROCK=1 $MGR_CMD"
  for i in 1 2 3; do
    WRK_CMDS[$i]="CLAUDE_CODE_USE_BEDROCK=1 ${WRK_CMDS[$i]}"
  done
fi

# Launch agents via per-pane launcher scripts - avoids shell escaping in send-keys
launch_agent() {
  local pane="$1" cmd="$2"
  local launcher="$REPO_ROOT/.coordination/pids/launch-$(basename "$pane").sh"
  cat > "$launcher" <<LAUNCHEOF
#!/usr/bin/env bash
cd $(printf '%q' "$REPO_ROOT") && $cmd
LAUNCHEOF
  chmod +x "$launcher"
  tmux send-keys -t "$pane" -l "\"$launcher\""
  tmux send-keys -t "$pane" Enter
}

launch_agent "${PANES[0]}" "$MGR_CMD"
for i in 1 2 3; do
  TEMPLATE="$REPO_ROOT/.coordination/prompts/worker-template.md"
  if [[ -f "$TEMPLATE" ]]; then
    sed "s/{{WORKER_ID}}/worker-$i/g; s/{{WORKER_NUM}}/$i/g" \
      "$TEMPLATE" > "$REPO_ROOT/.coordination/prompts/worker-$i.md"
  fi
  launch_agent "${PANES[$i]}" "${WRK_CMDS[$i]}"
done

tmux select-window -t "$SESSION:team"
tmux select-pane   -t "${PANES[0]}"

echo ""
echo "[OK] Team started: $SESSION  (repo: $REPO_ROOT)"
echo "  Attach:  tmux attach -t $SESSION"
echo "  Send:    team-send manager you 'your task here'"
echo "  Resume:  team-start --resume"
