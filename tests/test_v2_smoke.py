"""Smoke tests for the v2 (persistent-store) launcher.

These tests run WITHOUT a container runtime: they validate script syntax,
argument handling, config resolution, and template integrity. Containerized
integration tests are tracked in TODO.md.
"""

import json
import os
import re
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = REPO_ROOT / "agentic-researcher"
INNER = REPO_ROOT / "container" / "inner.sh"

BASH_SCRIPTS = [
    REPO_ROOT / "agentic-researcher",
    REPO_ROOT / "container" / "inner.sh",
    REPO_ROOT / "scripts" / "first-setup.sh",
    REPO_ROOT / "scripts" / "install.sh",
    REPO_ROOT / "scripts" / "cleanup.sh",
    REPO_ROOT / "scripts" / "uninstall.sh",
    REPO_ROOT / "scripts" / "test_sandbox.sh",
]


def run_launcher(args, env_overrides=None, cwd=None):
    """Run the launcher with an isolated HOME/XDG_CONFIG_HOME."""
    env = os.environ.copy()
    if env_overrides:
        env.update(env_overrides)
    return subprocess.run(
        ["bash", str(LAUNCHER), *args],
        capture_output=True,
        text=True,
        env=env,
        cwd=cwd or REPO_ROOT,
        timeout=60,
    )


@pytest.fixture
def isolated_env(tmp_path):
    home = tmp_path / "home"
    config = tmp_path / "config"
    home.mkdir()
    config.mkdir()
    return {
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(config),
    }


# ---------------------------------------------------------------------------
# Syntax / structure
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("script", BASH_SCRIPTS, ids=lambda p: p.name)
def test_bash_syntax(script):
    assert script.exists(), f"missing script: {script}"
    result = subprocess.run(
        ["bash", "-n", str(script)], capture_output=True, text=True
    )
    assert result.returncode == 0, result.stderr


def test_scripts_are_executable():
    for script in (LAUNCHER, INNER):
        assert os.access(script, os.X_OK), f"not executable: {script}"


def test_removed_files_are_gone():
    for relpath in [
        "container/Dockerfile",
        "container/agentic_researcher.def",
        "container/build.sh",
        "container/entrypoint.sh",
        "scripts/ssh-proxy-connect.py",
    ]:
        assert not (REPO_ROOT / relpath).exists(), f"should be removed: {relpath}"


def test_no_machine_specific_leftovers():
    """v2 must not contain ai-box machine-specific features."""
    banned = [
        "qdrant",
        "ntfy",
        "lmstudio",
        "LMSTUDIO",
        "SPARK_HOST",
        "aibox-ipc",
        "SOPS_AGE_KEY",
        "loadenv",
        "host.docker.internal",
        "ssh-agent",
        "AI_BOX_",
    ]
    for script in (LAUNCHER, INNER):
        text = script.read_text()
        for term in banned:
            assert term not in text, f"{script.name} still references '{term}'"


def test_no_extra_bind_or_ssh_mount_in_launcher():
    text = LAUNCHER.read_text()
    assert "AR_EXTRA_BIND_DIRS" not in text
    assert "--attach" not in text
    assert "/claude-home/.ssh" not in text
    assert ".ssh:" not in text


# ---------------------------------------------------------------------------
# Launcher behavior (no container runtime required)
# ---------------------------------------------------------------------------

def test_help_runs(isolated_env):
    result = run_launcher(["--help"], isolated_env)
    assert result.returncode == 0
    assert "agentic-researcher" in result.stdout
    assert "--build" in result.stdout
    assert "Prewarm" in result.stdout
    # removed functionality must not be advertised
    assert "--attach" not in result.stdout
    assert "--multi-node" not in result.stdout


def test_print_env_default(isolated_env):
    result = run_launcher(["--print-env"], isolated_env)
    assert result.returncode == 0
    assert "AR_CLI_TOOL=claude" in result.stdout
    assert "AR_AUTH_MODE=oauth" in result.stdout
    assert "node:24-bookworm" in result.stdout


def test_print_env_redacts_keys(isolated_env):
    env = dict(isolated_env)
    env["ANTHROPIC_API_KEY"] = "sk-super-secret"
    result = run_launcher(["--print-env"], env)
    assert result.returncode == 0
    assert "sk-super-secret" not in result.stdout
    assert "***set***" in result.stdout


