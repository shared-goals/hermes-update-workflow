#!/usr/bin/env bash
# patch-from-pr-or-files.sh
#
# Create managed patch files for hermes-agent and optionally apply them to the
# current hermes-agent checkout.
#
# Modes:
#   1) PR mode    - fetch upstream PR diff, normalize it in a clean worktree,
#                   write patches/<name>.patch + patches/<name>.yaml,
#                   then apply to live checkout.
#   2) Files mode - snapshot selected local changed files into a managed patch
#                   pair. Useful for local edits that are not in a PR yet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/patch-helpers.sh"

HERMES_DIR="${HERMES_DIR:-${HOME}/.hermes/hermes-agent}"
MY_HERMES_REPO="${MY_HERMES_REPO:-${HOME}/my-hermes}"
PATCHES_DIR="${MY_HERMES_REPO}/patches"
UPSTREAM_REPO="${UPSTREAM_REPO:-NousResearch/hermes-agent}"

MODE=""
PR_REF=""
PATCH_NAME=""
PATCH_NAME_EXPLICIT=0
TITLE_OVERRIDE=""
ISSUE_OVERRIDE=""
NOTES=""
NO_APPLY=0

declare -a FILES=()

usage() {
  cat <<'EOF'
Usage:
  patch-from-pr-or-files.sh --pr <url-or-number> [--name <slug>] [--title <text>] [--issue-url <url>] [--notes <text>] [--no-apply]

  patch-from-pr-or-files.sh --from-files --file <path> [--file <path> ...] [--name <slug>] [--title <text>] [--notes <text>]

Env vars:
  HERMES_DIR      hermes-agent checkout (default: ~/.hermes/hermes-agent)
  MY_HERMES_REPO  patch storage repo (default: ~/my-hermes)
  UPSTREAM_REPO   GitHub repo for PR lookup (default: NousResearch/hermes-agent)

Examples:
  MY_HERMES_REPO=~/my-hermes bash scripts/patch-from-pr-or-files.sh \
    --pr https://github.com/NousResearch/hermes-agent/pull/56911 \
    --name telegram-space-pr56911

  MY_HERMES_REPO=~/my-hermes bash scripts/patch-from-pr-or-files.sh \
    --from-files --name my-local-fix --file gateway/run.py --file cli.py
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

slugify() {
  local input="$1"
  local out
  out="$(echo "$input" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$out" ]]; then
    out="patch"
  fi
  # Keep names readable and bounded.
  echo "${out:0:80}"
}

extract_pr_number() {
  local pr_ref="$1"
  if [[ "$pr_ref" =~ ^[0-9]+$ ]]; then
    echo "$pr_ref"
    return 0
  fi
  if [[ "$pr_ref" =~ ^https://github\.com/[^/]+/[^/]+/pull/([0-9]+)([/?#].*)?$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

first_path_from_patch() {
  local patch_path="$1"
  patch_touched_paths "$patch_path" | head -n 1
}

write_yaml_sidecar() {
  local yaml_path="$1"
  local pr_url="$2"
  local issue_url="$3"
  local title="$4"
  local apply_to="$5"
  local notes="$6"

  {
    echo "pr: \"${pr_url}\""
    if [[ -n "$issue_url" ]]; then
      echo "issue: \"${issue_url}\""
    else
      echo "issue: null"
    fi
    echo "title: \"${title}\""
    if [[ -n "$apply_to" ]]; then
      echo "apply_to: ${apply_to}"
    fi
    if [[ -n "$notes" ]]; then
      echo "notes: \"${notes}\""
    fi
  } > "$yaml_path"
}

build_patch_from_pr() {
  require_cmd gh
  require_cmd git

  [[ -d "$HERMES_DIR/.git" ]] || fail "HERMES_DIR is not a git checkout: $HERMES_DIR"
  mkdir -p "$PATCHES_DIR"

  local pr_number
  pr_number="$(extract_pr_number "$PR_REF" || true)"
  [[ -n "$pr_number" ]] || fail "Invalid --pr value: $PR_REF"

  local pr_title pr_url issue_url
  pr_title="$(gh pr view "$pr_number" --repo "$UPSTREAM_REPO" --json title -q '.title')"
  pr_url="$(gh pr view "$pr_number" --repo "$UPSTREAM_REPO" --json url -q '.url')"

  if [[ -n "$ISSUE_OVERRIDE" ]]; then
    issue_url="$ISSUE_OVERRIDE"
  else
    issue_url="$(gh pr view "$pr_number" --repo "$UPSTREAM_REPO" --json closingIssuesReferences -q '.closingIssuesReferences[0].url // ""')"
  fi

  local patch_title
  if [[ -n "$TITLE_OVERRIDE" ]]; then
    patch_title="$TITLE_OVERRIDE"
  else
    patch_title="$pr_title"
  fi

  if [[ -z "$PATCH_NAME" ]]; then
    PATCH_NAME="pr-${pr_number}-$(slugify "$patch_title")"
  fi

  local patch_out yaml_out
  patch_out="$PATCHES_DIR/${PATCH_NAME}.patch"
  yaml_out="$PATCHES_DIR/${PATCH_NAME}.yaml"

  if [[ -e "$patch_out" || -e "$yaml_out" ]]; then
    if [[ "$PATCH_NAME_EXPLICIT" -eq 1 ]]; then
      fail "Patch target already exists: ${PATCH_NAME} (.patch/.yaml)"
    fi
    PATCH_NAME="${PATCH_NAME}-$(date +%Y%m%d-%H%M%S)"
    patch_out="$PATCHES_DIR/${PATCH_NAME}.patch"
    yaml_out="$PATCHES_DIR/${PATCH_NAME}.yaml"
  fi

  local raw_patch
  raw_patch="$(mktemp "${TMPDIR:-/tmp}/hermes-pr-${pr_number}.XXXXXX.patch")"
  gh pr diff "$pr_number" --repo "$UPSTREAM_REPO" > "$raw_patch"

  grep -q '^diff --git a/' "$raw_patch" || fail "PR diff is empty or unsupported: $pr_url"

  local wt_dir
  wt_dir="$(mktemp -d "${TMPDIR:-/tmp}/hermes-pr-worktree.XXXXXX")"
  git -C "$HERMES_DIR" worktree add --detach "$wt_dir" HEAD >/dev/null

  local cleanup_done=0
  cleanup() {
    if [[ "$cleanup_done" -eq 0 ]]; then
      git -C "$HERMES_DIR" worktree remove "$wt_dir" --force >/dev/null 2>&1 || true
      rm -f "$raw_patch"
      cleanup_done=1
    fi
  }
  trap cleanup EXIT

  apply_managed_patch "$wt_dir" "$raw_patch" || fail "PR patch does not apply cleanly to current HEAD in disposable worktree"

  git -C "$wt_dir" diff > "$patch_out"
  [[ -s "$patch_out" ]] || fail "Generated patch is empty after normalization"

  local apply_to
  apply_to="$(first_path_from_patch "$patch_out" || true)"
  write_yaml_sidecar "$yaml_out" "$pr_url" "$issue_url" "$patch_title" "$apply_to" "$NOTES"

  echo "Created: $patch_out"
  echo "Created: $yaml_out"

  if [[ "$NO_APPLY" -eq 1 ]]; then
    echo "Skipped apply to live checkout (--no-apply)."
  else
    apply_managed_patch "$HERMES_DIR" "$patch_out" || fail "Patch file created, but apply to live checkout failed"
    case "$PATCH_APPLY_RESULT" in
      applied_direct)
        echo "Applied to live checkout: direct"
        ;;
      applied_3way)
        echo "Applied to live checkout: 3-way"
        ;;
      applied_3way_refreshed)
        echo "Applied to live checkout: 3-way (refreshed context)"
        ;;
      already_applied)
        echo "Live checkout already had this change"
        ;;
    esac
  fi

  echo "Touched files:"
  patch_touched_paths "$patch_out" | sed 's/^/  - /'

  cleanup
  trap - EXIT
}

