#!/usr/bin/env bash
set -euo pipefail

PIN=$(ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-}" ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-}" python3 - <<'PY'
import json, os
print(json.dumps({"env": {
    "ANTHROPIC_BASE_URL": os.environ.get("ANTHROPIC_BASE_URL", ""),
    "ANTHROPIC_AUTH_TOKEN": os.environ.get("ANTHROPIC_AUTH_TOKEN", ""),
}}))
PY
)

UNSET_ENV_ARGS=()
read -r -a unset_names <<< "${BRAIN_UNSET_ENV:-}"
for env_name in "${unset_names[@]}"; do
    if [[ ! "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Invalid environment variable name in BRAIN_UNSET_ENV" >&2
        exit 2
    fi
    UNSET_ENV_ARGS+=(-u "$env_name")
done
exec env "${UNSET_ENV_ARGS[@]}" claude --settings "$PIN" "$@"
