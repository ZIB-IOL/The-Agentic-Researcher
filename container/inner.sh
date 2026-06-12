#!/usr/bin/env bash
#
# inner.sh: Container entrypoint for agentic-researcher (v2).
#
# Runs inside the container launched by the `agentic-researcher` host script.
# Converges the persistent store (/ar-store) toward a known set of tools on
# every start, configures the environment, and exec's the requested CLI.
#
# There is no custom image: the container starts from a stock base image and
# everything (CLI tools, runtimes, utilities) is installed into /ar-store,
# which is a bind mount of the host state root. Installs survive container
# exits; the container itself is throwaway.
#
# Required env vars (passed by the launcher):
#   AR_ENTRYPOINT   - what to exec (claude|gemini|opencode|codex|qwen|pi|bash)
#   AR_TOOL_PATHS   - colon-separated tool bin directories
#   HOME            - /ar-store/home
#   NPM_CONFIG_CACHE, NPM_CONFIG_PREFIX, UV_CACHE_DIR, JULIAUP_DEPOT_PATH
# Optional:
#   AR_UPDATE       - auto (default) | never
#   AR_UPDATE_TTL   - version cache TTL in seconds (default 21600 = 6h)
#   AR_NO_COOLDOWN  - comma-separated tool labels exempt from the 7-day gate
#   AR_GPU          - 1 when running on a CUDA base image
#   AR_UID, AR_GID  - host uid/gid for the privilege drop (Linux Docker only)
#   AR_TERMINFO_B64 - host terminal's terminfo entry (base64)
#   AR_CUSTOM_ENDPOINT - OpenAI-compatible base URL (codex provider config)
set -euo pipefail

STORE=/ar-store

