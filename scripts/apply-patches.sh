#!/usr/bin/env bash
# apply-patches.sh — re-apply my-hermes patches to hermes-agent after update
# Usage: MY_HERMES_REPO=~/my-hermes bash apply-patches.sh
set -euo pipefail

REPO="${MY_HERMES_REPO:-$HOME/my-hermes}"
PATCH_DIR="$REPO/patches"
HERMES_SRC="$HOME/.hermes/hermes-agent"

echo "Applying patches from $PATCH_DIR to $HERMES_SRC..."
for patch in "$PATCH_DIR"/*.patch; do
  [ -s "$patch" ] || continue
  echo "  → $(basename "$patch")"
  if git -C "$HERMES_SRC" apply --check --3way "$patch" 2>/dev/null; then
    git -C "$HERMES_SRC" apply --3way "$patch" && echo "    ✅ OK (3-way)"
  elif git -C "$HERMES_SRC" apply --check "$patch" 2>/dev/null; then
    git -C "$HERMES_SRC" apply "$patch" && echo "    ✅ OK"
  elif git -C "$HERMES_SRC" apply --check --reverse "$patch" 2>/dev/null; then
    echo "    ✅ Already applied (skipping)"
  else
    echo "    ❌ FAILED — 3-way and direct apply failed; rebuild patch"
  fi
done

echo "Done."
