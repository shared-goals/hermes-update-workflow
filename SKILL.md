---
name: hermes-update-workflow
description: >
  Safe hermes-agent update workflow. Use when checking for new releases,
  reviewing patch PR statuses, or performing a controlled update with
  automatic patch re-application. Replaces bare `hermes update`.
triggers:
  - "hermes update"
  - "check for updates"
  - "new hermes release"
  - "re-apply patches"
  - "patch registry"
---

# Hermes Update Workflow

## Overview

This workflow wraps `hermes update` (the standard bundled updater) with:
- GitHub PR/issue status checks for each local patch
- Automatic patch re-application after update
- Clean handling of the stash-restore prompt

**Design decision (May 2026):** We switched from custom `git checkout origin/main`
to delegating to `hermes update`. Reason: `hermes update` always pulls latest main
(not just tags), handles Python/Node deps, restarts gateway, and syncs bundled skills.
We don't replicate that logic — we wrap around it.

### How `hermes update` handles dirty working tree

1. If working tree is dirty → auto-stash (`hermes-update-autostash-YYYYMMDD`)
2. `git pull` → latest main
3. Asks: **"Restore local changes? [Y/n]"**
   - `Y` → `git stash apply` (may conflict if patch is stale)
   - `N` → changes stay in stash

**`--yes` flag** auto-answers Y on restore — NOT what we want (patches may conflict).
**Solution (KISS):** The script prints a visible warning before running `hermes update`:
```
⚠  If hermes asks "Restore local changes?" — answer N
   (patches will be re-applied by this script afterward)
```
User answers N manually. If they know what they're doing, they can answer Y.

`echo "n" | hermes update` is technically possible but hides information from the user — avoid it.

See also: `references/web-build-pitfalls.md`, `references/skills-sync-internals.md` — manifest format, hash algorithm, how user-modified skills are detected and protected. — TypeScript version, devDeps, vite invocation, locale pitfalls, patch scope.

## Key Files

| File | Purpose |
|------|---------|
| `~/my-hermes/patches/<name>.patch` | Patch file |
| `~/my-hermes/patches/<name>.yaml` | Metadata for that patch (pr, issue, title) |
| `scripts/hermes-update.sh` (this skill) | Main update script — source of truth |
| `~/Makefile` targets `update` / `check-update` | Entry points (call script from skill) |

## Commands

```bash
make update-check   # Report: new releases, PR statuses — no changes
make update         # Full workflow with confirmation
```

## What `make update` does

1. Check each `.yaml` sidecar via `gh issue/pr view` — resolved = patch can be retired
2. Check which patches are **actually applied** right now (`git apply --check --reverse`)
   - Applied → will be unapplied before update (via `echo "n" | hermes update` handles stash)
   - Not applied → will be applied after update
   - Stale (neither check passes) → flagged as needing rebuild
3. Show full summary (PR statuses, patch states) **before any changes**
4. Run `hermes update` with stdin=N (auto-declines stash restore) — pulls latest main, rebuilds deps, restarts gateway
5. Re-apply all open patches via `git apply`

**Key invariant:** working tree is always clean before `hermes update` runs.
If patches were applied, the script unapplies them first via `git apply --reverse`.

## Patch Metadata Format (`patches/<name>.yaml`)\n\nEach `.patch` file has a sibling `.yaml` with metadata. No central `registry.yaml`.\n\n```yaml\npr: 12345           # upstream PR number (or null)\nissue: 6122         # upstream issue (preferred — more stable than PR)\ntitle: \"Short description\"\napply_to: path/to/file.py\nnotes: \"optional\"\n```\n\n**No `registry.yaml`** — replaced by per-patch `.yaml` files. Self-contained pairs: `my-fix.patch` + `my-fix.yaml`.\n\n**Issue vs PR as source of truth**: track `issue` when available — issues outlive PRs (duplicates get closed, PRs get superseded), and a CLOSED issue reliably means the fix landed upstream. PRs can be CLOSED without merging (rejected). The script checks issue first, falls back to PR `MERGED` state.

## Adding a New Patch

1. Create branch, make changes, push, open PR
2. Create related upstream issue (if none exists) and link PR via `Closes #N` in body
3. Save patch **minimally** — see warning below
4. Add entry to `registry.yaml` (with both `pr` and `issue` fields)
5. Commit both to `my-hermes`

### Generating a clean minimal patch

**Do NOT use `git diff main..<branch>`** when the branch was created from an old
`main`. All commits that landed in `main` after branching appear as deletions —
the patch becomes enormous and breaks on apply.

Instead: apply the change to a clean checkout of `origin/main`, then diff:

