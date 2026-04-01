#!/bin/bash
#
# dispatcher.sh: Host-side daemon that watches for job requests from the
# containerized agent and dispatches them to remote nodes via srun + apptainer.
#
# Started by the agentic-researcher launcher (--multi-node) before launching
# the container. Killed automatically when the container exits.
#
# Usage: dispatcher.sh <dispatch-config-file>
#

# No set -e: this is a long-running daemon, we handle errors explicitly.
# No set -u: glob expansions and associative array lookups can trigger false failures.

CONFIG_FILE="${1:?Usage: dispatcher.sh <dispatch-config-file>}"

# Load config (written by the launcher)
source "$CONFIG_FILE"

JOBS_DIR="$DISPATCH_DIR/jobs"
mkdir -p "$JOBS_DIR"

# Write node list for the agent
scontrol show hostnames "$SLURM_JOB_NODELIST" > "$DISPATCH_DIR/nodes.txt"
echo "$HEAD_NODE" > "$DISPATCH_DIR/head_node.txt"

log() {
    echo "[dispatcher $(date +%H:%M:%S)] $*" >> "$DISPATCH_DIR/dispatcher.log"
}

log "Started. Config: $CONFIG_FILE"
log "Nodes: $(cat "$DISPATCH_DIR/nodes.txt" | tr '\n' ' ')"
log "Head node: $HEAD_NODE"
log "Container: $CONTAINER_IMAGE"

# Build the base apptainer bind-mount arguments for remote containers.
# Remote containers need workspace, scratch, and caches — but NOT Claude config,
# SSH keys, or the dispatch directory itself.
build_apptainer_args() {
    local args=(
        --nv
        --no-mount home
        --home /claude-home
        --bind "$WORKSPACE_HOST:/workspace"
        --bind "$UV_CACHE_DIR:/uv-cache"
        --bind "$UV_PYTHON_INSTALL_DIR:/uv-python"
        --bind "$UV_TOOL_DIR:/uv-tools"
        --bind "$STATE_ROOT:$STATE_ROOT"
        --pwd /workspace
        --env UV_CACHE_DIR=/uv-cache
        --env UV_PYTHON_INSTALL_DIR=/uv-python
        --env UV_TOOL_DIR=/uv-tools
        --env UV_LINK_MODE=symlink
        --env "HF_HOME=$HF_HOME"
        --env "TRITON_CACHE_DIR=$TRITON_CACHE_DIR"
        --env "WANDB_DIR=$WANDB_DIR"
        --env "TERM=${TERM:-xterm-256color}"
    )

    # Proxy
    if [[ -n "${HTTPS_PROXY:-}" ]]; then
        args+=(--env "https_proxy=$HTTPS_PROXY" --env "http_proxy=${HTTP_PROXY:-$HTTPS_PROXY}")
    fi

    # Bind /scratch/local if available on remote node
    if [[ -d /scratch/local ]]; then
        args+=(--bind /scratch/local:/scratch/local)
    fi

    echo "${args[@]}"
}

APPTAINER_ARGS=$(build_apptainer_args)
log "Apptainer args built OK"

run_job() {
    local job_file="$1"
    local job_id
    job_id=$(basename "$job_file" .job)
    local job_base="$JOBS_DIR/$job_id"

    # Read job specification
    local remote_node="" remote_gpus="" remote_cmd="" remote_workdir="/workspace"
    source "$job_file"
    # Variables set by sourcing: REMOTE_NODE, REMOTE_GPUS, REMOTE_CMD, REMOTE_WORKDIR (optional)
    remote_node="${REMOTE_NODE:-}"
    remote_gpus="${REMOTE_GPUS:-4}"
    remote_cmd="${REMOTE_CMD:-}"
    remote_workdir="${REMOTE_WORKDIR:-/workspace}"

    if [[ -z "$remote_node" || -z "$remote_cmd" ]]; then
        log "Job $job_id: INVALID (missing REMOTE_NODE or REMOTE_CMD)"
        echo "failed:invalid" > "$job_base.status"
        return
    fi

    log "Job $job_id: node=$remote_node gpus=$remote_gpus cmd='$remote_cmd'"

    # Mark as running (write PID after launch)
    echo "running" > "$job_base.status"

    # Dispatch via srun + apptainer on the remote node
    srun --overlap --nodes=1 --ntasks=1 \
        --nodelist="$remote_node" \
        --gres="gpu:$remote_gpus" --cpu-bind=none \
        apptainer exec \
        $APPTAINER_ARGS \
        --pwd "$remote_workdir" \
        "$CONTAINER_IMAGE" \
        bash -c "cd $remote_workdir && $remote_cmd" \
        > "$job_base.stdout" \
        2> "$job_base.stderr" &

    local srun_pid=$!
    echo "$srun_pid" > "$job_base.pid"
    log "Job $job_id: launched (pid=$srun_pid)"

    # Wait for completion in background
    (
        wait "$srun_pid" 2>/dev/null
        exit_code=$?
        echo "done:$exit_code" > "$job_base.status"
        log "Job $job_id: finished (exit=$exit_code)"
    ) &
}

# Track which jobs we've already processed
declare -A SEEN_JOBS

log "Entering main loop"

# Main loop: poll for new .job files
while true; do
    # Check for new jobs
    for job_file in "$JOBS_DIR"/*.job; do
        [[ -f "$job_file" ]] || continue
        job_id=$(basename "$job_file" .job)
        # Skip already-seen jobs
        [[ -n "${SEEN_JOBS[$job_id]:-}" ]] && continue
        SEEN_JOBS[$job_id]=1
        run_job "$job_file"
    done

    # Check for kill requests
    for kill_file in "$JOBS_DIR"/*.kill; do
        [[ -f "$kill_file" ]] || continue
        kill_pid=$(cat "$kill_file")
        kill_job_id=$(basename "$kill_file" .kill)
        log "Kill request for job $kill_job_id (pid=$kill_pid)"
        kill "$kill_pid" 2>/dev/null && log "Killed pid $kill_pid" || log "pid $kill_pid already dead"
        echo "killed" > "$JOBS_DIR/$kill_job_id.status"
        rm -f "$kill_file"
    done

    sleep 1
done
