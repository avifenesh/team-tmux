# team-tmux

Run a 1-manager + 3-worker AI agent team in tmux. Works with Claude Code and Codex CLI.

File-based message queue with atomic delivery. Agents coordinate through inbox files - no shared context, no direct connections.

## Install

```bash
git clone https://github.com/avifenesh/team-tmux.git
cd team-tmux
./install.sh
```

Creates `team-start`, `team-send`, `team-watch`, `team-stop` symlinks on your PATH (copies on Windows). It installs missing `tmux`, `python3` and the file watcher with the system package manager. `./install.sh --check` reports what is installed without changing anything.

### Requirements

- tmux
- python3
- claude (Claude Code) or codex (Codex CLI)
- Linux: `inotify-tools` for instant message delivery (falls back to 1s poll)
- macOS: 1s poll (`install.sh` installs `fswatch`, but `team-watch` does not use it yet)
- Windows: poll mode only (via Git Bash or WSL)

## Usage

```bash
# Start a team in your project directory
cd /path/to/project
team-start

# Start with a specific model
team-start --model opus

# Start with Codex instead of Claude
team-start --codex
team-start --codex --model o4-mini

# Start with AWS Bedrock (Opus manager, Sonnet workers)
team-start --bedrock

# Start in a specific directory
team-start /path/to/project

# Re-attach to the session, or restart Claude agents with their previous conversation if it is gone
team-start --resume
```

### Stopping

```bash
team-stop                    # stop the team for $PWD
team-stop /path/to/project   # stop the team for a specific repo
team-stop --clean            # stop and remove .coordination/
team-stop --all              # stop all *-team sessions
```

### Sending messages

```bash
team-send manager you "Implement the auth module"
team-send worker-1 manager "Handle the database layer"
team-send manager worker-1 "Done. All tests pass."
```

### Tmux layout

```
+------------------+------------------+
|     MANAGER      |    WORKER 1      |
+------------------+------------------+
|    WORKER 2      |    WORKER 3      |
+------------------+------------------+
```

A second tmux window (`watchers`) runs the inbox watchers in the background.

## How it works

1. `team-start` creates a tmux session with 4 panes, launches an AI agent in each. Agents run with approvals off (`claude --dangerously-skip-permissions`, `codex --dangerously-bypass-approvals-and-sandbox`)
2. Each agent has an inbox at `.coordination/mailbox/inbox/<agent>/`
3. `team-send` writes a JSON message to the target agent's inbox (atomic rename)
4. `team-watch` detects the new file and injects the message text into the agent's tmux pane
5. On first message, the role brief from `.coordination/prompts/<agent>.md` is sent automatically

### Project setup

Create `.coordination/prompts/` in your project with role briefs:

```
.coordination/
  prompts/
    manager.md              # Manager role brief
    worker-template.md      # Template with {{WORKER_ID}} and {{WORKER_NUM}} placeholders
```

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SESSION` | `$(basename $PWD)-team` | tmux session name |
| `MANAGER_MODEL` | Bedrock Opus 4.6 | Bedrock manager model ID |
| `WORKER_MODEL` | Bedrock Sonnet 4.6 | Bedrock worker model ID |

## License

BSD-3-Clause
