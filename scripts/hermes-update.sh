#!/usr/bin/env bash
# hermes-update.sh — safe hermes update workflow
# Usage: bash hermes-update.sh [--check]  (--check = report only, no changes)
#
# Flow:
#   1. Fetch and identify the exact latest origin/main commit
#   2. Check patch PR statuses and applied state
#   3. If --check: exit here
#   4. Unapply any applied patches and require a clean tree
#   5. Optionally enable a full backup (default: no) and run `hermes update --branch main`
#   6. Re-apply patches and verify HEAD == origin/main
set -euo pipefail

HERMES_DIR="${HERMES_DIR:-${HOME}/.hermes/hermes-agent}"
PATCHES_DIR="${MY_HERMES_REPO:-${HOME}/my-hermes}/patches"
REPO="NousResearch/hermes-agent"
WORKFLOW_REPO="shared-goals/hermes-update-workflow"
WORKFLOW_ARCHIVE_URL="${HERMES_UPDATE_WORKFLOW_ARCHIVE_URL:-https://github.com/${WORKFLOW_REPO}/archive/refs/heads/main.tar.gz}"
CHECK_ONLY="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HERMES_BIN="${HERMES_DIR}/venv/bin/hermes"

if [[ ! -x "$HERMES_BIN" ]]; then
  echo "Error: hermes binary not found at $HERMES_BIN" >&2
  exit 1
fi

source "$SCRIPT_DIR/patch-helpers.sh"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
DIM='\033[2m'

