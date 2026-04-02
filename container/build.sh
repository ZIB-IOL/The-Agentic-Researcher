#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load config if available
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/agentic-researcher/config.sh"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Proxy: config → environment → nothing
if [[ -n "${AR_HTTPS_PROXY:-}" ]]; then
    export https_proxy="$AR_HTTPS_PROXY"
    export http_proxy="${AR_HTTP_PROXY:-$AR_HTTPS_PROXY}"
fi
# Also honor pre-existing env vars
[[ -n "${https_proxy:-}" ]] && export https_proxy
[[ -n "${http_proxy:-}" ]] && export http_proxy

OCI_RUNTIME=""
case "${1:-}" in
    --docker|docker)
        OCI_RUNTIME="docker"
        ;;
    --podman|podman)
        OCI_RUNTIME="podman"
        ;;
esac

if [[ -n "$OCI_RUNTIME" ]]; then
    if ! command -v "$OCI_RUNTIME" >/dev/null 2>&1; then
        echo "Error: '$OCI_RUNTIME' is not installed or not on PATH."
        echo ""
        echo "Install $OCI_RUNTIME on the host, then rerun:"
        echo "  agentic-researcher --$OCI_RUNTIME --build"
        exit 1
    fi

    first_char="${OCI_RUNTIME%${OCI_RUNTIME#?}}"
    rest="${OCI_RUNTIME#?}"
    first_char_upper="$(printf '%s' "$first_char" | tr '[:lower:]' '[:upper:]')"
    runtime_name="${first_char_upper}${rest}"
    echo "Building ${runtime_name} container..."
    if [[ "$OCI_RUNTIME" == "podman" ]]; then
        "$OCI_RUNTIME" build --format docker -t agentic-researcher:latest "$SCRIPT_DIR"
    else
        "$OCI_RUNTIME" build -t agentic-researcher:latest "$SCRIPT_DIR"
    fi
    echo ""
    echo "${runtime_name} image built: agentic-researcher:latest"
else
    if [[ "$(uname -s)" != "Linux" ]]; then
        echo "Error: Apptainer builds are only supported on Linux hosts. Current host: $(uname -s)"
        echo ""
        echo "Use Docker on this machine:"
        echo "  agentic-researcher --docker --build"
        exit 1
    fi
    if ! command -v apptainer >/dev/null 2>&1; then
        echo "Error: 'apptainer' is not installed or not on PATH."
        echo ""
        echo "Install Apptainer on the Linux host, then rerun:"
        echo "  agentic-researcher --apptainer --build"
        exit 1
    fi

    # Apptainer needs writable tmp with enough space for the build
    STATE_ROOT="${AR_STATE_ROOT:-$HOME/.cache/agentic-researcher}"
    export APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-$STATE_ROOT/apptainer_cache}"
    export APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-$STATE_ROOT/apptainer_tmp}"
    mkdir -p "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"

    echo "Building Apptainer container..."
    echo "This may take 5-10 minutes on first build."
    echo ""

    apptainer build \
        --force \
        "$SCRIPT_DIR/agentic_researcher.sif" \
        "$SCRIPT_DIR/agentic_researcher.def"

    echo ""
    echo "Container built successfully: $SCRIPT_DIR/agentic_researcher.sif"

    # SECURITY: Generate integrity checksum
    echo "Generating integrity checksum..."
    (cd "$SCRIPT_DIR" && sha256sum agentic_researcher.sif > agentic_researcher.sif.sha256)
    echo "Checksum saved to: $SCRIPT_DIR/agentic_researcher.sif.sha256"
fi

echo ""
echo "Run with: agentic-researcher"
