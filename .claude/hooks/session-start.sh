#!/usr/bin/env bash

set -euo pipefail


VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_FILE="${VAULT_DIR}/wiki/logs/session-capture.log"

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
CWD=$(echo "$INPUT" | jq -r '.cwd // "unknown"')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DATE_PREFIX=$(date -u +"%Y-%m-%d")
SESSION_FILE="${VAULT_DIR}/outputs/session-summaries/${DATE_PREFIX}-${SESSION_ID}.md"

mkdir -p "${VAULT_DIR}/outputs/session-summaries"
mkdir -p "$(dirname "$LOG_FILE")"

if [[ -f "$SESSION_FILE" ]]; then
    echo "[${TIMESTAMP}] Session resumed (file exists): ${SESSION_ID}" >> "$LOG_FILE"
    exit 0
fi

EXISTING=$(find "${VAULT_DIR}/outputs/session-summaries" -name "*-${SESSION_ID}.md" -print -quit 2>/dev/null || true)
if [[ -n "$EXISTING" ]]; then
    echo "[${TIMESTAMP}] Session resumed (found ${EXISTING}): ${SESSION_ID}" >> "$LOG_FILE"
    exit 0
fi

STATUS_FILE="${VAULT_DIR}/outputs/.ingest-status.json"
if [[ -f "$STATUS_FILE" ]]; then
    warnings=$(
        streak=$(python3 -c "import json; d=json.load(open('$STATUS_FILE')); print(d.get('streak_failures',0))" 2>/dev/null || echo "0")
        auth_skip=$(python3 -c "import json; d=json.load(open('$STATUS_FILE')); print(d.get('auth_skip_streak',0))" 2>/dev/null || echo "0")
        pending=$(python3 -c "import json; d=json.load(open('$STATUS_FILE')); print(d.get('pending',0))" 2>/dev/null || echo "0")
        last_run=$(python3 -c "import json; d=json.load(open('$STATUS_FILE')); print(d.get('last_run',''))" 2>/dev/null || echo "")

        if [[ "$auth_skip" -ge 3 ]]; then
            echo "⚠️  auto-ingest STALLED: auth unavailable for ${auth_skip} cycles. Fix: check credentials."
        fi
        if [[ "$streak" -ge 3 ]]; then
            echo "⚠️  auto-ingest has ${streak} consecutive failures."
        fi
        if [[ "$pending" -ge 50 ]]; then
            echo "⚠️  ${pending} sessions pending ingest (backlog growing)."
        fi
        unknown=$(python3 -c "import json; d=json.load(open('$STATUS_FILE')); print(d.get('unknown_status_count',0))" 2>/dev/null || echo "0")
        if [[ "$unknown" -gt 0 ]]; then
            umap=$(python3 -c "import json; d=json.load(open('$STATUS_FILE')); print(json.dumps(d.get('unknown_status',{})))" 2>/dev/null || echo "{}")
            echo "⚠️  ${unknown} session summaries carry an UNRECOGNISED status ${umap} — the ingest pipeline cannot act on them."
        fi
        selfcheck_ok=$(python3 -c "import json; d=json.load(open('$STATUS_FILE')); print(d.get('gauge_selfcheck_ok',True))" 2>/dev/null || echo "True")
        if [[ "$selfcheck_ok" != "True" ]]; then
            echo "⚠️  auto-ingest gauge SELFCHECK FAILED — treat pending/healthy as unreliable."
        fi
        if [[ -n "$last_run" ]]; then
            last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_run" +%s 2>/dev/null || echo "0")
            now_epoch=$(date +%s)
            age=$(( (now_epoch - last_epoch) / 3600 ))
            if [[ "$age" -ge 48 ]]; then
                echo "⚠️  auto-ingest hasn't run in ${age} hours."
            fi
        fi
    ) 2>/dev/null || true

    if [[ -n "$warnings" ]]; then
        {
            echo "[${TIMESTAMP}] ingest-health warnings:"
            echo "$warnings"
        } >> "$LOG_FILE"
        echo "$warnings"   # stdout → visible in session context
    fi
fi

STALE_FILE="${VAULT_DIR}/outputs/.stale-count"
if [[ -f "$STALE_FILE" ]]; then
    stale_n=$(tr -cd '0-9' < "$STALE_FILE" 2>/dev/null || echo "")
    stale_mtime=$(stat -f %m "$STALE_FILE" 2>/dev/null || echo "0")
    stale_age_d=$(( ( $(date +%s) - stale_mtime ) / 86400 ))
    if [[ "$stale_age_d" -ge 7 ]]; then
        echo "⚠️  verification staleness unknown — .stale-count is ${stale_age_d}d old (run .claude/scripts/maintenance.sh)."
    elif [[ -n "$stale_n" && "$stale_n" -gt 0 ]]; then
        unearned_n=$(tr -cd '0-9' < "${VAULT_DIR}/outputs/.unearned-count" 2>/dev/null || echo "")
        extra=""
        [[ -n "$unearned_n" && "$unearned_n" -gt 0 ]] && extra=" ${unearned_n} more carry a recent but HAND-TYPED date (reads fresh, isn't evidence)."
        echo "⚠️  ${stale_n} volatile/fast-changing page(s) are past their verification window.${extra} See maintenance.sh step 3b; re-verify with .claude/scripts/verify-page.sh."
    fi
