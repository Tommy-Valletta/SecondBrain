#!/usr/bin/env bash

set -euo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATE_FILE="${VAULT_DIR}/.claude/templates/ingest-session-prompt.md"
GUIDELINES_FILE="${VAULT_DIR}/wiki/knowledge/concepts/ingest-quality-guidelines.md"
SOURCES_INDEX="${VAULT_DIR}/wiki/indexes/sources.md"
LOG_FILE="${VAULT_DIR}/wiki/logs/ingest.log"
SESSIONS_DIR="${VAULT_DIR}/outputs/session-summaries"
RAW_SESSIONS_DIR="${VAULT_DIR}/raw/claude-sessions"
SOURCE_TYPE="claude_code_session"
HARNESS="claude-code"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

DRY_RUN=false
ALL_MODE=false
MAX_SESSIONS=0
MODEL="${MODEL:-}"
INGEST_MODEL="${INGEST_MODEL:-}"

run_llm() {
    local model_flag pine
    model_flag=()
    if [[ -n "${PI_CODING_AGENT:-}" ]] || [[ -z "${CLAUDE_CODE_ENTRYPOINT:-}" ]]; then
        command -v pi >/dev/null || { echo "PLLM_ERROR: pi not found" >&2; return 127; }
        [[ -n "$INGEST_MODEL" ]] && model_flag=(--model "$INGEST_MODEL")
        pi -p --no-session "${model_flag[@]}" --tools read "$@"
        pine=$?
        return $pine
    fi
    model_flag=()
    [[ -n "${MODEL:-}" ]] && model_flag=(--model "$MODEL")
    "${VAULT_DIR}/.claude/scripts/lib/claude-parent-auth.sh" \
        -p "${model_flag[@]}" --dangerously-skip-permissions --tools "Read,Glob,Grep" "$@"
}
RESCORE=false
HEADLESS_ENTRYPOINTS="${HEADLESS_ENTRYPOINTS:-}"
AUTOMATION_PROJECT_RE="${AUTOMATION_PROJECT_RE:-^validation$|^gate[0-9].*-tmp$|^cwd-.*-(mcp-only|full-on|claudemd-only)}"


usage() {
    echo "Usage: $0 [--dry-run] [--all] [--max-sessions N] [--rescore] [<session-file>]"
    echo ""
    echo "Options:"
    echo "  --dry-run              Show what would happen without calling Claude or writing files"
    echo "  --all                  Process all eligible session summaries"
    echo "  --max-sessions N       Process at most N sessions (0 = unlimited, default: 0)"
    echo "  --rescore              Also re-open summaries already marked 'skipped'. They were"
    echo "                         made terminal by a triage scorer that no longer exists."
    echo "                         Does NOT touch 'draft' — use repair-draft-sessions.sh,"
    echo "                         which has the live-session guard."
    echo ""
    echo "Every session that clears the gate gets a full LLM ingest. There is no"
    echo "score and no threshold — cost is bounded by --max-sessions, newest first."
    exit 1
}

SESSION_FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --all)
            ALL_MODE=true
            shift
            ;;
        --max-sessions)
            MAX_SESSIONS="${2:?--max-sessions requires a number}"
            shift 2
            ;;
        --rescore)
            RESCORE=true
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
            SESSION_FILES+=("$1")
            shift
            ;;
    esac
done

