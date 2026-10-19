#!/usr/bin/env bash

set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/share/google-cloud-sdk/bin:$PATH"

if [[ -z "${NODE_EXTRA_CA_CERTS:-}" && -n "${BRAIN_CA_BUNDLE:-}" && -f "$BRAIN_CA_BUNDLE" ]]; then
    export NODE_EXTRA_CA_CERTS="$BRAIN_CA_BUNDLE"
fi

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATE_FILE="${VAULT_DIR}/.claude/templates/ingest-prompt.md"
GUIDELINES_FILE="${VAULT_DIR}/wiki/knowledge/concepts/ingest-quality-guidelines.md"
SOURCES_INDEX="${VAULT_DIR}/wiki/indexes/sources.md"
LOG_FILE="${VAULT_DIR}/wiki/logs/ingest.log"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DATE_PREFIX=$(date -u +"%Y-%m-%d")

DRY_RUN=false


usage() {
    echo "Usage: $0 [--dry-run] <path-to-raw-file>"
    echo ""
    echo "Options:"
    echo "  --dry-run    Show what would happen without calling Claude or writing files"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Error: Unknown option: $1"
            usage
            ;;
        *)
            RAW_FILE="$1"
            shift
            ;;
    esac
done

if [[ -z "${RAW_FILE:-}" ]]; then
    echo "Error: No file specified"
    usage
fi

if [[ ! "$RAW_FILE" = /* ]]; then
    RAW_FILE="$(cd "$(dirname "$RAW_FILE")" && pwd)/$(basename "$RAW_FILE")"
fi

if [[ ! -f "${RAW_FILE}" ]]; then
    echo "Error: File not found: ${RAW_FILE}"
    exit 1
fi

BASENAME=$(basename "$RAW_FILE")
if [[ "$BASENAME" == _template* ]] || [[ "$BASENAME" == *-template.md ]]; then
    echo "Skipping template file: ${BASENAME}"
    exit 0
fi


TITLE=""
SOURCE_URL=""
AUTHOR=""
PUBLISHED=""
DESCRIPTION=""
FM_TAGS=""
WHY_CAPTURED=""

FILENAME=$(basename "${RAW_FILE}")
EXTENSION="${FILENAME##*.}"
NAME="${FILENAME%.*}"

extract_frontmatter() {
    local file="$1"
    if [[ "$EXTENSION" != "md" && "$EXTENSION" != "markdown" ]]; then
        return
    fi

    if ! head -1 "$file" | grep -q '^---$'; then
        return
    fi

    local fm
    fm=$(sed -n '2,/^---$/p' "$file" | sed '$d')

    TITLE=$(echo "$fm" | grep -E '^title:' | sed 's/^title:[[:space:]]*//' | sed 's/^["'"'"']//;s/["'"'"']$//' || true)
    SOURCE_URL=$(echo "$fm" | grep -E '^source:' | sed 's/^source:[[:space:]]*//' | sed 's/^["'"'"']//;s/["'"'"']$//' || true)
    AUTHOR=$(echo "$fm" | grep -E '^author:' | sed 's/^author:[[:space:]]*//' | sed 's/^["'"'"']//;s/["'"'"']$//' || true)
    PUBLISHED=$(echo "$fm" | grep -E '^published:' | sed 's/^published:[[:space:]]*//' | sed 's/^["'"'"']//;s/["'"'"']$//' || true)
    DESCRIPTION=$(echo "$fm" | grep -E '^description:' | sed 's/^description:[[:space:]]*//' | sed 's/^["'"'"']//;s/["'"'"']$//' || true)
    FM_TAGS=$(echo "$fm" | sed -n '/^tags:/,/^[^ -]/p' | grep -E '^\s*-\s*' | sed 's/^\s*-\s*//' | sed 's/^["'"'"']//;s/["'"'"']$//' | tr '\n' ',' || true)
    WHY_CAPTURED=$(echo "$fm" | grep -E '^why_captured:' | sed 's/^why_captured:[[:space:]]*//' || true)
}

extract_frontmatter "$RAW_FILE"


classify_source() {
    if echo "$FM_TAGS" | grep -qi "clipping"; then
        echo "web_clipping"
        return
    fi

    case "${EXTENSION}" in
        md|markdown) echo "markdown" ;;
        pdf) echo "pdf" ;;
        txt) echo "text" ;;
        png|jpg|jpeg|gif|webp) echo "screenshot" ;;
        mp3|wav|m4a) echo "audio" ;;
        mp4|mov|avi) echo "video" ;;
        *) echo "unknown" ;;
    esac
}