else
    echo "⚠️  no verification-staleness reading yet — run .claude/scripts/maintenance.sh (verification freshness)."
fi

ALT_STATUS_FILE="${VAULT_DIR}/outputs/.altitude-status.json"
if [[ -f "$ALT_STATUS_FILE" ]]; then
    alt_warn=$(
        alt_mtime=$(stat -f %m "$ALT_STATUS_FILE" 2>/dev/null || echo "0")
        alt_age_d=$(( ( $(date +%s) - alt_mtime ) / 86400 ))
        if [[ "$alt_age_d" -ge 7 ]]; then
            echo "⚠️  hot-cache altitude unknown — .altitude-status.json is ${alt_age_d}d old (run .claude/scripts/maintenance.sh)."
        else
            dup=$(python3 -c "import json;print(json.load(open('$ALT_STATUS_FILE')).get('dup_passages') or 0)" 2>/dev/null || echo "0")
            dup_ex=$(python3 -c "import json;print(json.load(open('$ALT_STATUS_FILE')).get('dup_example') or '')" 2>/dev/null || echo "")
            secs=$(python3 -c "import json;print(json.load(open('$ALT_STATUS_FILE')).get('sections_over_3kb') or 0)" 2>/dev/null || echo "0")
            secs_n=$(python3 -c "import json;print(json.load(open('$ALT_STATUS_FILE')).get('sections_over_3kb_names') or '')" 2>/dev/null || echo "")
            if [[ "$dup" =~ ^[0-9]+$ && "$dup" -gt 0 ]]; then
                echo "⚠️  CLAUDE.md has ${dup} passage(s) duplicated in wiki/ or memory/ (pointers-not-copies drift, starting-context size). e.g. \"${dup_ex}\" — move to the downstream page, leave a pointer."
            fi
            if [[ "$secs" =~ ^[0-9]+$ && "$secs" -gt 0 ]]; then
                echo "⚠️  CLAUDE.md has ${secs} non-index section(s) over 3KB (container, not pointer, starting-context size): ${secs_n}. Extract to a wiki page and link it."
            fi
        fi
    ) 2>/dev/null || true
    if [[ -n "$alt_warn" ]]; then
        { echo "[${TIMESTAMP}] altitude-drift warnings:"; echo "$alt_warn"; } >> "$LOG_FILE"
        echo "$alt_warn"
    fi
else
    echo "⚠️  no hot-cache altitude reading yet — run .claude/scripts/maintenance.sh (starting-context size detectors)."
fi

PROJECT_NAME=$(basename "$CWD")

SYNTHETIC=false
SYNTHETIC_REASON=""
if [[ -n "${BRAIN_INGEST:-}" ]]; then
    SYNTHETIC=true
    SYNTHETIC_REASON="brain-ingest-self-call"
elif [[ "${BRAIN_SYNTHETIC:-0}" == "1" ]]; then
    SYNTHETIC=true
    SYNTHETIC_REASON="env"
else
    case "$CWD" in
        /tmp|/tmp/*|/private/tmp|/private/tmp/*)
            SYNTHETIC=true; SYNTHETIC_REASON="cwd:tmp" ;;
        "$HOME"/.claude/jobs/*)
            SYNTHETIC=true; SYNTHETIC_REASON="cwd:claude-jobs" ;;
        "$HOME"/.ablation-scratch|"$HOME"/.ablation-scratch/*)
            SYNTHETIC=true; SYNTHETIC_REASON="cwd:ablation-scratch" ;;
        "$HOME"/.brain-tax|"$HOME"/.brain-tax/*)
            SYNTHETIC=true; SYNTHETIC_REASON="cwd:brain-tax" ;;
        "$HOME"/*/outputs/validation|"$HOME"/*/outputs/validation/*)
            SYNTHETIC=true; SYNTHETIC_REASON="cwd:validation" ;;
        "$HOME"/abl-test*)
            SYNTHETIC=true; SYNTHETIC_REASON="cwd:abl-test" ;;
    esac
fi

cat > "$SESSION_FILE" <<EOF
---
id: ${SESSION_ID}
type: session_summary
project: ${PROJECT_NAME}
synthetic: ${SYNTHETIC}
synthetic_reason: ${SYNTHETIC_REASON}
source_type: claude_code
status: draft
confidence: medium
created_at: ${TIMESTAMP}
updated_at: ${TIMESTAMP}
sources: []
links: []
reviewed: false
tags:
  - session
  - claude-code
  - in-progress
---

# Session: ${SESSION_ID}

## Prompt Summary

_To be filled at session end from transcript_

## Key Outputs

_To be filled by session end_

## Ledger

_To be filled by session end from the transcript (tool trail + closing statement)_

## Files Changed

_To be filled by session end_

## Follow-up Tasks

_To be filled by session end_

## Open Questions

_To be filled by session end_

## Compact Summary

_To be filled by post-compact hook_

## Related Pages

_To be linked after session analysis_

## Provenance

- Session ID: \`${SESSION_ID}\`
- Started: ${TIMESTAMP}
- Working Directory: \`${CWD}\`
- Transcript: \`${TRANSCRIPT_PATH}\`
EOF

echo "[${TIMESTAMP}] Session started: ${SESSION_ID} in ${CWD}" >> "$LOG_FILE"