# ---------------------------------------------------------------------------
# Startup timing - prints elapsed time for each setup phase
# ---------------------------------------------------------------------------
_step_start=$(date +%s%N 2>/dev/null || date +%s)
_boot_start=$_step_start
step() {
  local now label="$1"
  now=$(date +%s%N 2>/dev/null || date +%s)
  if [[ ${#now} -gt 10 ]]; then
    local elapsed_ms=$(( (now - _step_start) / 1000000 ))
    printf "[agentic-researcher] %-40s %4d.%03ds\n" "$label" $((elapsed_ms / 1000)) $((elapsed_ms % 1000)) >&2
  else
    local elapsed=$(( now - _step_start ))
    printf "[agentic-researcher] %-40s %ds\n" "$label" "$elapsed" >&2
  fi
  _step_start=$now
}

log() { echo "[agentic-researcher] $*" >&2; }

# ---------------------------------------------------------------------------
# Store layout
# ---------------------------------------------------------------------------
mkdir -p \
  "$HOME" \
  "$HOME/.codex" \
  "$HOME/.config/uv" \
  "$NPM_CONFIG_CACHE" \
  "$NPM_CONFIG_PREFIX" \
  "$STORE/bin" \
  "$STORE/lib" \
  "$STORE/bun" \
  "$STORE/uv" \
  "$STORE/uv/cache" \
  "$STORE/juliaup" \
  "$STORE/julia" \
  "$STORE/hf_home" \
  "$STORE/triton_cache" \
  "$STORE/wandb"

step "init store dirs"

# ---------------------------------------------------------------------------
# Supply-chain hardening: minimum release age for package managers.
# Packages must be published for >=7 days before they can be installed,
# giving security scanners time to flag malicious releases. npm additionally
# blocks post-install scripts (the primary npm attack vector); our own tool
# installs opt back in per-command for trusted packages.
# ---------------------------------------------------------------------------
cat > "$HOME/.npmrc" <<'EOF'
min-release-age=7
ignore-scripts=true
EOF

cat > "$HOME/.bunfig.toml" <<'EOF'
[install]
minimumReleaseAge = 604800
EOF

cat > "$HOME/.config/uv/uv.toml" <<'EOF'
exclude-newer = "7 days"
EOF

step "package manager config"

# ---------------------------------------------------------------------------
# Terminal support: install the host terminal's terminfo if unknown here
# (handles non-standard terminals like ghostty, kitty, wezterm).
# ---------------------------------------------------------------------------
if [[ -n "${AR_TERMINFO_B64:-}" ]] && ! infocmp "${TERM:-}" >/dev/null 2>&1; then
  echo "$AR_TERMINFO_B64" | base64 -d | tic -x - 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Base image bootstrap. The default image (node:24-bookworm) ships node, curl,
# git. GPU images (nvidia/cuda:*) ship none of those, so install the
# essentials first (requires CAP_CHOWN, which the launcher adds in GPU mode).
# ---------------------------------------------------------------------------
if [[ "${AR_GPU:-0}" == "1" ]]; then
  if ! command -v curl >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    log "Installing essential tools (curl, wget, git, unzip, ca-certificates)..."
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq curl wget git unzip ca-certificates >/dev/null 2>&1 || true
    if command -v curl >/dev/null 2>&1; then
      log "Essential tools installed"
    else
      log "Warning: could not install essential tools"
    fi
  fi
fi

# Install Node.js into the store if the image doesn't provide it
if [[ ! -x "$(command -v node || true)" ]]; then
  log "Installing Node.js 20..."
  node_arch=$(uname -m)
  case "$node_arch" in
    x86_64) node_arch="x64" ;;
    aarch64) node_arch="arm64" ;;
  esac
  node_version="20.18.1"
  node_dir="$STORE/nodejs"
  mkdir -p "$node_dir"
  node_url="https://nodejs.org/dist/v${node_version}/node-v${node_version}-linux-${node_arch}.tar.gz"
  set +e
  curl -fsSL "$node_url" | tar -xz --strip-components=1 -C "$node_dir" 2>&1
  install_status=$?
  set -e
  if [[ $install_status -eq 0 ]] && [[ -x "$node_dir/bin/node" ]]; then
    export PATH="$node_dir/bin:$PATH"
    log "Node.js $("$node_dir/bin/node" --version) installed"
  else
    log "Warning: Node.js installation failed (status $install_status)"
  fi
fi

# chktex (LaTeX linter): extracted from the Debian .deb because apt-get is
# unavailable under --cap-drop=ALL. Version pinned; bump when needed.
if [[ ! -x "$STORE/bin/chktex" ]]; then
  log "Installing chktex..."
  _chktex_arch="$(uname -m)"
  [[ "$_chktex_arch" == "x86_64" ]] && _chktex_arch="amd64"
  [[ "$_chktex_arch" == "aarch64" ]] && _chktex_arch="arm64"
  _chktex_tmp=$(mktemp -d)
  (
    cd "$_chktex_tmp" && \
    curl -fsSL "http://deb.debian.org/debian/pool/main/c/chktex/chktex_1.7.8-1_${_chktex_arch}.deb" -o chktex.deb 2>/dev/null && \
    ar x chktex.deb && \
    tar xf data.tar.* && \
    cp usr/bin/chktex "$STORE/bin/" && \
    chmod +x "$STORE/bin/chktex"
  ) || log "Warning: chktex install failed"
  rm -rf "$_chktex_tmp"
fi

step "runtime bootstrap (node, terminfo, gpu)"

# ---------------------------------------------------------------------------
# Codex configuration. Regenerated on every start (not patched) so settings
# stay in sync when switching auth modes.
#   - sandbox_mode "danger-full-access": codex's internal sandbox is redundant
#     inside the container sandbox and conflicts with /ar-store permissions.
#   - custom provider: only when AR_CUSTOM_ENDPOINT is set; key comes from the
#     AR_CUSTOM_API_KEY env var (never written to disk).
# ---------------------------------------------------------------------------
codex_config="$HOME/.codex/config.toml"
{
  echo 'sandbox_mode = "danger-full-access"'
  echo ""
  if [[ -n "${AR_CUSTOM_ENDPOINT:-}" ]]; then
    echo 'model_provider = "custom"'
    echo ""
    echo '[model_providers.custom]'
    echo 'name = "Custom"'
    echo "base_url = \"${AR_CUSTOM_ENDPOINT}\""
    echo 'env_key = "AR_CUSTOM_API_KEY"'
    echo ""
  fi
  echo '[shell_environment_policy]'
  echo 'inherit = "all"'
} > "$codex_config"

# ---------------------------------------------------------------------------
# Shell profiles. Codex spawns login shells that source /etc/profile, which
# overwrites PATH; ~/.profile restores it. Overwritten on every start to
# prevent accumulation of stale entries.
# ---------------------------------------------------------------------------
cat > "$HOME/.profile" <<PROFILE_EOF
# agentic-researcher: add store tools to PATH (codex spawns login shells)
export PATH="$AR_TOOL_PATHS:\$PATH"
export LD_LIBRARY_PATH="$STORE/lib:\${LD_LIBRARY_PATH:-}"
[ -f ~/.bashrc ] && . ~/.bashrc
PROFILE_EOF
cat > "$HOME/.bashrc" <<PROFILE_EOF
# agentic-researcher: add store tools to PATH
export PATH="$AR_TOOL_PATHS:\$PATH"
export LD_LIBRARY_PATH="$STORE/lib:\${LD_LIBRARY_PATH:-}"
PROFILE_EOF

export PATH="$AR_TOOL_PATHS:$PATH"
# Shared libraries extracted alongside .deb binaries (e.g. libpopt for rsync)
# live in the store; LD_LIBRARY_PATH avoids needing root for ldconfig.
export LD_LIBRARY_PATH="$STORE/lib:${LD_LIBRARY_PATH:-}"

step "codex/shell config"

# ---------------------------------------------------------------------------
# Version cache: reduces GitHub/npm API calls by caching "latest version"
# lookups in the store with a TTL (default 6h).
# NOTE: version lookups run in subshells, so results are collected in a temp
# file - in-memory arrays don't survive subshell boundaries.
# ---------------------------------------------------------------------------
_LOCKFILE="$STORE/.tool-versions"
_LOCKFILE_TTL="${AR_UPDATE_TTL:-21600}"
declare -A _VERSION_CACHE
declare -A _VERSION_PREFETCHED
_CACHE_FRESH=0
_CACHE_ENTRIES=$(mktemp)

# npm package name -> short label (used by AR_NO_COOLDOWN)
declare -A _NPM_PKG_LABELS=(
  ["npm"]="npm"
  ["@google/gemini-cli"]="gemini"
  ["opencode-ai"]="opencode"
  ["@openai/codex"]="codex"
  ["@qwen-code/qwen-code"]="qwen"
  ["@earendil-works/pi-coding-agent"]="pi"
)

_label_no_cooldown() {
  local label="$1"
  local list=",${AR_NO_COOLDOWN:-},"
  [[ "$list" == *",${label},"* ]]
}

_load_version_cache() {
  [[ -f "$_LOCKFILE" ]] || return 1
  local last_check=""
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    [[ "$key" == "__last_check" ]] && last_check="$value" && continue
    _VERSION_CACHE["$key"]="$value"
  done < "$_LOCKFILE"
  [[ -z "$last_check" ]] && return 1
  local now; now=$(date +%s)
  (( now - last_check < _LOCKFILE_TTL ))
}

_save_version_cache() {
  local tmp; tmp=$(mktemp "$_LOCKFILE.XXXXXX")
  echo "# Auto-generated by agentic-researcher - do not edit" > "$tmp"
  echo "__last_check=$(date +%s)" >> "$tmp"
  cat "$_CACHE_ENTRIES" >> "$tmp" 2>/dev/null || true
  mv "$tmp" "$_LOCKFILE"
  rm -f "$_CACHE_ENTRIES"
}

normalize_arch() {
  case "$(uname -m)" in
    x86_64) echo "amd64" ;;
    aarch64) echo "arm64" ;;
    *) uname -m ;;
  esac
}

