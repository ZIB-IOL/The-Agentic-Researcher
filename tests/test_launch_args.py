"""Launch-path tests using a fake container runtime.

A stub docker/podman binary is placed on PATH; it accepts `info` and logs the
full argument vector of `run` invocations. This validates mounts, env vars,
capability flags, and staged assets without a real container runtime.
"""

import json
import os
import platform
import stat
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = REPO_ROOT / "agentic-researcher"

FAKE_RUNTIME = """#!/bin/sh
if [ "$1" = "info" ]; then
  exit 0
fi
printf '%s\\n' "$@" >> "${FAKE_RUNTIME_LOG:?}"
exit 0
"""


@pytest.fixture
def fake_env(tmp_path):
    """Isolated HOME/XDG plus a fake docker+podman on PATH."""
    home = tmp_path / "home"
    config = tmp_path / "config"
    bin_dir = tmp_path / "bin"
    workspace = tmp_path / "project"
    log = tmp_path / "runtime.log"
    for d in (home, config, bin_dir, workspace):
        d.mkdir()

    for name in ("docker", "podman"):
        stub = bin_dir / name
        stub.write_text(FAKE_RUNTIME)
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)

    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(config),
            "PATH": f"{bin_dir}:{env['PATH']}",
            "FAKE_RUNTIME_LOG": str(log),
            "AR_STATE_ROOT": str(tmp_path / "store"),
            "AR_DOCKER_GPUS": "none",
        }
    )
    return {"env": env, "workspace": workspace, "log": log, "tmp": tmp_path}


def launch(fake_env, args):
    return subprocess.run(
        ["bash", str(LAUNCHER), *args, str(fake_env["workspace"])],
        capture_output=True,
        text=True,
        env=fake_env["env"],
        timeout=60,
    )


def logged_args(fake_env):
    return fake_env["log"].read_text().splitlines()


def test_docker_run_args(fake_env):
    result = launch(fake_env, ["--docker"])
    assert result.returncode == 0, result.stderr + result.stdout
    args = logged_args(fake_env)

    store = fake_env["env"]["AR_STATE_ROOT"]
    assert "run" in args
    assert f"{fake_env['workspace']}:/workspace:rw" in args
    assert f"{store}:/ar-store:rw" in args
    assert "--cap-drop=ALL" in args
    assert "--cap-add=SETUID" in args
    assert "no-new-privileges" in args
    assert "HOME=/ar-store/home" in args
    assert "DISABLE_AUTOUPDATER=1" in args
    assert "/ar-entrypoint.sh" in " ".join(args)
    # GPU disabled
    assert "--gpus" not in args
    # no ssh/extra mounts
    joined = " ".join(args)
    assert ".ssh" not in joined
    assert "/attach" not in joined
    # claude defaults: model + entrypoint env
    assert "AR_ENTRYPOINT=claude" in args
    assert "--model" in args and "sonnet" in args

    if platform.system() == "Linux":
        assert f"AR_UID={os.getuid()}" in args


def test_yolo_translation(fake_env):
    result = launch(fake_env, ["--docker", "--yolo"])
    assert result.returncode == 0, result.stderr + result.stdout
    assert "--dangerously-skip-permissions" in logged_args(fake_env)


def test_podman_keep_id(fake_env):
    result = launch(fake_env, ["--podman"])
    assert result.returncode == 0, result.stderr + result.stdout
    args = logged_args(fake_env)
    assert "--userns" in args and "keep-id" in args
    # rootless podman: no uid/gid env for the privilege drop
    assert not any(a.startswith("AR_UID=") for a in args)


def test_unsafe_adds_chown_and_skips_uid(fake_env):
    result = launch(fake_env, ["--docker", "--unsafe"])
    assert result.returncode == 0, result.stderr + result.stdout
    args = logged_args(fake_env)
    assert "--cap-add=CHOWN" in args
    assert not any(a.startswith("AR_UID=") for a in args)


def test_lockdown_flags(fake_env):
    env = dict(fake_env["env"])
    env["AR_LOCKDOWN"] = "1"
    fake_env["env"] = env
    result = launch(fake_env, ["--docker"])
    assert result.returncode == 0, result.stderr + result.stdout
    args = logged_args(fake_env)
    assert "--read-only" in args
    assert "--pids-limit=256" in args


