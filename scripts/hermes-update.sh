#!/usr/bin/env bash
# hermes-update.sh — safe hermes update workflow
# Usage: bash hermes-update.sh [--check]  (--check = report only, no changes)
#
# Flow:
#   1. Check patch PR statuses on GitHub
#   2. Show which patches are applied / pending
#   3. If --check: exit here
#   4. Unapply any applied patches (so working tree is clean for hermes update)
#   5. Run `hermes update` (standard bundled updater → always pulls latest main)
#   6. Re-apply patches that are still needed
set -euo pipefail

HERMES_DIR="${HOME}/.hermes/hermes-agent"
PATCHES_DIR="${MY_HERMES_REPO:-${HOME}/my-hermes}/patches"
REPO="NousResearch/hermes-agent"
CHECK_ONLY="${1:-}"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
DIM='\033[2m'

step() { echo -e "\n${BOLD}${CYAN}▸ $*${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
err()  { echo -e "  ${RED}✗${NC} $*"; }
info() { echo -e "  ${DIM}$*${NC}\033[0m"; }

cd "$HERMES_DIR"

# ── 1. Check patch statuses (GitHub) ─────────────────────────────────────────
step "Local patches — upstream status"

PATCHES_OPEN=()     # PR/issue still open → need re-apply after update
PATCHES_MERGED=()   # PR/issue closed/merged → no longer needed

for yaml_file in "${PATCHES_DIR}"/*.yaml; do
  [[ -f "$yaml_file" ]] || continue
  patch_file="$(basename "${yaml_file%.yaml}.patch")"

  ISSUE=$(grep '^issue:' "$yaml_file" | awk '{print $2}' | tr -d '"')
  PR=$(grep '^pr:' "$yaml_file" | awk '{print $2}' | tr -d '"')
  TITLE=$(grep '^title:' "$yaml_file" | sed 's/^title: *//' | tr -d '"')
  RESOLVED=false

  if [[ "$ISSUE" != "null" && -n "$ISSUE" ]]; then
    ISSUE_STATE=$(gh issue view "$ISSUE" --repo "$REPO" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")
    if [[ "$ISSUE_STATE" == "CLOSED" ]]; then
      ok "Issue #${ISSUE} CLOSED — patch no longer needed: ${TITLE}"
      PATCHES_MERGED+=("$patch_file")
      RESOLVED=true
    else
      warn "Issue #${ISSUE} open  — ${TITLE}"
    fi
  fi

  if [[ "$RESOLVED" == "false" && "$PR" != "null" && -n "$PR" ]]; then
    PR_STATE=$(gh pr view "$PR" --repo "$REPO" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")
    if [[ "$PR_STATE" == "MERGED" ]]; then
      ok "PR #${PR} MERGED — patch no longer needed: ${TITLE}"
      PATCHES_MERGED+=("$patch_file")
      RESOLVED=true
    else
      warn "PR #${PR} open  — ${TITLE}"
    fi
  fi

  [[ "$RESOLVED" == "false" ]] && PATCHES_OPEN+=("$patch_file")
done

# ── 2. Check which patches are currently applied ──────────────────────────────
step "Local patches — applied state"

PATCHES_APPLIED=()   # open + already applied (need unapply before update)
PATCHES_PENDING=()   # open + not applied

for patch_file in "${PATCHES_OPEN[@]+"${PATCHES_OPEN[@]}"}"; do
  patch_path="${PATCHES_DIR}/${patch_file}"
  [[ -f "$patch_path" ]] || { err "Patch file not found: ${patch_path}"; continue; }

  if git apply --check --reverse "$patch_path" 2>/dev/null; then
    ok  "Applied:     ${patch_file}"
    PATCHES_APPLIED+=("$patch_file")
  elif git apply --check "$patch_path" 2>/dev/null; then
    warn "Not applied: ${patch_file}"
    PATCHES_PENDING+=("$patch_file")
  else
    err  "Stale (won't apply cleanly): ${patch_file} — needs rebuild"
    PATCHES_PENDING+=("$patch_file")
  fi
done

# ── 3. Summary ────────────────────────────────────────────────────────────────
step "Summary"

echo -e "  ${BOLD}Update:${NC}   will run ${BOLD}hermes update${NC} (→ latest main)"

if [[ ${#PATCHES_APPLIED[@]} -gt 0 ]]; then
  echo -e "  ${BOLD}Unapply:${NC}  ${#PATCHES_APPLIED[@]} patch(es) before update:"
  for p in "${PATCHES_APPLIED[@]}"; do info "    · $p"; done
fi

PATCHES_TO_APPLY=("${PATCHES_APPLIED[@]+"${PATCHES_APPLIED[@]}"}" "${PATCHES_PENDING[@]+"${PATCHES_PENDING[@]}"}")

if [[ ${#PATCHES_TO_APPLY[@]} -gt 0 ]]; then
  echo -e "  ${BOLD}Patches:${NC}  ${#PATCHES_TO_APPLY[@]} to apply after update:"
  for p in "${PATCHES_TO_APPLY[@]}"; do info "    · $p"; done
else
  echo -e "  ${BOLD}Patches:${NC}  none needed"
fi

if [[ ${#PATCHES_MERGED[@]} -gt 0 ]]; then
  echo -e "  ${BOLD}Retired:${NC}  ${#PATCHES_MERGED[@]} patch(es) merged upstream — can delete:"
  for p in "${PATCHES_MERGED[@]}"; do info "    · $p"; done
fi

if [[ "$CHECK_ONLY" == "--check" ]]; then
  echo ""
  ok "Check complete (--check mode, no changes made)"
  exit 0
fi

echo ""
echo -e "  ${BOLD}Proceed with update?${NC} [u]pdate / [s]kip / Ctrl+C to abort"
read -r -p "  Choice [u/s, default: u]: " CONFIRM
case "${CONFIRM,,}" in
  u|update|"" )
    ;;  # continue
  s|skip )
    echo ""
    ok "Skipped (no changes made)."
    exit 0
    ;;
  * )
    err "Aborted."
    exit 1
    ;;
esac

# ── 4. Unapply patches so working tree is clean ───────────────────────────────
if [[ ${#PATCHES_APPLIED[@]} -gt 0 ]]; then
  echo ""
  step "Unapplying patches before update"
  for patch_file in "${PATCHES_APPLIED[@]}"; do
    patch_path="${PATCHES_DIR}/${patch_file}"
    git apply --reverse "$patch_path"
    ok "Unapplied: ${patch_file}"
  done
fi

# ── 5. Run hermes update ──────────────────────────────────────────────────────
echo ""
step "Running hermes update"
echo -e "  ${YELLOW}⚠${NC}  If hermes asks ${BOLD}\"Restore local changes?\"${NC} — answer ${BOLD}N${NC}"
echo -e "     (patches will be re-applied by this script afterward)"
echo ""

hermes update

# ── 6. Apply patches ─────────────────────────────────────────────────────────
if [[ ${#PATCHES_TO_APPLY[@]} -gt 0 ]]; then
  echo ""
  step "Applying patches"
  for patch_file in "${PATCHES_TO_APPLY[@]}"; do
    patch_path="${PATCHES_DIR}/${patch_file}"
    [[ -f "$patch_path" ]] || { err "Patch file not found: ${patch_path}"; continue; }

    if git apply --check "$patch_path" 2>/dev/null; then
      git apply "$patch_path"
      ok "Applied: ${patch_file}"
    elif git apply --check --reverse "$patch_path" 2>/dev/null; then
      ok "Already applied (skipping): ${patch_file}"
    else
      err "CONFLICT — patch did not apply cleanly: ${patch_file}"
      err "  Needs rebuild: git diff main...fork/branch -- file > patches/${patch_file}"
    fi
  done
fi

echo ""
ok "${BOLD}Done.${NC}"
