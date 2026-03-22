#!/usr/bin/env bash
set -euo pipefail

INSTALL_PATH="$HOME/.devtools.zsh"
ZSHRC="$HOME/.zshrc"

MARKER_START="# devtools_init"
MARKER_END="# end devtools_init"

# 1. Remove source block from .zshrc
if grep -qF "$MARKER_START" "$ZSHRC" 2>/dev/null; then
  sed -i '' "/$MARKER_START/,/$MARKER_END/d" "$ZSHRC"
  echo "Removed source block from $ZSHRC"
else
  echo "No source block found in $ZSHRC — skipped"
fi

# 2. Optionally remove ~/.devtools.zsh
if [ -f "$INSTALL_PATH" ]; then
  read -rp "Remove $INSTALL_PATH? [y/N] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    rm "$INSTALL_PATH"
    echo "Removed $INSTALL_PATH"
  else
    echo "Kept $INSTALL_PATH"
  fi
else
  echo "$INSTALL_PATH not found — skipped"
fi

echo "Done. Restart your shell or run: source ~/.zshrc"
