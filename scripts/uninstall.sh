#!/bin/bash
#
# uninstall.sh: Remove an installed agentic-researcher setup.
#

set -euo pipefail

DEFAULT_INSTALL_DIR="$HOME/.local/share/agentic-researcher"
DEFAULT_BIN_DIR="$HOME/.local/bin"
INSTALL_MARKER=".agentic-researcher-install"

INSTALL_DIR="$DEFAULT_INSTALL_DIR"
BIN_DIR="$DEFAULT_BIN_DIR"
PURGE=true
ASSUME_YES=false

show_help() {
    cat <<'EOF'
Usage:
  agentic-researcher --uninstall [OPTIONS]

Options:
  --install-dir DIR  Remove checkout from DIR
  --bin-dir DIR      Remove symlink from DIR
  --keep-state       Keep config, local state, and docker image
  --yes              Skip confirmation prompt
  --help             Show this help
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
        --keep-state)
            PURGE=false
            shift
            ;;
        --yes)
            ASSUME_YES=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown uninstall option: $1" >&2
            echo "" >&2
            show_help >&2
            exit 1
            ;;
    esac
done

LINK_PATH="$BIN_DIR/agentic-researcher"

if [[ -L "$LINK_PATH" ]]; then
    link_target="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$LINK_PATH")"
    inferred_install_dir="$(cd "$(dirname "$link_target")" && pwd 2>/dev/null || true)"
    if [[ -n "$inferred_install_dir" && -f "$inferred_install_dir/agentic-researcher" ]]; then
        INSTALL_DIR="$inferred_install_dir"
    fi
fi

echo "Uninstall plan:"
echo "  Launcher symlink: $LINK_PATH"
echo "  Install dir:      $INSTALL_DIR"
if [[ "$PURGE" == "true" ]]; then
    echo "  Purge:            config + state + docker image"
else
    echo "  Purge:            no (keeping config + state + docker image)"
fi
echo ""

if [[ "$ASSUME_YES" != "true" ]]; then
    read -rp "Proceed with uninstall? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Uninstall cancelled."
        exit 0
    fi
fi

if [[ "$PURGE" == "true" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    "$SCRIPT_DIR/cleanup.sh" --all --yes
fi

if [[ -L "$LINK_PATH" || -e "$LINK_PATH" ]]; then
    rm -f "$LINK_PATH"
    echo "Removed launcher: $LINK_PATH"
else
    echo "Launcher not present: $LINK_PATH"
fi

if [[ -d "$INSTALL_DIR" ]]; then
    if [[ ! -f "$INSTALL_DIR/$INSTALL_MARKER" ]]; then
        echo "Refusing to remove unmarked directory: $INSTALL_DIR" >&2
        echo "Expected marker file: $INSTALL_DIR/$INSTALL_MARKER" >&2
        exit 1
    fi
    rm -rf "$INSTALL_DIR"
    echo "Removed install dir: $INSTALL_DIR"
else
    echo "Install dir not present: $INSTALL_DIR"
fi