if ! $ALL_MODE && [[ ${#SESSION_FILES[@]} -eq 0 ]]; then
    echo "Error: No session file specified. Use --all or provide a file path."
    usage
fi


slugify() {
    echo "$1" | \
        tr '[:upper:]' '[:lower:]' | \
        sed 's/[^a-z0-9 -]//g' | \
        sed 's/  */ /g' | \
        sed 's/ /-/g' | \
        cut -c1-60
}

gather_wiki_pages() {
    local dir="$1"
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

resolve_transcript() {
    local stub="$1" sid tx
    tx=$(grep -E '^- Transcript:' "$stub" 2>/dev/null | head -1 | sed 's/.*`\(.*\)`.*/\1/')
    if [[ -n "$tx" && -f "$tx" ]]; then echo "$tx"; return 0; fi
    sid=$(awk -F': ' '/^session_id:/{print $2; exit}' "$stub" 2>/dev/null | tr -d '\r ')
    [[ -z "$sid" ]] && sid=$(basename "$stub" .md | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//')
    [[ -z "$sid" ]] && { echo ""; return 1; }
    tx=$(find "$HOME/.claude/projects" -name "${sid}*.jsonl" 2>/dev/null | head -1)
    if [[ -n "$tx" && -f "$tx" ]]; then echo "$tx"; return 0; fi
    echo ""; return 1
}


fm_status() {
    awk '
        NR==1 && $0=="---" { inside=1; next }
        inside && $0=="---" { exit }
        inside && /^status:/ { n++; if (n==1) { v=$0; sub(/^status:[ \t]*/,"",v); sub(/[ \t]+$/,"",v) } }
        END { if (n>1) printf "!MULTI"; else printf "%s", v }
    ' "$1"
}

stub_hash() {
    awk '
        BEGIN { fence=0; skip=0 }
        /^---$/ && fence < 2 { fence++; next }
        fence < 2 { next }
        /^## Provenance/ { skip=1; next }
        /^## / { skip=0 }
        skip { next }
        { print }
    ' "$1" | shasum -a 256 | cut -c1-16
}

needs_repromote() {
    local file="$1" ph
    [[ "$(fm_status "$file")" == "promoted" ]] || return 1
    ph=$(fm_field "$file" "promoted_hash")
    [[ -n "$ph" ]] || return 1              # legacy promotion, grandfathered
    [[ "$ph" != "$(stub_hash "$file")" ]]
}

fm_field() {
    awk -v key="$2" '
        NR==1 && $0=="---" { inside=1; next }
        inside && $0=="---" { exit }
        inside && index($0, key ":") == 1 {
            v=$0; sub(/^[^:]*:[ \t]*/, "", v); sub(/[ \t]+$/, "", v); print v; exit
        }
    ' "$1"
}

fm_set_status() {
    local file="$1" allowed="$2" new="$3" promoted_to="${4:-}" phash="${5:-}"
    local cur tmp
    cur=$(fm_status "$file")
    if [[ "$cur" == "!MULTI" ]]; then
        echo "  REFUSED: >1 'status:' line in the frontmatter of $(basename "$file")" >&2
        return 1
    fi
    [[ " ${allowed} " == *" ${cur} "* ]] || return 1
    tmp=$(mktemp)
    awk -v new="$new" -v pt="$promoted_to" -v ph="$phash" '
        NR==1 && $0=="---" { inside=1; print; next }
        inside && $0=="---" { inside=0; print; next }
        inside && pt != "" && /^promoted_to:/ { next }
        inside && ph != "" && /^promoted_hash:/ { next }
        inside && /^status:/ && !swapped {
            print "status: " new
            if (pt != "") print "promoted_to: " pt
            if (ph != "") print "promoted_hash: " ph
            swapped=1
            next
        }
        { print }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$file"
    rm -f "$tmp"
    return 0
}


check_quality() {
    local file="$1"
    local reason=""

    local status
    status=$(fm_status "$file")
    if [[ "$status" == "!MULTI" ]]; then
        reason="ambiguous frontmatter (>1 status line)"
        echo "$reason"
        return 1
    fi
    if [[ "$status" == "promoted" ]]; then
        if ! needs_repromote "$file"; then
            if [[ -z "$(fm_field "$file" "promoted_hash")" ]]; then
                reason="already promoted"
            else
                reason="already promoted (unchanged)"
            fi
            echo "$reason"
            return 1
        fi
    elif $RESCORE; then
        if [[ "$status" != "captured" && "$status" != "skipped" ]]; then
            reason="status is '${status}', not re-triageable"
            echo "$reason"
            return 1
        fi
    elif [[ "$status" != "captured" ]]; then
        reason="status is '${status}', need 'captured'"
        echo "$reason"
        return 1
    fi

    local lines
    lines=$(wc -l < "$file" | tr -d ' ')
    if [[ "$lines" -lt 40 ]]; then
        reason="only ${lines} lines (need >= 40)"
        echo "$reason"
        return 1
    fi

    local actionable_placeholders=0
    local in_section=""
    while IFS= read -r line; do
        case "$line" in
            "## Prompt Summary") in_section="prompt" ;;
            "## Key Outputs")    in_section="outputs" ;;
            "## Files Changed")  in_section="files" ;;
            "## Decisions Made"|"## Ledger"|"## Follow-up Tasks"|"## Open Questions"|"## Compact Summary"|"## Related Pages"|"## Provenance")
                in_section="" ;;
            "## "*)              in_section="" ;;
        esac
        if [[ -n "$in_section" ]] && echo "$line" | grep -q '^_To be filled'; then
            actionable_placeholders=$((actionable_placeholders + 1))
        fi
    done < "$file"

    if [[ "$actionable_placeholders" -ge 3 ]]; then
        reason="too many actionable placeholder sections (${actionable_placeholders} of 4)"
        echo "$reason"
        return 1
    fi

    local substance_chars
    substance_chars=$(awk '
        BEGIN { skip=0 }
        /^---$/ { skip++; next }
        skip < 2 { next }
        /^#/ { next }
        /^$/ { next }
        /_To be filled/ { next }
        /_To be linked/ { next }
        /^- Session ID:/ { next }
        /^- Started:/ { next }
        /^- Ended:/ { next }
        /^- Working Directory:/ { next }
        /^- Transcript:/ { next }
        { total += length($0) }
        END { print total+0 }
    ' "$file")

    if [[ "$substance_chars" -lt 800 ]]; then
        reason="insufficient content (${substance_chars} chars of substance, need >= 800)"
        echo "$reason"
        return 1
    fi

    local now mtime
    now=$(date +%s)
    mtime=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null || echo "0")
    if [[ $((now - mtime)) -lt 60 ]]; then
        reason="file modified $((now - mtime))s ago (need >= 60s for transcript parser to finish)"
        echo "$reason"
        return 1
    fi

    echo "passed"
    return 0
}


