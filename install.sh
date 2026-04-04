#!/usr/bin/env bash
# install.sh - Detect OS, install team-start/team-send/team-watch, install dependencies
#
# Usage:
#   ./install.sh           # install commands + dependencies
#   ./install.sh --check   # check what's installed and what's missing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CMDS=(team-start team-send team-watch)
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

# Detect OS
detect_os() {
  case "$(uname -s)" in
    Linux*)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
      else
        echo "linux"
      fi
      ;;
    Darwin*) echo "macos" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *) echo "unknown" ;;
  esac
}

OS="$(detect_os)"

# Detect package manager
detect_pkg_manager() {
  case "$OS" in
    linux|wsl)
      if command -v apt-get &>/dev/null; then echo "apt"
      elif command -v dnf &>/dev/null; then echo "dnf"
      elif command -v pacman &>/dev/null; then echo "pacman"
      elif command -v apk &>/dev/null; then echo "apk"
      else echo "unknown"
      fi
      ;;
    macos) echo "brew" ;;
    windows) echo "scoop" ;;
  esac
}

PKG="$(detect_pkg_manager)"

# Check a command, report status, return 1 if missing
check_cmd() {
  local cmd="$1" required="$2"
  if command -v "$cmd" &>/dev/null; then
    local version
    version="$("$cmd" --version 2>&1 | head -1)" || version="installed"
    echo "  [OK] $cmd - $version"
    return 0
  elif [[ "$required" == "required" ]]; then
    echo "  [MISSING] $cmd (required)"
    return 1
  else
    echo "  [MISSING] $cmd (optional - improves performance)"
    return 1
  fi
}

# Install a package
install_pkg() {
  local pkg="$1"
  echo "  Installing $pkg..."
  case "$PKG" in
    apt)    sudo apt-get install -y "$pkg" ;;
    dnf)    sudo dnf install -y "$pkg" ;;
    pacman) sudo pacman -S --noconfirm "$pkg" ;;
    apk)    sudo apk add "$pkg" ;;
    brew)   brew install "$pkg" ;;
    scoop)  scoop install "$pkg" ;;
    *)      echo "  [ERROR] Unknown package manager. Install $pkg manually." >&2; return 1 ;;
  esac
}

echo "OS: $OS ($PKG)"
echo ""

# Check dependencies
echo "Dependencies:"
MISSING_REQUIRED=0
check_cmd tmux required || MISSING_REQUIRED=1
check_cmd python3 required || MISSING_REQUIRED=1
check_cmd claude optional || true
check_cmd codex optional || true

case "$OS" in
  linux|wsl)  check_cmd inotifywait optional || true ;;
  macos)      check_cmd fswatch optional || true ;;
  windows)    echo "  [INFO] File watching uses poll mode (1s)" ;;
esac
echo ""

if [[ "$CHECK_ONLY" == "1" ]]; then
  # Check if commands are installed
  echo "Commands:"
  for cmd in "${CMDS[@]}"; do
    if command -v "$cmd" &>/dev/null; then
      target="$(readlink -f "$(which "$cmd")" 2>/dev/null || which "$cmd")"
      echo "  [OK] $cmd -> $target"
    else
      echo "  [MISSING] $cmd"
    fi
  done
  exit 0
fi

# Install missing required dependencies
if [[ "$MISSING_REQUIRED" == "1" ]]; then
  echo "Installing missing dependencies..."
  command -v tmux &>/dev/null || install_pkg tmux
  command -v python3 &>/dev/null || install_pkg python3
  echo ""
fi

# Offer to install optional file-watcher
case "$OS" in
  linux|wsl)
    if ! command -v inotifywait &>/dev/null; then
      echo "Install inotify-tools for instant message delivery? (y/N)"
      read -r answer
      [[ "$answer" == [yY]* ]] && install_pkg inotify-tools
      echo ""
    fi
    ;;
  macos)
    if ! command -v fswatch &>/dev/null; then
      echo "Install fswatch for instant message delivery? (y/N)"
      read -r answer
      [[ "$answer" == [yY]* ]] && install_pkg fswatch
      echo ""
    fi
    ;;
esac

# Find or create bin directory
BIN_DIR=""
for dir in "$HOME/bin" "$HOME/.local/bin" "/usr/local/bin"; do
  if [[ -d "$dir" ]] && echo "$PATH" | tr ':' '\n' | grep -qx "$dir"; then
    BIN_DIR="$dir"
    break
  fi
done

if [[ -z "$BIN_DIR" ]]; then
  BIN_DIR="$HOME/.local/bin"
  mkdir -p "$BIN_DIR"
fi

# Install commands
chmod +x "$SCRIPT_DIR/team-start.sh" "$SCRIPT_DIR/team-send.sh" "$SCRIPT_DIR/team-watch.sh"

for cmd in "${CMDS[@]}"; do
  ln -sf "$SCRIPT_DIR/$cmd.sh" "$BIN_DIR/$cmd"
done

echo "[OK] Installed: ${CMDS[*]} -> $BIN_DIR"

# Check if BIN_DIR is on PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
  echo ""
  echo "[WARN] $BIN_DIR is not on PATH. Add to your shell profile:"
  SHELL_NAME="$(basename "${SHELL:-bash}")"
  case "$SHELL_NAME" in
    zsh)  echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc && source ~/.zshrc" ;;
    fish) echo "  fish_add_path $BIN_DIR" ;;
    *)    echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc && source ~/.bashrc" ;;
  esac
fi