def test_instruction_file_and_assets_staged(fake_env):
    result = launch(fake_env, ["--docker"])
    assert result.returncode == 0, result.stderr + result.stdout

    # workspace instruction file for claude
    assert (fake_env["workspace"] / "CLAUDE.md").exists()

    store_home = Path(fake_env["env"]["AR_STATE_ROOT"]) / "home"
    assert (store_home / ".claude.json").exists()
    assert json.loads((store_home / ".claude.json").read_text())[
        "hasCompletedOnboarding"
    ]
    assert (store_home / ".claude" / "commands" / "setup_research_plan.md").exists()
    assert (store_home / ".claude" / "INSTRUCTIONS.md.template").exists()


@pytest.mark.parametrize(
    "tool", ["claude", "opencode", "gemini", "codex", "qwen", "pi", "bash"]
)
def test_every_tool_launches(fake_env, tool):
    """Every advertised tool must reach the runtime with the right entrypoint."""
    result = launch(fake_env, ["--docker", "--tool", tool])
    assert result.returncode == 0, result.stderr + result.stdout
    args = logged_args(fake_env)
    assert f"AR_ENTRYPOINT={tool}" in args


def test_pi_arg_translation(fake_env):
    """pi: --resume ID becomes --session ID; default model appended."""
    env = dict(fake_env["env"])
    env["AR_DEFAULT_MODEL"] = "pi-model"
    fake_env["env"] = env
    result = launch(fake_env, ["--docker", "--tool", "pi", "--resume", "abc123"])
    assert result.returncode == 0, result.stderr + result.stdout
    args = logged_args(fake_env)
    assert "--session" in args and "abc123" in args
    assert "--resume" not in args
    assert "--model" in args and "pi-model" in args


def test_qwen_instruction_file(fake_env):
    result = launch(fake_env, ["--docker", "--tool", "qwen"])
    assert result.returncode == 0, result.stderr + result.stdout
    assert (fake_env["workspace"] / "QWEN.md").exists()
    assert "AR_ENTRYPOINT=qwen" in logged_args(fake_env)


def test_pi_custom_endpoint_renders_models_json(fake_env):
    env = dict(fake_env["env"])
    env["AR_CUSTOM_ENDPOINT"] = "https://gateway.example.com/v1"
    env["AR_DEFAULT_MODEL"] = "my-model"
    env["MY_KEY_VAR"] = "shh-secret"
    env["AR_API_KEY_ENV"] = "MY_KEY_VAR"
    fake_env["env"] = env

    result = launch(fake_env, ["--docker", "--tool", "pi"])
    assert result.returncode == 0, result.stderr + result.stdout

    models = Path(env["AR_STATE_ROOT"]) / "home" / ".pi" / "agent" / "models.json"
    assert models.exists()
    data = json.loads(models.read_text())
    provider = data["providers"]["custom"]
    assert provider["baseUrl"] == "https://gateway.example.com/v1"
    assert provider["models"][0]["id"] == "my-model"
    # secret must NOT be written to disk - env reference only
    assert "shh-secret" not in models.read_text()
    assert provider["apiKey"] == "$AR_CUSTOM_API_KEY"

    args = logged_args(fake_env)
    assert "AR_CUSTOM_ENDPOINT=https://gateway.example.com/v1" in args
    assert "AR_CUSTOM_API_KEY=shh-secret" in args


def test_opencode_custom_endpoint_renders_config(fake_env):
    env = dict(fake_env["env"])
    env["AR_CUSTOM_ENDPOINT"] = "https://gateway.example.com/v1"
    env["AR_DEFAULT_MODEL"] = "my-model"
    fake_env["env"] = env

    result = launch(fake_env, ["--docker", "--tool", "opencode"])
    assert result.returncode == 0, result.stderr + result.stdout

    oc = (
        Path(env["AR_STATE_ROOT"])
        / "home"
        / ".config"
        / "opencode"
        / "opencode.json"
    )
    assert oc.exists()
    data = json.loads(oc.read_text())
    assert (
        data["provider"]["custom"]["options"]["baseURL"]
        == "https://gateway.example.com/v1"
    )
    assert data["provider"]["custom"]["options"]["apiKey"] == "{env:AR_CUSTOM_API_KEY}"
    assert data["model"] == "custom/my-model"


def test_no_custom_endpoint_no_configs(fake_env):
    result = launch(fake_env, ["--docker", "--tool", "pi"])
    assert result.returncode == 0, result.stderr + result.stdout
    models = (
        Path(fake_env["env"]["AR_STATE_ROOT"]) / "home" / ".pi" / "agent" / "models.json"
    )
    assert not models.exists()


