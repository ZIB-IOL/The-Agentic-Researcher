#!/bin/bash
#
# install.sh: Install agentic-researcher locally and create a launcher symlink.
#

set -euo pipefail

DEFAULT_INSTALL_DIR="$HOME/.local/share/agentic-researcher"
DEFAULT_BIN_DIR="$HOME/.local/bin"
DEFAULT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agentic-researcher"
DEFAULT_REPO_URL="https://github.com/ZIB-IOL/The-Agentic-Researcher.git"
DEFAULT_REPO_REF="main"
INSTALL_MARKER=".agentic-researcher-install"

INSTALL_DIR="$DEFAULT_INSTALL_DIR"
BIN_DIR="$DEFAULT_BIN_DIR"
CONFIG_DIR="$DEFAULT_CONFIG_DIR"
REPO_URL="$DEFAULT_REPO_URL"
REPO_REF="$DEFAULT_REPO_REF"
RUNTIME=""
TOOL="claude"
STATE_ROOT="$HOME/.cache/agentic-researcher"
WRITE_CONFIG=false
BUILD_IMAGE=false
FORCE=false

detect_default_oci_runtime() {
    if command -v docker >/dev/null 2>&1; then
        printf '%s\n' "docker"
    elif command -v podman >/dev/null 2>&1; then
        printf '%s\n' "podman"
    else
        printf '%s\n' "docker"
    fi
}

show_help() {
    cat <<'EOF'
Usage:
  install.sh [OPTIONS]

Options:
  --install-dir DIR   Install checkout into DIR
  --bin-dir DIR       Create launcher symlink in DIR
  --repo-url URL      Git repository to clone for bootstrap installs
  --ref NAME          Git branch or tag to clone for bootstrap installs
  --runtime NAME      Default runtime in generated config (docker|podman|apptainer)
  --tool NAME         Default tool in generated config (claude|opencode|gemini|codex)
  --state-root DIR    State/cache root in generated config
  --write-config      Write ~/.config/agentic-researcher/config.sh
  --build             Build the selected container after install
  --force             Overwrite existing install and symlink
  --help              Show this help

Examples:
  ./scripts/install.sh
  ./scripts/install.sh --write-config --build
  ./scripts/install.sh --runtime apptainer --tool codex --write-config
  ./scripts/install.sh --runtime podman --write-config --build
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --bin-dir)
            BIN_DIR="$2"
            shift 2
            ;;
        --repo-url)
            REPO_URL="$2"
            shift 2
            ;;
        --ref)
            REPO_REF="$2"
            shift 2
            ;;
        --runtime)
            RUNTIME="$2"
            shift 2
            ;;
        --tool)
            TOOL="$2"
            shift 2
            ;;
        --state-root)
            STATE_ROOT="$2"
            shift 2
            ;;
        --write-config)
            WRITE_CONFIG=true
            shift
            ;;
        --build)
            BUILD_IMAGE=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown install option: $1" >&2
            echo "" >&2
            show_help >&2
            exit 1
            ;;
    esac
done

if [[ -z "$RUNTIME" ]]; then
    RUNTIME="$(detect_default_oci_runtime)"
    if [[ "$RUNTIME" == "podman" ]] && ! command -v docker >/dev/null 2>&1; then
        echo "Docker not found, falling back to Podman."
    fi
fi

case "$RUNTIME" in
    docker|podman|apptainer) ;;
    *)
        echo "Error: Unsupported runtime: $RUNTIME" >&2
        exit 1
        ;;
esac

case "$TOOL" in
    claude|opencode|gemini|codex) ;;
    *)
        echo "Error: Unsupported tool: $TOOL" >&2
        exit 1
        ;;