session_entrypoint() {
    local tx="$1"
    if [[ -z "$tx" || ! -f "$tx" ]]; then echo ""; return 0; fi
    head -40 "$tx" 2>/dev/null \
        | grep -o '"entrypoint"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 \
        | sed 's/.*"\([^"]*\)"$/\1/'
}

session_turn_count() {
    local tx="$1" n rc
    if [[ -z "$tx" || ! -f "$tx" ]]; then echo "-1"; return 0; fi
    n=$(grep -cE '"type"[[:space:]]*:[[:space:]]*"(user|assistant)"' "$tx" 2>/dev/null) && rc=0 || rc=$?
    case $rc in
        0) echo "$n" ;;
        1) echo "0" ;;
        *) echo "-1" ;;
    esac
}


extract_session_meta() {
    local file="$1"

    SESSION_ID=$(grep -E '^id:' "$file" | head -1 | sed 's/^id:[[:space:]]*//')
    PROJECT=$(grep -E '^project:' "$file" | head -1 | sed 's/^project:[[:space:]]*//')
    SESSION_CREATED=$(grep -E '^created_at:' "$file" | head -1 | sed 's/^created_at:[[:space:]]*//')

    SESSION_DATE=$(basename "$file" | cut -c1-10)

    SESSION_TITLE=$(grep -E '^# Session:' "$file" | head -1 | sed 's/^# Session:[[:space:]]*//')

    HARNESS=$(fm_field "$file" "harness")
    [[ -n "$HARNESS" ]] || HARNESS="claude-code"
    case "$HARNESS" in
        pi) SOURCE_TYPE="pi_session";      RAW_SESSIONS_DIR="${VAULT_DIR}/raw/pi-sessions" ;;
        claude-code) SOURCE_TYPE="claude_code_session"; RAW_SESSIONS_DIR="${VAULT_DIR}/raw/claude-sessions" ;;
        *)  # A harness we have never seen. Label it honestly and quarantine its
            SOURCE_TYPE="${HARNESS//-/_}_session"
            RAW_SESSIONS_DIR="${VAULT_DIR}/raw/${HARNESS}-sessions" ;;
    esac
}


