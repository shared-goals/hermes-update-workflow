# hermes-update-workflow

A [Hermes Agent](https://hermes-agent.nousresearch.com) skill for safely updating Hermes Agent — with release gating, patch management, and explicit confirmation.

## The problem

`hermes update` pulls the latest `main` immediately with no confirmation. This workflow shows the exact target commit, requires a fast-forward and clean tree, offers an optional full backup (default no), checks patch status, and asks for explicit approval before updating.

## Works well with

[hermes-git-sync](https://github.com/shared-goals/hermes-git-sync) — the template `Makefile` from that skill includes `make update`, `make patch-pr`, and `make patch-files` targets that call into this skill's scripts.

## Install

```bash
hermes skills tap add shared-goals/hermes-update-workflow
hermes skills install hermes-update-workflow
```

## Usage

Via `make` (recommended — requires [hermes-git-sync](https://github.com/shared-goals/hermes-git-sync) Makefile):

```bash
make update          # show status first, then ask whether to apply
make patch-pr https://github.com/NousResearch/hermes-agent/pull/56911
make patch-files gateway/run.py cli.py
```

Or directly:

```bash
MY_HERMES_REPO=~/my-hermes bash ~/.hermes/skills/devops/hermes-update-workflow/scripts/hermes-update.sh

# Apply upstream PR locally + generate managed patch files
MY_HERMES_REPO=~/my-hermes bash ~/.hermes/skills/devops/hermes-update-workflow/scripts/patch-from-pr-or-files.sh \
	--pr https://github.com/NousResearch/hermes-agent/pull/56911

# Create managed patch files from selected local changed files
MY_HERMES_REPO=~/my-hermes bash ~/.hermes/skills/devops/hermes-update-workflow/scripts/patch-from-pr-or-files.sh \
	--from-files --file gateway/run.py --file cli.py
```

## What `make update` does

1. Shows whether the installed update workflow matches this repository's latest `main`
2. Fetches `origin/main` and tags, failing closed if the fetch fails
3. Shows exact current/target SHAs and the real commit/file gap
4. Requires a fast-forward path and a clean tree after managed patches are removed
5. Checks each patch's PR/issue status — resolved patches can be retired
6. Shows the full summary and asks for confirmation
7. Prompts for optional full backup (default no), then runs `hermes update --branch main`
8. Re-applies still-needed patches and restarts the gateway when necessary
9. Verifies that the resulting `HEAD` equals the latest `origin/main`

## Patch management

Shared fixes can ship in this repository's `patches/` directory. Personal or
newly-authored fixes live in `~/my-hermes/patches/`. Both use self-contained
pairs:

```
patches/
├── my-fix.patch     # the patch itself
└── my-fix.yaml      # metadata: pr, issue, title
```

`my-fix.yaml` format:
```yaml
pr: "https://github.com/NousResearch/hermes-agent/pull/12345"
issue: "https://github.com/NousResearch/hermes-agent/issues/6122"
title: "Short description"
apply_to: path/to/file.py
```

Track `issue` when available — issues outlive PRs and a CLOSED issue reliably means the fix landed upstream.

The updater processes bundled and local pairs together. A local pair with the
same basename overrides the bundled pair, allowing patch context to be refreshed
without applying the same logical fix twice. Bundled assets remain immutable
during 3-way application so an update cannot make the installed skill appear
locally modified.

## Tip: guard against accidental `hermes update`

Add to `~/.zshrc`:
```zsh
alias hermes='_hermes_wrapper'
_hermes_wrapper() { [[ "$1" == "update" ]] && echo "⛔ Use: make update" && return 1; command hermes "$@"; }
```

## Author

[shag](https://github.com/sg-shag) · [Shared Goals](https://github.com/shared-goals)
