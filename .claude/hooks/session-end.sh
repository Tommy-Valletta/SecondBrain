#!/usr/bin/env bash

set -euo pipefail

if [[ -n "${BRAIN_INGEST:-}" ]]; then
    cat >/dev/null 2>&1 || true   # drain stdin so the caller never sees EPIPE
    exit 0
fi

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_FILE="${VAULT_DIR}/wiki/logs/session-capture.log"

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // "unknown"')
REASON=$(echo "$INPUT" | jq -r '.reason // "unknown"')

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "[${TIMESTAMP}] SessionEnd: session_id=${SESSION_ID} reason=${REASON}" >> "$LOG_FILE"

SESSION_FILE=""
for f in "${VAULT_DIR}/outputs/session-summaries/"*"-${SESSION_ID}.md"; do
    if [[ -f "$f" ]]; then
        SESSION_FILE="$f"
        break
    fi
done

if [[ -z "$SESSION_FILE" ]]; then
    echo "[${TIMESTAMP}] SessionEnd: session file not found for ${SESSION_ID}, skipping" >> "$LOG_FILE"
    exit 0
fi

if [[ "$REASON" != "prompt_input_exit" ]] && [[ "$REASON" != "clear" ]] && [[ ! -f "$TRANSCRIPT_PATH" ]]; then
    if VAULT_DIR="$VAULT_DIR" SESSION_FILE="$SESSION_FILE" python3 -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["VAULT_DIR"], ".claude", "scripts", "lib"))
from frontmatter import split_fence
fm, _, ok = split_fence(open(os.environ["SESSION_FILE"]).read())
sys.exit(0 if ok and any(l.strip() == "status: draft" for l in fm) else 1)'; then
        rm -f "$SESSION_FILE"
        echo "[${TIMESTAMP}] SessionEnd: removed stub for non-interactive session ${SESSION_ID}" >> "$LOG_FILE"
        exit 0
    fi
fi

export SESSION_FILE TIMESTAMP LOG_FILE VAULT_DIR

python3 <<'PYQUICK'
# Keep metadata updates inside the frontmatter fence.
import os, sys

sys.path.insert(0, os.path.join(os.environ["VAULT_DIR"], ".claude", "scripts", "lib"))
from frontmatter import set_field, edit_fence, sub_body_once, split_fence

session_file = os.environ["SESSION_FILE"]
timestamp = os.environ["TIMESTAMP"]
log_file = os.environ["LOG_FILE"]

with open(session_file, 'r') as f:
    content = f.read()

_, _, fence_ok = split_fence(content)
if not fence_ok:
    # Refuse updates when the frontmatter fence is incomplete.
    with open(log_file, 'a') as lf:
        lf.write(f"[{timestamp}] SessionEnd: REFUSED metadata update -- no terminated "
                 f"frontmatter fence in {session_file}\n")
    sys.exit(0)

# Preserve captured/promoted status; only unfinished drafts advance.
_fm, _, _ = split_fence(content)
if any(l.strip() == 'status: draft' for l in _fm):
    content, _ = set_field(content, 'status', 'captured')
content, _ = set_field(content, 'updated_at', timestamp)

def _tags(fm):
    fm = [l for l in fm if l.rstrip() != '  - in-progress']
    if not any(l.rstrip() == '  - needs-review' for l in fm):
        for i, l in enumerate(fm):
            if l.rstrip() == '  - claude-code':
                fm.insert(i + 1, '  - needs-review')
                break
    return fm

content, _ = edit_fence(content, _tags)

# Provenance markers genuinely live in the body; count=1 so a later quote survives.
if '- Ended: ' in content:
    content, _ = sub_body_once(content, r'- Ended: [^\n]+', f'- Ended: {timestamp}')
else:
    content, _ = sub_body_once(content, r'(- Started: [^\n]+)',
                               r'\1\n- Ended: ' + timestamp)

with open(session_file, 'w') as f:
    f.write(content)
PYQUICK

echo "[${TIMESTAMP}] SessionEnd: metadata updated for ${SESSION_ID}" >> "$LOG_FILE"

touch "${VAULT_DIR}/outputs/.ingest-pending" 2>/dev/null || true

if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
    (
        python3 "${VAULT_DIR}/.claude/scripts/fill-session-sections.py" \
            --transcript "$TRANSCRIPT_PATH" \
            --cwd "$CWD" \
            "$SESSION_FILE" >> "$LOG_FILE" 2>&1
    ) &
    disown 2>/dev/null
    echo "[${TIMESTAMP}] SessionEnd: background section fill launched" >> "$LOG_FILE"
else
    echo "[${TIMESTAMP}] SessionEnd: no transcript at ${TRANSCRIPT_PATH}" >> "$LOG_FILE"
fi

rm -f "${SESSION_FILE}.bak"

echo "[${TIMESTAMP}] Session ended: ${SESSION_ID}" >> "$LOG_FILE"
