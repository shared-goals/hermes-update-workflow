# Local PR patch policy

Use this when a Hermes Agent checkout carries local fixes that also have upstream PRs.

## Goal

Keep the day-to-day / production Hermes checkout updateable while still running local fixes before upstream merges them.

## Invariant

- The production checkout (`~/.hermes/hermes-agent`) should be on `main` / latest upstream baseline between update runs.
- Local fixes for open upstream PRs live as patch files in `~/my-hermes/patches/*.patch` with matching `*.yaml` metadata.
- Applied local fixes may make the production checkout dirty. That is expected and better than hiding them in local commits.
- Do **not** commit applied patches into the production checkout just to make `git status` clean.
- PR branches are for authoring/submission only, not for running Hermes day-to-day.

## Why

A committed local patch makes the working tree look clean, but it creates a private branch shape that `hermes update` is not designed around. The update wrapper tracks patch files, checks whether they are applied with `git apply --check --reverse`, unapplies them before update, then reapplies them afterward.

If a fix is committed locally *and* also tracked as a patch file, there are two sources of truth. After an update, the script may reverse/apply the patch against a branch commit and leave the checkout in a confusing state.

## Desired production checkout shape

```text
~/.hermes/hermes-agent
  branch: main
  baseline: origin/main or latest upstream main
  working tree: dirty only because open local patches are applied

~/my-hermes/patches/
  <patch-name>.patch
  <patch-name>.yaml
```

## Verify patches independently before normalizing

Use an isolated worktree based on `origin/main`; do not rely on the already-dirty production checkout.

```bash
cd ~/.hermes/hermes-agent
wt=/tmp/hermes-patch-check-$$
git worktree add --detach "$wt" origin/main
cd "$wt"

for p in ~/my-hermes/patches/*.patch; do
  git apply --check "$p" || exit 1
done

# Optional: verify that all patches apply sequentially together.
for p in ~/my-hermes/patches/*.patch; do
  git apply "$p" || exit 1
done
git diff --stat

cd ~/.hermes/hermes-agent
git worktree remove "$wt" --force
```

Expected result: each patch applies to clean `origin/main`; sequential application should also pass unless patches intentionally conflict.

## Normalize production checkout from a PR branch + patches

Use this when production is accidentally on a PR branch, or one patch is committed while another is uncommitted.

1. Record current state:
   ```bash
   cd ~/.hermes/hermes-agent
   git status --short --branch
   git branch --show-current
   git log --oneline --decorate -5
   ```
2. If an uncommitted patch is present on the PR branch, unapply it first:
   ```bash
   git apply --reverse ~/my-hermes/patches/<uncommitted-patch>.patch
   ```
3. Switch to `main` and fast-forward to upstream:
   ```bash
   git switch main
   git merge --ff-only origin/main
   ```
4. Apply every open patch as an uncommitted working-tree diff:
   ```bash
   for p in ~/my-hermes/patches/*.patch; do
     if git apply --check --reverse "$p" >/dev/null 2>&1; then
       echo "already applied: $(basename "$p")"
     elif git apply --check "$p" >/dev/null 2>&1; then
       git apply "$p"
       echo "applied: $(basename "$p")"
     else
       echo "conflict: $(basename "$p")" >&2
       git apply --check "$p" || true
       exit 2
     fi
   done
   ```
5. Verify final state:
   ```bash
   git status --short --branch
   for p in ~/my-hermes/patches/*.patch; do
     git apply --check --reverse "$p" && echo "APPLIED_OK: $(basename "$p")"
   done
   git diff --stat
   ```

Expected result:

```text
## main...origin/main
 M <files touched by open patches>
APPLIED_OK: <each patch>
```

## If a PR patch was accidentally committed in production checkout

1. Confirm the patch file exists and reverse-checks cleanly:
   ```bash
   cd ~/.hermes/hermes-agent
   git apply --check --reverse ~/my-hermes/patches/<name>.patch
   ```
2. Switch/reset the production checkout back to the normal baseline only after showing the plan and getting approval.
3. Re-apply the patch from `~/my-hermes/patches/<name>.patch` as an uncommitted working-tree diff.
4. Verify every patch with `git apply --check --reverse`.

## When to commit

Commit only in the PR branch used to submit upstream. After opening/updating the PR, regenerate the patch file from the minimal diff and return the production checkout to baseline + uncommitted applied patch.

Patch files and metadata may be committed in `~/my-hermes`; applied patch diffs should not be committed in `~/.hermes/hermes-agent`.
