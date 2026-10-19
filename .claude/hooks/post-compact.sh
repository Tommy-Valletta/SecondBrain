#!/usr/bin/env bash

set -euo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_FILE="${VAULT_DIR}/wiki/logs/session-capture.log"

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
COMPACT_SUMMARY=$(echo "$INPUT" | jq -r '.compact_summary // ""')
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "unknown"')

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "[${TIMESTAMP}] PostCompact: trigger=${TRIGGER}, summary_length=${#COMPACT_SUMMARY}" >> "$LOG_FILE"

if [[ -z "$COMPACT_SUMMARY" ]]; then
    echo "[${TIMESTAMP}] PostCompact: compact_summary field was empty in hook payload" >> "$LOG_FILE"
    exit 0
fi

SESSION_FILE=""
for f in "${VAULT_DIR}/outputs/session-summaries/"*"-${SESSION_ID}.md"; do
    if [[ -f "$f" ]]; then
        SESSION_FILE="$f"
        break
    fi
done

if [[ -z "$SESSION_FILE" ]]; then
    echo "[${TIMESTAMP}] PostCompact: session file not found for ${SESSION_ID}" >> "$LOG_FILE"
    exit 0
fi

export COMPACT_SUMMARY SESSION_FILE TIMESTAMP LOG_FILE VAULT_DIR

python3 <<'PYUPDATE'
import os, re, sys

summary = os.environ["COMPACT_SUMMARY"]
session_file = os.environ["SESSION_FILE"]
timestamp = os.environ["TIMESTAMP"]
log_file = os.environ["LOG_FILE"]

def log(msg):
    with open(log_file, 'a') as f:
        f.write(f"[{timestamp}] PostCompact: {msg}\n")

if not summary:
    log("summary was empty after env lookup")
    sys.exit(0)

log(f"writing {len(summary)} chars to session file")

with open(session_file, 'r') as f:
    content = f.read()

# Append compaction to history instead of replacing.
# Each compaction is a snapshot of cumulative understanding at that point.
marker = '## Compact Summary\n\n'
idx = content.find(marker)

if idx >= 0:
    rest = content[idx + len(marker):]
    next_heading_pos = rest.find('\n## ')

    # Extract existing compaction history
    if next_heading_pos >= 0:
        existing = rest[:next_heading_pos].strip()
        next_section = rest[next_heading_pos:]
    else:
        existing = rest.strip()
        next_section = ''

    # Build new compaction entry
    import re
    compaction_num = len(re.findall(r'^### Compaction \d+', existing, re.MULTILINE)) + 1
    new_entry = f"### Compaction {compaction_num} ({timestamp})\n\n{summary}"

    # Append to history
    if existing and existing != '_To be filled by post-compact hook_':
        updated = existing + '\n\n' + new_entry
    else:
        updated = new_entry

    content = content[:idx] + marker + updated + '\n' + next_section
else:
    log("'## Compact Summary' heading not found in session file")
    sys.exit(0)

# Preserve body text when updating metadata.
sys.path.insert(0, os.path.join(os.environ["VAULT_DIR"], ".claude", "scripts", "lib"))
from frontmatter import set_field
content, _changed = set_field(content, 'updated_at', timestamp)
if not _changed:
    log("WARN: updated_at not set (no usable frontmatter fence?)")

with open(session_file, 'w') as f:
    f.write(content)

log("session file updated successfully")
PYUPDATE
