#!/usr/bin/env bash
set -uo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)" || exit 0
[[ "${BRAIN_VERIFY_TOOL:-0}" == "1" ]] && exit 0

INPUT=$(cat)
command -v python3 >/dev/null 2>&1 || exit 0

VAULT="$VAULT_DIR" HOOK_INPUT="$INPUT" python3 - <<'PY' 2>/dev/null || exit 0
import json, os, re, sys

try:
    ev = json.loads(os.environ.get("HOOK_INPUT") or "")
except Exception:
    sys.exit(0)                                    # unparseable payload -> allow

vault = os.environ["VAULT"]
ti = ev.get("tool_input") or {}
path = ti.get("file_path") or ""
if not (path.startswith(os.path.join(vault, "wiki") + os.sep) and path.endswith(".md")):
    sys.exit(0)

chunks = [ti.get("new_string"), ti.get("content")]
chunks += [e.get("new_string") for e in (ti.get("edits") or []) if isinstance(e, dict)]
payload = "\n".join(c for c in chunks if isinstance(c, str))

if not re.search(r'^last_verified:[ \t]*(?!null\b|~\s*$)\S', payload, re.M):
    sys.exit(0)

def fence_span(text):
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---", 4)
    return (0, end) if end != -1 else None

touching_fence = False
if ti.get("content") is not None:                  # Write: whole-file replace
    span = fence_span(ti["content"])
    touching_fence = bool(span and re.search(
        r'^last_verified:[ \t]*(?!null\b)\S', ti["content"][:span[1]], re.M))
else:
    try:
        cur = open(path, encoding="utf-8").read()
    except OSError:
        sys.exit(0)                                # can't read it -> allow
    span = fence_span(cur)
    if span:
        head = cur[:span[1]]
        olds = [ti.get("old_string")] + [
            e.get("old_string") for e in (ti.get("edits") or []) if isinstance(e, dict)]
        touching_fence = any(isinstance(o, str) and o and o in head for o in olds)

if not touching_fence:
    sys.exit(0)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": (
            "last_verified is derived, not typed (verification freshness). "
            "Run: .claude/scripts/verify-page.sh <page> --claim \"...\" -- <command> "
            "— the stamp is written only by a check that actually ran and exited 0. "
            "Set `last_verified: null` by hand if you need to reset it."),
    },
    "systemMessage": (
        "BLOCKED: last_verified must be earned, not typed. "
        "Use .claude/scripts/verify-page.sh — it runs the check, refuses to stamp on "
        "failure, and records the command and its output next to the date."),
}))
PY
exit 0
