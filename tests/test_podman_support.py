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
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
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


def write_xdg_config(env: dict[str, str], xdg_config_home: Path, content: str) -> Path:
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
        base_env,
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
        base_env,
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
