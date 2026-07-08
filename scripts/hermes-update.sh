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

HERMES_DIR="${HERMES_DIR:-${HOME}/.hermes/hermes-agent}"
PATCHES_DIR="${MY_HERMES_REPO:-${HOME}/my-hermes}/patches"
REPO="NousResearch/hermes-agent"
CHECK_ONLY="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/patch-helpers.sh"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
DIM='\033[2m'

step() { echo -e "\n${BOLD}${CYAN}▸ $*${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
err()  { echo -e "  ${RED}✗${NC} $*"; }
info() { echo -e "  ${DIM}$*${NC}\033[0m"; }

extract_issue_id_from_url() {
  local url="$1"
  if [[ "$url" =~ ^https://github\.com/[^/]+/[^/]+/issues/([0-9]+)([/?#].*)?$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

extract_pr_id_from_url() {
  local url="$1"
  if [[ "$url" =~ ^https://github\.com/[^/]+/[^/]+/pull/([0-9]+)([/?#].*)?$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

cd "$HERMES_DIR"

# ── 1. Check update status (commits + latest release) ───────────────────────
step "Upstream update status"

# Refresh remote refs/tags best-effort so commit/release checks are current.
if git fetch --quiet origin main --tags >/dev/null 2>&1; then
  ok "Fetched upstream refs"
else
  warn "Could not refresh upstream refs (using local remote cache)"
fi

BEHIND_COUNT="$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "unknown")"
if [[ "$BEHIND_COUNT" == "0" ]]; then
  ok "Commits behind origin/main: 0 (up to date)"
elif [[ "$BEHIND_COUNT" =~ ^[0-9]+$ ]]; then
  warn "Commits behind origin/main: ${BEHIND_COUNT}"
else
  warn "Commits behind origin/main: unknown"
fi

LATEST_RELEASE_TAG=""
LATEST_RELEASE_URL=""
LATEST_RELEASE_RAW="$(gh release view --repo "$REPO" --json tagName,url,isDraft,isPrerelease -q 'select(.isDraft==false and .isPrerelease==false) | .tagName + "|" + .url' 2>/dev/null || true)"
if [[ -n "$LATEST_RELEASE_RAW" ]]; then
  LATEST_RELEASE_TAG="${LATEST_RELEASE_RAW%%|*}"
  LATEST_RELEASE_URL="${LATEST_RELEASE_RAW#*|}"
fi

LOCAL_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [[ -n "$LATEST_RELEASE_TAG" && -n "$LATEST_RELEASE_URL" ]]; then
  if [[ "$LOCAL_TAG" != "$LATEST_RELEASE_TAG" ]]; then
    warn "New release available: ${LATEST_RELEASE_TAG}"
    info "    · ${LATEST_RELEASE_URL}"
  else
    ok "Latest release already present: ${LATEST_RELEASE_TAG}"
    info "    · ${LATEST_RELEASE_URL}"
  fi
else
  warn "Could not resolve latest release info"
fi

# ── 2. Check patch statuses (GitHub) ─────────────────────────────────────────
step "Local patches — upstream status"

PATCHES_OPEN=()     # PR/issue still open → need re-apply after update
PATCHES_MERGED=()   # PR/issue closed/merged → no longer needed

for yaml_file in "${PATCHES_DIR}"/*.yaml; do
  [[ -f "$yaml_file" ]] || continue
  patch_file="$(basename "${yaml_file%.yaml}.patch")"

  ISSUE_URL=$(grep '^issue:' "$yaml_file" | awk '{print $2}' | tr -d '"')
  PR_URL=$(grep '^pr:' "$yaml_file" | awk '{print $2}' | tr -d '"')
  TITLE=$(grep '^title:' "$yaml_file" | sed 's/^title: *//' | tr -d '"')
  RESOLVED=false

  if [[ "$ISSUE_URL" != "null" && -n "$ISSUE_URL" ]]; then
    ISSUE_ID="$(extract_issue_id_from_url "$ISSUE_URL" || true)"
    if [[ -z "$ISSUE_ID" ]]; then
      err "Invalid issue URL in ${yaml_file}: ${ISSUE_URL}"
      err "  Expected format: https://github.com/<owner>/<repo>/issues/<number>"
      exit 1
    fi
    ISSUE_STATE=$(gh issue view "$ISSUE_ID" --repo "$REPO" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")
    ISSUE_LINK="$ISSUE_URL"
    if [[ "$ISSUE_STATE" == "CLOSED" ]]; then
      ok "Issue CLOSED — patch no longer needed: ${TITLE} (${ISSUE_LINK})"
      PATCHES_MERGED+=("$patch_file")
      RESOLVED=true
    else
      warn "Issue open  — ${TITLE} (${ISSUE_LINK})"
    fi
  fi

  if [[ "$RESOLVED" == "false" && "$PR_URL" != "null" && -n "$PR_URL" ]]; then
    PR_ID="$(extract_pr_id_from_url "$PR_URL" || true)"
    if [[ -z "$PR_ID" ]]; then
      err "Invalid PR URL in ${yaml_file}: ${PR_URL}"
      err "  Expected format: https://github.com/<owner>/<repo>/pull/<number>"
      exit 1
    fi
    PR_STATE=$(gh pr view "$PR_ID" --repo "$REPO" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")
    PR_LINK="$PR_URL"
    if [[ "$PR_STATE" == "MERGED" ]]; then
      ok "PR MERGED — patch no longer needed: ${TITLE} (${PR_LINK})"
      PATCHES_MERGED+=("$patch_file")
      RESOLVED=true
    else
      warn "PR open  — ${TITLE} (${PR_LINK})"
    fi
  fi

  [[ "$RESOLVED" == "false" ]] && PATCHES_OPEN+=("$patch_file")
done

# ── 3. Check which patches are currently applied ──────────────────────────────
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

# ── 4. Summary ────────────────────────────────────────────────────────────────
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
case "$(echo "${CONFIRM}" | tr '[:upper:]' '[:lower:]')" in
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

# ── 5. Unapply patches so working tree is clean ───────────────────────────────
if [[ ${#PATCHES_APPLIED[@]} -gt 0 ]]; then
  echo ""
  step "Unapplying patches before update"
  for patch_file in "${PATCHES_APPLIED[@]}"; do
    patch_path="${PATCHES_DIR}/${patch_file}"
    git apply --reverse "$patch_path"
    ok "Unapplied: ${patch_file}"
  done
fi

# ── 6. Run hermes update ──────────────────────────────────────────────────────
echo ""
step "Running hermes update"
echo -e "  ${YELLOW}⚠${NC}  If hermes asks ${BOLD}\"Restore local changes?\"${NC} — answer ${BOLD}N${NC}"
echo -e "     (patches will be re-applied by this script afterward)"
echo ""

hermes update

# ── 7. Apply patches ─────────────────────────────────────────────────────────
if [[ ${#PATCHES_TO_APPLY[@]} -gt 0 ]]; then
  echo ""
  step "Applying patches"
  for patch_file in "${PATCHES_TO_APPLY[@]}"; do
    patch_path="${PATCHES_DIR}/${patch_file}"
    [[ -f "$patch_path" ]] || { err "Patch file not found: ${patch_path}"; continue; }

    if apply_managed_patch "$HERMES_DIR" "$patch_path"; then
      case "$PATCH_APPLY_RESULT" in
        applied_direct)
          ok "Applied: ${patch_file}"
          ;;
        applied_3way)
          ok "Applied (3-way): ${patch_file}"
          ;;
        applied_3way_refreshed)
          ok "Applied (3-way, refreshed patch context): ${patch_file}"
          ;;
        already_applied)
          ok "Already applied (skipping): ${patch_file}"
          ;;
      esac
    else
      err "CONFLICT — patch would leave unresolved conflicts: ${patch_file}"
      err "  Rebuild it from current main if still needed, or keep the refreshed local diff after manual resolution."
    fi
  done

  echo ""
  step "Restarting Hermes gateway"
  if hermes gateway restart; then
    ok "Hermes gateway restarted"
  else
    warn "Hermes gateway restart failed — check gateway status manually"
  fi
fi

echo ""
ok "${BOLD}Done.${NC}"
