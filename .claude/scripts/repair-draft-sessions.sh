#!/usr/bin/env bash

set -euo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SESSIONS_DIR="${VAULT_DIR}/outputs/session-summaries"
LOG_FILE="${VAULT_DIR}/wiki/logs/repair-draft-sessions.log"
BACKUP_DIR="${HOME}/brain-backups"

MIN_AGE_SECONDS=7200            # 2h — floor for the reversible (-> captured) branch
MIN_DELETE_AGE_SECONDS=86400    # 24h — floor for the irreversible (delete) branch
APPLY=false
EXCLUDE_IDS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)                   APPLY=true; shift ;;
        --min-age-seconds)         MIN_AGE_SECONDS="${2:?--min-age-seconds requires a number}"; shift 2 ;;
        --min-delete-age-seconds)  MIN_DELETE_AGE_SECONDS="${2:?requires a number}"; shift 2 ;;
        --exclude)                 EXCLUDE_IDS="${EXCLUDE_IDS}${2:?--exclude requires a session id}"$'\n'; shift 2 ;;
        -h|--help)
            cat <<'EOHELP'
Usage: repair-draft-sessions.sh [--dry-run] [--all] [options]
EOHELP
            exit 0 ;;
        *)                         echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
STAMP=$(date -u +"%Y%m%dT%H%M%SZ")
mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR"


LIVE_BY_FLAG=$(ps -axo pid=,command= 2>/dev/null \
               | grep -o -- '--session-id [0-9a-fA-F-]\{36\}' \
               | awk '{print $2}' | sort -u || true)

LIVE_BY_ENV=$(find "${HOME}/.claude/session-env" -maxdepth 1 -type d \
                   -mmin -$((MIN_AGE_SECONDS / 60)) 2>/dev/null \
              | xargs -n1 basename 2>/dev/null | grep -E '^[0-9a-fA-F-]{36}$' || true)

LIVE_IDS=$(printf '%s\n%s\n%s\n' "$LIVE_BY_FLAG" "$LIVE_BY_ENV" "$EXCLUDE_IDS" \
           | grep -v '^$' | sort -u || true)

echo "Liveness: $(printf '%s\n' "$LIVE_IDS" | grep -cv '^$' || echo 0) protected session id(s)"
printf '%s\n' "$LIVE_IDS" | grep -v '^$' | sed 's/^/  PROTECTED  /' || true
echo ""

