#!/usr/bin/env bash

set -euo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RAW_DIR="${VAULT_DIR}/raw"
INGEST_SCRIPT="${VAULT_DIR}/.claude/scripts/ingest-source.sh"
DEBOUNCE_SECONDS=3

echo "Watching ${RAW_DIR} for new files..."
echo "Press Ctrl+C to stop"
echo ""

declare -A pending_files

process_file() {
    local file="$1"

    [[ -f "$file" ]] || return 0
    [[ "$(basename "$file")" == .* ]] && return 0

    echo "Ingesting: ${file}"
    if "${INGEST_SCRIPT}" "$file"; then
        echo "Successfully ingested: $(basename "$file")"
    else
        echo "Warning: Failed to ingest: $(basename "$file")"
    fi
    echo ""
}

if command -v fswatch &> /dev/null; then
    fswatch --latency "$DEBOUNCE_SECONDS" -0 -r "${RAW_DIR}" | while read -d "" file; do
        if [[ -f "${file}" && ! "$(basename "${file}")" == .* ]]; then
            process_file "$file"
        fi
    done
else
    echo "Warning: fswatch not installed. Using polling (less efficient)."
    echo "Install fswatch: brew install fswatch"
    echo ""

    declare -A seen_files

    while IFS= read -r -d '' file; do
        seen_files["$file"]=1
    done < <(find "${RAW_DIR}" -type f ! -name ".*" -print0 2>/dev/null)

    echo "Tracking ${#seen_files[@]} existing files. Waiting for new files..."
    echo ""

    while true; do
        while IFS= read -r -d '' file; do
            if [[ ! "${seen_files[$file]:-}" ]]; then
                seen_files["$file"]=1
                sleep "$DEBOUNCE_SECONDS"
                process_file "$file"
            fi
        done < <(find "${RAW_DIR}" -type f ! -name ".*" -print0 2>/dev/null)

        sleep 5
    done
fi
