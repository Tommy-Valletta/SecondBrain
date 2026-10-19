#!/usr/bin/env bash
set -euo pipefail

SUMMARY_FILE="${1:?usage: check-source-summary.sh <summary.md>}"

if [[ ! -f "$SUMMARY_FILE" ]]; then
    echo "GATE FAIL: summary file does not exist: $SUMMARY_FILE"
    exit 1
fi

if ! head -1 "$SUMMARY_FILE" | grep -q '^---$'; then
    echo "GATE FAIL: no YAML frontmatter"
    exit 1
fi

for field in id type status created_at raw_source; do
    if ! sed -n '2,/^---$/p' "$SUMMARY_FILE" | grep -qE "^${field}:"; then
        echo "GATE FAIL: missing frontmatter field: ${field}"
        exit 1
    fi
done

for section in "## Summary" "## Key Concepts" "## Provenance"; do
    if ! grep -q "^${section}" "$SUMMARY_FILE"; then
        echo "GATE FAIL: missing section: ${section}"
        exit 1
    fi
done

if ! grep -qE '✅|⚠️' "$SUMMARY_FILE"; then
    echo "GATE FAIL: no measured/estimated claim marks (claim verification)"
    exit 1
fi

SIZE=$(wc -c < "$SUMMARY_FILE" | tr -d ' ')
if [[ "$SIZE" -lt 1000 ]]; then
    echo "GATE FAIL: summary too small (${SIZE} bytes < 1000)"
    exit 1
fi

echo "GATE PASS: ${SUMMARY_FILE} (${SIZE} bytes)"
