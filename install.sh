#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_FILE="$SCRIPT_DIR/devtools.zsh"
INSTALL_PATH="$HOME/.devtools.zsh"
ZSHRC="$HOME/.zshrc"

MARKER_START="# devtools_init"
MARKER_END="# end devtools_init"

# 1. Copy devtools.zsh to ~/.devtools.zsh
cp "$SOURCE_FILE" "$INSTALL_PATH"
echo "Installed $INSTALL_PATH"

# 2. Add guarded source block to .zshrc if missing
if ! grep -qF "$MARKER_START" "$ZSHRC" 2>/dev/null; then
  printf '\n%s\nif [[ $- == *i* ]]; then\n    source ~/.devtools.zsh\nfi\n%s\n' \
    "$MARKER_START" "$MARKER_END" >> "$ZSHRC"
  echo "Added source block to $ZSHRC"
else
  echo "Source block already present in $ZSHRC — skipped"
fi

echo "Done. Restart your shell or run: source ~/.zshrc"
