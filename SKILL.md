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

`hermes update` pulls latest `main` immediately with no confirmation.
This workflow gates updates behind release tags, PR status checks,
and explicit approval.

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
make check-update   # Report: new releases, PR statuses — no changes
make update         # Full workflow with confirmation
```

## What `make update` does

1. Fetch upstream tags → find latest release tag
2. Compare with current (`git describe --tags`)
3. **If new tag exists** → show changelog (first 40 lines), offer to update to tag `[y/N]`
4. **If already on latest tag** → fetch `origin/main`, count commits ahead; if any, show count + offer to update to main `[y/N]` (weekly tag ≠ stable — main may have critical fixes)
5. Check each `.yaml` sidecar via `gh issue/pr view` — resolved = patch can be retired
6. Check which patches are **actually applied** right now (`git apply --check --reverse`)
   - Already applied → ✅ skip, not an error
   - Not applied → will be offered for re-apply after update
7. Show full summary (version delta, PR statuses, patch states) **before any confirmation**
8. **Two separate confirmations**: (a) update version? (b) re-apply patches?
9. After update, re-check applied state (patches may have slipped after checkout)

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

`check-update` is called from `morning-brief` cron (8am Samara). The prompt reads detail from `cron-prompt.md` — if a new release is found, it is included in the daily summary. The agent does NOT auto-update; it reports and lets Sergey decide during the day.

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

Hermes releases are **weekly snapshots of `main`** — date-stamped tags, not curated stable builds. A new tag is not "more stable" than the commits between tags. `origin/main` may contain bug fixes that haven't landed in a tag yet. The workflow offers both options explicitly.

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

## Pitfalls

- **`hermes update` from dashboard** — now guarded by ConfirmDialog (PR #23773),
  but if that patch isn't applied yet it will update without confirmation.
- **Patch conflicts after update** — script now distinguishes three states:
  - `git apply --check` passes → apply normally
  - `git apply --check --reverse` passes → patch **already applied**, skip (✅ not an error)
  - both fail → genuine conflict, manual fix needed
  Both `hermes-update.sh` and `apply-patches.sh` implement this logic.
- **`git describe` returns commit hash** — means repo is on a commit between tags
  (e.g. after manual `git pull`). Run `git checkout <tag>` to pin to a release.
- **PR state "CLOSED" ≠ merged** — may mean upstream rejected the approach.
  Review before discarding the patch.
