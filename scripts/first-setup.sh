#!/bin/bash
#
# first-setup.sh: Interactive setup wizard for Agentic Researcher.
#
# Generates ${XDG_CONFIG_HOME:-$HOME/.config}/agentic-researcher/config.sh
#
# Usage:
#   agentic-researcher --setup                          # Full interactive wizard
#   agentic-researcher --setup KEY=VALUE [KEY=VALUE...]  # Set individual values
#   agentic-researcher --setup auth                      # Toggle oauth / api-key
#
# Examples:
#   agentic-researcher --setup AR_CLI_TOOL=gemini
#   agentic-researcher --setup AR_NO_COOLDOWN=pi,opencode
#   agentic-researcher --setup auth                      # Switch between subscription and custom endpoint
#

set -e

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agentic-researcher"
CONFIG_FILE="$CONFIG_DIR/config.sh"

# ── Quick auth toggle mode ────────────────────────────────────────
if [[ $# -eq 1 && "$1" == "auth" ]]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: No config file found. Run 'agentic-researcher --setup' first."
        exit 1
    fi
    source "$CONFIG_FILE"
    echo "─── Authentication Mode ───"
    echo "  Current: $AR_AUTH_MODE"
    if [[ -n "${AR_CUSTOM_ANTHROPIC_ENDPOINT:-}" ]]; then
        echo "  Endpoint: $AR_CUSTOM_ANTHROPIC_ENDPOINT (used in api-key mode only)"
    fi
    echo ""
    echo "  1) oauth    — Claude subscription (interactive login)"
    echo "  2) api-key  — Custom API key + endpoint"
    echo ""
    read -rp "Select [current]: " auth_choice
    case "$auth_choice" in
        1) new_mode="oauth" ;;
        2) new_mode="api-key" ;;
        *) echo "No change."; exit 0 ;;
    esac
    if [[ "$new_mode" == "$AR_AUTH_MODE" ]]; then
        echo "Already set to $new_mode. No change."
        exit 0
    fi
    # If switching to api-key, prompt for endpoint + key env var if not already set
    if [[ "$new_mode" == "api-key" ]]; then
        if [[ -z "${AR_CUSTOM_ANTHROPIC_ENDPOINT:-}" ]]; then
            read -rp "Anthropic-compatible endpoint URL: " new_endpoint
            if [[ -n "$new_endpoint" ]]; then
                sed -i "s|^AR_CUSTOM_ANTHROPIC_ENDPOINT=.*|AR_CUSTOM_ANTHROPIC_ENDPOINT=\"${new_endpoint}\"|" "$CONFIG_FILE"
                echo "  Updated: AR_CUSTOM_ANTHROPIC_ENDPOINT=\"$new_endpoint\""
            fi
        fi
        cur_key_env="${AR_API_KEY_ENV:-ANTHROPIC_API_KEY}"
        read -rp "API key env var [$cur_key_env]: " new_key_env
        new_key_env="${new_key_env:-$cur_key_env}"
        if [[ "$new_key_env" != "$cur_key_env" ]]; then
            sed -i "s|^AR_API_KEY_ENV=.*|AR_API_KEY_ENV=\"${new_key_env}\"|" "$CONFIG_FILE"
            echo "  Updated: AR_API_KEY_ENV=\"$new_key_env\""
        fi
    fi
    sed -i "s|^AR_AUTH_MODE=.*|AR_AUTH_MODE=\"${new_mode}\"|" "$CONFIG_FILE"
    echo ""
    echo "Switched to: $new_mode"
    if [[ "$new_mode" == "oauth" ]]; then
        echo "  Claude will prompt for interactive login on next launch."
    else
        echo "  Endpoint: $(grep '^AR_CUSTOM_ANTHROPIC_ENDPOINT=' "$CONFIG_FILE" | cut -d'"' -f2)"
        echo "  Make sure \$${new_key_env:-$cur_key_env} is set before launching."
    fi
    exit 0
fi