resolve_transcript() {
    local stub="$1" sid tx
    tx=$(grep -E '^- Transcript:' "$stub" 2>/dev/null | head -1 | sed 's/.*`\(.*\)`.*/\1/')
    if [[ -n "$tx" && -f "$tx" ]]; then echo "$tx"; return 0; fi
    sid=$(awk -F': ' '/^session_id:/{print $2; exit}' "$stub" 2>/dev/null | tr -d '\r ')
    [[ -z "$sid" ]] && sid=$(awk -F': ' '/^id:/{print $2; exit}' "$stub" 2>/dev/null | tr -d '\r ')
    [[ -z "$sid" ]] && sid=$(basename "$stub" .md | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//')
    [[ -z "$sid" ]] && { echo ""; return 1; }
    tx=$(find "$HOME/.claude/projects" -name "${sid}*.jsonl" 2>/dev/null | head -1)
    if [[ -n "$tx" && -f "$tx" ]]; then echo "$tx"; return 0; fi
    echo ""; return 1
}

is_empty_stub() {
    python3 - "$1" <<'PY'
import re, sys
src = open(sys.argv[1], errors="replace").read()
body = re.sub(r'(?s)\A---\n.*?\n---\n', '', src)          # drop frontmatter
substantive = []
for line in body.splitlines():
    s = line.strip()
    if not s: continue
    if s.startswith('#'): continue                         # headings
    if s.startswith('_') and s.endswith('_'): continue     # italic placeholders
    if re.match(r'^- (Session ID|Started|Ended|Working Directory|Transcript):', s):
        continue                                           # provenance boilerplate
    substantive.append(s)
sys.exit(0 if not substantive else 1)
PY
}

newest_mtime() {   # max(mtime) over the args that exist; 0 if none
    local m best=0 f
    for f in "$@"; do
        [[ -n "$f" && -e "$f" ]] || continue
        m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
        [[ "$m" -gt "$best" ]] && best="$m"
    done
    echo "$best"
}

now=$(date +%s)
n_live=0 n_young=0 n_cap=0 n_del=0 n_held=0
DELETE_LIST=$(mktemp)
trap 'rm -f "$DELETE_LIST"' EXIT

shopt -s nullglob
for f in "${SESSIONS_DIR}"/*.md; do
    st=$(awk '/^status:/{sub(/^status:[[:space:]]*/,""); sub(/[[:space:]]+$/,""); print; exit}' "$f")
    [[ "$st" == "draft" ]] || continue

    sid=$(awk -F': ' '/^id:/{print $2; exit}' "$f" | tr -d '\r ')
    [[ -z "$sid" ]] && sid=$(basename "$f" .md | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//')

    if [[ -n "$LIVE_IDS" ]] && grep -qx "$sid" <<< "$LIVE_IDS"; then
        n_live=$((n_live + 1)); echo "  LIVE  keep draft : $(basename "$f")"; continue
    fi

    tx=$(resolve_transcript "$f" || true)

    mt=$(newest_mtime "$f" "$tx")
    age=$(( now - mt ))

    if [[ "$age" -lt "$MIN_AGE_SECONDS" ]]; then
        n_young=$((n_young + 1))
        echo "  YOUNG keep draft : $(basename "$f") ($(( age / 60 ))m since last write)"; continue
    fi

    if [[ -n "$tx" ]]; then
        n_cap=$((n_cap + 1)); echo "  -> captured      : $(basename "$f")"
        if $APPLY; then
            tmp_repair=$(mktemp)
            awk -v ts="${TS}" '
                NR==1 && $0=="---" { inside=1; print; next }
                inside && $0=="---" { inside=0; print; next }
                inside && /^status:[ \t]*draft[ \t]*$/ && !swapped {
                    print "status: captured"
                    print "repaired_from: draft"
                    print "repaired_at: " ts
                    swapped=1
                    next
                }
                { print }
            ' "$f" > "$tmp_repair" && [[ -s "$tmp_repair" ]] && cat "$tmp_repair" > "$f"
            rm -f "$tmp_repair"
            echo "[${TS}] repaired->captured $(basename "$f")" >> "$LOG_FILE"
        fi
        continue
    fi

    if [[ "$age" -lt "$MIN_DELETE_AGE_SECONDS" ]]; then
        n_held=$((n_held + 1))
        echo "  HELD  (too new) : $(basename "$f") ($(( age / 3600 ))h < $(( MIN_DELETE_AGE_SECONDS / 3600 ))h delete floor)"
        continue
    fi
    if ! is_empty_stub "$f"; then
        n_held=$((n_held + 1))
        echo "  HELD  (has body): $(basename "$f") — no transcript, but the file has real content"
        continue
    fi

    n_del=$((n_del + 1)); echo "  -> DELETE        : $(basename "$f") ($(wc -c < "$f" | tr -d ' ')B, no transcript, empty)"
    echo "$f" >> "$DELETE_LIST"
done

if $APPLY && [[ -s "$DELETE_LIST" ]]; then
    TARBALL="${BACKUP_DIR}/rx2-deleted-drafts-${STAMP}.tar.gz"
    tar -czf "$TARBALL" -C "$VAULT_DIR" $(sed "s|^${VAULT_DIR}/||" "$DELETE_LIST")
    echo ""
    echo "Backed up $(wc -l < "$DELETE_LIST" | tr -d ' ') file(s) -> ${TARBALL}"
    while read -r victim; do
        rm -f "$victim"
        echo "[${TS}] deleted-unrecoverable $(basename "$victim")" >> "$LOG_FILE"
    done < "$DELETE_LIST"
    echo "[${TS}] deletion tarball ${TARBALL}" >> "$LOG_FILE"
fi

echo ""
echo "live-kept=${n_live} young-kept=${n_young} held=${n_held} ->captured=${n_cap} ->deleted=${n_del} (apply=${APPLY})"
echo "[${TS}] SUMMARY live=${n_live} young=${n_young} held=${n_held} captured=${n_cap} deleted=${n_del} apply=${APPLY}" >> "$LOG_FILE"