SOURCE_TYPE=$(classify_source)

target_subdir() {
    case "$1" in
        web_clipping) echo "clippings" ;;
        pdf) echo "pdfs" ;;
        screenshot) echo "screenshots" ;;
        audio) echo "recordings" ;;
        video) echo "recordings" ;;
        claude_code_session) echo "claude-sessions" ;;
        *) echo "imports" ;;
    esac
}

TARGET_SUBDIR=$(target_subdir "$SOURCE_TYPE")
TARGET_DIR="${VAULT_DIR}/raw/${TARGET_SUBDIR}"


route_file() {
    local current_dir
    current_dir=$(dirname "$RAW_FILE")
    local expected_dir="$TARGET_DIR"

    if [[ "$current_dir" == "${VAULT_DIR}/raw" ]]; then
        mkdir -p "$expected_dir"
        if $DRY_RUN; then
            echo "[dry-run] Would move: ${RAW_FILE} -> ${expected_dir}/${FILENAME}"
        else
            mv "$RAW_FILE" "${expected_dir}/${FILENAME}"
            RAW_FILE="${expected_dir}/${FILENAME}"
            echo "Moved to: ${RAW_FILE}"
        fi
    fi
}

route_file


slugify() {
    echo "$1" | \
        tr '[:upper:]' '[:lower:]' | \
        sed 's/[^a-z0-9 -]//g' | \
        sed 's/  */ /g' | \
        sed 's/ /-/g' | \
        cut -c1-60
}

if [[ -n "$TITLE" ]]; then
    SLUG=$(slugify "$TITLE")
else
    SLUG=$(slugify "$NAME")
fi

SOURCE_ID="source-${DATE_PREFIX}-${SLUG}"
SUMMARY_FILE="${VAULT_DIR}/wiki/summaries/${SOURCE_ID}.md"


if [[ -f "$SUMMARY_FILE" ]]; then
    echo "Summary already exists: ${SUMMARY_FILE}"
    echo "Skipping ingestion."
    exit 0
fi


RAW_SOURCE_PATH="${RAW_FILE#${VAULT_DIR}/}"


