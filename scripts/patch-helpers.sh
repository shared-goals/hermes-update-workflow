#!/usr/bin/env bash

patch_touched_paths() {
  local patch_path="$1"
  awk '
    /^diff --git a\// {
      path = $4
      sub(/^b\//, "", path)
      if (!seen[path]++) {
        print path
      }
    }
  ' "$patch_path"
}

patch_has_unmerged_paths() {
  local repo_path="$1"
  local patch_path="$2"
  local paths=()
  local path

  while IFS= read -r path; do
    [[ -n "$path" ]] && paths+=("$path")
  done < <(patch_touched_paths "$patch_path")

  if [[ ${#paths[@]} -eq 0 ]]; then
    return 1
  fi

  git -C "$repo_path" diff --name-only --diff-filter=U -- "${paths[@]}" | grep -q .
}

patch_can_apply_3way_cleanly() {
  local repo_path="$1"
  local patch_path="$2"
  local temp_index
  local index_path

  temp_index=$(mktemp "${TMPDIR:-/tmp}/hermes-patch-index.XXXXXX")
  index_path=$(git -C "$repo_path" rev-parse --git-path index)
  if [[ "$index_path" != /* ]]; then
    index_path="$repo_path/$index_path"
  fi
  cp "$index_path" "$temp_index"

  if ! GIT_INDEX_FILE="$temp_index" git -C "$repo_path" apply --3way --index "$patch_path" >/dev/null 2>&1; then
    rm -f "$temp_index"
    return 1
  fi

  if GIT_INDEX_FILE="$temp_index" git -C "$repo_path" ls-files -u | grep -q .; then
    rm -f "$temp_index"
    return 1
  fi

  rm -f "$temp_index"
  return 0
}

refresh_patch_after_3way() {
  local repo_path="$1"
  local patch_path="$2"
  local temp_patch
  local paths=()
  local path

  while IFS= read -r path; do
    [[ -n "$path" ]] && paths+=("$path")
  done < <(patch_touched_paths "$patch_path")

  if [[ ${#paths[@]} -eq 0 ]]; then
    return 1
  fi

  temp_patch=$(mktemp "${TMPDIR:-/tmp}/$(basename "$patch_path").XXXXXX")
  if ! git -C "$repo_path" diff -- "${paths[@]}" > "$temp_patch"; then
    rm -f "$temp_patch"
    return 1
  fi

  if [[ ! -s "$temp_patch" ]]; then
    rm -f "$temp_patch"
    return 1
  fi

  mv "$temp_patch" "$patch_path"
  return 0
}

apply_managed_patch() {
  local repo_path="$1"
  local patch_path="$2"
  local refresh_after_3way="${3:-true}"

  PATCH_APPLY_RESULT=""

  if git -C "$repo_path" apply --check --reverse "$patch_path" >/dev/null 2>&1; then
    PATCH_APPLY_RESULT="already_applied"
    return 0
  fi

  if git -C "$repo_path" apply --check "$patch_path" >/dev/null 2>&1; then
    git -C "$repo_path" apply "$patch_path"
    PATCH_APPLY_RESULT="applied_direct"
    return 0
  fi

  if ! patch_can_apply_3way_cleanly "$repo_path" "$patch_path"; then
    PATCH_APPLY_RESULT="conflict"
    return 1
  fi

  git -C "$repo_path" apply --3way "$patch_path" >/dev/null

  if patch_has_unmerged_paths "$repo_path" "$patch_path"; then
    PATCH_APPLY_RESULT="conflict"
    return 1
  fi

  if [[ "$refresh_after_3way" == "true" ]] && refresh_patch_after_3way "$repo_path" "$patch_path"; then
    PATCH_APPLY_RESULT="applied_3way_refreshed"
  else
    PATCH_APPLY_RESULT="applied_3way"
  fi

  return 0
}
