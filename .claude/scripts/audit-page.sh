#!/usr/bin/env bash

set -euo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATE_FILE="${VAULT_DIR}/.claude/templates/audit-prompt.md"
GUIDELINES_FILE="${VAULT_DIR}/wiki/knowledge/concepts/ingest-quality-guidelines.md"
LOG_FILE="${VAULT_DIR}/wiki/logs/audit.log"
PROPOSALS_DIR="${VAULT_DIR}/wiki/logs/audit-proposals"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

DRY_RUN=false
APPLY=false
CONFIDENCE_THRESHOLD="0.7"


usage() {
    echo "Usage: $0 [--dry-run] [--apply] [--confidence-threshold N] <path-to-wiki-page>"
    echo ""
    echo "Options:"
    echo "  --dry-run              Show what would happen without calling Claude"
    echo "  --apply                Apply proposed changes (default: store proposals only)"
    echo "  --confidence-threshold Minimum confidence for proposals (default: 0.7)"
    echo ""
    echo "Output modes:"
    echo "  Default: Write proposals to wiki/logs/audit-proposals/ for review"
    echo "  --apply: Write proposals AND apply update_section/update_frontmatter operations"
    echo "  --dry-run: Preview prompt and metadata, no Claude call"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --apply)
            APPLY=true
            shift
            ;;
        --confidence-threshold)
            CONFIDENCE_THRESHOLD="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Error: Unknown option: $1"
            usage
            ;;
        *)
            PAGE_FILE="$1"
            shift
            ;;
    esac
done

if [[ -z "${PAGE_FILE:-}" ]]; then
    echo "Error: No page file specified"
    usage
fi

