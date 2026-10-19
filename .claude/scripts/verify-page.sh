#!/usr/bin/env bash
set -uo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PAGE=""; CLAIM=""; EXPECT=""; REFUTE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --claim) CLAIM="${2:-}"; shift 2 ;;
        --expect) EXPECT="${2:-}"; shift 2 ;;
        --refute) REFUTE="${2:-}"; shift 2 ;;
        --) shift; break ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) if [[ -z "$PAGE" ]]; then PAGE="$1"; else echo "unexpected arg: $1" >&2; exit 2; fi; shift ;;
    esac
done
[[ -n "$PAGE" && $# -gt 0 ]] || {
    echo 'usage: verify-page.sh <page.md> [--claim "..."] [--expect RE] [--refute RE] -- <command...>' >&2
    echo '  --expect RE   refuse to stamp unless the output matches RE (egrep)' >&2
    echo '  --refute RE   refuse to stamp if the output matches RE' >&2
    exit 2; }
[[ "$PAGE" = /* ]] || PAGE="${VAULT_DIR}/${PAGE}"
[[ -f "$PAGE" ]] || { echo "no such page: $PAGE" >&2; exit 2; }

CMD=$(printf '%q ' "$@"); CMD="${CMD% }"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "→ running: $CMD"
OUTPUT=$("$@" 2>&1); RC=$?
printf '%s\n' "$OUTPUT" | head -20
echo "→ exit $RC"

if [[ $RC -ne 0 ]]; then
    echo "✗ command failed (exit $RC). last_verified NOT written." >&2
    echo "  A failed check is not a verification. Fix the command or the claim." >&2
    exit "$RC"
fi

if [[ -n "$EXPECT" ]] && ! printf '%s\n' "$OUTPUT" | grep -qE -- "$EXPECT"; then
    echo "✗ output does not match --expect '$EXPECT'. last_verified NOT written." >&2
    exit 1
fi
if [[ -n "$REFUTE" ]] && printf '%s\n' "$OUTPUT" | grep -qE -- "$REFUTE"; then
    echo "✗ output matches --refute '$REFUTE'. last_verified NOT written." >&2
    exit 1
fi

export BRAIN_VERIFY_TOOL=1
PAGE="$PAGE" TS="$TIMESTAMP" CMD="$CMD" CLAIM="$CLAIM" RESULT="$OUTPUT" \
EXPECT="$EXPECT" REFUTE="$REFUTE" python3 - <<'PY'
import os, re, sys

page, ts = os.environ["PAGE"], os.environ["TS"]
cmd, claim = os.environ["CMD"], os.environ["CLAIM"]
result = " ".join(os.environ["RESULT"].split())[:300] or "(no output)"

src = open(page, encoding="utf-8").read()
end = src.find("\n---", 4)
if not src.startswith("---\n") or end == -1:
    sys.exit("✗ page has no usable frontmatter fence — refusing to guess where it ends (frontmatter boundaries)")
head, body = src[:end], src[end:]

def yq(s):
    """Single-quoted YAML scalar: the only escape is '' for a literal quote."""
    return "'" + s.replace("'", "''") + "'"

rescued = ""
m = re.search(r'^last_verified:[ \t]*(.*)$', head, re.M)
if m:
    old = m.group(1).strip()
    bare = old.split("#")[0].strip().strip("'\"")
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', bare) and old:
        rescued = old

head = re.sub(r'^updated_at:.*$', f'updated_at: {ts}', head, count=1, flags=re.M)

stamp = f"last_verified: {ts}\nverified_by: {yq(cmd)}"

head = re.sub(r'^verified_by:.*\n?', '', head, flags=re.M)
if re.search(r'^last_verified:', head, re.M):
    head = re.sub(r'^last_verified:.*$', lambda _m: stamp, head, count=1, flags=re.M)
elif re.search(r'^updated_at:', head, re.M):
    head = re.sub(r'^(updated_at:.*)$', lambda mm: mm.group(1) + "\n" + stamp, head, count=1, flags=re.M)
else:
    head = head.rstrip("\n") + "\n" + stamp

entry = (f"\n### {ts[:10]} — verified\n"
         f"- **Claim**: {claim or '_(none given — say what this establishes next time)_'}\n"
         f"- **Command**: `{cmd}`\n"
         f"- **Result**: `{result}`\n")
for lbl, key in (("Asserted", "EXPECT"), ("Refuted", "REFUTE")):
    v = os.environ.get(key, "")
    if v:
        entry += f"- **{lbl}**: output {'matches' if key == 'EXPECT' else 'must not match'} `/{v}/`\n"
if rescued:
    entry += f"- **Superseded hand-typed value**: `{rescued}`\n"

if "\n## Verification\n" in body:
    body = body.replace("\n## Verification\n", "\n## Verification\n" + entry, 1)
else:
    body = body.rstrip("\n") + "\n\n## Verification\n" + entry

open(page, "w", encoding="utf-8").write(head + body)
print(f"✓ last_verified: {ts}")
print(f"✓ verified_by:   {cmd}")
print(f"  → {page}")
if rescued:
    print(f"  ↳ rescued a hand-typed value into ## Verification: {rescued[:60]}…")
PY
