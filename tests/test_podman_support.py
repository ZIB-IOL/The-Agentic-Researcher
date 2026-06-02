import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
AGENTIC_RESEARCHER = REPO_ROOT / "agentic-researcher"
BUILD_SCRIPT = REPO_ROOT / "container" / "build.sh"
INSTALL_SCRIPT = REPO_ROOT / "scripts" / "install.sh"
FIRST_SETUP_SCRIPT = REPO_ROOT / "scripts" / "first-setup.sh"
CLEANUP_SCRIPT = REPO_ROOT / "scripts" / "cleanup.sh"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


@pytest.fixture
def fake_bin(tmp_path: Path) -> Path:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()

    make_executable(
        bin_dir / "podman",
        "#!/bin/sh\n"
        "printf 'env:https_proxy=%s http_proxy=%s\\n' \"${https_proxy-}\" \"${http_proxy-}\" >> \"${FAKE_PODMAN_LOG:?}\"\n"
        "printf 'cmd:%s %s\\n' \"$0\" \"$*\" >> \"${FAKE_PODMAN_LOG:?}\"\n",
    )
    make_executable(
        bin_dir / "docker",
        "#!/bin/sh\n"
        "printf 'cmd:%s %s\\n' \"$0\" \"$*\" >> \"${FAKE_DOCKER_LOG:?}\"\n",
    )

    real_git = shutil.which("git")
    if real_git is None:
        raise RuntimeError("git is required for tests")
    make_executable(
        bin_dir / "git",
        "#!/bin/sh\n"
        "for arg in \"$@\"; do\n"
        "  if [ \"$arg\" = rev-parse ]; then\n"
        "    printf 'deadbeef\\n'\n"
        "    exit 0\n"
        "  fi\n"
        "done\n"
        f"exec {shlex_quote(real_git)} \"$@\"\n",
    )
    return bin_dir


@pytest.fixture
def base_env(fake_bin: Path, tmp_path: Path) -> dict[str, str]:
    env = os.environ.copy()
    filtered_path = [
        d for d in env["PATH"].split(":")
        if not (Path(d) / "docker").exists()
    ]
    env["PATH"] = f"{fake_bin}:{':'.join(filtered_path)}"
    env["FAKE_PODMAN_LOG"] = str(tmp_path / "podman.log")
    env["FAKE_DOCKER_LOG"] = str(tmp_path / "docker.log")
    env["HOME"] = str(tmp_path / "home")
    Path(env["HOME"]).mkdir(parents=True, exist_ok=True)
    return env


def shlex_quote(text: str) -> str:
    return "'" + text.replace("'", "'\"'\"'") + "'"


def run(command: list[str], env: dict[str, str], **kwargs) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        **kwargs,
    )


def read_log(path: str) -> str:
    log_path = Path(path)
    if not log_path.exists():
        return ""
    return log_path.read_text()


def write_xdg_config(xdg_config_home: Path, content: str) -> Path:
    config_dir = xdg_config_home / "agentic-researcher"
    config_dir.mkdir(parents=True, exist_ok=True)
    config_path = config_dir / "config.sh"
    config_path.write_text(content)
    return config_path


def test_build_script_uses_podman_for_podman_runtime(base_env: dict[str, str]) -> None:
    result = run([str(BUILD_SCRIPT), "--podman"], base_env)

    assert result.returncode == 0
    assert "Building Podman container" in result.stdout
    assert "Podman image built" in result.stdout
    podman_log = read_log(base_env["FAKE_PODMAN_LOG"])
    assert "cmd:" in podman_log
    assert "build --format docker -t agentic-researcher:latest" in podman_log
    assert read_log(base_env["FAKE_DOCKER_LOG"]) == ""


def test_build_script_reads_xdg_config_for_proxy(base_env: dict[str, str], tmp_path: Path) -> None:
    xdg_config_home = tmp_path / "xdg-config"
    write_xdg_config(
        xdg_config_home,
        'AR_HTTPS_PROXY="http://proxy.example:3128"\nAR_HTTP_PROXY="http://proxy.example:3128"\n',
    )

    result = run(
        [str(BUILD_SCRIPT), "--podman"],
        {**base_env, "XDG_CONFIG_HOME": str(xdg_config_home)},
    )

    assert result.returncode == 0
    podman_log = read_log(base_env["FAKE_PODMAN_LOG"])
    assert "env:https_proxy=http://proxy.example:3128 http_proxy=http://proxy.example:3128" in podman_log


