#!/bin/bash
# Install MCC git hooks. Run once per clone.
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOKS_DIR="$REPO_ROOT/.git/hooks"
SOURCE_DIR="$REPO_ROOT/.git-hooks"

mkdir -p "$HOOKS_DIR"
ln -sf "$SOURCE_DIR/pre-push" "$HOOKS_DIR/pre-push"
chmod +x "$SOURCE_DIR/pre-push"
echo "✓ Installed pre-push hook (symlink to .git-hooks/pre-push)"