gather_wiki_pages() {
    local dir="$1"
    local label="$2"
    if [[ -d "$dir" ]]; then
        for f in "$dir"/*.md; do
            [[ -f "$f" ]] || continue
            local name
            name=$(basename "$f" .md)
            local rel_path="${f#${VAULT_DIR}/}"
            local title
            title=$(awk '/^---$/{fm++; next} fm>=2 && /^# /{print substr($0,3); exit}' "$f")
            local aliases
            aliases=$(awk '/^aliases:/{found=1; next} found && /^  - /{gsub(/^  - /,""); printf "%s, ", $0; next} found{exit}' "$f" | sed 's/, $//')
            local entry="- [[${rel_path%.md}|${title:-${name}}]]"
            if [[ -n "$aliases" ]]; then
                entry+=" (aliases: ${aliases})"
            fi
            echo "$entry"
        done
    else
        echo "_None yet_"
    fi
}

CONCEPT_PAGES=$(gather_wiki_pages "${VAULT_DIR}/wiki/knowledge/concepts" "concepts")
ENTITY_PAGES=$(gather_wiki_pages "${VAULT_DIR}/wiki/knowledge/entities" "entities")
SOURCE_PAGES=$(gather_wiki_pages "${VAULT_DIR}/wiki/summaries" "summaries")
DECISION_PAGES=$(gather_wiki_pages "${VAULT_DIR}/wiki/knowledge/decisions" "decisions")
PROJECT_PAGES=$(gather_wiki_pages "${VAULT_DIR}/wiki/knowledge/projects" "projects")

QUALITY_GUIDELINES=""
if [[ -f "$GUIDELINES_FILE" ]]; then
    QUALITY_GUIDELINES=$(awk 'BEGIN{skip=0} /^---$/{skip++; next} skip>=2{print}' "$GUIDELINES_FILE")
fi


build_prompt() {
    local template
    template=$(cat "$TEMPLATE_FILE")

    template="${template//\{\{FILE_PATH\}\}/${RAW_FILE}}"
    template="${template//\{\{SOURCE_TYPE\}\}/${SOURCE_TYPE}}"
    template="${template//\{\{TITLE\}\}/${TITLE:-${NAME}}}"
    template="${template//\{\{SOURCE_URL\}\}/${SOURCE_URL:-N/A}}"
    template="${template//\{\{AUTHOR\}\}/${AUTHOR:-Unknown}}"
    template="${template//\{\{PUBLISHED\}\}/${PUBLISHED:-Unknown}}"
    template="${template//\{\{DESCRIPTION\}\}/${DESCRIPTION:-N/A}}"
    template="${template//\{\{WHY_CAPTURED\}\}/${WHY_CAPTURED:-Not specified}}"
    template="${template//\{\{SOURCE_ID\}\}/${SOURCE_ID}}"
    template="${template//\{\{TIMESTAMP\}\}/${TIMESTAMP}}"
    template="${template//\{\{RAW_SOURCE_PATH\}\}/${RAW_SOURCE_PATH}}"
    template="${template//\{\{CONCEPT_PAGES\}\}/${CONCEPT_PAGES}}"
    template="${template//\{\{ENTITY_PAGES\}\}/${ENTITY_PAGES}}"
    template="${template//\{\{SOURCE_PAGES\}\}/${SOURCE_PAGES}}"
    template="${template//\{\{DECISION_PAGES\}\}/${DECISION_PAGES}}"
    template="${template//\{\{PROJECT_PAGES\}\}/${PROJECT_PAGES}}"
    template="${template//\{\{QUALITY_GUIDELINES\}\}/${QUALITY_GUIDELINES}}"

    echo "$template"
}

PROMPT=$(build_prompt)


if $DRY_RUN; then
    echo ""
    echo "=== DRY RUN ==="
    echo "File:        ${RAW_FILE}"
    echo "Source type:  ${SOURCE_TYPE}"
    echo "Title:        ${TITLE:-${NAME}}"
    echo "Source URL:   ${SOURCE_URL:-N/A}"
    echo "Author:       ${AUTHOR:-Unknown}"
    echo "Source ID:    ${SOURCE_ID}"
    echo "Output:       ${SUMMARY_FILE}"
    echo "Raw path:     ${RAW_SOURCE_PATH}"
    echo ""
    echo "=== PROMPT PREVIEW (first 40 lines) ==="
    echo "$PROMPT" | head -40
    echo "..."
    echo ""
    echo "=== WIKI CONTEXT ==="
    echo "Concepts: $(echo "$CONCEPT_PAGES" | wc -l | tr -d ' ') pages"
    echo "Entities: $(echo "$ENTITY_PAGES" | wc -l | tr -d ' ') pages"
    echo "Sources:  $(echo "$SOURCE_PAGES" | wc -l | tr -d ' ') pages"
    echo "Projects: $(echo "$PROJECT_PAGES" | wc -l | tr -d ' ') pages"
    echo ""
    echo "[dry-run] Would call: claude -p --no-session-persistence"
    echo "[dry-run] Would write to: ${SUMMARY_FILE}"
    echo "[dry-run] Would update: ${SOURCES_INDEX}"
    exit 0
fi


echo "Ingesting: ${FILENAME}"
echo "Source type: ${SOURCE_TYPE}"
echo "Source ID: ${SOURCE_ID}"
echo ""
echo "Calling Claude for summarization..."

TEMP_FILE=$(mktemp)
trap 'rm -f "$TEMP_FILE"' EXIT

run_summarizer() {
    local model="$1"
    local model_args=()
    [[ -n "$model" ]] && model_args=(--model "$model")
    local err_file
    err_file=$(mktemp)
    if ! echo "$PROMPT" | pi -p --no-session "${model_args[@]}" --tools read > "$TEMP_FILE" 2>"$err_file"; then
        local err_msg
        err_msg=$(cat "$err_file" | tail -5)
        rm -f "$err_file"
        echo "Error: pi -p ($model) failed: ${err_msg}" >&2
        return 1
    fi
    rm -f "$err_file"

    if [[ ! -s "$TEMP_FILE" ]]; then
        echo "Error: pi -p ($model) returned empty output" >&2
        return 1
    fi

    if grep -qn '^---$' "$TEMP_FILE"; then
        local first_fm_line
        first_fm_line=$(grep -n '^---$' "$TEMP_FILE" | head -1 | cut -d: -f1)
        if [[ "$first_fm_line" -gt 1 ]]; then
            echo "Note: Stripped ${first_fm_line} lines of preamble before frontmatter"
            tail -n "+${first_fm_line}" "$TEMP_FILE" > "${TEMP_FILE}.clean"
            mv "${TEMP_FILE}.clean" "$TEMP_FILE"
        fi
    else
        echo "Error: pi -p ($model) output contains no YAML frontmatter (no '---' found)" >&2
        return 1
    fi

    if ! grep -q '## Summary' "$TEMP_FILE"; then
        echo "Error: pi -p ($model) output missing '## Summary' section" >&2
        return 1
    fi

    return 0
}

if [[ -n "${PI_CODING_AGENT:-}" ]] || [[ -z "${CLAUDE_CODE_ENTRYPOINT:-}" ]]; then
    if command -v pi >/dev/null; then
        PRIMARY_MODEL="${INGEST_MODEL:-}"
        FALLBACK_MODEL="${INGEST_FALLBACK_MODEL:-}"

        if ! run_summarizer "$PRIMARY_MODEL"; then
            if [[ -n "$FALLBACK_MODEL" && "$PRIMARY_MODEL" != "$FALLBACK_MODEL" ]]; then
                echo "Retrying summarization with fallback model: ${FALLBACK_MODEL}..." >&2
                if ! run_summarizer "$FALLBACK_MODEL"; then
                    echo "[${TIMESTAMP}] ERROR: pi -p failed on both primary (${PRIMARY_MODEL}) and fallback (${FALLBACK_MODEL}) for ${FILENAME}" >> "$LOG_FILE"
                    exit 1
                fi
            else
                echo "[${TIMESTAMP}] ERROR: pi -p failed for ${FILENAME}" >> "$LOG_FILE"
                exit 1
            fi
        fi
    else
        echo "Error: pi not found and CLAUDE_CODE_ENTRYPOINT unset — cannot summarize" >&2
        exit 1
    fi
elif ! echo "$PROMPT" | "$(dirname "$0")/lib/claude-parent-auth.sh" -p --no-session-persistence --dangerously-skip-permissions --tools "Read,Glob,Grep" > "$TEMP_FILE" 2>/dev/null; then
    echo "Error: claude -p failed" >&2
    echo "[${TIMESTAMP}] ERROR: claude -p failed for ${FILENAME}" >> "$LOG_FILE"
    exit 1
fi


mkdir -p "$(dirname "$SUMMARY_FILE")"
cp "$TEMP_FILE" "$SUMMARY_FILE"
echo "Summary written: ${SUMMARY_FILE}"


index_section_name() {
    case "$SOURCE_TYPE" in
        web_clipping) echo "Web Clippings" ;;
        pdf) echo "PDFs" ;;
        screenshot) echo "Screenshots" ;;
        markdown) echo "Markdown Documents" ;;
        text) echo "Text Files" ;;
        audio) echo "Audio" ;;
        video) echo "Video" ;;
        claude_code_session) echo "Claude Code Sessions" ;;
        *) echo "Other" ;;
    esac
}

SECTION_NAME=$(index_section_name)
INDEX_ENTRY="- [[wiki/summaries/${SOURCE_ID}|${TITLE:-${NAME}}]] - ${DESCRIPTION:-${SOURCE_TYPE} source}"

if [[ -f "$SOURCES_INDEX" ]]; then
    if grep -q "### ${SECTION_NAME}" "$SOURCES_INDEX"; then
        if grep -A1 "### ${SECTION_NAME}" "$SOURCES_INDEX" | grep -q '_None yet_'; then
            sed -i '' "/### ${SECTION_NAME}/{n;s/_None yet_/${INDEX_ENTRY}/;}" "$SOURCES_INDEX"
        else
            sed -i '' "/### ${SECTION_NAME}/a\\
${INDEX_ENTRY}
" "$SOURCES_INDEX"
        fi
    fi

    RECENT_ENTRY="- ${DATE_PREFIX}: [[wiki/summaries/${SOURCE_ID}|${TITLE:-${NAME}}]] (${SOURCE_TYPE})"
    sed -i '' "/## Recently Added/a\\
${RECENT_ENTRY}
" "$SOURCES_INDEX"

    echo "Index updated: ${SOURCES_INDEX}"
fi


mkdir -p "$(dirname "$LOG_FILE")"
echo "[${TIMESTAMP}] Ingested: ${FILENAME} -> ${SOURCE_ID} (${SOURCE_TYPE})" >> "$LOG_FILE"

echo ""
echo "Done. Open in Obsidian: ${SUMMARY_FILE}"