# ── Individual key=value mode ──────────────────────────────────────
if [[ $# -gt 0 && "$1" == *=* ]]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: No config file found. Run 'agentic-researcher --setup' first (without arguments)."
        exit 1
    fi
    for arg in "$@"; do
        key="${arg%%=*}"
        val="${arg#*=}"
        if grep -q "^${key}=" "$CONFIG_FILE"; then
            sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$CONFIG_FILE"
            echo "Updated: $key=\"$val\""
        else
            echo "${key}=\"${val}\"" >> "$CONFIG_FILE"
            echo "Added: $key=\"$val\""
        fi
    done
    exit 0
fi

# ── Full interactive wizard ────────────────────────────────────────

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          Agentic Researcher - Setup Wizard                    ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

if [[ -f "$CONFIG_FILE" ]]; then
    echo "Existing configuration found: $CONFIG_FILE"
    echo ""
    echo "Tip: To change individual settings without re-running the full wizard:"
    echo "  agentic-researcher --setup KEY=VALUE"
    echo "  e.g., agentic-researcher --setup AR_CLI_TOOL=gemini"
    echo ""
    read -rp "Re-run full wizard? [y/N] " overwrite
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
        echo "Setup cancelled."
        exit 0
    fi
    echo ""
fi

# ── 1. Container Runtime ──────────────────────────────────────────────
echo "─── Container Runtime ───"
echo "  1) docker     (local workstations / cloud)"
echo "  2) podman     (rootless containers)"
echo ""
echo "  (Apptainer support is planned - see TODO.md)"
echo ""
read -rp "Select [1]: " runtime_choice
case "${runtime_choice:-1}" in
    1) AR_CONTAINER_RUNTIME=docker ;;
    2) AR_CONTAINER_RUNTIME=podman ;;
    *) echo "Invalid choice, defaulting to docker"; AR_CONTAINER_RUNTIME=docker ;;
esac
echo "  → $AR_CONTAINER_RUNTIME"
echo ""

# ── 2. CLI Tool ──────────────────────────────────────────────────────
echo "─── CLI Tool ───"
echo "  1) claude    (Claude Code — default)"
echo "  2) opencode  (OpenCode — open-source, any LLM)"
echo "  3) gemini    (Gemini CLI — Google)"
echo "  4) codex     (Codex CLI — OpenAI)"
echo "  5) qwen      (Qwen Code — Alibaba)"
echo "  6) pi        (pi — any provider)"
echo ""
read -rp "Select [1]: " tool_choice
case "${tool_choice:-1}" in
    1)
        AR_CLI_TOOL=claude
        AR_DEFAULT_MODEL_DEFAULT=sonnet
        AR_AUTH_MODE=oauth
        AR_API_PROVIDER=anthropic
        AR_API_KEY_ENV=ANTHROPIC_API_KEY
        ;;
    2)
        AR_CLI_TOOL=opencode
        AR_DEFAULT_MODEL_DEFAULT=""
        AR_AUTH_MODE=tool
        AR_API_PROVIDER=""
        AR_API_KEY_ENV="OPENAI_API_KEY"
        ;;
    3)
        AR_CLI_TOOL=gemini
        AR_DEFAULT_MODEL_DEFAULT=""
        AR_AUTH_MODE=tool
        AR_API_PROVIDER=""
        AR_API_KEY_ENV="GEMINI_API_KEY"
        ;;
    4)
        AR_CLI_TOOL=codex
        AR_DEFAULT_MODEL_DEFAULT=""
        AR_AUTH_MODE=tool
        AR_API_PROVIDER=""
        AR_API_KEY_ENV="OPENAI_API_KEY"
        ;;
    5)
        AR_CLI_TOOL=qwen
        AR_DEFAULT_MODEL_DEFAULT=""
        AR_AUTH_MODE=tool
        AR_API_PROVIDER=""
        AR_API_KEY_ENV="OPENAI_API_KEY"
        ;;
    6)
        AR_CLI_TOOL=pi
        AR_DEFAULT_MODEL_DEFAULT=""
        AR_AUTH_MODE=tool
        AR_API_PROVIDER=""
        AR_API_KEY_ENV="ANTHROPIC_API_KEY"
        ;;
    *)
        echo "Invalid choice, defaulting to claude"
        AR_CLI_TOOL=claude
        AR_DEFAULT_MODEL_DEFAULT=sonnet
        AR_AUTH_MODE=oauth
        AR_API_PROVIDER=anthropic
        AR_API_KEY_ENV=ANTHROPIC_API_KEY
        ;;
esac
echo "  → $AR_CLI_TOOL"
echo ""