def test_launcher_apply_defaults_keeps_real_auth_defaults(base_env: dict[str, str]) -> None:
    result = run(
        [str(AGENTIC_RESEARCHER), "--help"],
        {**base_env, "AR_CLI_TOOL": "claude"},
    )

    assert result.returncode == 0
    launcher_text = AGENTIC_RESEARCHER.read_text()
    assert 'AR_AUTH_MODE="${AR_AUTH_MODE:-oauth}"' in launcher_text
    assert 'AR_API_KEY_ENV="${AR_API_KEY_ENV:-ANTHROPIC_API_KEY}"' in launcher_text
    assert 'AR_AUTH_MODE="${AR_AUTH_MODE:-tool}"' in launcher_text


def test_setup_opencode_reads_api_key_from_configured_env_var(base_env: dict[str, str], tmp_path: Path) -> None:
    launcher_text = AGENTIC_RESEARCHER.read_text()
    assert 'local api_key_var="${AR_API_KEY_ENV:-OPENAI_API_KEY}"' in launcher_text
    assert 'local api_key="${!api_key_var:-}"' in launcher_text


def test_build_env_args_uses_env_args_for_apptainer_key_forwarding(base_env: dict[str, str]) -> None:
    launcher_text = AGENTIC_RESEARCHER.read_text()
    assert 'ENV_ARGS+=(--env "${anthropic_key_name}=${!_ar_key_var}")' in launcher_text


def test_install_help_mentions_xdg_config_path(base_env: dict[str, str]) -> None:
    result = run([str(INSTALL_SCRIPT), "--help"], base_env)

    assert result.returncode == 0
    assert "${XDG_CONFIG_HOME:-$HOME/.config}/agentic-researcher/config.sh" in result.stdout


def test_setup_writes_config_to_xdg_config_home(base_env: dict[str, str], tmp_path: Path) -> None:
    xdg_config_home = tmp_path / "xdg-config"
    result = run(
        [str(FIRST_SETUP_SCRIPT)],
        {**base_env, "XDG_CONFIG_HOME": str(xdg_config_home)},
        input="1\n1\n\n\n\n\n",
    )

    assert result.returncode == 0
    assert (xdg_config_home / "agentic-researcher" / "config.sh").exists()
    assert not (Path(base_env["HOME"]) / ".config" / "agentic-researcher" / "config.sh").exists()


def test_cleanup_uses_xdg_config_path(base_env: dict[str, str], tmp_path: Path) -> None:
    xdg_config_home = tmp_path / "xdg-config"
    state_root = tmp_path / "state-root"
    state_root.mkdir()
    config_path = write_xdg_config(
        xdg_config_home,
        f'AR_STATE_ROOT="{state_root}"\n',
    )

    result = run(
        [str(CLEANUP_SCRIPT), "--include-config", "--yes"],
        {**base_env, "XDG_CONFIG_HOME": str(xdg_config_home)},
    )

    assert result.returncode == 0
    assert not config_path.exists()
    assert not state_root.exists()


def test_install_script_accepts_podman_runtime(base_env: dict[str, str], tmp_path: Path) -> None:
    install_dir = tmp_path / "install"
    bin_dir = tmp_path / "launcher-bin"
    config_dir = tmp_path / "config"

    result = run(
        [
            str(INSTALL_SCRIPT),
            "--install-dir",
            str(install_dir),
            "--bin-dir",
            str(bin_dir),
            "--runtime",
            "podman",
            "--write-config",
            "--build",
            "--force",
        ],
        {**base_env, "XDG_CONFIG_HOME": str(config_dir)},
    )

    assert result.returncode == 0
    assert (bin_dir / "agentic-researcher").is_symlink()
    config_text = (config_dir / "agentic-researcher" / "config.sh").read_text()
    assert 'AR_CONTAINER_RUNTIME="podman"' in config_text
    assert "build --format docker -t agentic-researcher:latest" in read_log(base_env["FAKE_PODMAN_LOG"])
    assert read_log(base_env["FAKE_DOCKER_LOG"]) == ""


def test_launcher_builds_with_podman_flag(base_env: dict[str, str]) -> None:
    result = run([str(AGENTIC_RESEARCHER), "--podman", "--build"], base_env)

    assert result.returncode == 0
    assert "Building Podman container" in result.stdout
    assert "build --format docker -t agentic-researcher:latest" in read_log(base_env["FAKE_PODMAN_LOG"])
    assert read_log(base_env["FAKE_DOCKER_LOG"]) == ""


def test_launcher_auto_detects_podman_for_build_when_docker_is_absent(
    base_env: dict[str, str], fake_bin: Path
) -> None:
    (fake_bin / "docker").unlink()

    result = run([str(AGENTIC_RESEARCHER), "--build"], base_env)

    assert result.returncode == 0
    assert "Docker not found, falling back to Podman." in result.stdout
    assert "Building Podman container" in result.stdout
    assert "build --format docker -t agentic-researcher:latest" in read_log(base_env["FAKE_PODMAN_LOG"])
    assert read_log(base_env["FAKE_DOCKER_LOG"]) == ""


