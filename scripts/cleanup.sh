#!/bin/bash
#
# cleanup.sh: Remove launcher-managed local state conservatively.
#

set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agentic-researcher"
CONFIG_FILE="$CONFIG_DIR/config.sh"
REMOVE_CONFIG=false
REMOVE_IMAGE=false
ASSUME_YES=false

show_help() {
    cat <<'EOF'
Usage:
  agentic-researcher --clean [OPTIONS]

Options:
  --yes             Skip confirmation prompt
  --include-config  Also remove ${XDG_CONFIG_HOME:-$HOME/.config}/agentic-researcher/config.sh
  --include-image   Also remove agentic-researcher:latest from Docker/Podman if available
  --all             Equivalent to --include-config --include-image
  --help            Show this help

Default behavior:
  Removes only launcher-managed local state under the configured state root.
  Does not remove project files.
  Does not remove container images unless explicitly requested.
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
        --include-image)
            REMOVE_IMAGE=true
            ;;
        --all)
            REMOVE_CONFIG=true
            REMOVE_IMAGE=true
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
echo "  State root:    $STATE_ROOT"
if [[ "$REMOVE_CONFIG" == "true" ]]; then
    echo "  Config file:   $CONFIG_FILE"
else
    echo "  Config file:   keep"
fi
if [[ "$REMOVE_IMAGE" == "true" ]]; then
    echo "  OCI image:     agentic-researcher:latest"
else
    echo "  OCI image:     keep"
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
    echo "Removed state root: $STATE_ROOT"
else
    echo "State root not present: $STATE_ROOT"
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

if [[ "$REMOVE_IMAGE" == "true" ]]; then
    removed_any=false
    for runtime in docker podman; do
        if command -v "$runtime" >/dev/null 2>&1; then
            if "$runtime" image inspect agentic-researcher:latest >/dev/null 2>&1; then
                if "$runtime" image rm agentic-researcher:latest >/dev/null 2>&1; then
                    echo "Removed $runtime image: agentic-researcher:latest"
                    removed_any=true
                else
                    echo "$runtime image could not be removed: agentic-researcher:latest"
                fi
            else
                echo "$runtime image not present: agentic-researcher:latest"
            fi
        fi
    done
    if [[ "$removed_any" != "true" ]] && ! command -v docker >/dev/null 2>&1 && ! command -v podman >/dev/null 2>&1; then
        echo "Neither Docker nor Podman is available; skipped image cleanup."
    fi
fi
