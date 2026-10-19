#!/usr/bin/env bash
# bootstrap.sh — Setup and configuration script for SecondBrain
# Idempotent and safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_PATH="$SCRIPT_DIR"
OWNER_NAME="${USER:-Builder}"
HARNESSES="claude,pi"
INGEST_MODEL=""
CLAUDE_MODEL=""
SCHEDULER="none"
LABEL_PREFIX="com.secondbrain"
NON_INTERACTIVE=false
FORCE=false
VERIFY=false

usage() {
    cat <<'EOF'
Usage: ./bootstrap.sh [options]

Options:
  --vault PATH           Path to the vault directory (default: current directory)
  --owner NAME           Owner name for templates (default: current user)
  --harnesses LIST       Comma-separated list of harnesses (claude, pi) (default: claude,pi)
  --ingest-model ID      Pi model override (default: configured agent default)
  --claude-model ID      Model ID for claude interactive/batch runs
  --scheduler TYPE       Scheduler to configure: launchd, cron, or none (default: none)
  --label-prefix PREFIX  Label prefix for launchd plist (default: com.secondbrain)
  --non-interactive      Run without interactive prompts
  --force                Overwrite existing rendered files and contract symlinks
  --verify               Run automated acceptance checks after setup
  -h, --help             Show this help message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vault) VAULT_PATH="$2"; shift 2 ;;
        --owner) OWNER_NAME="$2"; shift 2 ;;
        --harnesses) HARNESSES="$2"; shift 2 ;;
        --ingest-model) INGEST_MODEL="$2"; shift 2 ;;
        --claude-model) CLAUDE_MODEL="$2"; shift 2 ;;
        --scheduler) SCHEDULER="$2"; shift 2 ;;
        --label-prefix) LABEL_PREFIX="$2"; shift 2 ;;
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        --force) FORCE=true; shift ;;
        --verify) VERIFY=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

echo "=== SecondBrain Bootstrap ==="
echo "Vault path:  $VAULT_PATH"
echo "Owner name:  $OWNER_NAME"
echo "Harnesses:   $HARNESSES"
echo ""

# 1. Preflight
echo "1. Checking prerequisites..."
command -v python3 >/dev/null || { echo "ERROR: python3 not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq not found" >&2; exit 1; }
command -v git >/dev/null || { echo "ERROR: git not found" >&2; exit 1; }

python_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
echo "  python3 version: $python_ver"

if [[ "$HARNESSES" == *"claude"* ]] && ! command -v claude >/dev/null 2>&1; then
    echo "  WARN: 'claude' CLI not found in PATH"
fi
if [[ "$HARNESSES" == *"pi"* ]] && ! command -v pi >/dev/null 2>&1; then
    echo "  WARN: 'pi' CLI not found in PATH"
fi
echo "  Prerequisites OK."
echo ""

# 2. Render templates
echo "2. Rendering configuration templates..."
mkdir -p "$VAULT_PATH"

render_file() {
    local src="$1"
    local dest="$2"
    if [[ -f "$dest" && "$FORCE" != true ]]; then
        echo "  Notice: $dest already exists (use --force to overwrite)"
        return 0
    fi
    sed -e "s|{{OWNER_NAME}}|$OWNER_NAME|g" \
        -e "s|{{VAULT_PATHS}}|- \`$VAULT_PATH/\` — Main personal knowledge base|g" \
        "$src" > "$dest"
    echo "  Rendered $dest"
}

render_file "$VAULT_PATH/CLAUDE.md.template" "$VAULT_PATH/CLAUDE.md"
render_file "$VAULT_PATH/AGENTS.md.template" "$VAULT_PATH/AGENTS.md"

# 3. Write brain.env
echo "3. Writing brain.env..."
cat <<EOF > "$VAULT_PATH/brain.env"
export INGEST_MODEL="$INGEST_MODEL"
export INGEST_FALLBACK_MODEL=""
export MODEL="$CLAUDE_MODEL"
export BRAIN_UNSET_ENV=""
export BRAIN_LOCK_DIR="/tmp/brain-auto-ingest.lock"
export BRAIN_CA_BUNDLE=""
export BRAIN_LAUNCHD_LABEL="${LABEL_PREFIX}.auto-ingest"
export BRAIN_SYNTHETIC_CWD_RE=""
export BRAIN_EXTRA_RECALL_DIR=""
export MAX_SESSIONS="5"
EOF
echo "  Wrote $VAULT_PATH/brain.env"
echo ""