build_patch_from_files() {
  require_cmd git

  [[ -d "$HERMES_DIR/.git" ]] || fail "HERMES_DIR is not a git checkout: $HERMES_DIR"
  mkdir -p "$PATCHES_DIR"

  [[ ${#FILES[@]} -gt 0 ]] || fail "--from-files requires at least one --file"

  local patch_title
  if [[ -n "$TITLE_OVERRIDE" ]]; then
    patch_title="$TITLE_OVERRIDE"
  else
    patch_title="local file patch"
  fi

  if [[ -z "$PATCH_NAME" ]]; then
    local first_file
    first_file="$(basename "${FILES[0]}")"
    PATCH_NAME="local-$(slugify "${first_file}")-$(date +%Y%m%d-%H%M%S)"
  fi

  local patch_out yaml_out temp_patch
  patch_out="$PATCHES_DIR/${PATCH_NAME}.patch"
  yaml_out="$PATCHES_DIR/${PATCH_NAME}.yaml"

  if [[ -e "$patch_out" || -e "$yaml_out" ]]; then
    if [[ "$PATCH_NAME_EXPLICIT" -eq 1 ]]; then
      fail "Patch target already exists: ${PATCH_NAME} (.patch/.yaml)"
    fi
    PATCH_NAME="${PATCH_NAME}-$(date +%Y%m%d-%H%M%S)"
    patch_out="$PATCHES_DIR/${PATCH_NAME}.patch"
    yaml_out="$PATCHES_DIR/${PATCH_NAME}.yaml"
  fi

  temp_patch="$(mktemp "${TMPDIR:-/tmp}/hermes-files.XXXXXX.patch")"
  git -C "$HERMES_DIR" diff -- "${FILES[@]}" > "$temp_patch"
  [[ -s "$temp_patch" ]] || fail "No diff found for provided --file paths"

  mv "$temp_patch" "$patch_out"

  local apply_to
  apply_to="$(first_path_from_patch "$patch_out" || true)"
  write_yaml_sidecar "$yaml_out" "" "$ISSUE_OVERRIDE" "$patch_title" "$apply_to" "$NOTES"

  echo "Created: $patch_out"
  echo "Created: $yaml_out"
  echo "Note: --from-files captures existing local diff and does not apply anything."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)
      MODE="pr"
      PR_REF="${2:-}"
      shift 2
      ;;
    --from-files)
      MODE="files"
      shift
      ;;
    --file)
      FILES+=("${2:-}")
      shift 2
      ;;
    --name)
      PATCH_NAME="${2:-}"
      PATCH_NAME_EXPLICIT=1
      shift 2
      ;;
    --title)
      TITLE_OVERRIDE="${2:-}"
      shift 2
      ;;
    --issue-url)
      ISSUE_OVERRIDE="${2:-}"
      shift 2
      ;;
    --notes)
      NOTES="${2:-}"
      shift 2
      ;;
    --no-apply)
      NO_APPLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$MODE" ]] || {
  usage
  exit 1
}

if [[ "$MODE" == "pr" ]]; then
  [[ -n "$PR_REF" ]] || fail "--pr requires a URL or PR number"
  build_patch_from_pr
elif [[ "$MODE" == "files" ]]; then
  build_patch_from_files
else
  fail "Unsupported mode: $MODE"
fi
