import os
import stat
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
AGENTIC_RESEARCHER = REPO_ROOT / "agentic-researcher"
BUILD_SCRIPT = REPO_ROOT / "container" / "build.sh"
INSTALL_SCRIPT = REPO_ROOT / "scripts" / "install.sh"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


@pytest.fixture
def fake_bin(tmp_path: Path) -> Path:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    make_executable(
        bin_dir / "podman",
        "#!/bin/sh\nprintf '%s\n' \"$0 $*\" >> \"${FAKE_PODMAN_LOG:?}\"\n",
    )
    make_executable(
        bin_dir / "docker",
        "#!/bin/sh\nprintf '%s\n' \"$0 $*\" >> \"${FAKE_DOCKER_LOG:?}\"\n",
    )
    make_executable(
        bin_dir / "git",
        "#!/bin/sh\nif [ \"$1\" = rev-parse ]; then\n  printf 'deadbeef\n'\n  exit 0\nfi\nexec /usr/bin/git \"$@\"\n",
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


def read_log(path: str) -> str:
    log_path = Path(path)
    if not log_path.exists():
        return ""
    return log_path.read_text()


def test_build_script_uses_podman_for_podman_runtime(base_env: dict[str, str]) -> None:
    result = subprocess.run(
        [str(BUILD_SCRIPT), "--podman"],
        cwd=REPO_ROOT,
        env=base_env,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0
    assert "Building Podman container" in result.stdout
    assert "Podman image built" in result.stdout
    assert "build -t agentic-researcher:latest" in read_log(base_env["FAKE_PODMAN_LOG"])
    assert read_log(base_env["FAKE_DOCKER_LOG"]) == ""


def test_install_script_accepts_podman_runtime(base_env: dict[str, str], tmp_path: Path) -> None:
    install_dir = tmp_path / "install"
    bin_dir = tmp_path / "launcher-bin"
    config_dir = tmp_path / "config"

    result = subprocess.run(
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
        cwd=REPO_ROOT,
        env={**base_env, "XDG_CONFIG_HOME": str(config_dir)},
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0
    assert (bin_dir / "agentic-researcher").is_symlink()
    config_text = (config_dir / "agentic-researcher" / "config.sh").read_text()
    assert 'AR_CONTAINER_RUNTIME="podman"' in config_text
    assert "build -t agentic-researcher:latest" in read_log(base_env["FAKE_PODMAN_LOG"])
    assert read_log(base_env["FAKE_DOCKER_LOG"]) == ""


def test_launcher_builds_with_podman_flag(base_env: dict[str, str]) -> None:
    result = subprocess.run(
        [str(AGENTIC_RESEARCHER), "--podman", "--build"],
        cwd=REPO_ROOT,
        env=base_env,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0
    assert "Building Podman container" in result.stdout
    assert "build -t agentic-researcher:latest" in read_log(base_env["FAKE_PODMAN_LOG"])
    assert read_log(base_env["FAKE_DOCKER_LOG"]) == ""


def test_launcher_auto_detects_podman_for_build_when_docker_is_absent(
    base_env: dict[str, str], fake_bin: Path
) -> None:
    (fake_bin / "docker").unlink()

    result = subprocess.run(
        [str(AGENTIC_RESEARCHER), "--build"],
        cwd=REPO_ROOT,
        env=base_env,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0
    assert "Docker not found, falling back to Podman." in result.stdout
    assert "Building Podman container" in result.stdout
    assert "build -t agentic-researcher:latest" in read_log(base_env["FAKE_PODMAN_LOG"])
    assert read_log(base_env["FAKE_DOCKER_LOG"]) == ""


def test_install_script_auto_detects_podman_when_docker_is_absent(
    base_env: dict[str, str], fake_bin: Path, tmp_path: Path
) -> None:
    (fake_bin / "docker").unlink()
    install_dir = tmp_path / "install-auto"
    bin_dir = tmp_path / "launcher-bin-auto"
    config_dir = tmp_path / "config-auto"

    result = subprocess.run(
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
        cwd=REPO_ROOT,
        env={**base_env, "XDG_CONFIG_HOME": str(config_dir)},
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0
    config_text = (config_dir / "agentic-researcher" / "config.sh").read_text()
    assert 'AR_CONTAINER_RUNTIME="podman"' in config_text
    assert "Docker not found, falling back to Podman." in result.stdout
    assert "Building Podman container" in result.stdout
    assert "build -t agentic-researcher:latest" in read_log(base_env["FAKE_PODMAN_LOG"])
    assert read_log(base_env["FAKE_DOCKER_LOG"]) == ""
