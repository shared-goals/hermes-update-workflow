---
name: hermes-update-workflow
description: Safe Hermes update and local patch intake workflow.
triggers:
  - "hermes update"
  - "make update"
  - "make patch-pr"
  - "make patch-files"
  - "apply upstream PR locally"
  - "create patch from changed files"
---

# Hermes Update Workflow Skill

## Overview

This skill owns two related workflows:

1. Safe update wrapper around `hermes update`.
2. Local patch intake from upstream PRs or selected changed files.

The update path remains centered on:

- `make update`
- `make patch-pr <pr_url_or_id>`
- `make patch-files <file1> <file2> ...`

No custom replacement of Hermes core updater logic is used. The wrapper delegates to
`hermes update`, then restores local patch state.

## Source Of Truth Files

- `scripts/hermes-update.sh`: update/check orchestration
- `scripts/patch-helpers.sh`: shared patch-apply logic
- `scripts/patch-from-pr-or-files.sh`: new patch intake script
- `~/my-hermes/patches/*.patch`: local patch payload
- `~/my-hermes/patches/*.yaml`: metadata sidecar

## When To Use

Use this skill when you need one of the following:

- Check if local patches are still needed upstream.
- Update Hermes safely while preserving local patch set.
- Apply an upstream PR to the current local Hermes checkout.
- Snapshot selected local changed files into a managed patch pair.

## Prerequisites

- `gh` CLI installed and authenticated for PR mode.
- Local checkout at `~/.hermes/hermes-agent`.
- Patch repo at `~/my-hermes` (override with `MY_HERMES_REPO`).

## Quick Commands

```bash
# Show update status, then ask whether to apply
make update

# Apply PR diff to local checkout + generate patch/.yaml in my-hermes
make patch-pr https://github.com/NousResearch/hermes-agent/pull/56911

# Create patch/.yaml from current local diff for chosen files
make patch-files gateway/run.py cli.py
```

## Update Workflow Behavior

`make update` performs this sequence:

1. Compare the installed workflow files with `shared-goals/hermes-update-workflow@main`.
   - Matching files show a green freshness banner.
   - Outdated or locally modified files show a warning and refresh guidance.
   - A failed freshness lookup is non-blocking because Hermes update safety still runs locally.
2. Fetch `origin/main`; fail instead of using a stale cached ref.
3. Show the exact current and target SHAs plus the real commit and changed-file gap.
4. Require that the local checkout can fast-forward to `origin/main`.
5. Read patch sidecars (`*.yaml`) from `~/my-hermes/patches`.
6. Resolve upstream status (issue first, PR second).
7. Detect per-patch local state:
   - not applied
   - applied
   - stale/conflicting
8. Show summary before changes and ask for confirmation.
9. Remove applied managed patches and require a clean working tree.
10. Run `hermes update --branch main --backup` when confirmed.
11. Re-apply only still-needed patches.
12. Refresh `origin/main` and require `HEAD == origin/main`.

Important prompt handling:

- If `hermes update` asks `Restore local changes? [Y/n]`, answer `N`.
- Local patches are re-applied by this skill scripts afterward.

## Patch Intake Workflow

### PR Mode (`--pr`)

`patch-from-pr-or-files.sh --pr ...` does the following:

1. Fetch PR diff with `gh pr diff`.
2. Create a disposable worktree from current local `HEAD`.
3. Apply PR diff in disposable worktree (with shared managed patch logic).
4. Generate normalized patch file from the resulting diff.
5. Write patch pair in `~/my-hermes/patches`:
   - `<name>.patch`
   - `<name>.yaml`
6. Apply generated patch to live `~/.hermes/hermes-agent` checkout (unless `--no-apply`).

Why this design:

- Existing local patches in live checkout do not contaminate generated patch content.
- Resulting patch is generated from clean disposable state and then applied to live repo.

### Files Mode (`--from-files --file ...`)

Use this when you already made local edits and want to register them as patch artifacts.

1. Collect diff for selected file paths from live checkout.
2. Write `<name>.patch` and `<name>.yaml` into `~/my-hermes/patches`.
3. No apply step is needed because changes already exist locally.

## Sidecar Metadata Format

```yaml
pr: "https://github.com/NousResearch/hermes-agent/pull/12345"
issue: "https://github.com/NousResearch/hermes-agent/issues/6122"
title: "Short description"
apply_to: path/to/file.py
notes: "optional"
```

Rules:

- Keep `pr` as full URL for PR-based patches.
- Keep `issue` when known (prefer issue lifecycle for retirement decisions).
- Patch name and sidecar basename must match exactly.

## Validation Checklist

After patch intake from PR:

```bash
cd ~/.hermes/hermes-agent
# expected: reverse-check passes if patch is applied
git apply --check --reverse ~/my-hermes/patches/<name>.patch

# verify touched files
git status --short

cd ~/my-hermes
ls patches/<name>.patch patches/<name>.yaml
```

## Pitfalls

- `--yes` with `hermes update` auto-restores stash and may conflict with stale patches.
- Patch files can go stale after large upstream churn; regenerate using PR mode.
- PR `CLOSED` is not equal to `MERGED`; issue lifecycle is more reliable for retirement.
- If PR diff includes build artifacts not needed locally, keep patch focused on source files.

## Better Local Patch Control (Recommended Policy)

Use a three-layer model:

1. Live runtime state: local applied patches in `~/.hermes/hermes-agent`.
2. Durable local registry: `~/my-hermes/patches/*.patch` + `*.yaml`.
3. Upstream truth: GitHub issue/PR state.

Operational pattern:

- Intake via PR mode whenever possible.
- Keep patch artifacts in `my-hermes` under git.
- Use `make update` as the single controlled entrypoint.
- Retire patch artifacts when upstream issue is closed or PR is merged.