```bash
cd ~/.hermes/hermes-agent
git checkout origin/main -- path/to/file.py   # clean baseline
# apply changes manually (patch tool or editor)
git diff path/to/file.py > ~/shag-hermes/patches/my-fix.patch
git apply --check ~/shag-hermes/patches/my-fix.patch  # must pass
git restore path/to/file.py                            # undo working copy change
```

Always verify with `git apply --check` on a clean `origin/main` before saving.

**Best practice — use a worktree for verification** (avoids contaminating the working tree):

```bash
cd ~/.hermes/hermes-agent
git worktree add /tmp/hermes-check origin/main
cd /tmp/hermes-check
git apply --check ~/shag-hermes/patches/my-fix.patch && echo OK
cd ~/.hermes/hermes-agent
git worktree remove /tmp/hermes-check --force
```

Using `git stash` + `git apply --check` is unreliable when the working tree already
has multiple patches applied — stash only saves uncommitted changes, not the baseline
against which the patch was written.

## Patching Web Source Files (App.tsx, i18n, etc.)

Any patch that touches `web/src/` is **incomplete without a rebuilt `web_dist/`**.
Hermes validates the dist on startup and will refuse to start if it's stale.

Build steps (run from `~/.hermes/hermes-agent/web/`):

```bash
# 1. Install devDependencies (often missing in production checkout)
npm install --include=dev

# 2. TypeScript — must match package.json version, NOT latest global tsc
npm install -g typescript@$(node -e "console.log(require('./package.json').devDependencies.typescript.replace('~',''))")
tsc -b   # must be clean before vite build

# 3. Vite — do NOT use `npm run build` or `npx vite build` (triggers long-running-process guard)
npm run sync-assets
node node_modules/vite/bin/vite.js build

# 4. web_dist/ is in .gitignore — force-add it
git add -f hermes_cli/web_dist/
```

**i18n pitfall**: Adding a new key to `en.ts` + `types.ts` causes `tsc` to fail on all
other locale files (`af`, `de`, `es`, `fr`, `ga`, `hu`, `it`, `ja`, `ko`, `pt`, `ru`,
`tr`, `uk`, `zh`, `zh-hant`). Add the key to every locale file before building.

Quick script to add a key after an existing one across all locales:
```python
# patch all locale files: insert new_key after anchor_key
import glob, re
for f in glob.glob('web/src/i18n/*.ts'):
    if 'en.ts' in f or 'types.ts' in f or 'index.ts' in f:
        continue
    txt = open(f).read()
    if 'new_key' not in txt:
        txt = txt.replace('anchor_key: ', 'new_key: "…",\n    anchor_key: ')
        open(f, 'w').write(txt)
```

After amending the commit, force-push the PR branch:
```bash
git push fork <branch> --force
```
Then regenerate the patch file in `~/shag-hermes/patches/`.

## Bundled Skills Sync Mechanism

`tools/skills_sync.py` manages bundled→user skill sync via MD5 manifest at `~/.hermes/skills/.bundled_manifest`:

- **NEW skill** (not in manifest) → copied to `~/.hermes/skills/`, hash recorded
- **UNCHANGED skill** (hash matches) → updated from bundled if bundled changed
- **USER-MODIFIED skill** (hash differs) → **skipped**, reported as `~ N user-modified (kept)`
- **USER-DELETED skill** → respected, not re-added

To accept upstream changes for a modified skill: `hermes skills reset <name>`

This means: modifying skills in `~/.hermes/skills/` directly is safe across updates.
`external_dirs` is for skills from external projects, not for user-modified bundled skills.

### Patch validation across multiple patches

When verifying that local patches match upstream PRs, contamination of the working tree
makes `git apply --check` unreliable. Use a **worktree** to isolate each check:

```bash
git worktree add /tmp/hermes-check origin/main
cd /tmp/hermes-check
git apply --check ~/shag-hermes/patches/my-fix.patch && echo OK
cd ~/.hermes/hermes-agent
git worktree remove /tmp/hermes-check --force
```

PR diffs (`gh pr diff <N>`) may include `web_dist/` build artifacts — local patches
should contain only `web/src/` source changes. The two are semantically equivalent;
the dist is rebuilt separately.

## Bundled Skills Protection During Update

`hermes update` calls `skills_sync.sync_skills()` which reads `~/.hermes/skills/.bundled_manifest`.
- Skills where user copy MD5 ≠ origin_hash → **kept, not overwritten** — reported as `~ N user-modified (kept)`
- The "6 user-modified" message during update is expected and correct
- To accept upstream changes to a skill you modified: `hermes skills reset <skill-name>`
- Manifest lives at `~/.hermes/skills/.bundled_manifest`

User-modified skills tracked in git via `~/my-hermes/scripts/sync-my-skills.py` → `my-hermes/my-skills/`.

`sync-my-skills.py` uses the same dir_hash algorithm as `skills_sync.py`. For each modified skill it also writes `bundled.diff` (diff vs upstream) so the change is readable in git history. Run manually or via `hermes-git-sync.sh` (daily cron).

