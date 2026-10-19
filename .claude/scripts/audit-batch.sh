#!/usr/bin/env bash

set -euo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS_DIR="${VAULT_DIR}/.claude/scripts"

DRY_RUN=false
APPLY=false
CONFIDENCE_THRESHOLD="0.7"
SCOPE="all"
MAX_PAGES=0  # 0 = no limit


usage() {
    echo "Usage: $0 [--dry-run] [--apply] [--confidence-threshold N] [--scope SCOPE] [--max-pages N]"
    echo ""
    echo "Scopes:"
    echo "  recent         Summaries from the last 7 days"
    echo "  summaries      All wiki/summaries/*.md"
    echo "  concepts       All wiki/knowledge/concepts/*.md"
    echo "  entities       All wiki/knowledge/entities/*.md"
    echo "  all            summaries -> concepts -> entities -> projects (recommended order)"
    echo ""
    echo "Options:"
    echo "  --dry-run              Preview without calling Claude"
    echo "  --apply                Apply proposed changes after auditing"
    echo "  --confidence-threshold Minimum confidence for proposals (default: 0.7)"
    echo "  --max-pages N          Stop after N pages (0 = no limit)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=true; shift ;;
        --apply)     APPLY=true; shift ;;
        --confidence-threshold) CONFIDENCE_THRESHOLD="$2"; shift 2 ;;
        --scope)     SCOPE="$2"; shift 2 ;;
        --max-pages) MAX_PAGES="$2"; shift 2 ;;
        -h|--help)   usage ;;
        *)           echo "Error: Unknown option: $1"; usage ;;
    esac
done


PAGES=()

add_pages() {
    local pattern="$1"
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        local base
        base=$(basename "$f")
        if [[ "$base" == "maintenance-issues.md" || "$base" == "open-questions.md" ]]; then
            continue
        fi
        PAGES+=("$f")
    done < <(ls $pattern 2>/dev/null | sort)
}

case "$SCOPE" in
    recent)
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            PAGES+=("$f")
        done < <(find "${VAULT_DIR}/wiki/summaries" -name "*.md" -type f -mtime -7 2>/dev/null | sort)
        ;;
    summaries)
        add_pages "${VAULT_DIR}/wiki/summaries/*.md"
        ;;
    concepts)
        add_pages "${VAULT_DIR}/wiki/knowledge/concepts/*.md"
        ;;
    entities)
        add_pages "${VAULT_DIR}/wiki/knowledge/entities/*.md"
        ;;
    all)
        add_pages "${VAULT_DIR}/wiki/summaries/*.md"
        add_pages "${VAULT_DIR}/wiki/knowledge/concepts/*.md"
        add_pages "${VAULT_DIR}/wiki/knowledge/entities/*.md"
        add_pages "${VAULT_DIR}/wiki/knowledge/projects/*.md"
        ;;
    *)
        echo "Error: Unknown scope: ${SCOPE}"
        usage
        ;;
esac

TOTAL=${#PAGES[@]}
echo "=== Wiki Audit Batch ==="
echo "Scope: ${SCOPE}"
echo "Pages: ${TOTAL}"
if [[ "$MAX_PAGES" -gt 0 ]]; then
    echo "Max:   ${MAX_PAGES}"
fi
echo ""

if [[ "$TOTAL" -eq 0 ]]; then
    echo "No pages found for scope: ${SCOPE}"
    exit 0
fi


FLAGS=""
if $DRY_RUN; then FLAGS="$FLAGS --dry-run"; fi
if $APPLY; then FLAGS="$FLAGS --apply"; fi
FLAGS="$FLAGS --confidence-threshold $CONFIDENCE_THRESHOLD"


AUDITED=0
SKIPPED=0
FAILED=0

for page in "${PAGES[@]}"; do
    if [[ "$MAX_PAGES" -gt 0 && "$AUDITED" -ge "$MAX_PAGES" ]]; then
        echo "Reached max-pages limit (${MAX_PAGES}). Stopping."
        break
    fi

    echo "=== [$(( AUDITED + SKIPPED + FAILED + 1 ))/${TOTAL}] $(basename "$page") ==="

    if "${SCRIPTS_DIR}/audit-page.sh" $FLAGS "$page"; then
        AUDITED=$((AUDITED + 1))
    else
        exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            SKIPPED=$((SKIPPED + 1))
        else
            echo "  FAILED (exit code ${exit_code})"
            FAILED=$((FAILED + 1))
        fi
    fi
    echo ""
done


echo "=== Audit Batch Complete ==="
echo "Scope:   ${SCOPE}"
echo "Audited: ${AUDITED}"
echo "Skipped: ${SKIPPED}"
echo "Failed:  ${FAILED}"

if [[ -d "${VAULT_DIR}/wiki/logs/audit-proposals" ]]; then
    echo ""
    echo "=== Proposal Totals ==="
    for action in update_section update_frontmatter propose_create flag_gap flag_stale; do
        count=$(grep -r "\"action\": \"${action}\"" "${VAULT_DIR}/wiki/logs/audit-proposals/" 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$count" -gt 0 ]]; then
            echo "  ${action}: ${count}"
        fi
    done
fi

echo ""
echo "Proposals directory: ${VAULT_DIR}/wiki/logs/audit-proposals/"
