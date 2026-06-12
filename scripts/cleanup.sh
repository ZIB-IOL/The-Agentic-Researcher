#!/bin/bash
#
# cleanup.sh: Remove launcher-managed local state conservatively.
#

set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agentic-researcher"
CONFIG_FILE="$CONFIG_DIR/config.sh"
REMOVE_CONFIG=false
ASSUME_YES=false

show_help() {
    cat <<'EOF'
Usage:
  agentic-researcher --clean [OPTIONS]

Options:
  --yes             Skip confirmation prompt
  --include-config  Also remove ${XDG_CONFIG_HOME:-$HOME/.config}/agentic-researcher/config.sh
  --all             Equivalent to --include-config
  --help            Show this help

Default behavior:
  Removes only the launcher-managed persistent store (AR_STATE_ROOT): all
  installed CLI tools, runtimes, caches, and the agent home. Tools are
  reinstalled automatically on the next launch.
  Does not remove project files.
  Does not remove stock base images (node:24-bookworm etc.) - they may be
  shared with other uses; remove manually via 'docker image rm' if desired.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)
            ASSUME_YES=true
            ;;
        --include-config)
            REMOVE_CONFIG=true
            ;;
        --all)
            REMOVE_CONFIG=true
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown cleanup option: $1"
            echo ""
            show_help
            exit 1
            ;;
    esac
    shift
done

STATE_ROOT="$HOME/.cache/agentic-researcher"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    STATE_ROOT="${AR_STATE_ROOT:-$STATE_ROOT}"
fi

if ! STATE_ROOT="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$STATE_ROOT" 2>/dev/null)"; then
    echo "Error: Could not resolve state root: $STATE_ROOT"
    exit 1
fi

case "$STATE_ROOT" in
    ""|"/"|"$HOME"|"$HOME/"*)
        if [[ "$STATE_ROOT" == "$HOME" || "$STATE_ROOT" == "/" || -z "$STATE_ROOT" ]]; then
            echo "Error: Refusing to clean unsafe path: $STATE_ROOT"
            exit 1
        fi
        ;;
esac

echo "Cleanup plan:"
echo "  Store (state root):  $STATE_ROOT"
if [[ "$REMOVE_CONFIG" == "true" ]]; then
    echo "  Config file:         $CONFIG_FILE"
else
    echo "  Config file:         keep"
fi
echo ""
echo "Project files are not touched."
echo ""

if [[ "$ASSUME_YES" != "true" ]]; then
    read -rp "Proceed with cleanup? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Cleanup cancelled."
        exit 0
    fi
fi

if [[ -d "$STATE_ROOT" ]]; then
    rm -rf "$STATE_ROOT"
    echo "Removed store: $STATE_ROOT"
else
    echo "Store not present: $STATE_ROOT"
fi

if [[ "$REMOVE_CONFIG" == "true" ]]; then
    if [[ -f "$CONFIG_FILE" ]]; then
        rm -f "$CONFIG_FILE"
        echo "Removed config file: $CONFIG_FILE"
    else
        echo "Config file not present: $CONFIG_FILE"
    fi
    if [[ -d "$CONFIG_DIR" ]]; then
        rmdir "$CONFIG_DIR" 2>/dev/null || true
    fi
fi