## Morning-brief integration

`update-check` is called from `morning-brief` cron (8am Samara). The prompt reads detail from `cron-prompt.md` — if a new release is found, it is included in the daily summary. The agent does NOT auto-update; it reports and lets Sergey decide during the day.

`make update` is the interactive path — run manually in terminal when ready to update.

The script (`scripts/hermes-update.sh`) lives in this skill directory. `~/Makefile` calls it via:
```makefile
update:
    MY_HERMES_REPO=$(HERMES_DIR) bash $(HOME)/.hermes/skills/devops/hermes-update-workflow/scripts/hermes-update.sh
check-update:
    MY_HERMES_REPO=$(HERMES_DIR) bash $(HOME)/.hermes/skills/devops/hermes-update-workflow/scripts/hermes-update.sh --check
```

## Workflow discipline

When making structural changes (moving files, changing config, deleting folders):
1. **Show the plan first** — list every file that will be affected, wait for confirm
2. **Show `git diff --stat` before every commit** — never auto-commit after a sequence of changes
3. **One commit per logical step** — don't bundle unrelated changes
4. **git reset is available** — if history got messy, `git reset --hard <hash> && git push --force` after explicit user approval

## Release policy

Hermes releases are **weekly snapshots of `main`** — date-stamped tags, not curated stable builds. `origin/main` = latest state, always. We target latest main, not tags.

**`make update` = correct entry point.** `hermes update` alone skips patch management.

Add to `~/.zshrc` to prevent bypassing `make update`:
```zsh
alias hermes='_hermes_wrapper'
_hermes_wrapper() { [[ "$1" == "update" ]] && echo "⛔ Use: make update" && return 1; command hermes "$@"; }
```

## apply-patches.sh

Lives in `scripts/apply-patches.sh` (this skill). Called via Makefile:

```makefile
patch:
    @MY_HERMES_REPO=$(HERMES_DIR) bash $(UPDATE_SCRIPTS)/apply-patches.sh
```

Uses `MY_HERMES_REPO` (default `~/my-hermes`) to locate `patches/*.patch`. Does NOT use relative paths — portable across machines. Legacy location `~/my-hermes/scripts/apply-patches.sh` is dead, delete it.

## Script locations

All scripts live **inside the skill directory** — not in `~/my-hermes/scripts/`. The Makefile calls them via absolute paths:

```makefile
UPDATE_SCRIPTS := $(HOME)/.hermes/skills/devops/hermes-update-workflow/scripts
patch:
    MY_HERMES_REPO=$(HERMES_DIR) bash $(UPDATE_SCRIPTS)/apply-patches.sh
```

`apply-patches.sh` uses `MY_HERMES_REPO` env var (default: `~/my-hermes`) to locate `patches/`. Never hardcode `$(dirname $0)/../patches` — it breaks when the script moves.

## Update flow — key facts

- `hermes update` auto-stashes dirty working tree before pulling — no manual unapply needed
- When `hermes update` asks **"Restore local changes? [Y/n]"** — answer **N** if patches will be re-applied by the script. The script prints a visible warning before launching `hermes update`.
- Do NOT use `hermes update --yes` — it answers Y to stash restore automatically, which may cause conflicts with patches.
- After `hermes update`, patch files become stale (upstream line numbers shift). Regenerate with:
  ```bash
  cd ~/.hermes/hermes-agent
  git diff HEAD -- hermes_cli/gateway.py > ~/my-hermes/patches/gateway-extra-env.patch
  ```
  Verify with: `git apply --check --reverse ~/my-hermes/patches/<name>.patch` — should say "Applied".
- `hermes update` pulls to **latest main** (not a release tag). This is the correct behavior — do not override with custom git checkout logic.

## Stale upstream PRs

See `references/stale-upstream-prs.md` — pattern for backporting a minimal fix
from a stale upstream PR instead of waiting for merge or fighting rebase conflicts.

## Public skill repos — structure

Both `hermes-git-sync` and `hermes-update-workflow` are published as separate repos under `shared-goals/` org. Each skill directory (`~/.hermes/skills/devops/<name>/`) has `.git` directly inside it — SSH remote (`git@github.com:shared-goals/<name>.git`). This allows `git push` directly from the skill dir.

`my-hermes/my-skills/` is a **snapshot only** (no `.git`) — updated via `make skills-sync`. Never put `.git` there.

To bootstrap a new skill repo with `.git`:
```bash
git clone https://github.com/shared-goals/<name>.git /tmp/<name>-tmp
mv /tmp/<name>-tmp/.git ~/.hermes/skills/devops/<name>/.git
cd ~/.hermes/skills/devops/<name>
git remote set-url origin git@github.com:shared-goals/<name>.git
```

