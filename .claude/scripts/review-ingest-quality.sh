#!/usr/bin/env bash

set -euo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUIDELINES_FILE="${VAULT_DIR}/wiki/knowledge/concepts/ingest-quality-guidelines.md"
PROMPT_TEMPLATE="${VAULT_DIR}/.claude/templates/ingest-prompt.md"
LOG_FILE="${VAULT_DIR}/wiki/logs/quality-review.log"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi


echo "Scanning for meta-relevant sources..."

META_SOURCES=()
for f in "${VAULT_DIR}"/wiki/summaries/*.md; do
    [[ -f "$f" ]] || continue
    if grep -q 'meta-relevant:.*true' "$f" 2>/dev/null; then
        META_SOURCES+=("$f")
    fi
done

if [[ ${#META_SOURCES[@]} -eq 0 ]]; then
    echo "No meta-relevant sources found. Nothing to review."
    echo "Sources are tagged meta-relevant: true when they cover summarization,"
    echo "retrieval, linking, knowledge management, or related topics."
    exit 0
fi

echo "Found ${#META_SOURCES[@]} meta-relevant source(s):"
for src in "${META_SOURCES[@]}"; do
    echo "  - $(basename "$src")"
done


if [[ ! -f "$GUIDELINES_FILE" ]]; then
    echo "Error: Guidelines file not found: ${GUIDELINES_FILE}"
    exit 1
fi

CURRENT_GUIDELINES=$(cat "$GUIDELINES_FILE")


CURRENT_TEMPLATE=""
if [[ -f "$PROMPT_TEMPLATE" ]]; then
    CURRENT_TEMPLATE=$(cat "$PROMPT_TEMPLATE")
fi


SOURCE_CONTENT=""
for src in "${META_SOURCES[@]}"; do
    SOURCE_CONTENT+="
=== SOURCE: $(basename "$src") ===
$(cat "$src")

"
done


if $DRY_RUN; then
    echo ""
    echo "=== DRY RUN ==="
    echo "Would review ${#META_SOURCES[@]} meta-relevant source(s) against current guidelines."
    echo "Would update: ${GUIDELINES_FILE}"
    echo "Would log to: ${LOG_FILE}"
    exit 0
fi


REVIEW_PROMPT="You are a quality improvement agent for a knowledge base ingest pipeline.


Review the current ingest quality guidelines against the meta-relevant sources below. These sources contain knowledge about summarization, retrieval, linking, knowledge management, or related topics that could improve how we ingest future sources.

Output an updated version of the guidelines page. Preserve what works, add what's missing, revise what's contradicted by the sources. The output must be a complete replacement for the guidelines file — same YAML frontmatter structure, same markdown format.

Update the updated_at timestamp to: ${TIMESTAMP}


${CURRENT_GUIDELINES}


${CURRENT_TEMPLATE}


${SOURCE_CONTENT}


1. Output ONLY the complete markdown file (frontmatter + body). No preamble, no commentary.
2. The first line must be \`---\` (YAML frontmatter start)
3. Keep the same frontmatter schema — update only content fields and updated_at
4. Add a note in the Sources section citing which meta-relevant sources informed each change
5. If no changes are warranted, output the file unchanged (still update updated_at)
6. Be conservative — only add guidelines that are clearly supported by the sources
7. Don't remove guidelines unless a source actively contradicts them"


echo ""
echo "Calling Claude to review guidelines..."

TEMP_FILE=$(mktemp)
trap 'rm -f "$TEMP_FILE"' EXIT

if ! echo "$REVIEW_PROMPT" | "$(dirname "$0")/lib/claude-parent-auth.sh" -p --no-session-persistence --dangerously-skip-permissions --tools "Read,Glob,Grep" > "$TEMP_FILE" 2>/dev/null; then
    echo "Error: claude -p failed"
    echo "[${TIMESTAMP}] ERROR: claude -p failed during quality review" >> "$LOG_FILE"
    exit 1
fi


if [[ ! -s "$TEMP_FILE" ]]; then
    echo "Error: Claude returned empty output"
    echo "[${TIMESTAMP}] ERROR: empty output during quality review" >> "$LOG_FILE"
    exit 1
fi

if grep -qn '^---$' "$TEMP_FILE"; then
    FIRST_FM_LINE=$(grep -n '^---$' "$TEMP_FILE" | head -1 | cut -d: -f1)
    if [[ "$FIRST_FM_LINE" -gt 1 ]]; then
        tail -n "+${FIRST_FM_LINE}" "$TEMP_FILE" > "${TEMP_FILE}.clean"
        mv "${TEMP_FILE}.clean" "$TEMP_FILE"
    fi
else
    echo "Error: Output contains no YAML frontmatter"
    head -5 "$TEMP_FILE"
    echo "[${TIMESTAMP}] ERROR: no frontmatter in quality review output" >> "$LOG_FILE"
    exit 1
fi


echo ""
echo "=== Changes ==="
if diff -u "$GUIDELINES_FILE" "$TEMP_FILE" > /dev/null 2>&1; then
    echo "No changes to guidelines."
    echo "[${TIMESTAMP}] Quality review: no changes (${#META_SOURCES[@]} sources reviewed)" >> "$LOG_FILE"
else
    diff -u "$GUIDELINES_FILE" "$TEMP_FILE" || true
    echo ""
    cp "$TEMP_FILE" "$GUIDELINES_FILE"
    echo "Guidelines updated: ${GUIDELINES_FILE}"
    echo "[${TIMESTAMP}] Quality review: guidelines updated (${#META_SOURCES[@]} sources reviewed)" >> "$LOG_FILE"
fi

echo ""
echo "Done. Review the updated guidelines in Obsidian."