esac

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
REPO_ROOT=""
if [[ -n "$SCRIPT_SOURCE" && -f "$SCRIPT_SOURCE" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

is_local_checkout() {
    [[ -n "$REPO_ROOT" && -f "$REPO_ROOT/agentic-researcher" && -d "$REPO_ROOT/container" ]]
}

stage_local_checkout() {
    mkdir -p "$(dirname "$INSTALL_DIR")"
    if [[ -e "$INSTALL_DIR" ]]; then
        if [[ "$FORCE" != "true" ]]; then
            echo "Error: Install directory already exists: $INSTALL_DIR" >&2
            echo "Use --force to replace it." >&2
            exit 1
        fi
        rm -rf "$INSTALL_DIR"
    fi
    mkdir -p "$INSTALL_DIR"
    tar -C "$REPO_ROOT" \
        --exclude='.git' \
        --exclude='.venv' \
        --exclude='__pycache__' \
        -cf - . | tar -C "$INSTALL_DIR" -xf -
    local install_commit=""
    if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
        install_commit="$(git -C "$REPO_ROOT" rev-parse HEAD)"
    fi
    printf 'managed_by=agentic-researcher\nsource=local-checkout\nsource_path=%s\ninstall_commit=%s\n' \
        "$REPO_ROOT" "$install_commit" > "$INSTALL_DIR/$INSTALL_MARKER"
}

bootstrap_remote_checkout() {
    mkdir -p "$(dirname "$INSTALL_DIR")"
    if [[ -e "$INSTALL_DIR" ]]; then
        if [[ "$FORCE" != "true" ]]; then
            echo "Error: Install directory already exists: $INSTALL_DIR" >&2
            echo "Use --force to replace it." >&2
            exit 1
        fi
        rm -rf "$INSTALL_DIR"
    fi
    if [[ -n "$REPO_REF" ]]; then
        git clone --branch "$REPO_REF" --single-branch "$REPO_URL" "$INSTALL_DIR"
    else
        git clone "$REPO_URL" "$INSTALL_DIR"
    fi
    printf 'managed_by=agentic-researcher\nsource=%s\nref=%s\n' "$REPO_URL" "$REPO_REF" > "$INSTALL_DIR/$INSTALL_MARKER"
}

write_config() {
    local auth_mode api_provider api_key_env default_model

    case "$TOOL" in
        claude)
            auth_mode="oauth"
            api_provider="anthropic"
            api_key_env="ANTHROPIC_API_KEY"
            default_model="sonnet"
            ;;
        opencode)
            auth_mode="tool"
            api_provider=""
            api_key_env=""
            default_model=""
            ;;
        gemini)
            auth_mode="tool"
            api_provider=""
            api_key_env=""
            default_model=""
            ;;
        codex)
            auth_mode="tool"
            api_provider=""
            api_key_env=""
            default_model=""
            ;;
    esac

    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/config.sh" <<EOF
# Agentic Researcher configuration
AR_CONTAINER_RUNTIME="$RUNTIME"
AR_AUTH_MODE="$auth_mode"
AR_API_PROVIDER="$api_provider"
AR_API_KEY_ENV="$api_key_env"
AR_CUSTOM_ENDPOINT=""
AR_CUSTOM_ANTHROPIC_ENDPOINT=""
AR_CLI_TOOL="$TOOL"
AR_DEFAULT_MODEL="$default_model"
AR_HTTPS_PROXY=""
AR_HTTP_PROXY=""
AR_STATE_ROOT="$STATE_ROOT"
AR_EXTRA_BIND_DIRS=""
EOF
}

install_symlink() {
    local target="$INSTALL_DIR/agentic-researcher"
    local link_path="$BIN_DIR/agentic-researcher"

    mkdir -p "$BIN_DIR"

    if [[ -L "$link_path" || -e "$link_path" ]]; then
        if [[ "$FORCE" != "true" ]]; then
            echo "Error: Launcher already exists: $link_path" >&2
            echo "Use --force to replace it." >&2
            exit 1
        fi
        rm -f "$link_path"
    fi

    chmod +x "$target"
    ln -s "$target" "$link_path"

    echo "Installed:"
    echo "  $link_path -> $target"
}

print_path_hint() {
    case ":$PATH:" in
        *":$BIN_DIR:"*)
            echo ""
            echo "Your PATH already includes $BIN_DIR"
            ;;
        *)
            echo ""
            echo "Add this to your shell profile:"
            echo "  export PATH=\"$BIN_DIR:\$PATH\""
            ;;
    esac
}

run_build() {
    local launcher="$BIN_DIR/agentic-researcher"
    if [[ "$RUNTIME" == "docker" || "$RUNTIME" == "podman" ]]; then
        "$launcher" --"$RUNTIME" --build
    else
        "$launcher" --apptainer --build
    fi
}

if is_local_checkout; then
    stage_local_checkout
else
    bootstrap_remote_checkout
fi

install_symlink

if [[ "$WRITE_CONFIG" == "true" ]]; then
    write_config
    echo "Wrote config: $CONFIG_DIR/config.sh"
fi

print_path_hint

if [[ "$BUILD_IMAGE" == "true" ]]; then
    echo ""
    echo "Building container..."
    run_build
fi

echo ""
echo "Next steps:"
echo "  1. Build the container: agentic-researcher --build"
echo "  2. Start the agent:     agentic-researcher ~/your-project"
