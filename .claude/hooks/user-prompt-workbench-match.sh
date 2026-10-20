#!/usr/bin/env bash

set -uo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
INPUT=$(cat 2>/dev/null || true)

HOOK_INPUT="$INPUT" python3 - "$VAULT_DIR" <<'PY' 2>/dev/null || true
import sys, os, json, re, glob

vault = sys.argv[1]
try:
    prompt = (json.loads(os.environ.get("HOOK_INPUT", "") or "{}") or {}).get("prompt", "") or ""
except Exception:
    sys.exit(0)
if not prompt.strip():
    sys.exit(0)

plow = prompt.lower()
prompt_words = set(re.findall(r"[a-z0-9][a-z0-9_-]*", plow))

STOP = {
    "go", "api", "apm", "rpc", "jwt", "ci", "cd", "mr", "pr", "adr", "cve", "url",
    "select", "review", "security", "test", "tests", "code", "data", "error",
    "cron", "gcs", "gke", "sso", "ruby", "rails", "python", "bash", "json",
    "cache", "auth", "redis", "sns", "slo", "pat", "wif", "pi", "ai", "ml",
}

def specific(tag):
    """A tag is specific enough to flag on if it is multi-part (hyphen/underscore),
    reasonably long, or a ticket key — not a bare short dictionary word."""
    if tag in STOP:
        return False
    if "-" in tag or "_" in tag:
        return True
    if re.match(r"^[a-z]+-?\d", tag):   # identifier-style, e.g. demo-101
        return True
    return len(tag) >= 5

def read_meta(path):
    tags, title = [], None
    try:
        with open(path, encoding="utf-8") as source:
            txt = source.read()
    except Exception:
        return tags, title
    m = re.search(r"^tech_surface:\s*\[(.*?)\]", txt, re.MULTILINE | re.DOTALL)
    if m:
        tags = [t.strip().lower() for t in m.group(1).split(",") if t.strip()]
    h = re.search(r"^#\s+(.+)$", txt, re.MULTILINE)
    if h:
        title = h.group(1).strip()
    return tags, title

hits = []
for path in sorted(glob.glob(os.path.join(vault, "wiki/workbench/*.md"))):
    tags, title = read_meta(path)
    matched = sorted({t for t in tags if specific(t) and t in prompt_words})
    if matched:
        rel = os.path.relpath(path, vault)
        hits.append((len(matched), rel, title or os.path.basename(path), matched))

if not hits:
    sys.exit(0)

hits.sort(key=lambda h: -h[0])
lines = ["🔎 Workbench cross-pollination — this prompt touches active work item(s):"]
for _, rel, title, matched in hits[:3]:
    shown = ", ".join(matched[:5])
    lines.append(f'  • {title} — {rel} (matched: {shown})')
if len(hits) > 3:
    lines.append(f"  • …and {len(hits) - 3} more (grep tech_surface: in wiki/workbench/ to see all)")
lines.append("  Re-check these pages before acting — they are volatile.")
print("\n".join(lines))
PY
exit 0