if [[ ! "$PAGE_FILE" = /* ]]; then
    PAGE_FILE="$(cd "$(dirname "$PAGE_FILE")" && pwd)/$(basename "$PAGE_FILE")"
fi

if [[ ! -f "${PAGE_FILE}" ]]; then
    echo "Error: File not found: ${PAGE_FILE}"
    exit 1
fi


PAGE_REL="${PAGE_FILE#${VAULT_DIR}/}"
PAGE_BASENAME=$(basename "$PAGE_FILE" .md)

case "$PAGE_REL" in
    wiki/knowledge/concepts/*) PAGE_TYPE="concept" ;;
    wiki/knowledge/entities/*) PAGE_TYPE="entity" ;;
    wiki/summaries/*) PAGE_TYPE="source_summary" ;;
    wiki/knowledge/projects/*) PAGE_TYPE="project" ;;
    wiki/knowledge/decisions/*) PAGE_TYPE="decision" ;;
    *) PAGE_TYPE="unknown" ;;
esac

PAGE_ID=$(grep -m1 '^id:' "$PAGE_FILE" | sed 's/^id:[[:space:]]*//' | tr -d '"'"'" || echo "$PAGE_BASENAME")

echo "Auditing: ${PAGE_REL}"
echo "Type: ${PAGE_TYPE}"
echo "ID: ${PAGE_ID}"


CONTENT_HASH=$(md5 -q "$PAGE_FILE" 2>/dev/null || md5sum "$PAGE_FILE" | cut -d' ' -f1)
LAST_AUDIT_HASH=""

if [[ -d "$PROPOSALS_DIR" ]]; then
    LATEST_PROPOSAL=$(ls -t "${PROPOSALS_DIR}/${PAGE_BASENAME}"-*.json 2>/dev/null | head -1 || true)
    if [[ -n "$LATEST_PROPOSAL" ]]; then
        LAST_AUDIT_HASH=$(jq -r '.content_hash // ""' "$LATEST_PROPOSAL" 2>/dev/null || true)
    fi
fi

if [[ "$CONTENT_HASH" == "$LAST_AUDIT_HASH" && "$DRY_RUN" == false ]]; then
    echo "Page unchanged since last audit. Skipping."
    echo "  Last audit: ${LATEST_PROPOSAL}"
    echo "  To force re-audit, edit the page or delete the proposal file."
    exit 0
fi


PAGE_CONTENT=$(cat "$PAGE_FILE")


gather_wiki_index() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        echo "_None yet_"
        return
    fi

    for f in "$dir"/*.md; do
        [[ -f "$f" ]] || continue
        local name
        name=$(basename "$f" .md)
        local rel_path="${f#${VAULT_DIR}/}"
        rel_path="${rel_path%.md}"

        local title
        title=$(grep -m1 '^# ' "$f" | sed 's/^# //' || echo "$name")

        local aliases=""
        aliases=$(awk '/^aliases:/{found=1; next} found && /^  - /{gsub(/^  - /,""); gsub(/"/,""); printf "%s, ", $0; next} found{exit}' "$f" 2>/dev/null || true)
        aliases="${aliases%, }"

        local tags=""
        tags=$(awk '/^tags:/{found=1; next} found && /^  - /{gsub(/^  - /,""); gsub(/"/,""); printf "%s, ", $0; next} found{exit}' "$f" 2>/dev/null || true)
        tags="${tags%, }"

        local entry="- [[${rel_path}|${title}]]"
        if [[ -n "$aliases" ]]; then
            entry="${entry} (aliases: ${aliases})"
        fi
        if [[ -n "$tags" ]]; then
            entry="${entry} [tags: ${tags}]"
        fi
        echo "$entry"
    done
}

CONCEPT_INDEX=$(gather_wiki_index "${VAULT_DIR}/wiki/knowledge/concepts")
ENTITY_INDEX=$(gather_wiki_index "${VAULT_DIR}/wiki/knowledge/entities")
SOURCE_INDEX=$(gather_wiki_index "${VAULT_DIR}/wiki/summaries")
PROJECT_INDEX=$(gather_wiki_index "${VAULT_DIR}/wiki/knowledge/projects")


QUALITY_GUIDELINES=""
if [[ -f "$GUIDELINES_FILE" ]]; then
    QUALITY_GUIDELINES=$(awk 'BEGIN{skip=0} /^---$/{skip++; next} skip>=2{print}' "$GUIDELINES_FILE")
fi


build_prompt() {
    local template
    template=$(cat "$TEMPLATE_FILE")

    template="${template//\{\{PAGE_PATH\}\}/${PAGE_REL}}"
    template="${template//\{\{PAGE_TYPE\}\}/${PAGE_TYPE}}"
    template="${template//\{\{VAULT_DIR\}\}/${VAULT_DIR}}"
    template="${template//\{\{CONFIDENCE_THRESHOLD\}\}/${CONFIDENCE_THRESHOLD}}"

    python3 -c "
import sys, os

template = sys.stdin.read()

replacements = {
    '{{PAGE_CONTENT}}': os.environ.get('PAGE_CONTENT', ''),
    '{{CONCEPT_INDEX}}': os.environ.get('CONCEPT_INDEX', ''),
    '{{ENTITY_INDEX}}': os.environ.get('ENTITY_INDEX', ''),
    '{{SOURCE_INDEX}}': os.environ.get('SOURCE_INDEX', ''),
    '{{PROJECT_INDEX}}': os.environ.get('PROJECT_INDEX', ''),
    '{{QUALITY_GUIDELINES}}': os.environ.get('QUALITY_GUIDELINES', ''),
}

for key, value in replacements.items():
    template = template.replace(key, value)

print(template)
" <<< "$template"
}

export PAGE_CONTENT CONCEPT_INDEX ENTITY_INDEX SOURCE_INDEX PROJECT_INDEX QUALITY_GUIDELINES
PROMPT=$(build_prompt)


if $DRY_RUN; then
    echo ""
    echo "=== DRY RUN ==="
    echo "Page:        ${PAGE_REL}"
    echo "Type:        ${PAGE_TYPE}"
    echo "ID:          ${PAGE_ID}"
    echo "Hash:        ${CONTENT_HASH}"
    echo "Threshold:   ${CONFIDENCE_THRESHOLD}"
    echo ""
    echo "=== WIKI CONTEXT ==="
    echo "Concepts: $(echo "$CONCEPT_INDEX" | grep -c '^\-' || echo 0) pages"
    echo "Entities: $(echo "$ENTITY_INDEX" | grep -c '^\-' || echo 0) pages"
    echo "Sources:  $(echo "$SOURCE_INDEX" | grep -c '^\-' || echo 0) pages"
    echo "Projects: $(echo "$PROJECT_INDEX" | grep -c '^\-' || echo 0) pages"
    echo ""
    echo "=== PROMPT PREVIEW (first 50 lines) ==="
    echo "$PROMPT" | head -50
    echo "..."
    echo ""
    PROMPT_LINES=$(echo "$PROMPT" | wc -l | tr -d ' ')
    PROMPT_BYTES=$(echo "$PROMPT" | wc -c | tr -d ' ')
    echo "Total prompt: ${PROMPT_LINES} lines, ${PROMPT_BYTES} bytes"
    echo ""
    echo "[dry-run] Would call: "$(dirname "$0")/lib/claude-parent-auth.sh" -p --no-session-persistence --dangerously-skip-permissions --tools \"Read,Glob,Grep\""
    echo "[dry-run] Would write proposals to: ${PROPOSALS_DIR}/${PAGE_BASENAME}-${TIMESTAMP}.json"
    if $APPLY; then
        echo "[dry-run] Would apply operations (--apply flag set)"
    fi
    exit 0
fi


echo "Calling Claude for audit..."

TEMP_FILE=$(mktemp)
trap 'rm -f "$TEMP_FILE" "${TEMP_FILE}.clean" "${TEMP_FILE}.filtered"' EXIT

if ! echo "$PROMPT" | "$(dirname "$0")/lib/claude-parent-auth.sh" -p --no-session-persistence --dangerously-skip-permissions --tools "Read,Glob,Grep" > "$TEMP_FILE" 2>/dev/null; then
    echo "Error: claude -p failed"
    echo "[${TIMESTAMP}] ERROR: claude -p failed for ${PAGE_REL}" >> "$LOG_FILE"
    exit 1
fi


if [[ ! -s "$TEMP_FILE" ]]; then
    echo "Error: Claude returned empty output"
    echo "[${TIMESTAMP}] ERROR: empty output for ${PAGE_REL}" >> "$LOG_FILE"
    exit 1
fi


python3 -c "
import sys, re
text = open(sys.argv[1]).read()
text = re.sub(r'\`\`\`json\s*\n?', '', text)
text = re.sub(r'\`\`\`\s*\n?', '', text)
start = text.find('[')
end = text.rfind(']')
if start == -1 or end == -1:
    print('ERROR: No JSON array found in output', file=sys.stderr)
    sys.exit(1)
json_text = text[start:end+1]
print(json_text)
" "$TEMP_FILE" > "${TEMP_FILE}.clean"

if [[ $? -ne 0 ]]; then
    echo "Error: Could not extract JSON from Claude output"
    echo "First 20 lines of output:"
    head -20 "$TEMP_FILE"
    echo "[${TIMESTAMP}] ERROR: no JSON in output for ${PAGE_REL}" >> "$LOG_FILE"
    exit 1
fi

mv "${TEMP_FILE}.clean" "$TEMP_FILE"

if ! jq empty "$TEMP_FILE" 2>/dev/null; then
    echo "Error: Invalid JSON in output"
    echo "First 10 lines:"
    head -10 "$TEMP_FILE"
    echo "[${TIMESTAMP}] ERROR: invalid JSON for ${PAGE_REL}" >> "$LOG_FILE"
    exit 1
fi

OP_COUNT=$(jq 'length' "$TEMP_FILE")
echo "Claude returned ${OP_COUNT} proposed operations"

if [[ "$OP_COUNT" -eq 0 ]]; then
    echo "No changes needed."
    echo "[${TIMESTAMP}] AUDIT: ${PAGE_REL} — no changes needed" >> "$LOG_FILE"
    mkdir -p "$PROPOSALS_DIR"
    echo "{\"page\": \"${PAGE_REL}\", \"content_hash\": \"${CONTENT_HASH}\", \"timestamp\": \"${TIMESTAMP}\", \"operations\": []}" \
        | jq '.' > "${PROPOSALS_DIR}/${PAGE_BASENAME}-${TIMESTAMP}.json"
    exit 0
fi


INVALID=$(jq '[.[] | select(.action != "flag_stale" and (.provenance_span == null or .provenance_span == "" or (.provenance_span | length) < 10))] | length' "$TEMP_FILE")
if [[ "$INVALID" -gt 0 ]]; then
    echo "Warning: Removing ${INVALID} operations without valid provenance_span"
    jq '[.[] | select(.action == "flag_stale" or (.provenance_span != null and .provenance_span != "" and (.provenance_span | length) >= 10))]' "$TEMP_FILE" > "${TEMP_FILE}.filtered"
    mv "${TEMP_FILE}.filtered" "$TEMP_FILE"
    OP_COUNT=$(jq 'length' "$TEMP_FILE")
    echo "Remaining operations after provenance filter: ${OP_COUNT}"
fi


LOW_CONF=$(jq --arg thresh "$CONFIDENCE_THRESHOLD" '[.[] | select(.confidence != null and (.confidence | tonumber) < ($thresh | tonumber))] | length' "$TEMP_FILE")
if [[ "$LOW_CONF" -gt 0 ]]; then
    echo "Note: ${LOW_CONF} operations below confidence threshold ${CONFIDENCE_THRESHOLD} (flagged for review)"
    jq --arg thresh "$CONFIDENCE_THRESHOLD" '[.[] | if .confidence != null and (.confidence | tonumber) < ($thresh | tonumber) then . + {"needs_human_review": true} else . end]' "$TEMP_FILE" > "${TEMP_FILE}.filtered"
    mv "${TEMP_FILE}.filtered" "$TEMP_FILE"
fi


mkdir -p "$PROPOSALS_DIR"
PROPOSAL_FILE="${PROPOSALS_DIR}/${PAGE_BASENAME}-${TIMESTAMP}.json"

jq -n \
    --arg page "$PAGE_REL" \
    --arg hash "$CONTENT_HASH" \
    --arg ts "$TIMESTAMP" \
    --arg thresh "$CONFIDENCE_THRESHOLD" \
    --slurpfile ops "$TEMP_FILE" \
    '{page: $page, content_hash: $hash, timestamp: $ts, confidence_threshold: $thresh, operations: $ops[0]}' \
    > "$PROPOSAL_FILE"

echo "Proposals written: ${PROPOSAL_FILE}"


echo ""
echo "=== Proposal Summary ==="
for action in update_section update_frontmatter propose_create flag_gap flag_stale; do
    count=$(jq --arg a "$action" '[.operations[] | select(.action == $a)] | length' "$PROPOSAL_FILE")
    if [[ "$count" -gt 0 ]]; then
        echo "  ${action}: ${count}"
    fi
done

REVIEW_COUNT=$(jq '[.operations[] | select(.needs_human_review == true)] | length' "$PROPOSAL_FILE")
if [[ "$REVIEW_COUNT" -gt 0 ]]; then
    echo "  needs_human_review: ${REVIEW_COUNT}"
fi


if $APPLY; then
    echo ""
    echo "Applying operations..."

    APPLIED=0
    SKIPPED=0

    jq -c '.operations[]' "$PROPOSAL_FILE" | while IFS= read -r op; do
        action=$(echo "$op" | jq -r '.action')
        path=$(echo "$op" | jq -r '.path')
        full_path="${VAULT_DIR}/${path}"

        needs_review=$(echo "$op" | jq -r '.needs_human_review // false')
        if [[ "$needs_review" == "true" ]]; then
            echo "  SKIP (needs human review): ${path} [${action}]"
            continue
        fi

        case "$action" in
            update_section)
                if [[ ! -f "$full_path" ]]; then
                    echo "  SKIP (not found): ${path}"
                    continue
                fi
                section=$(echo "$op" | jq -r '.section')
                content=$(echo "$op" | jq -r '.content')

                python3 -c "
import sys, re

file_path = sys.argv[1]
section_name = sys.argv[2]
new_content = sys.argv[3]

with open(file_path, 'r') as f:
    text = f.read()

pattern = r'(## ' + re.escape(section_name) + r'\n)(.*?)(\n## |\Z)'
match = re.search(pattern, text, re.DOTALL)
if match:
    replacement = match.group(1) + new_content + '\n' + match.group(3)
    text = text[:match.start()] + replacement + text[match.end():]
    with open(file_path, 'w') as f:
        f.write(text)
    print(f'  UPDATE [{section_name}]: {sys.argv[4]}')
else:
    print(f'  SKIP (section not found: {section_name}): {sys.argv[4]}')
" "$full_path" "$section" "$content" "$path"
                echo "[${TIMESTAMP}] APPLIED update_section [${section}]: ${path}" >> "$LOG_FILE"
                ;;

            update_frontmatter)
                if [[ ! -f "$full_path" ]]; then
                    echo "  SKIP (not found): ${path}"
                    continue
                fi
                field=$(echo "$op" | jq -r '.field')
                value_json=$(echo "$op" | jq -c '.value')

                python3 -c "
import sys, re, json

file_path = sys.argv[1]
field = sys.argv[2]
value = json.loads(sys.argv[3])

with open(file_path, 'r') as f:
    text = f.read()

parts = text.split('---', 2)
if len(parts) >= 3:
    fm = parts[1]
    body = parts[2]

    if isinstance(value, list):
        new_value = field + ':\n' + ''.join(f'  - {v}\n' for v in value)
    else:
        new_value = f'{field}: {value}\n'

    field_pattern = re.compile(r'^' + re.escape(field) + r':.*?(?=^[a-zA-Z]|\Z)', re.MULTILINE | re.DOTALL)
    if field_pattern.search(fm):
        fm = field_pattern.sub(new_value, fm)
    else:
        fm = fm.rstrip() + '\n' + new_value

    with open(file_path, 'w') as f:
        f.write('---' + fm + '---' + body)
    print(f'  UPDATE frontmatter [{field}]: {sys.argv[4]}')
else:
    print(f'  SKIP (no frontmatter): {sys.argv[4]}')
" "$full_path" "$field" "$value_json" "$path"
                echo "[${TIMESTAMP}] APPLIED update_frontmatter [${field}]: ${path}" >> "$LOG_FILE"
                ;;

            propose_create)
                echo "  PROPOSE: ${path} ($(echo "$op" | jq -r '.name')) — review in proposals file"
                ;;

            flag_gap)
                echo "  GAP: ${path} [$(echo "$op" | jq -r '.section')] — $(echo "$op" | jq -r '.issue')"
                ;;

            flag_stale)
                echo "  STALE: ${path} — $(echo "$op" | jq -r '.reason')"
                ;;

            *)
                echo "  UNKNOWN: ${action} for ${path}"
                ;;
        esac
    done

    echo ""
    echo "Operations applied. Review changes in Obsidian."
fi


mkdir -p "$(dirname "$LOG_FILE")"
echo "[${TIMESTAMP}] AUDIT: ${PAGE_REL} — ${OP_COUNT} operations proposed (hash: ${CONTENT_HASH})" >> "$LOG_FILE"

echo ""
echo "Done. Proposals: ${PROPOSAL_FILE}"
