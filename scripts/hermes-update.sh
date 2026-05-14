#!/usr/bin/env bash
# hermes-update.sh — safe hermes update workflow
# Usage: bash hermes-update.sh [--check]  (--check = report only, no changes)
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
info() { echo -e "  ${DIM}$*${NC}"; }

# ── 1. Current version ───────────────────────────────────────────────────────
step "Current version"
cd "$HERMES_DIR"
CURRENT=$(git describe --tags --abbrev=0 2>/dev/null || git rev-parse --short HEAD)
CURRENT_DATE=$(git log -1 --format="%ci" "$CURRENT" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
ok "Installed: ${BOLD}${CURRENT}${NC}  (tagged ${CURRENT_DATE})"

# ── 2. Check latest release tag ──────────────────────────────────────────────
step "Checking upstream"
git fetch origin --tags -q 2>/dev/null || true
LATEST_TAG=$(git tag --sort=-version:refname | head -1)
LATEST_TAG_DATE=$(git log -1 --format="%ci" "$LATEST_TAG" 2>/dev/null | cut -d' ' -f1 || echo "unknown")

# Commits on origin/main ahead of current
MAIN_AHEAD=$(git log --oneline "${CURRENT}..origin/main" 2>/dev/null | wc -l | tr -d ' ')
MAIN_SHA=$(git rev-parse --short origin/main 2>/dev/null || echo "unknown")

UPDATE_TO=""   # what we'll actually checkout: tag or "origin/main"
SKIP_UPDATE=true

if [[ "$LATEST_TAG" != "$CURRENT" ]]; then
  TAG_AHEAD=$(git log --oneline "${CURRENT}..${LATEST_TAG}" 2>/dev/null | wc -l | tr -d ' ')
  warn "New release tag: ${BOLD}${LATEST_TAG}${NC}  (${LATEST_TAG_DATE}, +${TAG_AHEAD} commits)"

  # Show release notes highlights
  step "What's new in ${LATEST_TAG}"
  gh release view "$LATEST_TAG" --repo "$REPO" 2>/dev/null \
    | grep -A 40 '^##' | head -40 | sed 's/^/  /' \
    || warn "Could not fetch release notes"

  UPDATE_TO="$LATEST_TAG"
  SKIP_UPDATE=false
else
  ok "Already on latest release ${BOLD}${LATEST_TAG}${NC}"

  # Offer main if there are commits ahead of tag
  if [[ "$MAIN_AHEAD" -gt 0 ]]; then
    warn "origin/main is ${BOLD}${MAIN_AHEAD} commits${NC} ahead of ${LATEST_TAG}  (${MAIN_SHA})"
    info "main = unreleased commits (may include bug fixes not yet in a tag)"
    UPDATE_TO="origin/main"
    SKIP_UPDATE=false
  else
    ok "origin/main is in sync with ${LATEST_TAG} — nothing upstream"
  fi
fi

# ── 3. Check patch statuses (GitHub) ─────────────────────────────────────────
step "Local patches — upstream status"

PATCHES_OPEN=()     # issue/PR still open → need re-apply after any update
PATCHES_MERGED=()   # issue/PR closed/merged → no longer needed

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
    fi
  fi

  [[ "$RESOLVED" == "false" ]] && PATCHES_OPEN+=("$patch_file")
done

# ── 4. Check which patches are actually applied right now ─────────────────────
step "Local patches — applied state"

PATCHES_TO_APPLY=()   # open + not yet applied
PATCHES_ALREADY=()    # open + already applied

for patch_file in "${PATCHES_OPEN[@]+"${PATCHES_OPEN[@]}"}"; do
  patch_path="${PATCHES_DIR}/${patch_file}"
  [[ -f "$patch_path" ]] || { err "Patch file not found: ${patch_path}"; continue; }

  if git apply --check --reverse "$patch_path" 2>/dev/null; then
    ok "Already applied: ${patch_file}"
    PATCHES_ALREADY+=("$patch_file")
  else
    warn "Not applied:     ${patch_file}"
    PATCHES_TO_APPLY+=("$patch_file")
  fi
done

# ── 5. Summary ───────────────────────────────────────────────────────────────
step "Summary"

if [[ "$SKIP_UPDATE" == "false" ]]; then
  if [[ "$UPDATE_TO" == "origin/main" ]]; then
    echo -e "  ${BOLD}Update:${NC}   ${CURRENT} → ${BOLD}origin/main${NC} (${MAIN_AHEAD} commits, unreleased)"
  else
    echo -e "  ${BOLD}Update:${NC}   ${CURRENT} → ${BOLD}${UPDATE_TO}${NC}"
    echo -e "  ${BOLD}Note:${NC}     weekly snapshot of main (not a curated stable build)"
  fi
else
  echo -e "  ${BOLD}Update:${NC}   already on ${BOLD}${CURRENT}${NC}, in sync with origin/main"
fi

if [[ ${#PATCHES_TO_APPLY[@]} -gt 0 ]]; then
  echo -e "  ${BOLD}Patches:${NC}  ${#PATCHES_TO_APPLY[@]} not applied — will apply:"
  for p in "${PATCHES_TO_APPLY[@]}"; do info "    · $p"; done
elif [[ ${#PATCHES_OPEN[@]} -gt 0 ]]; then
  echo -e "  ${BOLD}Patches:${NC}  all ${#PATCHES_ALREADY[@]} open patch(es) already applied ✓"
else
  echo -e "  ${BOLD}Patches:${NC}  none"
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

# Nothing to do
if [[ "$SKIP_UPDATE" == "true" && ${#PATCHES_TO_APPLY[@]} -eq 0 ]]; then
  ok "Nothing to do"
  exit 0
fi

# ── 6. Confirm update ────────────────────────────────────────────────────────
echo ""
DO_UPDATE=false

if [[ "$SKIP_UPDATE" == "false" ]]; then
  if [[ "$UPDATE_TO" == "origin/main" ]]; then
    PROMPT="Update to latest main (${MAIN_AHEAD} unreleased commits)?"
  else
    PROMPT="Update to ${UPDATE_TO}?"
  fi
  read -rp "$(echo -e "${BOLD}${PROMPT}${NC} [y/N] ")" CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] && DO_UPDATE=true || echo "  Skipping update."
fi

# ── 7. Update ────────────────────────────────────────────────────────────────
if [[ "$DO_UPDATE" == "true" ]]; then
  step "Updating to ${UPDATE_TO}"
  git checkout "$UPDATE_TO"
  ok "Checked out ${UPDATE_TO}"

  # After update, re-check which patches need applying
  PATCHES_TO_APPLY=()
  for patch_file in "${PATCHES_OPEN[@]+"${PATCHES_OPEN[@]}"}"; do
    patch_path="${PATCHES_DIR}/${patch_file}"
    [[ -f "$patch_path" ]] || continue
    git apply --check --reverse "$patch_path" 2>/dev/null || PATCHES_TO_APPLY+=("$patch_file")
  done
fi

# ── 8. Apply patches ─────────────────────────────────────────────────────────
if [[ ${#PATCHES_TO_APPLY[@]} -gt 0 ]]; then
  echo ""
  read -rp "$(echo -e "${BOLD}Apply ${#PATCHES_TO_APPLY[@]} patch(es)?${NC} [y/N] ")" CONFIRM
  if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    step "Applying patches"
    for patch_file in "${PATCHES_TO_APPLY[@]}"; do
      patch_path="${PATCHES_DIR}/${patch_file}"
      if git apply --check "$patch_path" 2>/dev/null; then
        git apply "$patch_path"
        ok "Applied: ${patch_file}"
      elif git apply --check --reverse "$patch_path" 2>/dev/null; then
        ok "Already applied (skipping): ${patch_file}"
      else
        err "CONFLICT — patch did not apply cleanly: ${patch_file}"
        err "  Manual fix needed: git apply ${patch_path}"
      fi
    done
  else
    echo "  Skipping patches."
  fi
fi

echo ""
ok "${BOLD}Done.${NC}"
