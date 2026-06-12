# TODO

## Runtime / platform

- [ ] Apptainer runtime support on top of the persistent-store model.
      The container entrypoint (`container/inner.sh`) is already non-root
      tolerant (skips chown/setpriv when uid != 0), but Apptainer needs:
      launch path in `agentic-researcher`, pty handling
      (`scripts/pty-wrapper.py`), and cluster testing. (`agentic-researcher`,
      `container/inner.sh`)
- [ ] Re-enable multi-node Slurm dispatch once Apptainer support lands.
      `scripts/dispatcher.sh`, `scripts/remote-run`, and
      `scripts/pty-wrapper.py` are kept in-tree but are currently gated off
      (`--multi-node` errors out). (`scripts/dispatcher.sh`)
- [ ] GPU passthrough for Podman (currently Docker-only; consider CDI
      `--device nvidia.com/gpu=all`). (`agentic-researcher`)
- [ ] HPC ephemeral-store UX: document cold-install cost (~minutes per job),
      consider store seeding/snapshotting from a warm store. (`README.md`)

## Features

- [ ] Revisit codex custom-endpoint workarounds (WebSocket transport, remote
      compaction) if gateway/proxy issues surface; v1 of ai-box needed
      `supports_websockets = false` and `remote_compaction = false` for
      LiteLLM. (`container/inner.sh`)
- [ ] Consider optional model discovery for opencode/pi custom endpoints
      (querying `/models`); currently static templates only by design.
      (`config/*.template.json`)

## Testing

- [ ] Extend the v2 test suite: containerized integration tests (launch with
      a fake runtime, assert mount/env/cap flags), inner.sh function-level
      tests (version cache, cooldown gating). Requires a host with a
      container runtime. (`tests/`)
- [ ] End-to-end smoke test on macOS (Docker Desktop) and rootless Podman
      (`--userns keep-id` file ownership in the store). (`tests/`)
