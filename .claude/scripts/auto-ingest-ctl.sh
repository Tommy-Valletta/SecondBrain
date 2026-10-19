#!/usr/bin/env bash

set -euo pipefail

LABEL="${BRAIN_LAUNCHD_LABEL:-com.secondbrain.auto-ingest}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATUS_FILE="${VAULT_DIR}/outputs/.ingest-status.json"

case "${1:-help}" in
    start)
        if launchctl list | grep -q "$LABEL"; then
            echo "Already running."
        else
            launchctl load "$PLIST"
            echo "Started auto-ingest agent (runs every 10 minutes)."
        fi
        ;;
    stop)
        if launchctl list | grep -q "$LABEL"; then
            launchctl unload "$PLIST"
            echo "Stopped auto-ingest agent."
        else
            echo "Not running."
        fi
        ;;
    status)
        echo "=== Launchd Agent ==="
        if launchctl list | grep -q "$LABEL"; then
            echo "  Status: RUNNING"
            launchctl list "$LABEL" 2>/dev/null | grep -E 'PID|LastExitStatus' | sed 's/^/  /'
        else
            echo "  Status: STOPPED"
        fi
        echo ""

        echo "=== Ingest Status ==="
        if [[ -f "$STATUS_FILE" ]]; then
            cat "$STATUS_FILE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"  Last run:     {d['last_run']}\")
print(f\"  Processed:    {d['processed']}\")
print(f\"  Skipped:      {d['skipped']}\")
print(f\"  Failed:       {d['failed']}\")
print(f\"  Pending:      {d['pending']}\")
print(f\"  Total wiki:   {d['total_summaries']}\")
print(f\"  Healthy:      {d.get('healthy', 'unknown')}\")
print(f\"  Streak fails: {d['streak_failures']}\")
if d.get('auth_skip_streak', 0):
    print(f\"  Auth skips:   {d['auth_skip_streak']} (check credentials)\")
if d.get('last_error'):
    print(f\"  Last error:   {d['last_error']}\")
if d.get('dry_run'):
    print(f\"  (dry run)\")
" 2>/dev/null || cat "$STATUS_FILE"
        else
            echo "  No status file yet (auto-ingest hasn't run)"
        fi
        echo ""

        echo "=== Session Counts ==="
        "${VAULT_DIR}/.claude/scripts/auto-ingest.sh" --scan \
            | awk -F'\t' '
                /^PENDING=/       { print "  " $0; next }
                /^HISTOGRAM_JSON=/{ next }
                /^UNKNOWN_JSON=/  { print "  " $0; next }
                /^TOTALFILES\t/   { printf "  %-10s %s\n", "TOTAL:", $2; next }
                NF==2             { printf "  %-10s %s\n", $1 ":", $2 }
              '
        ;;
    logs)
        echo "=== Recent Auto-Ingest Log ==="
        tail -50 "${VAULT_DIR}/wiki/logs/auto-ingest.log" 2>/dev/null || echo "No logs yet."
        echo ""
        echo "=== Launchd Stdout ==="
        tail -20 "${VAULT_DIR}/wiki/logs/auto-ingest-launchd.log" 2>/dev/null || echo "No launchd output yet."
        echo ""
        echo "=== Launchd Stderr ==="
        tail -20 "${VAULT_DIR}/wiki/logs/auto-ingest-launchd-err.log" 2>/dev/null || echo "No launchd errors."
        ;;
    run)
        echo "Running auto-ingest manually..."
        "${VAULT_DIR}/.claude/scripts/auto-ingest.sh" "${@:2}"
        ;;
    help|*)
        echo "Usage: $0 <start|stop|status|logs|run>"
        echo ""
        echo "  start   Load the launchd agent (runs every 10 minutes)"
        echo "  stop    Unload the launchd agent"
        echo "  status  Show agent status, ingest status, and session counts"
        echo "  logs    Tail recent logs"
        echo "  run     Run auto-ingest manually (pass --dry-run for testing)"
        ;;
esac
