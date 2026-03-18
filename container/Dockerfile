FROM ubuntu:22.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive
ENV LC_ALL=C.UTF-8
ENV LANG=C.UTF-8

# Basic setup + CLI utilities
RUN apt-get update && apt-get install -y \
        --no-install-recommends \
        curl \
        git \
        git-lfs \
        ca-certificates \
        build-essential \
        gosu \
        jq \
        ripgrep \
        chktex \
        python3 \
        unzip \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
        amd64) node_arch="x64" ;; \
        arm64) node_arch="arm64" ;; \
        *) echo "Unsupported architecture for Node.js: $arch" >&2; exit 1 ;; \
    esac \
    && node_version="$(curl -fsSL https://nodejs.org/dist/index.json | jq -r --arg node_arch "$node_arch" 'map(select(.files | index("linux-" + $node_arch))) | .[0].version')" \
    && curl -fsSL "https://nodejs.org/dist/${node_version}/node-${node_version}-linux-${node_arch}.tar.xz" -o /tmp/node.tar.xz \
    && mkdir -p /opt/node \
    && tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1 \
    && ln -sf /opt/node/bin/node /usr/local/bin/node \
    && ln -sf /opt/node/bin/npm /usr/local/bin/npm \
    && ln -sf /opt/node/bin/npx /usr/local/bin/npx \
    && rm -f /tmp/node.tar.xz

RUN curl -fsSL https://install.julialang.org | sh -s -- --yes --path /opt/juliaup \
    && ln -sf /opt/juliaup/bin/julia /usr/local/bin/julia \
    && ln -sf /opt/juliaup/bin/juliaup /usr/local/bin/juliaup

RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
        amd64) yq_arch="amd64" ;; \
        arm64) yq_arch="arm64" ;; \
        *) echo "Unsupported architecture for yq: $arch" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}" -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
        amd64) gh_arch="amd64" ;; \
        arm64) gh_arch="arm64" ;; \
        *) echo "Unsupported architecture for gh: $arch" >&2; exit 1 ;; \
    esac \
    && gh_version="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r '.tag_name | ltrimstr("v")')" \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${gh_version}/gh_${gh_version}_linux_${gh_arch}.tar.gz" -o /tmp/gh.tar.gz \
    && tar -xzf /tmp/gh.tar.gz -C /tmp \
    && install -m 0755 "/tmp/gh_${gh_version}_linux_${gh_arch}/bin/gh" /usr/local/bin/gh \
    && rm -rf /tmp/gh.tar.gz "/tmp/gh_${gh_version}_linux_${gh_arch}"

RUN curl -LsSf https://astral.sh/uv/install.sh \
    | env UV_UNMANAGED_INSTALL="/usr/local/bin" sh

RUN curl -fsSL https://bun.sh/install | bash \
    && install -m 0755 /root/.bun/bin/bun /usr/local/bin/bun

RUN npm install -g \
        "@anthropic-ai/claude-code" \
        "opencode-ai" \
        "@google/gemini-cli" \
        "@openai/codex" \
    && npm cache clean --force

ENV PATH="/opt/node/bin:/usr/local/bin:$PATH"

# Create home directory for container
RUN mkdir -p /claude-home
ENV HOME=/claude-home

WORKDIR /workspace

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
