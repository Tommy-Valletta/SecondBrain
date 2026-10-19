#!/usr/bin/env bash
set -uo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)" || exit 0
INPUT=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null) || exit 0
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[[ -n "$FILE_PATH" ]] || exit 0

case "$FILE_PATH" in
    "${VAULT_DIR}"/wiki/*.md) ;;
    *) exit 0 ;;
esac

SESSION_ID="${SESSION_ID//[^A-Za-z0-9._-]/_}"

mkdir -p "${VAULT_DIR}/outputs/.touched" 2>/dev/null || exit 0
printf '%s\n' "$FILE_PATH" >> "${VAULT_DIR}/outputs/.touched/${SESSION_ID}.txt" 2>/dev/null
exit 0