def test_launcher_podman_test_mode_overrides_entrypoint(base_env: dict[str, str]) -> None:
    result = run([str(AGENTIC_RESEARCHER), "--podman", "--tool", "codex", "--test"], base_env)

    assert result.returncode == 0
    podman_log = read_log(base_env["FAKE_PODMAN_LOG"])
    assert "run --rm" in podman_log
    assert "-it" not in podman_log
    assert "--userns keep-id" in podman_log
    assert ":/claude-home" in podman_log
    assert "--entrypoint /bin/bash" in podman_log
    assert "/test_sandbox.sh" in podman_log


def test_install_script_auto_detects_podman_when_docker_is_absent(
    base_env: dict[str, str], fake_bin: Path, tmp_path: Path
) -> None:
    (fake_bin / "docker").unlink()
    install_dir = tmp_path / "install-auto"
    bin_dir = tmp_path / "launcher-bin-auto"
    config_dir = tmp_path / "config-auto"

    result = run(
        [
            str(INSTALL_SCRIPT),
            "--install-dir",
            str(install_dir),
            "--bin-dir",
            str(bin_dir),
            "--write-config",
            "--build",
            "--force",
        ],
        {**base_env, "XDG_CONFIG_HOME": str(config_dir)},
    )

    assert result.returncode == 0
    config_text = (config_dir / "agentic-researcher" / "config.sh").read_text()
    assert 'AR_CONTAINER_RUNTIME="podman"' in config_text
    assert "Docker not found, falling back to Podman." in result.stdout
    assert "Building Podman container" in result.stdout
    assert "build --format docker -t agentic-researcher:latest" in read_log(base_env["FAKE_PODMAN_LOG"])
    assert read_log(base_env["FAKE_DOCKER_LOG"]) == ""


# ── pi (@earendil-works/pi-coding-agent) tool support ────────────────────

def test_launcher_podman_runs_pi_tool(base_env: dict[str, str], tmp_path: Path) -> None:
    workspace = tmp_path / "ws"
    workspace.mkdir()

    result = run(
        [str(AGENTIC_RESEARCHER), "--podman", "--tool", "pi", str(workspace)],
        base_env,
    )

    assert result.returncode == 0
    assert "Starting pi" in result.stdout
    podman_log = read_log(base_env["FAKE_PODMAN_LOG"])
    assert "run --rm" in podman_log
    assert "SANDBOX_TOOL=pi" in podman_log
    # pi reads AGENTS.md; the launcher must seed it into the workspace.
    assert (workspace / "AGENTS.md").exists()
    # pi auto-discovers project skills under .agents/skills/ (same as Codex).
    for skill in ("setup_research_plan", "retro", "update_base"):
        assert (workspace / ".agents" / "skills" / skill / "SKILL.md").exists()
    assert read_log(base_env["FAKE_DOCKER_LOG"]) == ""


def test_pi_translates_resume_to_session_and_warns_on_yolo(
    base_env: dict[str, str], tmp_path: Path
) -> None:
    workspace = tmp_path / "ws"
    workspace.mkdir()

    result = run(
        [
            str(AGENTIC_RESEARCHER),
            "--podman",
            "--tool",
            "pi",
            "--debug-launch",
            "--resume",
            "ABC123",
            "--yolo",
            str(workspace),
        ],
        base_env,
    )

    assert result.returncode == 0
    # pi has no bare --resume ID; it maps to --session ID.
    assert "--session ABC123" in result.stdout
    # --debug-launch enables pi's verbose startup.
    assert "--verbose" in result.stdout
    # pi has no permission system, so --yolo is a no-op with a warning.
    assert "--yolo has no effect in pi mode" in result.stdout


def test_pi_apptainer_bind_and_config_store_wiring() -> None:
    launcher_text = AGENTIC_RESEARCHER.read_text()
    # Apptainer path binds the host pi config dir (~/.pi) into the sandbox.
    assert 'BIND_ARGS+=(--bind "$PI_STATE_DIR:/claude-home/.pi")' in launcher_text
    assert 'PI_STATE_DIR="$HOME/.pi"' in launcher_text
    # Docker/Podman path seeds the per-tool dir inside the single config store.
    assert '"$AR_CONFIG_STORE/.pi/agent"' in launcher_text
    # pi uses AGENTS.md as its instruction file.
    assert "opencode|codex|pi)" in launcher_text
    # pi shares Codex's project-skill setup (rendered into .agents/skills/).
    assert '"$AR_CLI_TOOL" == "codex" || "$AR_CLI_TOOL" == "pi"' in launcher_text
