#!/usr/bin/env bash

set -euo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
EXTRA_RECALL_DIR="${BRAIN_EXTRA_RECALL_DIR:-}"
CLAUDE_PROJECTS="$HOME/.claude/projects"
HTML_MODE_RECALL="$HOME/.claude/plugins/cache/html-mode-marketplace/html-mode/1.0.0/scripts/recall.py"

QUERY=""
DEEP=false
PROJECT_FILTER=""
AFTER_DATE=""
BEFORE_DATE=""
INCLUDE_SYNTHETIC=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --deep) DEEP=true; shift ;;
        --include-synthetic) INCLUDE_SYNTHETIC=true; shift ;;
        --project) PROJECT_FILTER="$2"; shift 2 ;;
        --after) AFTER_DATE="$2"; shift 2 ;;
        --before) BEFORE_DATE="$2"; shift 2 ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) QUERY="$1"; shift ;;
    esac
done

if [[ -z "$QUERY" ]]; then
    echo "Usage: recall.sh <query> [--deep] [--include-synthetic] [--project <name>] [--after YYYY-MM-DD] [--before YYYY-MM-DD]"
    exit 1
fi

date_filter() {
    local file="$1"
    local basename
    basename=$(basename "$file")
    local file_date="${basename:0:10}"  # Extract YYYY-MM-DD prefix

    if [[ -n "$AFTER_DATE" ]] && [[ "$file_date" < "$AFTER_DATE" ]]; then
        return 1
    fi
    if [[ -n "$BEFORE_DATE" ]] && [[ "$file_date" > "$BEFORE_DATE" ]]; then
        return 1
    fi
    return 0
}

project_filter() {
    local file="$1"
    if [[ -z "$PROJECT_FILTER" ]]; then
        return 0
    fi
    grep -q "^project: .*${PROJECT_FILTER}" "$file" 2>/dev/null
}

synthetic_filter() {
    local file="$1"
    if [[ "$INCLUDE_SYNTHETIC" == true ]]; then
        return 0
    fi
    grep -q '^synthetic: true' "$file" 2>/dev/null && return 1
    return 0
}

show_match() {
    local file="$1"
    local label="$2"
    local date project transcript

    date=$(basename "$file" | cut -c1-10)
    project=$(grep '^project:' "$file" 2>/dev/null | head -1 | sed 's/^project:[[:space:]]*//' || true)
    transcript=$(grep '^- Transcript:' "$file" 2>/dev/null | head -1 | sed 's/^- Transcript:[[:space:]]*`\(.*\)`/\1/' || true)

    echo ""
    echo "═══ ${label} ═══"
    echo "  Date:       ${date}"
    echo "  Project:    ${project:-unknown}"
    echo "  File:       ${file}"
    [[ -n "$transcript" ]] && echo "  Transcript: ${transcript}"
    echo "  ───"
    grep -i -n --color=never -C 1 "$QUERY" "$file" 2>/dev/null | head -12 | sed 's/^/  /' || true
}


if [[ -f "$HTML_MODE_RECALL" ]]; then
    echo "╔══ Tier 0: Authored Pages ══╗"

    T0_ARGS=()
    [[ -n "$AFTER_DATE" ]] && T0_ARGS+=(--after "$AFTER_DATE")
    [[ -n "$BEFORE_DATE" ]] && T0_ARGS+=(--before "$BEFORE_DATE")
    [[ -n "$PROJECT_FILTER" ]] && T0_ARGS+=(--project "$PROJECT_FILTER")

    T0_RC=0
    T0_OUT="$(python3 "$HTML_MODE_RECALL" "$QUERY" --limit 6 "${T0_ARGS[@]+"${T0_ARGS[@]}"}" 2>/dev/null)" || T0_RC=$?
    if [[ $T0_RC -eq 0 && -n "$T0_OUT" ]]; then
        echo "$T0_OUT" | sed 's/^/  /'
    else
        [[ $T0_RC -le 1 ]] && echo "  (no authored pages matched)" \
                           || echo "  (tier unavailable — recall.py exited $T0_RC)"
    fi
    echo ""
fi


echo "╔══ Tier 1: Session Summaries ══╗"
FOUND=0
SUPPRESSED=0

if [[ -d "${VAULT_DIR}/outputs/session-summaries" ]]; then
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        date_filter "$file" || continue
        project_filter "$file" || continue
        if ! synthetic_filter "$file"; then
            SUPPRESSED=$((SUPPRESSED + 1)); continue
        fi
        show_match "$file" "Current library"
        FOUND=$((FOUND + 1))
    done < <(grep -i -l "$QUERY" "${VAULT_DIR}/outputs/session-summaries/"*.md 2>/dev/null || true)
fi

if [[ -n "$EXTRA_RECALL_DIR" && -d "${EXTRA_RECALL_DIR}/outputs/session-summaries" ]]; then
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        date_filter "$file" || continue
        project_filter "$file" || continue
        if ! synthetic_filter "$file"; then
            SUPPRESSED=$((SUPPRESSED + 1)); continue
        fi
        show_match "$file" "Additional library"
        FOUND=$((FOUND + 1))
    done < <(grep -i -l "$QUERY" "${EXTRA_RECALL_DIR}/outputs/session-summaries/"*.md 2>/dev/null || true)
fi

echo ""
echo "Found ${FOUND} matching session(s) in Tier 1."
if [[ "$SUPPRESSED" -gt 0 ]]; then
    echo "(${SUPPRESSED} harness/ablation session(s) hidden — rerun with --include-synthetic)"
fi


if [[ "$DEEP" == true ]]; then
    echo ""
    echo "╔══ Tier 2: JSONL Transcripts ══╗"
    DEEP_FOUND=0

    if [[ -d "$CLAUDE_PROJECTS" ]]; then
        while IFS= read -r jsonl; do
            [[ -z "$jsonl" ]] && continue
            proj_dir=$(dirname "$jsonl")
            proj_name=$(basename "$proj_dir" | sed -E 's/^-Users-[^/-]+-//' | sed 's/-/\//g')

            if [[ -n "$PROJECT_FILTER" ]] && [[ "$proj_name" != *"$PROJECT_FILTER"* ]]; then
                continue
            fi

            session_id=$(basename "$jsonl" .jsonl)

            echo ""
            echo "═══ Transcript: ${proj_name} ═══"
            echo "  Session:  ${session_id}"
            echo "  File:     ${jsonl}"
            echo "  ───"

            grep -i "$QUERY" "$jsonl" 2>/dev/null | head -5 | while IFS= read -r line; do
                text=$(echo "$line" | python3 -c "
import sys, json
try:
    entry = json.loads(sys.stdin.read())
    msg = entry.get('message', {})
    content = msg.get('content', '')
    if isinstance(content, str):
        print(content[:200])
    elif isinstance(content, list):
        for b in content:
            if isinstance(b, dict) and b.get('type') == 'text':
                t = b.get('text', '')
                if t:
                    print(t[:200])
                    break
except: pass
" 2>/dev/null)
                if [[ -n "$text" ]]; then
                    echo "  ${text}" | head -3
                fi
            done

            DEEP_FOUND=$((DEEP_FOUND + 1))
        done < <(grep -i -l "$QUERY" "${CLAUDE_PROJECTS}/"*/*.jsonl 2>/dev/null || true)
    fi

    echo ""
    echo "Found ${DEEP_FOUND} matching transcript(s) in Tier 2."
fi