step() { echo -e "\n${BOLD}${CYAN}▸ $*${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
err()  { echo -e "  ${RED}✗${NC} $*"; }
info() { echo -e "  ${DIM}$*${NC}\033[0m"; }

check_workflow_freshness() {
  local temp_dir archive_path upstream_root upstream_file relative_path
  local differing_files=0

  step "Update workflow status"

  if ! command -v curl >/dev/null 2>&1; then
    warn "Cannot check ${WORKFLOW_REPO}: curl is unavailable"
    return 0
  fi

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/hermes-update-workflow.XXXXXX")"
  archive_path="${temp_dir}/workflow.tar.gz"

  if ! curl -fsSL --connect-timeout 5 --max-time 20 "$WORKFLOW_ARCHIVE_URL" -o "$archive_path"; then
    warn "Could not check ${WORKFLOW_REPO}@main (continuing without freshness data)"
    rm -rf "$temp_dir"
    return 0
  fi

  if ! tar -xzf "$archive_path" -C "$temp_dir"; then
    warn "Could not unpack ${WORKFLOW_REPO}@main (continuing without freshness data)"
    rm -rf "$temp_dir"
    return 0
  fi

  upstream_root="$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)"
  if [[ -z "$upstream_root" ]]; then
    warn "Downloaded workflow archive has no source directory"
    rm -rf "$temp_dir"
    return 0
  fi

  while IFS= read -r upstream_file; do
    relative_path="${upstream_file#${upstream_root}/}"
    if [[ ! -f "${SKILL_ROOT}/${relative_path}" ]] || ! cmp -s "$upstream_file" "${SKILL_ROOT}/${relative_path}"; then
      differing_files=$((differing_files + 1))
    fi
  done < <(
    find "$upstream_root" -type f \
      \( -path "$upstream_root/README.md" -o -path "$upstream_root/SKILL.md" \
      -o -path "$upstream_root/references/*" -o -path "$upstream_root/scripts/*" \) \
      | sort
  )

  rm -rf "$temp_dir"

  if [[ "$differing_files" -eq 0 ]]; then
    ok "Workflow matches ${WORKFLOW_REPO}@main"
  else
    warn "Update workflow is outdated or locally modified (${differing_files} file(s) differ)"
    info "    · https://github.com/${WORKFLOW_REPO}"
    info "    · Refresh it before updating Hermes; hub install: hermes skills update hermes-update-workflow"
  fi
}

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

release_version_from_name() {
  local release_name="$1"
  if [[ "$release_name" =~ v([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    echo "v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
  fi
}

cd "$HERMES_DIR"

check_workflow_freshness

# ── 1. Check update status (commits + latest release) ───────────────────────
step "Upstream update status"

# A safe latest-main update cannot use a stale cached ref.
if ! git fetch --quiet origin main --tags; then
  err "Could not refresh origin/main; refusing to report or install a stale target"
  exit 1
fi
ok "Fetched upstream refs"

CURRENT_SHA="$(git rev-parse HEAD)"
TARGET_SHA="$(git rev-parse origin/main)"

if ! git merge-base --is-ancestor HEAD origin/main; then
  warn "Local HEAD cannot fast-forward to origin/main; forcing alignment"
  info "Current: ${CURRENT_SHA}"
  info "Target:  ${TARGET_SHA}"
  if [[ -n "$(git status --porcelain)" ]]; then
    err "Working tree is dirty; refusing to force-reset local-only commits"
    git status --short
    exit 1
  fi
  info "Discarding local-only commit(s) not on origin/main:"
  git log --oneline origin/main..HEAD | sed 's/^/    · /'
  git reset --hard origin/main
  CURRENT_SHA="$(git rev-parse HEAD)"
  ok "Forced HEAD to origin/main (${CURRENT_SHA})"
fi

BEHIND_COUNT="$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "unknown")"
CHANGED_FILES="$(git diff --name-only HEAD..origin/main | wc -l | tr -d ' ')"
info "Current: ${CURRENT_SHA}"
info "Target:  ${TARGET_SHA}"
if [[ "$BEHIND_COUNT" == "0" ]]; then
  ok "Gap: 0 commits, ${CHANGED_FILES} changed files (up to date)"
elif [[ "$BEHIND_COUNT" =~ ^[0-9]+$ ]]; then
  warn "Gap: ${BEHIND_COUNT} commits, ${CHANGED_FILES} changed files"
else
  warn "Commits behind origin/main: unknown"
fi

LATEST_RELEASE_TAG=""
LATEST_RELEASE_NAME=""
LATEST_RELEASE_VERSION=""
LATEST_RELEASE_LINE=""
LATEST_RELEASE_URL=""
LATEST_RELEASE_RAW="$(gh release view --repo "$REPO" --json tagName,name,url,isDraft,isPrerelease -q 'select(.isDraft==false and .isPrerelease==false) | .tagName + "|" + .name + "|" + .url' 2>/dev/null || true)"
if [[ -n "$LATEST_RELEASE_RAW" ]]; then
  LATEST_RELEASE_TAG="${LATEST_RELEASE_RAW%%|*}"
  LATEST_RELEASE_RAW="${LATEST_RELEASE_RAW#*|}"
  LATEST_RELEASE_NAME="${LATEST_RELEASE_RAW%%|*}"
  LATEST_RELEASE_URL="${LATEST_RELEASE_RAW#*|}"
  LATEST_RELEASE_VERSION="$(release_version_from_name "$LATEST_RELEASE_NAME")"
  LATEST_RELEASE_LINE="${LATEST_RELEASE_VERSION%.*}"
fi

LOCAL_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
CURRENT_RELEASE_VERSION=""
CURRENT_RELEASE_LINE=""
if [[ -n "$LOCAL_TAG" ]]; then
  CURRENT_RELEASE_NAME="$(gh release view "$LOCAL_TAG" --repo "$REPO" --json name -q '.name' 2>/dev/null || true)"
  CURRENT_RELEASE_VERSION="$(release_version_from_name "$CURRENT_RELEASE_NAME")"
  CURRENT_RELEASE_LINE="${CURRENT_RELEASE_VERSION%.*}"
fi

if [[ -n "$LATEST_RELEASE_TAG" && -n "$LATEST_RELEASE_URL" ]]; then
  if [[ -n "$CURRENT_RELEASE_VERSION" ]]; then
    info "Current release: ${CURRENT_RELEASE_VERSION}"
  elif [[ -n "$LOCAL_TAG" ]]; then
    warn "Current release: unavailable (${LOCAL_TAG})"
  else
    warn "Current release: unavailable"
  fi
  if [[ -n "$LATEST_RELEASE_VERSION" ]]; then
    info "Following release: ${LATEST_RELEASE_VERSION}"
  else
    info "Following release: ${LATEST_RELEASE_TAG}"
  fi
  if [[ -n "$CURRENT_RELEASE_LINE" && "$CURRENT_RELEASE_LINE" == "$LATEST_RELEASE_LINE" ]]; then
    ok "Release line ${LATEST_RELEASE_LINE} already present"
    info "    · ${LATEST_RELEASE_URL}"
  elif [[ -n "$LATEST_RELEASE_VERSION" ]]; then
    warn "New release line available: ${LATEST_RELEASE_LINE}"
    info "    · ${LATEST_RELEASE_URL}"
  else
    warn "New release available: ${LATEST_RELEASE_TAG}"
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

echo -e "  ${BOLD}Update:${NC}   ${CURRENT_SHA:0:12} → ${TARGET_SHA:0:12} (latest origin/main)"
echo -e "  ${BOLD}Backup:${NC}   optional full pre-update Hermes backup (default: no)"

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

BACKUP_ARGS=()
echo ""
echo -e "  ${BOLD}Enable full pre-update Hermes backup?${NC} [y]es / [n]o (default: n)"
read -r -p "  Choice [y/n, default: n]: " BACKUP_CHOICE
case "$(echo "${BACKUP_CHOICE}" | tr '[:upper:]' '[:lower:]')" in
  y|yes )
    BACKUP_ARGS=(--backup)
    ok "Full backup enabled for this run"
    ;;
  n|no|"" )
    info "Full backup disabled (default)"
    ;;
  * )
    err "Aborted (invalid backup choice)."
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
if [[ -n "$(git status --porcelain)" ]]; then
  err "Working tree is still dirty after patch unapply; refusing to update"
  git status --short
  exit 1
fi

echo ""
step "Running hermes update"
echo -e "  ${YELLOW}⚠${NC}  If hermes asks ${BOLD}\"Restore local changes?\"${NC} — answer ${BOLD}N${NC}"
echo -e "     (patches will be re-applied by this script afterward)"
info "Rollback code SHA: ${CURRENT_SHA}"
echo ""

"$HERMES_BIN" update --branch main "${BACKUP_ARGS[@]+"${BACKUP_ARGS[@]}"}"

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

if ! git fetch --quiet origin main; then
  err "Update completed, but origin/main could not be refreshed for final verification"
  exit 1
fi

FINAL_SHA="$(git rev-parse HEAD)"
LATEST_SHA="$(git rev-parse origin/main)"
if [[ "$FINAL_SHA" != "$LATEST_SHA" ]]; then
  err "Update finished at ${FINAL_SHA}, but latest origin/main is ${LATEST_SHA}"
  err "Run make update again after reviewing the new upstream commits"
  exit 1
fi

echo ""
ok "${BOLD}Done.${NC} HEAD is latest origin/main: ${FINAL_SHA}"