generate_source_id() {
    local slug

    if echo "$SESSION_TITLE" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-'; then
        slug="session-$(echo "$SESSION_TITLE" | cut -c1-8)"
    else
        slug="session-$(slugify "$SESSION_TITLE")"
    fi

    SOURCE_ID="source-${SESSION_DATE}-${slug}"
}


process_session() {
    local session_file="$1"

    if [[ ! "$session_file" = /* ]]; then
        session_file="$(cd "$(dirname "$session_file")" && pwd)/$(basename "$session_file")"
    fi

    if [[ ! -f "$session_file" ]]; then
        echo "Error: File not found: ${session_file}"
        return 1
    fi

    echo "--- Processing: $(basename "$session_file") ---"

    local _proj0
    _proj0=$(awk -F': ' '/^project:/{print $2; exit}' "$session_file" 2>/dev/null | tr -d '\r ')
    if grep -q '^synthetic: true' "$session_file" 2>/dev/null \
       || [[ "$_proj0" =~ $AUTOMATION_PROJECT_RE ]]; then
        echo "  SKIP: harness/experiment session (${_proj0})"
        if ! $DRY_RUN && fm_set_status "$session_file" "captured" "skipped"; then
            echo "  Marked: status: skipped (automation namespace)"
        fi
        echo ""
        return 0
    fi

    local gate_result
    gate_result=$(check_quality "$session_file") || true

    case "$gate_result" in
        "already promoted"|"status is "*|"file modified"*|"ambiguous frontmatter"*)
            echo "  SKIP: ${gate_result}"
            echo ""
            return 0
            ;;
    esac

    local _tx _entry
    _tx=$(resolve_transcript "$session_file") || true
    _entry=$(session_entrypoint "$_tx")
    if [[ -n "$_entry" ]] && [[ " ${HEADLESS_ENTRYPOINTS} " == *" ${_entry} "* ]]; then
        echo "  SKIP: headless ${_entry} call, not a session"
        if ! $DRY_RUN && fm_set_status "$session_file" "captured" "skipped"; then
            echo "  Marked: status: skipped (headless ${_entry})"
        fi
        echo ""
        return 0
    fi

    local rescue_transcript=""
    if [[ "$gate_result" != "passed" && -n "$_tx" ]]; then
        case "$gate_result" in
            "insufficient content"*|"too many actionable"*|"only "*)
                if [[ "$(session_turn_count "$_tx")" == "0" ]]; then
                    echo "  SKIP: thin stub and a transcript with 0 conversational turns"
                    if ! $DRY_RUN && fm_set_status "$session_file" "captured" "skipped"; then
                        echo "  Marked: status: skipped (null session — no turns anywhere)"
                    fi
                    echo ""
                    return 0
                fi
                rescue_transcript="$_tx"
                echo "  RESCUE: thin stub, ${_entry:-unknown} session — summarizing from raw transcript"
                ;;
        esac
    fi

    if [[ "$gate_result" != "passed" && -z "$rescue_transcript" ]]; then
        echo "  SKIP: ${gate_result}"
        if ! $DRY_RUN \
           && [[ "$gate_result" != file\ modified* ]] \
           && fm_set_status "$session_file" "captured" "skipped"; then
            echo "  Marked: status: skipped (terminal — leaves ingest queue)"
        fi
        echo ""
        return 0
    fi

    echo "  Gate: passed (${_entry:-unknown-entrypoint}${rescue_transcript:+, rescued from transcript})"

    extract_session_meta "$session_file"
    generate_source_id

    SUMMARY_FILE="${VAULT_DIR}/wiki/summaries/${SOURCE_ID}.md"
    RAW_SOURCE_PATH="${RAW_SESSIONS_DIR#${VAULT_DIR}/}/$(basename "$session_file")"

    if [[ -f "$SUMMARY_FILE" ]] && ! needs_repromote "$session_file"; then
        echo "  SKIP: summary already exists at ${SUMMARY_FILE}"
        echo ""
        return 0
    fi
    if [[ -f "$SUMMARY_FILE" ]]; then
        echo "  REGENERATING: ${SUMMARY_FILE} (stub changed since promotion)"
    fi

    echo "  Session ID:  ${SESSION_ID}"
    echo "  Title:       ${SESSION_TITLE}"
    echo "  Project:     ${PROJECT}"
    echo "  Source ID:   ${SOURCE_ID}"
    echo "  Output:      ${SUMMARY_FILE}"


    CONCEPT_PAGES=$(gather_wiki_pages "${VAULT_DIR}/wiki/knowledge/concepts")
    ENTITY_PAGES=$(gather_wiki_pages "${VAULT_DIR}/wiki/knowledge/entities")
    SOURCE_PAGES=$(gather_wiki_pages "${VAULT_DIR}/wiki/summaries")
    DECISION_PAGES=$(gather_wiki_pages "${VAULT_DIR}/wiki/knowledge/decisions")
    PROJECT_PAGES=$(gather_wiki_pages "${VAULT_DIR}/wiki/knowledge/projects")

    QUALITY_GUIDELINES=""
    if [[ -f "$GUIDELINES_FILE" ]]; then
        QUALITY_GUIDELINES=$(awk 'BEGIN{skip=0} /^---$/{skip++; next} skip>=2{print}' "$GUIDELINES_FILE")
    fi

    local template
    template=$(cat "$TEMPLATE_FILE")

    template="${template//\{\{SESSION_FILE_PATH\}\}/${session_file}}"
    template="${template//\{\{SESSION_ID\}\}/${SESSION_ID}}"
    template="${template//\{\{PROJECT\}\}/${PROJECT}}"
    template="${template//\{\{SESSION_DATE\}\}/${SESSION_DATE}}"
    template="${template//\{\{SOURCE_ID\}\}/${SOURCE_ID}}"
    template="${template//\{\{TIMESTAMP\}\}/${TIMESTAMP}}"
    template="${template//\{\{RAW_SOURCE_PATH\}\}/${RAW_SOURCE_PATH}}"
    template="${template//\{\{SOURCE_TYPE\}\}/${SOURCE_TYPE}}"
    template="${template//\{\{HARNESS\}\}/${HARNESS}}"
    template="${template//\{\{CONCEPT_PAGES\}\}/${CONCEPT_PAGES}}"
    template="${template//\{\{ENTITY_PAGES\}\}/${ENTITY_PAGES}}"
    template="${template//\{\{SOURCE_PAGES\}\}/${SOURCE_PAGES}}"
    template="${template//\{\{DECISION_PAGES\}\}/${DECISION_PAGES}}"
    template="${template//\{\{PROJECT_PAGES\}\}/${PROJECT_PAGES}}"
    template="${template//\{\{QUALITY_GUIDELINES\}\}/${QUALITY_GUIDELINES}}"

    if [[ -n "${rescue_transcript:-}" ]]; then
        template="${template}

The session stub is sparse. That is all that is known — whether the session itself was substantial is for you to determine, not something this instruction asserts. Do NOT rely on the stub. Read the full raw transcript here:

    ${rescue_transcript}

It is newline-delimited JSON (one message per line: user/assistant turns and tool calls). Use Read (and Grep for long files) to extract what actually happened — the task, key findings, decisions, and outcomes — and base your summary primarily on it. Assess confidence from the transcript's real content.

SIZE WARNING (this transcript is $(wc -c < "$rescue_transcript" | tr -d ' ') bytes): a single full-file Read fails above ~25k tokens (~100KB). If the file is larger than that, NEVER Read it whole — page through it with Read offset/limit (e.g. limit=400 per call), or Grep for user prompts (\"type\":\"user\") first to map the turns, then Read the relevant ranges. A failed whole-file Read wastes the entire call.

If the transcript shows that little or nothing happened (a cancelled command, an immediate exit, an error at turn zero), say so plainly and briefly. \"This session did no substantive work\" is a correct and useful summary; padding it into something that sounds substantial is not."
    fi

    if $DRY_RUN; then
        echo ""
        echo "  === DRY RUN ==="
        echo "  Quality gate: PASSED"
        echo "  Gate: passed (${_entry:-unknown-entrypoint}${rescue_transcript:+, rescued from transcript})"
        echo "  Wiki context: $(echo "$CONCEPT_PAGES" | wc -l | tr -d ' ') concepts, $(echo "$ENTITY_PAGES" | wc -l | tr -d ' ') entities, $(echo "$SOURCE_PAGES" | wc -l | tr -d ' ') sources"
        echo "  Would copy session to: ${RAW_SESSIONS_DIR}/$(basename "$session_file")"
        echo "  Would call Claude to generate: ${SUMMARY_FILE}"
        if [[ -f "$SOURCES_INDEX" ]]; then
            echo "  Would update index: ${SOURCES_INDEX}"
        else
            echo "  Would NOT update index: ${SOURCES_INDEX#${VAULT_DIR}/} does not exist (index availability)"
        fi
        echo "  Would mark session as: status: promoted"
        echo ""
        return 0
    fi

    mkdir -p "$RAW_SESSIONS_DIR"
    cp "$session_file" "${RAW_SESSIONS_DIR}/$(basename "$session_file")"
    echo "  Raw copy: ${RAW_SESSIONS_DIR}/$(basename "$session_file")"

    echo "  Calling summarizer (${HARNESS} harness, model ${MODEL:-<inherit>})..."

    local temp_file
    temp_file=$(mktemp)
    local stderr_file="${temp_file}.stderr"

    local attempt=0
    local max_attempts=2
    local claude_ok=false
    local claude_rc=0
    local claude_fail_class="none"

    while [[ $attempt -lt $max_attempts ]]; do
        attempt=$((attempt + 1))
        claude_rc=0
        echo "$template" | BRAIN_INGEST=1 run_llm > "$temp_file" 2>"$stderr_file" || claude_rc=$?
        if [[ $claude_rc -eq 0 ]]; then
            claude_ok=true
            break
        fi

        local fail_stdout fail_stderr fail_output
        fail_stdout=$(cat "$temp_file" 2>/dev/null || true)
        fail_stderr=$(grep -vE '^warn: ignoring extra certs' "$stderr_file" 2>/dev/null || true)
        if [[ -n "${fail_stdout// }" ]]; then
            fail_output="$fail_stdout"
        else
            fail_output="$fail_stderr"
        fi

        if echo "$fail_output" | grep -qiE 'certificate|self.signed|unable to verify|CERT_|SSL routines|PEM routines'; then
            claude_fail_class="tls-ca"
        elif echo "$fail_output" | grep -qiE '429|503|rate.limit|overloaded|timeout|UNAVAILABLE|ENOTFOUND|ECONNRESET|socket hang up|FailedToOpenSocket|Unable to connect'; then
            claude_fail_class="transient"
        elif echo "$fail_output" | grep -qiE 'spend limit|usage limit|usage-credits|out of credits?'; then
            claude_fail_class="spend-limit"
        elif echo "$fail_output" | grep -qiE '401|403|PERMISSION_DENIED|UNAUTHENTICATED|credential'; then
            claude_fail_class="auth"
        elif [[ -z "${fail_output// }" ]]; then
            claude_fail_class="silent"
        else
            claude_fail_class="unclassified"
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            if [[ "$claude_fail_class" == "transient" || "$claude_fail_class" == "silent" ]]; then
                echo "  Attempt ${attempt} failed (${claude_fail_class}, retryable), waiting 30s..."
                sleep 30
            else
                echo "  Attempt ${attempt} failed (${claude_fail_class}, non-retryable, exit=${claude_rc})"
                break
            fi
        fi
    done

    if ! $claude_ok; then
        if [[ -s "$temp_file" ]] && grep -q '^---$' "$temp_file" && grep -q '## Summary' "$temp_file"; then
            echo "  Salvaged: exit=${claude_rc} (${claude_fail_class}) but output is complete — keeping it"
            echo "[${TIMESTAMP}] SALVAGE session=${SESSION_ID} exit=${claude_rc} class=${claude_fail_class}: output passed validation, kept" >> "$LOG_FILE"
            claude_ok=true
        fi
    fi

    if ! $claude_ok; then
        echo "  Error: claude -p failed after ${attempt} attempts (exit=${claude_rc}, class=${claude_fail_class})"
        local claude_route
        if [[ -n "${PI_CODING_AGENT:-}" ]] || [[ "${HARNESS:-claude-code}" == pi ]]; then
            claude_route="pi:${PI_MODEL:-<inherit>}"
        else
            claude_route="claude:${MODEL:-<settings-default>}"
        fi
        echo "[${TIMESTAMP}] ERROR-DETAIL session=${SESSION_ID} exit=${claude_rc} class=${claude_fail_class} route=${claude_route} stdout_bytes=$(wc -c < "$temp_file" | tr -d ' ') stderr_bytes=$(wc -c < "$stderr_file" | tr -d ' ')" >> "$LOG_FILE"

        local stream
        for stream in stdout:"$temp_file" stderr:"$stderr_file"; do
            local label="${stream%%:*}" path="${stream#*:}"
            if [[ -s "$path" ]]; then
                echo "  ${label}:"
                head -c 500 "$path" | sed 's/^/    /'
                echo ""
                { echo "[${TIMESTAMP}] ERROR-OUTPUT stream=${label} session=${SESSION_ID}:"; head -c 500 "$path"; echo ""; } >> "$LOG_FILE"
            fi
        done

        if [[ "$claude_fail_class" == "tls-ca" ]]; then
            echo "  Hint: NODE_EXTRA_CA_CERTS is unset or wrong for this process (TLS proxy interception)."
            echo "[${TIMESTAMP}] HINT session=${SESSION_ID}: tls-ca — check NODE_EXTRA_CA_CERTS in auto-ingest.sh" >> "$LOG_FILE"
        fi

        echo "[${TIMESTAMP}] ERROR: claude -p failed for session ${SESSION_ID} after ${attempt} attempts (class=${claude_fail_class})" >> "$LOG_FILE"
        rm -f "$temp_file" "$stderr_file"
        return 1
    fi
    rm -f "$stderr_file"

    if [[ ! -s "$temp_file" ]]; then
        echo "  Error: Claude returned empty output"
        echo "[${TIMESTAMP}] ERROR: empty output for session ${SESSION_ID}" >> "$LOG_FILE"
        rm -f "$temp_file"
        return 1
    fi

    local norm_rc
    python3 "${VAULT_DIR}/.claude/scripts/lib/normalize-summary.py" < "$temp_file" > "${temp_file}.clean" 2>/dev/null
    norm_rc=$?
    if [[ $norm_rc -eq 0 ]] && [[ -s "${temp_file}.clean" ]]; then
        mv "${temp_file}.clean" "$temp_file"
    else
        echo "  Error: Output contains no YAML frontmatter"
        head -5 "$temp_file"
        echo "[${TIMESTAMP}] ERROR: no frontmatter in output for session ${SESSION_ID}" >> "$LOG_FILE"
        rm -f "$temp_file" "${temp_file}.clean"
        return 1
    fi

    if ! grep -q '## Summary' "$temp_file"; then
        echo "  Error: Output missing '## Summary' section"
        echo "[${TIMESTAMP}] ERROR: missing Summary section for session ${SESSION_ID}" >> "$LOG_FILE"
        rm -f "$temp_file"
        return 1
    fi

    mkdir -p "$(dirname "$SUMMARY_FILE")"
    cp "$temp_file" "$SUMMARY_FILE"
    rm -f "$temp_file"
    echo "  Summary written: ${SUMMARY_FILE}"

    local index_section
    case "$HARNESS" in
        pi)          index_section="pi Sessions" ;;
        claude-code) index_section="Claude Code Sessions" ;;
        *)           index_section="${HARNESS} Sessions" ;;
    esac
    local index_entry="- [[wiki/summaries/${SOURCE_ID}|${SESSION_TITLE}]] - ${index_section%s} (${PROJECT})"


    if [[ -f "$SOURCES_INDEX" ]]; then
        if ! grep -qF "### ${index_section}" "$SOURCES_INDEX"; then
            echo "" >> "$SOURCES_INDEX"
            echo "### ${index_section}" >> "$SOURCES_INDEX"
            echo "" >> "$SOURCES_INDEX"
        fi

        if grep -qF "### ${index_section}" "$SOURCES_INDEX"; then
            if grep -A1 -F "### ${index_section}" "$SOURCES_INDEX" | grep -q '_None yet_'; then
                sed -i '' "/### ${index_section}/{n;s/_None yet_/${index_entry}/;}" "$SOURCES_INDEX"
            else
                sed -i '' "/### ${index_section}/a\\
${index_entry}
" "$SOURCES_INDEX"
            fi
        fi

        local recent_entry="- ${SESSION_DATE}: [[wiki/summaries/${SOURCE_ID}|${SESSION_TITLE}]] (${SOURCE_TYPE})"
        sed -i '' "/## Recently Added/a\\
${recent_entry}
" "$SOURCES_INDEX"

        echo "  Index updated: ${SOURCES_INDEX}"
    fi

    if fm_set_status "$session_file" "captured skipped promoted" "promoted" \
                     "wiki/summaries/${SOURCE_ID}.md" "$(stub_hash "$session_file")"; then
        echo "  Session marked as promoted"
    else
        echo "  WARNING: could not mark promoted — frontmatter status is '$(fm_status "$session_file")'"
        echo "[${TIMESTAMP}] WARN session=${SESSION_ID}: summary written to ${SOURCE_ID} but stub not marked promoted" >> "$LOG_FILE"
    fi

    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[${TIMESTAMP}] Ingested session: $(basename "$session_file") -> ${SOURCE_ID}" >> "$LOG_FILE"

    echo "  Done."
    echo ""
}


if $ALL_MODE; then
    echo "=== Session Ingestion (--all mode) ==="
    [[ "$MAX_SESSIONS" -gt 0 ]] && echo "  Max sessions: ${MAX_SESSIONS}"
    echo ""

    TOTAL=0
    INGESTED=0
    SKIPPED=0
    FAILED=0

    for f in "${SESSIONS_DIR}"/*.md; do
        [[ -f "$f" ]] || continue
        TOTAL=$((TOTAL + 1))

        if [[ "$MAX_SESSIONS" -gt 0 && "$INGESTED" -ge "$MAX_SESSIONS" ]]; then
            echo "--- Reached max-sessions limit (${MAX_SESSIONS}) ---"
            echo ""
            break
        fi

        local_result=$(process_session "$f" 2>&1) || true
        echo "$local_result"

        if echo "$local_result" | grep -q 'SKIP:'; then
            SKIPPED=$((SKIPPED + 1))
        elif echo "$local_result" | grep -q 'Error:'; then
            FAILED=$((FAILED + 1))
        elif echo "$local_result" | grep -q 'Done.'; then
            INGESTED=$((INGESTED + 1))
        elif echo "$local_result" | grep -q 'DRY RUN'; then
            INGESTED=$((INGESTED + 1))
        fi
    done

    echo "=== Complete ==="
    echo "  Total: ${TOTAL} | Ingested: ${INGESTED} | Skipped: ${SKIPPED} | Failed: ${FAILED}"
    echo ""
else
    for f in "${SESSION_FILES[@]}"; do
        process_session "$f"
    done
fi