def test_both_templates_rendered_regardless_of_tool(fake_env):
    """Endpoint configs are kept in sync even when launching another tool."""
    env = dict(fake_env["env"])
    env["AR_CUSTOM_ENDPOINT"] = "https://gateway.example.com/v1"
    fake_env["env"] = env

    result = launch(fake_env, ["--docker", "--tool", "claude"])
    assert result.returncode == 0, result.stderr + result.stdout

    store_home = Path(env["AR_STATE_ROOT"]) / "home"
    assert (store_home / ".pi" / "agent" / "models.json").exists()
    assert (store_home / ".config" / "opencode" / "opencode.json").exists()


def test_stale_managed_configs_removed_when_endpoint_unset(fake_env):
    """Rendered endpoint configs must not linger after the endpoint is unset."""
    env_with = dict(fake_env["env"])
    env_with["AR_CUSTOM_ENDPOINT"] = "https://gateway.example.com/v1"
    fake_env["env"] = env_with
    result = launch(fake_env, ["--docker", "--tool", "pi"])
    assert result.returncode == 0, result.stderr + result.stdout

    store_home = Path(env_with["AR_STATE_ROOT"]) / "home"
    models = store_home / ".pi" / "agent" / "models.json"
    oc = store_home / ".config" / "opencode" / "opencode.json"
    assert models.exists() and oc.exists()

    # Relaunch without the endpoint: both rendered configs disappear
    env_without = dict(fake_env["env"])
    del env_without["AR_CUSTOM_ENDPOINT"]
    fake_env["env"] = env_without
    result = launch(fake_env, ["--docker", "--tool", "pi"])
    assert result.returncode == 0, result.stderr + result.stdout
    assert not models.exists()
    assert not oc.exists()


def test_user_authored_configs_never_removed(fake_env):
    """Configs without the launcher's marker file must be left untouched."""
    store_home = Path(fake_env["env"]["AR_STATE_ROOT"]) / "home"
    models = store_home / ".pi" / "agent" / "models.json"
    models.parent.mkdir(parents=True, exist_ok=True)
    models.write_text('{"providers": {}}')

    result = launch(fake_env, ["--docker", "--tool", "pi"])
    assert result.returncode == 0, result.stderr + result.stdout
    assert models.exists()
    assert models.read_text() == '{"providers": {}}'


def test_gitconfig_copied_not_mounted(fake_env):
    gitconfig = Path(fake_env["env"]["HOME"]) / ".gitconfig"
    gitconfig.write_text("[user]\n\tname = Test\n")
    result = launch(fake_env, ["--docker"])
    assert result.returncode == 0, result.stderr + result.stdout

    copied = Path(fake_env["env"]["AR_STATE_ROOT"]) / "home" / ".gitconfig"
    assert copied.exists()
    assert "name = Test" in copied.read_text()
    # must be a copy, not a bind mount
    assert ".gitconfig" not in " ".join(logged_args(fake_env))


def test_extra_env_forwarded(fake_env):
    env = dict(fake_env["env"])
    env["AR_EXTRA_ENV"] = "HF_TOKEN=hf_abc|WANDB_API_KEY=wb_xyz"
    fake_env["env"] = env
    result = launch(fake_env, ["--docker"])
    assert result.returncode == 0, result.stderr + result.stdout
    args = logged_args(fake_env)
    assert "HF_TOKEN=hf_abc" in args
    assert "WANDB_API_KEY=wb_xyz" in args


def test_test_mode_mounts_sandbox_script(fake_env):
    result = launch(fake_env, ["--docker", "--test"])
    assert result.returncode == 0, result.stderr + result.stdout
    args = logged_args(fake_env)
    assert any(a.endswith("test_sandbox.sh:/test_sandbox.sh:ro") for a in args)
    assert "AR_ENTRYPOINT=bash" in args
    assert "/test_sandbox.sh" in args


def test_ephemeral_store_created_and_removed(fake_env, tmp_path):
    env = dict(fake_env["env"])
    env["TMPDIR"] = str(tmp_path / "tmpdir")
    os.makedirs(env["TMPDIR"], exist_ok=True)
    del env["AR_STATE_ROOT"]
    fake_env["env"] = env

    result = launch(fake_env, ["--docker", "--ephemeral", "--tool", "bash"])
    assert result.returncode == 0, result.stderr + result.stdout
    assert "(ephemeral)" in result.stdout
    assert "Removed ephemeral store" in result.stderr + result.stdout
    leftovers = list(Path(env["TMPDIR"]).glob("agentic-researcher-store-*"))
    assert leftovers == []
