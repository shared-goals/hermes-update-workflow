# skills_sync.py internals

Source: `~/.hermes/hermes-agent/tools/skills_sync.py`

## How bundled skill sync works

- Manifest lives at `~/.hermes/skills/.bundled_manifest`
- Format: `skill_name:origin_hash` (v2), one per line
- `origin_hash` = MD5 of bundled skill **at time of last sync**

## Hash algorithm (`_dir_hash`)

```python
hasher = hashlib.md5()
for fpath in sorted(directory.rglob("*")):
    if fpath.is_file():
        rel = fpath.relative_to(directory)
        hasher.update(str(rel).encode("utf-8"))  # filename included!
        hasher.update(fpath.read_bytes())
return hasher.hexdigest()
```

Key: **both filename and content** are hashed. If you only hash content, results won't match manifest.

## Update logic

| Condition | Action |
|-----------|--------|
| Skill not in manifest | Copy from bundled, record hash |
| In manifest, user copy matches origin_hash | User hasn't modified → safe to update |
| In manifest, user copy differs from origin_hash | **user-modified → SKIP, keep user version** |
| In manifest, absent from user dir | User deleted → respect, don't re-add |
| In manifest, gone from bundled | Clean from manifest |

## Skill directory layout

Bundled skills are stored with categories:
```
~/.hermes/hermes-agent/skills/<category>/<skill-name>/SKILL.md
~/.hermes/skills/<category>/<skill-name>/SKILL.md
```

Skills are looked up **flat by name** across all category subdirs.
`~/.hermes/skills/` is searched **before** external_dirs — user skills win.

## Detecting user-modified skills (Python snippet)

```python
import hashlib
from pathlib import Path

SKILLS_DIR = Path.home() / ".hermes/skills"
MANIFEST = SKILLS_DIR / ".bundled_manifest"

def dir_hash(path):
    hasher = hashlib.md5()
    for fpath in sorted(path.rglob("*")):
        if fpath.is_file():
            rel = fpath.relative_to(path)
            hasher.update(str(rel).encode("utf-8"))
            hasher.update(fpath.read_bytes())
    return hasher.hexdigest()

manifest = {}
for line in MANIFEST.read_text().splitlines():
    if ":" in line:
        name, _, h = line.partition(":")
        manifest[name.strip()] = h.strip()

for skill_md in SKILLS_DIR.rglob("SKILL.md"):
    skill_dir = skill_md.parent
    name = skill_dir.name
    if name in manifest and dir_hash(skill_dir) != manifest[name]:
        print(f"user-modified: {name}")
    elif name not in manifest:
        print(f"user-created: {name}")
```

## hermes update output

During `hermes update`, skills sync prints:
- `+ N new` — newly bundled skills copied to user dir
- `↑ N updated` — bundled changed, user copy was unmodified → updated
- `~ N user-modified (kept)` — user changed these, upstream skipped them
- `− N removed` — cleaned from manifest

`hermes skills reset <name>` — clears user-modified flag, accepts upstream version.
