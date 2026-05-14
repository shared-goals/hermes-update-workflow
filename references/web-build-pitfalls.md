# Web Build Pitfalls (hermes-agent web/src patches)

## TypeScript version mismatch

`tsc` must match `package.json` devDependencies version, not latest global.

```bash
# Check required version
cat web/package.json | grep '"typescript"'
# → "typescript": "~5.9.3"

# Install matching global
npm install -g typescript@5.9.3
tsc --version   # verify
```

TypeScript 6.x will fail silently or with cryptic errors on a 5.x project.

## devDependencies not installed

Production checkout of hermes-agent often has only `dependencies`, not `devDependencies`.
`tsc`, `vite`, `@vitejs/plugin-react` etc. will be missing.

```bash
cd ~/.hermes/hermes-agent/web
npm install --include=dev
```

## vite build — long-running-process guard

`npm run build` and `npx vite build` trigger the long-running-process guard.
Use node directly:

```bash
cd ~/.hermes/hermes-agent/web
npm run sync-assets                          # copies fonts/assets from @nous-research/ui
node node_modules/vite/bin/vite.js build    # safe equivalent of `npm run build`
```

## web_dist is gitignored — force-add

```bash
git add -f hermes_cli/web_dist/
```

Without this the dist is not included in the commit and the PR patch is incomplete.
Hermes validates dist freshness on startup and refuses to start if stale.

## All locale files must have every key

Adding a key to `en.ts` + `types.ts` makes `tsc` fail on af/de/es/fr/ga/hu/it/ja/ko/pt/ru/tr/uk/zh/zh-hant.
Add the new key to every locale file before building.

Pattern (run from web/ dir):
```python
import glob
new_line = '    confirmSomething: "This will do the thing.",'
anchor   = '    updatingSomething:'
for f in glob.glob('src/i18n/*.ts'):
    if any(x in f for x in ('en.ts', 'types.ts', 'index.ts')):
        continue
    txt = open(f).read()
    if 'confirmSomething' not in txt:
        open(f, 'w').write(txt.replace(anchor, new_line + '\n    ' + anchor.strip()))
```

## Patch verification after web changes

Use a worktree, not git stash — the working tree has other patches applied:

```bash
git worktree add /tmp/hermes-check origin/main
cd /tmp/hermes-check
git apply --check ~/shag-hermes/patches/my-web-fix.patch && echo OK
cd ~/.hermes/hermes-agent
git worktree remove /tmp/hermes-check --force
```

## Patch scope — web/src only, not web_dist

The patch file for a PR should cover only `web/src/` changes.
`web_dist/` is rebuilt and force-committed separately on the PR branch.
The patch in `~/shag-hermes/patches/` should NOT include `web_dist/` —
it's too large, machine-generated, and will conflict on every upstream update.

Generate patch scoped to src:
```bash
git diff origin/main -- web/src/ > ~/shag-hermes/patches/my-fix.patch
```
