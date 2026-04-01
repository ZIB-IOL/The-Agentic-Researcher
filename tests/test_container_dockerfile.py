from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DOCKERFILE = REPO_ROOT / "container" / "Dockerfile"


def test_dockerfile_pins_julia_tarball_install_to_known_version() -> None:
    dockerfile = DOCKERFILE.read_text()

    assert "JULIA_VERSION=1.12.4" in dockerfile
    assert "juliaup" not in dockerfile
    assert "https://julialang-s3.julialang.org/bin/linux/${julia_dir_arch}/${JULIA_VERSION%.*}/julia-${JULIA_VERSION}-linux-${julia_arch}.tar.gz" in dockerfile
    assert 'ln -sf "/opt/julia-${JULIA_VERSION}/bin/julia" /usr/local/bin/julia' in dockerfile