## Why packages downgrade after `hermes update`

`hermes update` does `git reset --hard origin/main` when fast-forward fails (diverged history),
then runs `uv pip install -e .` from the updated `pyproject.toml`. If upstream pinned an older
version of a dependency than what was locally installed, pip enforces the pin → downgrade.

This is **intentional and correct** — hermes aligns deps strictly with `pyproject.toml` on `main`.
It is NOT a bug in the update workflow.

Example:
```
local:  SomeLib==1.5.0   (installed manually or via another tool)
main:   SomeLib==1.3.0   (pinned in pyproject.toml)
result: pip downgrades to 1.3.0
```

To pin a newer dep locally, you'd need to patch `pyproject.toml` — hard to maintain.
Preferred approach: accept the managed deps, or open upstream PR to bump the pin.

## Makefile target naming convention

- `install-my-hermes` — bootstrap my-hermes on a new machine (NOT `install`, which is ambiguous with `hermes install`)
- `update-check` — check for new releases, no changes (NOT `check-update`)
- `update` — full interactive update with confirmation

Keep target names unambiguous: prefix my-hermes management targets with `my-hermes-` or `update-`
so they don't shadow standard tool commands (`install`, `update`, `check`).

## Why packages get downgraded after `hermes update`

`hermes update` (`_cmd_update_impl` in `hermes_cli/main.py`) runs:
1. `git fetch origin`
2. `git pull --ff-only origin main` — if history has diverged (upstream force-pushed or rebased):
3. `git reset --hard origin/main` ← resets working tree to remote state exactly
4. `uv pip install -e .` (or `pip install -e .`) — reinstalls from the now-reset `pyproject.toml`

If `pyproject.toml` on `origin/main` pins a lower version of a dependency than what was locally installed, pip downgrades it. This is **intentional** — hermes enforces exact upstream dependency state. Workaround: patch `pyproject.toml` as a local patch (`.patch` file in `~/my-hermes/patches/`), not by manually installing packages.

## Pitfalls

- **Patch file stale after update** — upstream line numbers shift. Always regenerate patch files after `hermes update` and verify with `git apply --check --reverse`.
- **HTTPS remote blocks push in terminal** — skill repos must use SSH remote. Check with `git remote -v`; fix with `git remote set-url origin git@github.com:shared-goals/<name>.git`.
- **`.git` in wrong place** — `.git` belongs in `~/.hermes/skills/devops/<name>/`, NOT in `my-hermes/my-skills/`. The snapshot dir has no `.git` by design.
- **`hermes update` on custom branch** — updater detects non-main branch, switches to main, stashes. Always stay on `main` between update runs.



- **`hermes update` from dashboard** — now guarded by ConfirmDialog (PR #23773),
  but if that patch isn't applied yet it will update without confirmation.
- **Patch conflicts after update** — script now distinguishes three states:
  - `git apply --check` passes → apply normally
  - `git apply --check --reverse` passes → patch **already applied**, skip (✅ not an error)
  - both fail → genuine conflict, manual fix needed
  Both `hermes-update.sh` and `apply-patches.sh` implement this logic.
- **`git describe` returns commit hash** — means repo is on a commit between tags
  (e.g. after manual `git pull`). Normal — we target `origin/main`, not tags.
- **PR state "CLOSED" ≠ merged** — may mean upstream rejected the approach.
  Review before discarding the patch.
- **Stale patches after upstream churn** — patches targeting `web/src/App.tsx`
  or `hermes_cli/completion.py` go stale quickly (high-churn files). Check with
  `git apply --check` before running `make update`. Rebuild stale patches using
  the worktree method above.
- **Patch line numbers drift after `hermes update`** — even if the logic is still applied,
  `git apply --check` will fail because upstream shifted line numbers. Symptom:
  `error: patch failed: hermes_cli/gateway.py:2452` (old line) but code is present.
  Fix: regenerate the patch from current state:
  ```bash
  cd ~/.hermes/hermes-agent
  git diff HEAD -- hermes_cli/gateway.py > ~/my-hermes/patches/gateway-extra-env.patch
  # verify it matches what's applied:
  git apply --check --reverse ~/my-hermes/patches/gateway-extra-env.patch && echo "✅ OK"
  ```
  Run this after every `hermes update` that brings significant upstream churn (50+ commits).
- **`hermes update` auto-stash trap** — if patches are applied when you run
  `hermes update` directly (not via `make update`), it auto-stashes them, then
  asks "Restore?" — answering Y may cause conflicts on stale patches, answering
  N leaves them unapplied with no obvious indication. Always use `make update`.
- **`echo "n" | hermes update`** — the correct way to auto-decline stash restore
  in non-interactive contexts. `--yes` flag does the opposite (auto-confirms restore).
