#!/usr/bin/env bash

set -euo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WIKI_DIR="${VAULT_DIR}/wiki"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "Running in dry-run mode (no changes will be made)"
fi

echo "=== Vault Maintenance ==="
echo "Started: ${TIMESTAMP}"
echo ""

mkdir -p "${WIKI_DIR}/logs"

LOG_FILE="${WIKI_DIR}/logs/maintenance-${TIMESTAMP}.log"

log() {
    echo "$@" | tee -a "${LOG_FILE}"
}

log "1. Scanning for broken links..."

BROKEN_LINKS=()
while IFS= read -r -d '' file; do
    if [[ -f "${file}" ]]; then
        while IFS= read -r link; do
            clean_link=$(echo "${link}" | sed 's/\[\[//;s/\]\]//' | cut -d'|' -f1 | cut -d'#' -f1)

            if [[ "$clean_link" == "..."
               || "$clean_link" == *"path/to/"*
               || "$clean_link" == *"type/slug"*
               || "$clean_link" == "A"
               || "$clean_link" == "B"
               || "$clean_link" == "create a link" ]]; then
                continue
            fi

            if [[ ! -f "${VAULT_DIR}/${clean_link}" && ! -f "${VAULT_DIR}/${clean_link}.md" ]]; then
                BROKEN_LINKS+=("${file}: [[${clean_link}]]")
            fi
        done < <(grep -v '^\s*```' "${file}" | grep -v '`\[\[' | grep -oE '\[\[[^]]+\]\]' || true)
    fi
done < <(find "${WIKI_DIR}" -type f -name "*.md" ! -name "maintenance-issues.md" -print0)

