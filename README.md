# hermes-update-workflow

A [Hermes Agent](https://hermes-agent.nousresearch.com) skill for safely updating Hermes Agent — with release gating, patch management, and explicit confirmation.

## The problem

`hermes update` pulls the latest `main` immediately with no confirmation. This workflow gates updates behind release tags, PR status checks, and explicit approval — so you never accidentally update mid-session or lose your local patches.

## Works well with

[hermes-git-sync](https://github.com/shared-goals/hermes-git-sync) — the template `Makefile` from that skill includes `make update`, `make check-update`, and `make patch` targets that call into this skill's scripts.

## Install

```bash
hermes skills tap add shared-goals/hermes-update-workflow
hermes skills install hermes-update-workflow
```

## Usage

Via `make` (recommended — requires [hermes-git-sync](https://github.com/shared-goals/hermes-git-sync) Makefile):

```bash
make check-update    # report new releases and patch PR statuses — no changes
make update          # full workflow: review, confirm, update, re-apply patches
make patch           # re-apply patches only (after manual hermes update)
```

Or directly:

```bash
MY_HERMES_REPO=~/my-hermes bash ~/.hermes/skills/devops/hermes-update-workflow/scripts/hermes-update.sh --check
MY_HERMES_REPO=~/my-hermes bash ~/.hermes/skills/devops/hermes-update-workflow/scripts/hermes-update.sh
```

## What `make update` does

1. Fetches upstream tags → finds latest release tag
2. Compares with current version
3. Shows changelog and asks for confirmation before updating
4. Checks each patch's PR/issue status — resolved patches can be retired
5. Checks which patches are already applied (skips them, no false conflicts)
6. Shows full summary before any confirmation
7. Two separate confirmations: update version? re-apply patches?

## Patch management

Patches live in `~/my-hermes/patches/` as self-contained pairs:

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

## Tip: guard against accidental `hermes update`

Add to `~/.zshrc`:
```zsh
alias hermes='_hermes_wrapper'
_hermes_wrapper() { [[ "$1" == "update" ]] && echo "⛔ Use: make update" && return 1; command hermes "$@"; }
```

## Author

[shag](https://github.com/sg-shag) · [Shared Goals](https://github.com/shared-goals)
