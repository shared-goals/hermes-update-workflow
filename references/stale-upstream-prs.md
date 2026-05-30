# Stale Upstream PRs — Minimal Backport Pattern

## When this applies

An upstream PR fixes the bug you're experiencing, but `git apply --check` fails
against current `origin/main` because:
- PR was opened weeks/months ago against an earlier `main`
- Surrounding code has shifted (line numbers, refactor, added helpers)
- PR includes tests/docs/examples you don't strictly need today

`hermes update` will eventually merge it (or reject it), but you need the fix now.

## The workflow

Don't fork the PR branch and rebase — that drags in stale context. Instead:

1. **Verify it's the right PR.** `gh pr view <N> --json body,comments` — confirm
   it addresses the exact symptom (status code, model, error class, not just
   "fallback broken" at a surface level).
2. **Download and sanity-check:**
   ```bash
   gh pr diff <N> > /tmp/pr-<N>.patch
   cd ~/.hermes/hermes-agent
   git worktree add /tmp/hermes-check origin/main
   cd /tmp/hermes-check
   git apply --check /tmp/pr-<N>.patch && echo "✅ applies clean" || echo "❌ stale"
   ```
3. **If stale — extract the minimal semantic fix.** Read the PR diff; identify the
   1–5 lines that actually change behavior (vs test scaffolding, doc updates,
   surrounding refactors). Apply only those to a clean `origin/main` checkout
   via `sed` or manual edit, then `git diff > ~/my-hermes/patches/<name>.patch`.
4. **Metadata in `.yaml` still references the upstream PR and issue:**
   ```yaml
   pr: 15666          # stale upstream PR — our patch is a minimal backport
   issue: 32961       # the actual bug — more authoritative than the PR
   title: "fix(error_classifier): 503/529 should trigger fallback chain"
   apply_to: agent/error_classifier.py
   notes: "Upstream PR #15666 is stale (25 April, main moved on). Minimal backport: adds should_fallback=True to 503/529 classifier branch."
   ```
5. **Verify on clean worktree:**
   ```bash
   git apply --check ~/my-hermes/patches/<name>.patch && echo "✅"
   ```

## When NOT to do this

- Upstream PR is **already merged** → just `make update`. Local patch would conflict.
- Upstream PR is **closed (rejected)** → the maintainer decided against it. Don't
  carry it locally; document why and accept upstream's call.
- The fix touches **web/src/** or high-churn generated/dist files → minimal
  backport breaks easily. Better to wait for upstream merge.

## Retiring the patch

When the upstream PR merges and the fix lands in `origin/main`:
1. `make update` (pulls the fix)
2. `git apply --check --reverse ~/my-hermes/patches/<name>.patch` returns
   "already applied" — the script detects and removes the patch file
3. No manual cleanup needed if `apply-patches.sh` handles this case

## Real example (May 2026)

- **Bug:** Daily Compass cron failed with 503, fallback never fired (`fallback_providers` config ignored)
- **Upstream:** PR #15666 (opened 25 April) added 27 lines across 4 files including eager-fallback control flow changes — `git apply --check` failed because `run_agent.py` context had drifted
- **Backport:** 1-line fix in `agent/error_classifier.py`:
  ```python
  # line 786, was:
  return result_fn(FailoverReason.overloaded, retryable=True)
  # became:
  return result_fn(FailoverReason.overloaded, retryable=True, should_fallback=True)
  ```
- **Issue reference:** #32961 (created same day, narrower scope — the classifier default)

The semantic fix was always the classifier default; the rest of PR #15666 was
belt-and-braces. Carrying just the classifier line survived the next update
without conflict.