# Default model
if [[ -n "$AR_DEFAULT_MODEL_DEFAULT" ]]; then
    read -rp "Default model [$AR_DEFAULT_MODEL_DEFAULT]: " AR_DEFAULT_MODEL
    AR_DEFAULT_MODEL="${AR_DEFAULT_MODEL:-$AR_DEFAULT_MODEL_DEFAULT}"
else
    read -rp "Default model (leave empty for tool default): " AR_DEFAULT_MODEL
fi
if [[ -n "$AR_DEFAULT_MODEL" ]]; then
    echo "  → $AR_DEFAULT_MODEL"
fi
echo ""

# ── 3. Network Proxy ────────────────────────────────────────────────
echo "─── Network Proxy (leave empty if not needed) ───"
read -rp "HTTPS proxy (e.g., http://proxy:3128): " AR_HTTPS_PROXY
AR_HTTP_PROXY="$AR_HTTPS_PROXY"  # Default: same as HTTPS
if [[ -n "$AR_HTTPS_PROXY" ]]; then
    read -rp "HTTP proxy [$AR_HTTPS_PROXY]: " AR_HTTP_PROXY
    AR_HTTP_PROXY="${AR_HTTP_PROXY:-$AR_HTTPS_PROXY}"
fi
echo ""

# ── 4. Persistent store ─────────────────────────────────────────────
echo "─── Persistent Store ───"
echo "  All CLI tools, runtimes, caches, and the agent home are installed"
echo "  into this directory on first run (no image build) and reused after."
STATE_ROOT_DEFAULT="$HOME/.cache/agentic-researcher"
read -rp "Store directory [$STATE_ROOT_DEFAULT]: " AR_STATE_ROOT
AR_STATE_ROOT="${AR_STATE_ROOT:-$STATE_ROOT_DEFAULT}"
echo "  → $AR_STATE_ROOT"
echo ""

# ── Write config (all values quoted for safety) ────────────────────
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" << EOF
# Agentic Researcher configuration
# Generated by: agentic-researcher --setup ($(date +%Y-%m-%d))

# Container runtime: docker | podman
AR_CONTAINER_RUNTIME="$AR_CONTAINER_RUNTIME"

# Authentication: oauth | tool | api-key
AR_AUTH_MODE="$AR_AUTH_MODE"

# Optional provider metadata
AR_API_PROVIDER="$AR_API_PROVIDER"

# Env var name for launcher-managed API key validation / custom endpoints
AR_API_KEY_ENV="$AR_API_KEY_ENV"

# Custom endpoints
AR_CUSTOM_ENDPOINT=""
AR_CUSTOM_ANTHROPIC_ENDPOINT=""

# CLI tool: claude | opencode | gemini | codex | qwen | pi | bash
AR_CLI_TOOL="$AR_CLI_TOOL"

# Default model
AR_DEFAULT_MODEL="$AR_DEFAULT_MODEL"

# Network proxy
AR_HTTPS_PROXY="$AR_HTTPS_PROXY"
AR_HTTP_PROXY="$AR_HTTP_PROXY"

# Persistent store (tools, caches, agent home; mounted at /ar-store)
AR_STATE_ROOT="$AR_STATE_ROOT"

# Tool updates: auto | never (version cache TTL in seconds, default 21600)
AR_UPDATE="auto"
AR_UPDATE_TTL=""

# Comma-separated tool labels exempt from the 7-day release cooldown
# (labels: npm, gemini, opencode, codex, qwen, pi)
AR_NO_COOLDOWN=""

# Extra environment variables (pipe-separated KEY=VALUE pairs)
AR_EXTRA_ENV=""
EOF

echo "════════════════════════════════════════════════════════════════"
echo "Configuration saved to: $CONFIG_FILE"
echo ""
echo "Tip: Change individual settings later with:"
echo "  agentic-researcher --setup KEY=VALUE"
echo ""
echo "Next steps:"
echo "  1. (Optional) Prewarm the tool store: agentic-researcher --build"
if [[ "$AR_CLI_TOOL" == "claude" ]]; then
    echo "  2. Launch: agentic-researcher  (will prompt for OAuth login)"
else
    echo "  2. Launch: agentic-researcher"
    echo "  3. If needed, export the tool's standard API key env var before launch"
fi
echo "════════════════════════════════════════════════════════════════"