# Get latest GitHub release version. Usage: github_latest_version owner/repo [strip_prefix]
github_latest_version() {
  local repo="$1" strip="${2:-v}"
  local _ck="gh:${repo}"
  if [[ "$_CACHE_FRESH" -eq 1 ]] && [[ -n "${_VERSION_CACHE[$_ck]:-}" ]]; then
    echo "${_VERSION_CACHE[$_ck]}"; return
  fi
  local _result; _result=$(curl -fsSL --connect-timeout 5 --max-time 15 \
    "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | \
    node -e "
      let d='';
      process.stdin.on('data',c=>d+=c);
      process.stdin.on('end',()=>{
        try{
          let v=JSON.parse(d).tag_name;
          let strip=process.argv[1];
          if(strip) v=v.replace(new RegExp('^'+strip),'');
          console.log(v);
        }catch(e){}
      });
    " "$strip" || true)
  [[ -n "$_result" ]] && echo "${_ck}=${_result}" >> "$_CACHE_ENTRIES"
  echo "$_result"
}

# Generic binary installer.
# Usage: ensure_binary name bin_path version_cmd github_repo url_template [post_install] [strip_prefix] [extract_dir]
# url_template placeholders: {version}, {arch} (amd64/arm64), {raw_arch} (x86_64/aarch64), {os}
ensure_binary() {
  [[ "${AR_UPDATE:-auto}" == "never" ]] && return 0

  local name="$1" bin_path="$2" version_cmd="$3"
  local repo="$4" url_template="$5" post_install="${6:-}"
  local strip_prefix="${7:-v}" extract_dir="${8:-}"

  local cur="" latest=""
  [[ -x "$bin_path" ]] && cur=$(eval "$version_cmd" 2>/dev/null || true)
  latest=$(github_latest_version "$repo" "$strip_prefix")

  [[ -z "$latest" ]] && { log "Warning: could not determine latest $name version"; return 0; }

  # Skip if installed is already at or newer than "latest"
  if [[ -n "$cur" ]] && [[ "$cur" != "$latest" ]]; then
    local newest
    newest=$(printf '%s\n%s\n' "$cur" "$latest" | sort -V | tail -1)
    [[ "$newest" != "$latest" ]] && return 0
  fi

  if [[ -z "$cur" ]] || [[ "$cur" != "$latest" ]]; then
    [[ -z "$cur" ]] && log "Installing $name (v${latest})" \
                    || log "Updating $name: ${cur} -> ${latest}"

    local arch raw_arch os url
    arch=$(normalize_arch)
    raw_arch=$(uname -m)
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    url=$(echo "$url_template" | sed "s/{version}/$latest/g; s/{arch}/$arch/g; s/{raw_arch}/$raw_arch/g; s/{os}/$os/g")

    mkdir -p "$(dirname "$bin_path")"
    if [[ "$url" == *.tar.gz ]] || [[ "$url" == *.tgz ]]; then
      local tmp_dir; tmp_dir=$(mktemp -d)
      curl -fsSL "$url" | tar xz --no-same-owner -C "$tmp_dir" 2>/dev/null || true
      if [[ -n "$extract_dir" ]]; then
        # Multi-binary package: copy all executables to extract_dir.
        # Remove before copy to avoid "text file busy" on running binaries.
        mkdir -p "$extract_dir"
        find "$tmp_dir" -type f -perm -111 -print0 | while IFS= read -r -d '' src; do
          local dst="$extract_dir/$(basename "$src")"
          rm -f "$dst" 2>/dev/null || true
          cp "$src" "$dst" 2>/dev/null || true
        done
        chmod +x "$extract_dir"/* 2>/dev/null || true
      else
        rm -f "$bin_path" 2>/dev/null || true
        find "$tmp_dir" -name "$name" -type f -exec cp {} "$bin_path" \; 2>/dev/null || \
          find "$tmp_dir" -name "${name}*" -type f -perm -111 -exec cp {} "$bin_path" \; 2>/dev/null || true
      fi
      rm -rf "$tmp_dir"
    else
      curl -fsSL "$url" -o "$bin_path" 2>/dev/null || true
    fi
    chmod +x "$bin_path" 2>/dev/null || true

    [[ -n "$post_install" ]] && eval "$post_install" 2>/dev/null || true

    local after=""
    [[ -x "$bin_path" ]] && after=$(eval "$version_cmd" 2>/dev/null || true)
    if [[ "$after" != "$latest" ]]; then
      log "Warning: $name update to v${latest} may have failed (installed: ${after:-none})"
    fi
  fi
}

installed_version() {
  local pkg="$1"
  # Read version directly from package.json - much faster than `npm ls`
  local pkg_json="$NPM_CONFIG_PREFIX/lib/node_modules/$pkg/package.json"
  [[ -f "$pkg_json" ]] || { echo ""; return 0; }
  jq -r '.version // ""' "$pkg_json" 2>/dev/null || echo ""
}

latest_version() {
  local pkg="$1"
  local _ck="npm:${pkg}"
  local _label="${_NPM_PKG_LABELS[$pkg]:-}"
  local _no_cooldown=0
  if [[ -n "$_label" ]] && _label_no_cooldown "$_label"; then
    _no_cooldown=1
  fi
  # Fast paths: (a) fetched in this run, (b) disk cache is fresh. Skipped for
  # no-cooldown packages - the cached value was computed with the 7-day filter.
  if [[ "$_no_cooldown" -eq 0 ]]; then
    if [[ -n "${_VERSION_PREFETCHED[$_ck]:-}" ]] && [[ -n "${_VERSION_CACHE[$_ck]:-}" ]]; then
      echo "${_VERSION_CACHE[$_ck]}"; return
    fi
    if [[ "$_CACHE_FRESH" -eq 1 ]] && [[ -n "${_VERSION_CACHE[$_ck]:-}" ]]; then
      echo "${_VERSION_CACHE[$_ck]}"; return
    fi
  fi
  local _min_age_ms=$(( 7 * 86400 * 1000 ))
  if [[ "$_no_cooldown" -eq 1 ]]; then
    _min_age_ms=0
  fi
  local _result; _result=$(node -e "
    const {execSync} = require('child_process');
    const pkg = process.argv[1];
    const minAge = parseInt(process.argv[2], 10);
    const now = Date.now();
    try {
      const times = JSON.parse(execSync('npm view --fetch-timeout=5000 ' + pkg + ' time --json', {encoding:'utf8',stdio:['ignore','pipe','ignore'],timeout:8000}));
      let best = '', bestTime = 0;
      for (const [ver, ts] of Object.entries(times)) {
        if (ver === 'modified' || ver === 'created' || /-/.test(ver)) continue;
        const t = new Date(ts).getTime();
        if ((now - t) >= minAge && t > bestTime) { best = ver; bestTime = t; }
      }
      process.stdout.write(best);
    } catch(e) { process.stdout.write(''); }
  " "$pkg" "$_min_age_ms" 2>/dev/null || true)
  if [[ -z "$_result" ]] && [[ -n "${_VERSION_CACHE[$_ck]:-}" ]]; then
    log "Warning: npm view timed out for $pkg, using cached version"
    _result="${_VERSION_CACHE[$_ck]}"
  fi
  [[ -n "$_result" ]] && echo "${_ck}=${_result}" >> "$_CACHE_ENTRIES"
  echo "$_result"
}

# Pre-fetch npm package versions in parallel when the cache is stale.
prefetch_npm_versions() {
  [[ "${AR_UPDATE:-auto}" == "never" ]] && return 0
  [[ "$_CACHE_FRESH" -eq 1 ]] && return 0
  local pkgs=("npm" "@google/gemini-cli" "opencode-ai" "@openai/codex" "@qwen-code/qwen-code" "@earendil-works/pi-coding-agent")
  for pkg in "${pkgs[@]}"; do
    latest_version "$pkg" >/dev/null &
  done
  wait
  if [[ -f "$_CACHE_ENTRIES" ]]; then
    while IFS='=' read -r key value; do
      if [[ -n "$key" ]]; then
        _VERSION_CACHE["$key"]="$value"
        _VERSION_PREFETCHED["$key"]=1
      fi
    done < "$_CACHE_ENTRIES"
  fi
}

ensure_pkg_latest() {
  local pkg="$1"
  local label="$2"

  if [[ "${AR_UPDATE:-auto}" == "never" ]]; then
    return 0
  fi

  local cur latest
  cur="$(installed_version "$pkg")"
  latest="$(latest_version "$pkg")"

  if [[ -z "$latest" ]]; then
    log "Warning: could not determine latest version for $pkg (skipping update check)"
    return 0
  fi

  # Clean up stale npm temp directories that cause ENOTEMPTY errors
  local base_name="${pkg##*/}"
  if [[ "$pkg" == @*/* ]]; then
    local scope="${pkg%/*}"
    rm -rf "$NPM_CONFIG_PREFIX/lib/node_modules/${scope}/.${base_name}"-* 2>/dev/null || true
  else
    rm -rf "$NPM_CONFIG_PREFIX/lib/node_modules/.${base_name}"-* 2>/dev/null || true
  fi

  # Bypass the 7-day gate for packages listed in AR_NO_COOLDOWN
  local min_age_flag=""
  if _label_no_cooldown "$label"; then
    min_age_flag="--min-release-age=0"
    log "${label}: no-cooldown active (cur=${cur:-none}, latest=${latest})"
  fi

  if [[ -z "$cur" ]]; then
    log "Installing ${label}..."
    npm install -g --ignore-scripts=false ${min_age_flag} "${pkg}@latest" \
      || log "Warning: ${label} install failed (continuing startup)"
    local after; after="$(installed_version "$pkg")"
    if [[ -n "$after" ]]; then
      log "Installed ${label} v${after}"
    else
      log "Warning: ${label} install may have failed"
    fi
  elif [[ "$cur" != "$latest" ]]; then
    # Skip if installed is already at or newer than "latest"
    local newest
    newest=$(printf '%s\n%s\n' "$cur" "$latest" | sort -V | tail -1)
    if [[ "$newest" != "$latest" ]]; then
      return 0
    fi
    log "Updating ${label}: ${cur} -> ${latest}..."
    npm install -g --ignore-scripts=false ${min_age_flag} "${pkg}@latest" \
      || log "Warning: ${label} update failed (continuing startup)"
    local after; after="$(installed_version "$pkg")"
    if [[ -n "$after" ]] && [[ "$after" != "$cur" ]]; then
      log "Updated ${label}: ${cur} -> ${after}"
    elif [[ -n "$after" ]]; then
      log "${label} install ran but version unchanged (still ${after})"
    fi
  fi
}

ensure_claude_native() {
  # Claude Code native installer -> $HOME/.local/bin/claude.
  # The container always sets DISABLE_AUTOUPDATER=1: Claude Code's native
  # auto-updater has a known race when multiple containers share an install
  # (anthropics/claude-code#19063, #28847, #13213). Updates run here instead,
  # gated on the version cache.
  local claude_bin="$HOME/.local/bin/claude"

  if [[ -x "$claude_bin" ]]; then
    if [[ "${AR_UPDATE:-auto}" != "never" ]] && [[ "$_CACHE_FRESH" -eq 0 ]]; then
      local _before _after
      _before=$("$claude_bin" --version 2>/dev/null | awk '{print $1}' || true)
      log "Checking Claude Code updates (current: ${_before:-unknown})"
      "$claude_bin" update >/dev/null 2>&1 || true
      _after=$("$claude_bin" --version 2>/dev/null | awk '{print $1}' || true)
      if [[ -n "$_after" ]] && [[ "$_before" != "$_after" ]]; then
        log "Updated Claude Code: ${_before} -> ${_after}"
      else
        log "Claude Code up to date (${_after:-$_before})"
      fi
    fi
    return 0
  fi

  log "Installing Claude Code (native installer)"
  curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1 || true

  if [[ -x "$claude_bin" ]]; then
    log "Claude Code installed successfully"
  else
    log "Warning: Claude Code native install may have failed, falling back to npm"
    npm install -g --ignore-scripts=false "@anthropic-ai/claude-code@latest" >/dev/null 2>&1 || true
  fi
}

ensure_bun_latest() {
  [[ "${AR_UPDATE:-auto}" == "never" ]] && return 0

  local bun_bin="$STORE/bun/bin/bun"
  local cur="" latest=""
  [[ -x "$bun_bin" ]] && cur=$("$bun_bin" --version 2>/dev/null || true)
  latest=$(github_latest_version "oven-sh/bun" "bun-v")

  [[ -z "$latest" ]] && { log "Warning: could not determine latest bun version"; return 0; }

  if [[ -n "$cur" ]] && [[ "$cur" != "$latest" ]]; then
    local newest
    newest=$(printf '%s\n%s\n' "$cur" "$latest" | sort -V | tail -1)
    [[ "$newest" != "$latest" ]] && return 0
  fi

  if [[ -z "$cur" ]] || [[ "$cur" != "$latest" ]]; then
    [[ -z "$cur" ]] && log "Installing bun (v${latest})" \
                    || log "Updating bun: ${cur} -> ${latest}"
    curl -fsSL https://bun.sh/install | BUN_INSTALL="$STORE/bun" bash -s "bun-v${latest}" >/dev/null 2>&1 || true

    local after=""
    [[ -x "$bun_bin" ]] && after=$("$bun_bin" --version 2>/dev/null || true)
    if [[ "$after" != "$latest" ]]; then
      log "Warning: bun update to v${latest} may have failed (installed: ${after:-none})"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Install / update tools
# ---------------------------------------------------------------------------

_load_version_cache && _CACHE_FRESH=1
[[ "$_CACHE_FRESH" -eq 1 ]] && log "Using cached version info ($(( _LOCKFILE_TTL / 3600 ))h TTL)"

prefetch_npm_versions
step "npm prefetch"

# npm itself first (min-release-age requires npm >= 11.10.0; base image has 10.x)
ensure_pkg_latest "npm" "npm"
step "npm check"

ensure_pkg_latest "@google/gemini-cli" "gemini"
ensure_pkg_latest "opencode-ai" "opencode"
ensure_pkg_latest "@openai/codex" "codex"
ensure_pkg_latest "@qwen-code/qwen-code" "qwen"
ensure_pkg_latest "@earendil-works/pi-coding-agent" "pi"
step "npm packages (gemini/opencode/codex/qwen/pi)"

ensure_claude_native
step "claude native"
ensure_bun_latest
step "bun"

# uv: multi-binary (uv + uvx), no v-prefix on tags
ensure_binary "uv" "$STORE/uv/bin/uv" \
  "$STORE/uv/bin/uv --version | awk '{print \$2}'" \
  "astral-sh/uv" \
  "https://github.com/astral-sh/uv/releases/download/{version}/uv-{raw_arch}-unknown-linux-gnu.tar.gz" \
  "" "" "$STORE/uv/bin"

# juliaup: multi-binary (juliaup + julia), v-prefixed tags
ensure_binary "juliaup" "$STORE/juliaup/bin/juliaup" \
  "$STORE/juliaup/bin/juliaup --version | awk '{print \$2}'" \
  "JuliaLang/juliaup" \
  "https://github.com/JuliaLang/juliaup/releases/download/v{version}/juliaup-{version}-{raw_arch}-unknown-linux-musl-portable.tar.gz" \
  "" "v" "$STORE/juliaup/bin"

step "binaries (uv/juliaup)"

# Install/update Julia via juliaup
if [[ -x "$STORE/juliaup/bin/juliaup" ]] && [[ "${AR_UPDATE:-auto}" != "never" ]]; then
  if ! "$STORE/juliaup/bin/juliaup" status 2>/dev/null | grep -q 'release'; then
    log "Installing Julia (release channel)"
    "$STORE/juliaup/bin/juliaup" add release >/dev/null 2>&1 || true
  fi
  # Julia distribution updates only when the cache is stale (slowest step)
  if [[ "$_CACHE_FRESH" -eq 0 ]]; then
    "$STORE/juliaup/bin/juliaup" update >/dev/null 2>&1 || true
  fi
fi
step "julia update"

# jq: jq- prefixed version tags
ensure_binary "jq" "$STORE/bin/jq" \
  "$STORE/bin/jq --version | sed 's/^jq-//'" \
  "jqlang/jq" \
  "https://github.com/jqlang/jq/releases/download/jq-{version}/jq-{os}-{arch}" \
  "" "jq-"

# yq: standard v-prefixed version
ensure_binary "yq" "$STORE/bin/yq" \
  "$STORE/bin/yq --version | awk '{print \$NF}' | sed 's/^v//'" \
  "mikefarah/yq" \
  "https://github.com/mikefarah/yq/releases/download/v{version}/yq_{os}_{arch}"

# gh: GitHub CLI
ensure_binary "gh" "$STORE/bin/gh" \
  "$STORE/bin/gh --version | head -1 | awk '{print \$3}'" \
  "cli/cli" \
  "https://github.com/cli/cli/releases/download/v{version}/gh_{version}_linux_{arch}.tar.gz"

# git-lfs: with post-install to configure git
ensure_binary "git-lfs" "$STORE/bin/git-lfs" \
  "$STORE/bin/git-lfs --version | awk '{print \$1}' | sed 's|git-lfs/||'" \
  "git-lfs/git-lfs" \
  "https://github.com/git-lfs/git-lfs/releases/download/v{version}/git-lfs-{os}-{arch}-v{version}.tar.gz" \
  "$STORE/bin/git-lfs install --skip-smudge"

# ripgrep: arch-specific target (musl for x86_64 portability, gnu for aarch64)
_rg_target="x86_64-unknown-linux-musl"
[[ "$(uname -m)" == "aarch64" ]] && _rg_target="aarch64-unknown-linux-gnu"
ensure_binary "rg" "$STORE/bin/rg" \
  "$STORE/bin/rg --version | head -1 | awk '{print \$2}'" \
  "BurntSushi/ripgrep" \
  "https://github.com/BurntSushi/ripgrep/releases/download/{version}/ripgrep-{version}-${_rg_target}.tar.gz" \
  "" ""

step "binaries (jq/yq/gh/git-lfs/rg)"

# Re-register git-lfs filters on every start: the launcher refreshes
# ~/.gitconfig from the host copy at launch, which wipes the [filter "lfs"]
# section written by a previous `git lfs install`. Idempotent and cheap.
if [[ -x "$STORE/bin/git-lfs" ]] && command -v git >/dev/null 2>&1; then
  "$STORE/bin/git-lfs" install --skip-smudge >/dev/null 2>&1 || true
fi

# rsync: extracted from Debian bookworm's .deb (includes security backports for
# CVE-2024-12084..12088). libpopt0 (the only missing dep) is extracted to
# $STORE/lib and resolved via LD_LIBRARY_PATH (no root / ldconfig needed).
# Hardcoded versions; bump when bookworm publishes a newer security update.
_rsync_dpkg_arch="$(uname -m)"
_rsync_lib_triple=""
case "$_rsync_dpkg_arch" in
  x86_64)  _rsync_dpkg_arch="amd64"; _rsync_lib_triple="x86_64-linux-gnu" ;;
  aarch64) _rsync_dpkg_arch="arm64"; _rsync_lib_triple="aarch64-linux-gnu" ;;
esac
if [[ -n "$_rsync_lib_triple" ]] && [[ ! -x "$STORE/bin/rsync" || ! -e "$STORE/lib/libpopt.so.0" ]]; then
  log "Installing rsync (Debian 3.2.7-1+deb12u5)..."
  _rsync_tmp=$(mktemp -d)
  (
    cd "$_rsync_tmp" && \
    curl -fsSL "http://security.debian.org/debian-security/pool/updates/main/r/rsync/rsync_3.2.7-1+deb12u5_${_rsync_dpkg_arch}.deb" -o rsync.deb 2>/dev/null && \
    ar x rsync.deb && tar xf data.tar.xz && \
    cp usr/bin/rsync "$STORE/bin/rsync" && chmod +x "$STORE/bin/rsync" && \
    rm -rf usr data.tar* control.tar* debian-binary && \
    curl -fsSL "http://deb.debian.org/debian/pool/main/p/popt/libpopt0_1.19+dfsg-1_${_rsync_dpkg_arch}.deb" -o popt.deb 2>/dev/null && \
    ar x popt.deb && tar xf data.tar.xz && \
    cp "usr/lib/${_rsync_lib_triple}/libpopt.so.0.0.2" "$STORE/lib/libpopt.so.0"
  ) || log "Warning: rsync install failed"
  rm -rf "$_rsync_tmp"
fi
step "rsync"

# tmux: static binary (asset naming doesn't match ensure_binary conventions)
if [[ "${AR_UPDATE:-auto}" != "never" ]]; then
_tmux_cur=""; [[ -x "$STORE/bin/tmux" ]] && _tmux_cur=$("$STORE/bin/tmux" -V 2>/dev/null | awk '{print $2}' || true)
_tmux_ver=$(github_latest_version "pythops/tmux-linux-binary" "v")
if [[ -n "$_tmux_ver" ]] && [[ "$_tmux_cur" != "$_tmux_ver" ]]; then
  [[ -z "$_tmux_cur" ]] && log "Installing tmux (v${_tmux_ver})" \
                        || log "Updating tmux: ${_tmux_cur} -> ${_tmux_ver}"
  _tmux_arch="$(uname -m)"
  [[ "$_tmux_arch" == "aarch64" ]] && _tmux_arch="arm64"
  { curl -fsSL "https://github.com/pythops/tmux-linux-binary/releases/download/v${_tmux_ver}/tmux-linux-${_tmux_arch}" \
    -o "$STORE/bin/tmux" 2>/dev/null && chmod +x "$STORE/bin/tmux"; } \
    || log "Warning: tmux install failed"
fi
fi
step "tmux"

# micro: text editor (asset naming doesn't match ensure_binary conventions)
if [[ "${AR_UPDATE:-auto}" != "never" ]]; then
_micro_cur=""; [[ -x "$STORE/bin/micro" ]] && _micro_cur=$("$STORE/bin/micro" --version 2>/dev/null | head -1 | awk '{print $2}' || true)
_micro_ver=$(github_latest_version "micro-editor/micro" "v")
if [[ -n "$_micro_ver" ]] && [[ "$_micro_cur" != "$_micro_ver" ]]; then
  [[ -z "$_micro_cur" ]] && log "Installing micro (v${_micro_ver})" \
                         || log "Updating micro: ${_micro_cur} -> ${_micro_ver}"
  _micro_arch="linux64"
  [[ "$(uname -m)" == "aarch64" ]] && _micro_arch="linux-arm64"
  _micro_tmp=$(mktemp -d)
  curl -fsSL "https://github.com/micro-editor/micro/releases/download/v${_micro_ver}/micro-${_micro_ver}-${_micro_arch}.tar.gz" \
    | tar xz --no-same-owner -C "$_micro_tmp" 2>/dev/null || true
  find "$_micro_tmp" -name "micro" -type f -exec cp {} "$STORE/bin/micro" \; 2>/dev/null || true
  chmod +x "$STORE/bin/micro" 2>/dev/null || log "Warning: micro install failed"
  rm -rf "$_micro_tmp"
fi
fi
export EDITOR=micro
step "micro"

# Save version cache (only when fresh lookups were made)
[[ "$_CACHE_FRESH" -eq 0 ]] && [[ "${AR_UPDATE:-auto}" != "never" ]] && _save_version_cache

# ---------------------------------------------------------------------------
# Privilege drop. With Docker on Linux the container starts as root so setup
# can write the store; the actual CLI runs as the host user (AR_UID/AR_GID)
# so files created in /workspace have correct ownership. With rootless Podman
# (--userns keep-id) or any non-root runtime, the script already runs as the
# host user and this is a no-op - the same path keeps the script compatible
# with user-namespace runtimes (e.g. a future Apptainer backend).
# ---------------------------------------------------------------------------
run_as_user() {
  if [[ "$(id -u)" == "0" ]] && [[ -n "${AR_UID:-}" ]] && [[ -n "${AR_GID:-}" ]] \
     && [[ "$AR_UID" != "0" ]]; then
    # Ensure the tool can write to the store (configs created by root above)
    chown -R "$AR_UID:$AR_GID" "$STORE" 2>/dev/null || true
    exec setpriv --reuid="$AR_UID" --regid="$AR_GID" --clear-groups -- "$@"
  fi
  exec "$@"
}

# Deduplicate PATH (profiles and tool installers accumulate duplicate entries)
PATH=$(printf '%s' "$PATH" | awk -v RS=: -v ORS=: '!seen[$0]++' | sed 's/:$//')
export PATH

# Print total boot time
_now=$(date +%s%N 2>/dev/null || date +%s)
if [[ ${#_now} -gt 10 ]]; then
  _total_ms=$(( (_now - _boot_start) / 1000000 ))
  printf "[agentic-researcher] %-40s %4d.%03ds\n" "TOTAL" $((_total_ms / 1000)) $((_total_ms % 1000)) >&2
else
  printf "[agentic-researcher] %-40s %ds\n" "TOTAL" $(( _now - _boot_start )) >&2
fi

# ---------------------------------------------------------------------------
# Exec the requested entrypoint (absolute paths preferred)
# ---------------------------------------------------------------------------
ep="${AR_ENTRYPOINT:-bash}"
if [[ "$ep" == "bash" ]]; then
  run_as_user /bin/bash "$@"
fi
if [[ "$ep" == "claude" && -x "$HOME/.local/bin/claude" ]]; then
  run_as_user "$HOME/.local/bin/claude" "$@"
fi
if [[ -x "$NPM_CONFIG_PREFIX/bin/$ep" ]]; then
  run_as_user "$NPM_CONFIG_PREFIX/bin/$ep" "$@"
fi
run_as_user "$ep" "$@"