def test_tool_selection_via_flag(isolated_env):
    result = run_launcher(["--tool", "pi", "--print-env"], isolated_env)
    assert result.returncode == 0
    assert "AR_CLI_TOOL=pi" in result.stdout


def test_tool_selection_via_env(isolated_env):
    env = dict(isolated_env)
    env["AR_CLI_TOOL"] = "qwen"
    result = run_launcher(["--print-env"], env)
    assert result.returncode == 0
    assert "AR_CLI_TOOL=qwen" in result.stdout


def test_unknown_tool_rejected(isolated_env):
    result = run_launcher(["--tool", "nonsense", "--print-env"], isolated_env)
    assert result.returncode != 0
    assert "Unknown tool" in result.stdout + result.stderr


def test_apptainer_gated(isolated_env):
    result = run_launcher(["--apptainer"], isolated_env)
    assert result.returncode != 0
    assert "not yet supported" in result.stdout + result.stderr


def test_multi_node_gated(isolated_env):
    result = run_launcher(["--multi-node"], isolated_env)
    assert result.returncode != 0
    assert "not yet supported" in result.stdout + result.stderr


def test_config_file_respected(isolated_env, tmp_path):
    config_dir = Path(isolated_env["XDG_CONFIG_HOME"]) / "agentic-researcher"
    config_dir.mkdir(parents=True)
    (config_dir / "config.sh").write_text(
        'AR_CLI_TOOL="gemini"\n'
        'AR_STATE_ROOT="/tmp/custom-store"\n'
        'AR_NO_COOLDOWN="pi"\n'
    )
    result = run_launcher(["--print-env"], isolated_env)
    assert result.returncode == 0
    assert "AR_CLI_TOOL=gemini" in result.stdout
    assert "AR_STATE_ROOT=/tmp/custom-store" in result.stdout
    assert "AR_NO_COOLDOWN=pi" in result.stdout


def test_env_overrides_config(isolated_env):
    config_dir = Path(isolated_env["XDG_CONFIG_HOME"]) / "agentic-researcher"
    config_dir.mkdir(parents=True)
    (config_dir / "config.sh").write_text('AR_CLI_TOOL="gemini"\n')
    env = dict(isolated_env)
    env["AR_CLI_TOOL"] = "codex"
    result = run_launcher(["--print-env"], env)
    assert result.returncode == 0
    assert "AR_CLI_TOOL=codex" in result.stdout


def test_gpu_image_resolution(isolated_env):
    env = dict(isolated_env)
    env["AR_DOCKER_GPUS"] = "none"
    env["AR_IMAGE"] = "my-custom:image"
    result = run_launcher(["--print-env"], env)
    assert result.returncode == 0
    assert "AR_IMAGE=my-custom:image" in result.stdout


# ---------------------------------------------------------------------------
# Config example + templates
# ---------------------------------------------------------------------------

def test_config_example_sources_cleanly():
    example = REPO_ROOT / "config" / "config.example.sh"
    result = subprocess.run(
        ["bash", "-c", f'set -e; source "{example}"; echo "$AR_CLI_TOOL"'],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "claude"
    text = example.read_text()
    assert "AR_EXTRA_BIND_DIRS" not in text


@pytest.mark.parametrize(
    "template",
    ["opencode_config.template.json", "pi_models.template.json"],
)
def test_templates_render_to_valid_json(template):
    raw = (REPO_ROOT / "config" / template).read_text()
    rendered = raw.replace("__AR_CUSTOM_ENDPOINT__", "https://example.com/v1")
    rendered = rendered.replace("__AR_DEFAULT_MODEL__", "some-model")
    data = json.loads(rendered)
    assert data
    # The API key must be an env reference, never a literal placeholder that
    # the launcher would substitute with the real secret.
    assert "__AR_API_KEY__" not in rendered
    assert "AR_CUSTOM_API_KEY" in rendered


def test_inner_uses_ar_store_paths():
    text = INNER.read_text()
    assert "/ar-store" in text or 'STORE=/ar-store' in text
    assert "/ai-box" not in text


def test_test_sandbox_expects_store_home():
    text = (REPO_ROOT / "scripts" / "test_sandbox.sh").read_text()
    assert "/ar-store/home" in text
    assert "/claude-home" not in text


def test_codex_login_check_preserved():
    """Regression: codex login session must be accepted without an API key."""
    script = (REPO_ROOT / "scripts" / "test_sandbox.sh").read_text()
    assert "codex login status >/dev/null 2>&1" in script
    assert 'pass "Codex login session is available"' in script