if [[ ${#BROKEN_LINKS[@]} -gt 0 ]]; then
    log "Found ${#BROKEN_LINKS[@]} broken links:"
    for link in "${BROKEN_LINKS[@]}"; do
        log "  - ${link}"
    done
else
    log "✓ No broken links found"
fi

echo ""
log "2. Scanning for orphan pages..."

ORPHAN_PAGES=()
while IFS= read -r -d '' file; do
    filename=$(basename "${file}")

    if [[ "${filename}" == "index.md" || "${file}" == *"/logs/"* ]]; then
        continue
    fi

    references=$(grep -r "\[\[.*${filename%.*}" "${WIKI_DIR}" || true)

    if [[ -z "${references}" ]]; then
        ORPHAN_PAGES+=("${file}")
    fi
done < <(find "${WIKI_DIR}" -type f -name "*.md" -print0)

if [[ ${#ORPHAN_PAGES[@]} -gt 0 ]]; then
    log "Found ${#ORPHAN_PAGES[@]} orphan pages:"
    for page in "${ORPHAN_PAGES[@]}"; do
        log "  - ${page}"
    done
else
    log "✓ No orphan pages found"
fi

echo ""
log "3. Checking frontmatter consistency..."

MISSING_FRONTMATTER=()
while IFS= read -r -d '' file; do
    if ! head -1 "${file}" | grep -q "^---$"; then
        MISSING_FRONTMATTER+=("${file}")
    fi
done < <(find "${WIKI_DIR}" -type f -name "*.md" ! -path "*/logs/*" -print0)

if [[ ${#MISSING_FRONTMATTER[@]} -gt 0 ]]; then
    log "Found ${#MISSING_FRONTMATTER[@]} files missing frontmatter:"
    for file in "${MISSING_FRONTMATTER[@]}"; do
        log "  - ${file}"
    done
else
    log "✓ All wiki pages have frontmatter"
fi

echo ""
log "3b. Checking verification staleness (verification freshness)..."

STALE_COUNT=0
STALE_LINES=()
UNEARNED_COUNT=0
UNEARNED_LINES=()
NOW_EPOCH=$(date -u +%s)
while IFS= read -r -d '' f; do
    fc=$(awk 'NR==1&&!/^---/{exit} /^---/{n++; if(n==2) exit; next} /^freshness_class:/{sub(/^freshness_class:[[:space:]]*/,""); print $1; exit}' "$f")
    case "$fc" in
        volatile)      max=7 ;;
        fast-changing) max=30 ;;
        *)             continue ;;
    esac
    lv=$(awk 'NR==1&&!/^---/{exit} /^---/{n++; if(n==2) exit; next} /^last_verified:/{sub(/^last_verified:[[:space:]]*/,""); sub(/[[:space:]]*#.*$/,""); print; exit}' "$f")
    lv="${lv%\"}"; lv="${lv#\"}"; lv="${lv%\'}"; lv="${lv#\'}"
    vb=$(awk 'NR==1&&!/^---/{exit} /^---/{n++; if(n==2) exit; next} /^verified_by:[[:space:]]*[^[:space:]]/{print "y"; exit}' "$f")
    rel="${f#"${VAULT_DIR}"/}"
    if [[ -z "$lv" || "$lv" == "null" || "$lv" == "~" ]]; then
        STALE_LINES+=("  NEVER    [${fc}]  ${rel}")
        STALE_COUNT=$((STALE_COUNT + 1)); continue
    fi
    t=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$lv" +%s 2>/dev/null || echo "")
    if [[ -z "$t" ]]; then
        STALE_LINES+=("  UNPARSEABLE [${fc}]  ${rel}  -> '${lv:0:48}'")
        STALE_COUNT=$((STALE_COUNT + 1)); continue
    fi
    age=$(( (NOW_EPOCH - t) / 86400 ))
    if [[ "$age" -gt "$max" ]]; then
        STALE_LINES+=("  ${age}d ago [${fc}, max ${max}d]  ${rel}")
        STALE_COUNT=$((STALE_COUNT + 1))
        continue
    fi
    if [[ -z "$vb" ]]; then
        UNEARNED_LINES+=("  ${age}d ago [${fc}]  ${rel}")
        UNEARNED_COUNT=$((UNEARNED_COUNT + 1))
    fi
done < <(find "${WIKI_DIR}" -type f -name "*.md" ! -path "*/logs/*" -print0)

if [[ "$STALE_COUNT" -gt 0 ]]; then
    log "${STALE_COUNT} page(s) need a live check:"
    for l in "${STALE_LINES[@]}"; do log "$l"; done
    log "  Re-verify with: .claude/scripts/verify-page.sh <page> --claim \"...\" -- <command>"
else
    log "✓ Every volatile/fast-changing page has been checked inside its window"
fi

if [[ "$UNEARNED_COUNT" -gt 0 ]]; then
    log "${UNEARNED_COUNT} page(s) carry a RECENT BUT HAND-TYPED date (in window, no verified_by):"
    for l in "${UNEARNED_LINES[@]}"; do log "$l"; done
    log "  Dates without a recorded check do not establish verified freshness."
fi
printf '%s' "$STALE_COUNT" > "${VAULT_DIR}/outputs/.stale-count" 2>/dev/null || true
printf '%s' "$UNEARNED_COUNT" > "${VAULT_DIR}/outputs/.unearned-count" 2>/dev/null || true

ALT_STATUS_FILE="${VAULT_DIR}/outputs/.altitude-status.json"
bash "${VAULT_DIR}/.claude/scripts/brain-vitals.sh" --json --no-snapshot 2>/dev/null \
  | python3 -c "
import json, sys, datetime
try:
    ms = {m.get('key'): m.get('value') for m in json.load(sys.stdin).get('metrics', []) if isinstance(m, dict)}
except Exception:
    ms = {}
out = {
    'computed_at': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'dup_passages': ms.get('claudemd_dup_passages'),
    'dup_example': ms.get('claudemd_dup_passages_example'),
    'sections_over_3kb': ms.get('claudemd_sections_over_3kb'),
    'sections_over_3kb_names': ms.get('claudemd_sections_over_3kb_names'),
}
open('${ALT_STATUS_FILE}', 'w').write(json.dumps(out))
" 2>/dev/null || true
if [[ -f "$ALT_STATUS_FILE" ]]; then
    log "altitude/dup drop-file written (starting-context size detectors)"
fi

echo ""
log "4. Generating maintenance summary..."

SUMMARY_FILE="${VAULT_DIR}/wiki/indexes/maintenance-issues.md"

if [[ "${DRY_RUN}" == false ]]; then
    cat > "${SUMMARY_FILE}" <<EOF
---
id: maintenance-issues
type: index
status: active
updated_at: ${TIMESTAMP}
tags:
  - index
  - maintenance
---

# Maintenance Issues

Last updated: ${TIMESTAMP}

## Broken Links (${#BROKEN_LINKS[@]})

$(if [[ ${#BROKEN_LINKS[@]} -gt 0 ]]; then
    for link in "${BROKEN_LINKS[@]}"; do
        echo "- ${link}"
    done
else
    echo "None found ✓"
fi)

## Orphan Pages (${#ORPHAN_PAGES[@]})

$(if [[ ${#ORPHAN_PAGES[@]} -gt 0 ]]; then
    for page in "${ORPHAN_PAGES[@]}"; do
        echo "- [[${page}]]"
    done
else
    echo "None found ✓"
fi)

## Missing Frontmatter (${#MISSING_FRONTMATTER[@]})

$(if [[ ${#MISSING_FRONTMATTER[@]} -gt 0 ]]; then
    for file in "${MISSING_FRONTMATTER[@]}"; do
        echo "- [[${file}]]"
    done
else
    echo "None found ✓"
fi)

## Next Actions

- Review broken links and fix or remove
- Review orphan pages and link or archive
- Add frontmatter to pages missing it
EOF

    log "✓ Maintenance summary written to ${SUMMARY_FILE}"
else
    log "Dry-run: Would write summary to ${SUMMARY_FILE}"
fi

echo ""
log "=== Maintenance Complete ==="
log "Log: ${LOG_FILE}"
if [[ "${DRY_RUN}" == false ]]; then
    log "Summary: ${SUMMARY_FILE}"
fi
