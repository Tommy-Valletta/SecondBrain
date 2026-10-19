#!/usr/bin/env bash
set -uo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)" || exit 0
LOG_FILE="${VAULT_DIR}/wiki/logs/session-capture.log"
INPUT=$(cat)

command -v jq >/dev/null 2>&1 || exit 0
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null) || exit 0
SESSION_ID="${SESSION_ID//[^A-Za-z0-9._-]/_}"

LIST="${VAULT_DIR}/outputs/.touched/${SESSION_ID}.txt"
[[ -f "$LIST" ]] || exit 0

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

STAMPED=$(LIST="$LIST" TS="$TIMESTAMP" VAULT="$VAULT_DIR" python3 - <<'PY' 2>/dev/null
import os, re, sys

ts, vault = os.environ["TS"], os.environ["VAULT"]
try:
    pages = sorted(set(l.strip() for l in open(os.environ["LIST"], encoding="utf-8") if l.strip()))
except OSError:
    print(0); sys.exit(0)

n = 0
for page in pages:
    if not (page.startswith(os.path.join(vault, "wiki") + os.sep) and page.endswith(".md")):
        continue
    try:
        src = open(page, encoding="utf-8").read()
    except OSError:
        continue
    if not src.startswith("---\n"):
        continue                      # no frontmatter: not ours to touch
    end = src.find("\n---", 4)
    if end == -1:
        continue                      # unterminated fence: leave it alone (frontmatter boundaries)
    head, body = src[:end], src[end:]
    if re.search(r'^updated_at:', head, re.M):
        new = re.sub(r'^updated_at:.*$', f'updated_at: {ts}', head, count=1, flags=re.M)
    else:
        new = head.rstrip("\n") + f"\nupdated_at: {ts}"
    if new != head:
        try:
            open(page, "w", encoding="utf-8").write(new + body)
            n += 1
        except OSError:
            pass
print(n)
PY
)

rm -f "$LIST" 2>/dev/null
[[ -n "${STAMPED:-}" ]] || STAMPED=0
if [[ "$STAMPED" -gt 0 ]]; then
    echo "[${TIMESTAMP}] Stop: derived updated_at on ${STAMPED} page(s)" >> "$LOG_FILE" 2>/dev/null || true
fi
exit 0