# 4. Global contract symlink
echo "4. Checking global agent instruction symlinks..."
setup_symlink() {
    local target="$1"
    local link_path="$2"
    mkdir -p "$(dirname "$link_path")"
    if [[ -L "$link_path" ]]; then
        local cur_target
        cur_target=$(readlink "$link_path")
        if [[ "$cur_target" == "$target" ]]; then
            echo "  $link_path already points to $target"
            return 0
        fi
    fi
    if [[ -e "$link_path" && "$FORCE" != true ]]; then
        echo "  Notice: $link_path exists and is not pointing to $target. (Pass --force to back up and replace with symlink)"
        return 0
    fi
    if [[ -e "$link_path" ]]; then
        local ts
        ts=$(date +%Y%m%d%H%M%S)
        mv "$link_path" "${link_path}.bak-${ts}"
        echo "  Backed up existing $link_path to ${link_path}.bak-${ts}"
    fi
    ln -sf "$target" "$link_path"
    echo "  Symlinked $link_path -> $target"
}

if [[ "$HARNESSES" == *"claude"* ]]; then
    setup_symlink "$VAULT_PATH/AGENTS.md" "$HOME/.claude/CLAUDE.md"
fi
if [[ "$HARNESSES" == *"pi"* ]]; then
    setup_symlink "$VAULT_PATH/AGENTS.md" "$HOME/.pi/agent/AGENTS.md"
fi
echo ""

# 5. Claude Code hooks
if [[ "$HARNESSES" == *"claude"* ]]; then
    echo "5. Configuring Claude Code hooks in ~/.claude/settings.json..."
    SETTINGS_FILE="$HOME/.claude/settings.json"
    mkdir -p "$HOME/.claude"
    if [[ ! -f "$SETTINGS_FILE" ]]; then
        echo "{}" > "$SETTINGS_FILE"
    else
        cp "$SETTINGS_FILE" "${SETTINGS_FILE}.bak-$(date +%Y%m%d%H%M%S)"
    fi

    HOOKS_JSON=$(cat <<EOF
{
  "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "$VAULT_PATH/.claude/hooks/session-start.sh"}]}],
  "SessionEnd": [{"matcher": "", "hooks": [{"type": "command", "command": "$VAULT_PATH/.claude/hooks/session-end.sh"}]}],
  "PostCompact": [{"matcher": "", "hooks": [{"type": "command", "command": "$VAULT_PATH/.claude/hooks/post-compact.sh"}]}],
  "PreToolUse": [{"matcher": "Write|Edit|MultiEdit", "hooks": [{"type": "command", "command": "$VAULT_PATH/.claude/hooks/pre-tool-guard-verified.sh"}]}],
  "PostToolUse": [{"matcher": "Write|Edit|MultiEdit|NotebookEdit", "hooks": [{"type": "command", "command": "$VAULT_PATH/.claude/hooks/post-tool-record.sh"}]}],
  "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "$VAULT_PATH/.claude/hooks/stop-stamp.sh"}]}],
  "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "$VAULT_PATH/.claude/hooks/user-prompt-workbench-match.sh"}]}]
}
EOF
)
    tmp_out=$(mktemp)
    jq --argjson new_hooks "$HOOKS_JSON" '.hooks = ((.hooks // {}) * $new_hooks)' "$SETTINGS_FILE" > "$tmp_out"
    mv "$tmp_out" "$SETTINGS_FILE"
    echo "  Updated $SETTINGS_FILE with 7 hook registrations."
    echo ""
fi

# 6. Schedulers
echo "6. Scheduler setup..."
PLIST_LABEL="${LABEL_PREFIX}.auto-ingest"
if [[ "$SCHEDULER" == "launchd" ]]; then
    PLIST_FILE="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    sed -e "s|{{LABEL}}|$PLIST_LABEL|g" \
        -e "s|{{VAULT_PATH}}|$VAULT_PATH|g" \
        "$VAULT_PATH/schedulers/launchd.plist.template" > "$PLIST_FILE"
    echo "  Rendered launchd plist to $PLIST_FILE"
    echo "  To load: launchctl load $PLIST_FILE"
elif [[ "$SCHEDULER" == "cron" ]]; then
    echo "  Crontab entry (run 'crontab -e' and add):"
    sed -e "s|{{VAULT_PATH}}|$VAULT_PATH|g" "$VAULT_PATH/schedulers/crontab.template" | sed 's/^/    /'
else
    echo "  Scheduler set to none. To run auto-ingest periodically, see schedulers/ directory."
fi
echo ""

# 7. MCP instructions
echo "7. MCP Server registration:"
echo "  To query this vault from Claude Code or Cursor, register the FastMCP server:"
echo "  claude mcp add secondbrain python3 $VAULT_PATH/.claude/mcp-server/vault_server.py -e VAULT_PATH=$VAULT_PATH"
echo ""

# 8. Verification (if requested)
if [[ "$VERIFY" == true ]]; then
    echo "8. Running verification checks..."
    bash "$VAULT_PATH/.claude/scripts/auto-ingest.sh" --selfcheck || exit 1
    python3 "$VAULT_PATH/.claude/scripts/compile-wiki.py" backlinks indexes || exit 1
    echo "  Selfcheck and compilation PASS."
fi

echo "=== Bootstrap Complete ==="
