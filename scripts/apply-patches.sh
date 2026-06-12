#!/usr/bin/env bash
# apply-patches.sh — re-apply my-hermes patches to hermes-agent after update
# Usage: MY_HERMES_REPO=~/my-hermes bash apply-patches.sh
set -euo pipefail

REPO="${MY_HERMES_REPO:-$HOME/my-hermes}"
PATCH_DIR="$REPO/patches"
HERMES_SRC="${HERMES_SRC:-$HOME/.hermes/hermes-agent}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/patch-helpers.sh"

echo "Applying patches from $PATCH_DIR to $HERMES_SRC..."
for patch in "$PATCH_DIR"/*.patch; do
  [ -s "$patch" ] || continue
  echo "  → $(basename "$patch")"
  if apply_managed_patch "$HERMES_SRC" "$patch"; then
    case "$PATCH_APPLY_RESULT" in
      applied_direct)
        echo "    ✅ OK"
        ;;
      applied_3way)
        echo "    ✅ OK (3-way)"
        ;;
      applied_3way_refreshed)
        echo "    ✅ OK (3-way, refreshed patch context)"
        ;;
      already_applied)
        echo "    ✅ Already applied (skipping)"
        ;;
    esac
  else
    echo "    ❌ FAILED — 3-way would leave unresolved conflicts; rebuild patch"
  fi
done

echo "Done."
