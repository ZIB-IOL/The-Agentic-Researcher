#!/bin/bash
#
# test_sandbox.sh: Validate the sandbox environment
#
# Runs inside the container to check CLI tools, filesystem, network, and GPU.
# Exit 0 if all required checks pass; GPU failure is a warning only.
#

PASS=0
FAIL=0
WARN=0

pass() {
    echo "  [PASS] $1"
    ((PASS++))
}

fail() {
    echo "  [FAIL] $1"
    ((FAIL++))
}

warn() {
    echo "  [WARN] $1"
    ((WARN++))
}

# --- CLI Tools ---
echo "=== CLI Tools ==="
for tool in claude opencode gemini codex uv git gh jq rg yq python3; do
    if command -v "$tool" &>/dev/null; then
        pass "$tool found ($(command -v "$tool"))"
    else
        fail "$tool not found"
    fi
done

for tool in gemini codex; do
    if ! "$tool" --version >/dev/null 2>&1; then
        fail "$tool is installed but not runnable"
    else
        pass "$tool --version works"
    fi
done
echo ""

# --- Filesystem ---
echo "=== Filesystem ==="

if [[ -d /workspace ]]; then
    pass "/workspace exists"
else
    fail "/workspace does not exist"
fi

TESTFILE="/workspace/.sandbox_test_$$"
if touch "$TESTFILE" 2>/dev/null; then
    pass "/workspace is writable"
    rm -f "$TESTFILE"
else
    fail "/workspace is not writable"
fi

if [[ "$HOME" == "/claude-home" ]]; then
    pass "HOME is /claude-home"
else
    fail "HOME is '$HOME' (expected /claude-home)"
fi

TMPFILE="/tmp/.sandbox_test_$$"
if touch "$TMPFILE" 2>/dev/null; then
    pass "/tmp is writable"
    rm -f "$TMPFILE"
else
    fail "/tmp is not writable"
fi
echo ""

# --- Network ---
echo "=== Network ==="
if curl -sf --max-time 10 https://api.anthropic.com/ >/dev/null 2>&1 || \
   curl -sf --max-time 10 https://www.google.com/ >/dev/null 2>&1; then
    pass "Network connectivity (HTTPS)"
else
    fail "No network connectivity"
fi
echo ""

# --- GPU (optional) ---
echo "=== GPU (optional) ==="
if command -v nvidia-smi &>/dev/null; then
    if nvidia-smi &>/dev/null; then
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
        pass "GPU available: $GPU_NAME"
    else
        warn "nvidia-smi found but failed to run (no GPU allocated?)"
    fi
else
    warn "nvidia-smi not found (no GPU support)"
fi
echo ""

# --- Tool-specific checks ---
ACTIVE_TOOL="${AR_CLI_TOOL:-claude}"
echo "=== Active Tool: $ACTIVE_TOOL ==="
case "$ACTIVE_TOOL" in
    claude)
        if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
            pass "ANTHROPIC_API_KEY is set"
        else
            fail "ANTHROPIC_API_KEY is not set"
        fi
        ;;
    opencode)
        if [[ -f "$HOME/.config/opencode/opencode.json" ]]; then
            pass "OpenCode config file is mounted"
        else
            warn "OpenCode config file not found (may use defaults)"
        fi
        ;;
    gemini)
        if [[ -n "${GOOGLE_API_KEY:-}" || -n "${GEMINI_API_KEY:-}" ]]; then
            pass "Google/Gemini API key is set"
        else
            fail "GOOGLE_API_KEY or GEMINI_API_KEY is not set"
        fi
        ;;
    codex)
        if [[ -n "${OPENAI_API_KEY:-}" ]]; then
            pass "OPENAI_API_KEY is set"
        else
            fail "OPENAI_API_KEY is not set"
        fi
        ;;
esac
echo ""

# --- Summary ---
echo "================================"
echo "Results: $PASS passed, $FAIL failed, $WARN warnings"

if [[ $FAIL -eq 0 ]]; then
    echo "Status: ALL REQUIRED CHECKS PASSED"
    exit 0
else
    echo "Status: SOME CHECKS FAILED"
    exit 1
fi
