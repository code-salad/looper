# syntax=docker/dockerfile:1.7

# Base: Ubuntu 24.04 LTS (matches CI runners: blacksmith-*-ubuntu-2404).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH="/root/.cargo/bin:/root/.local/bin:/usr/local/bin:/usr/bin:/bin"

# Core OS packages — pinned to apt (stable, reproducible per Ubuntu release).
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        gh \
        jq \
        curl \
        ca-certificates \
        build-essential \
        pkg-config \
        libssl-dev \
        python3 \
        python3-pip \
        python3-venv \
        unzip \
        xz-utils \
        ripgrep \
    && rm -rf /var/lib/apt/lists/*

# Node.js LTS (20.x) via NodeSource — the current Ubuntu 24.04 apt Node is 18.x.
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g npm@latest pnpm yarn

# Rust stable via rustup (non-interactive).
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --default-toolchain stable --profile minimal \
    && /root/.cargo/bin/rustup component add clippy rustfmt

# Docker CLI (client only — no daemon).
# The container talks to the HOST daemon via a bind-mounted
# /var/run/docker.sock (DooD). This lets compose-isolate /
# compose-lifecycle spawn sibling containers from inside the sandbox.
# No daemon ever runs in this image.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         docker.io \
         docker-compose-v2 \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI (official install script).
RUN curl -fsSL https://claude.ai/install.sh | bash

# Pre-install the looper plugin at the well-known path.
# ARG LOOPER_REF=alpha allows the release workflow to pass LOOPER_REF=v<version>
# so the baked plugin matches the release tag.
ARG LOOPER_REF=alpha
RUN mkdir -p /root/.claude/plugins \
    && git clone --depth 1 --branch "${LOOPER_REF}" \
        https://github.com/code-salad/looper.git /tmp/looper \
    && cp -r /tmp/looper/plugins/looper /root/.claude/plugins/looper \
    && chmod -R +x /root/.claude/plugins/looper/skills/looper/scripts \
    && rm -rf /tmp/looper

WORKDIR /workspace

# Sanity check — all critical binaries resolve.
RUN command -v git \
    && command -v gh \
    && command -v jq \
    && command -v claude \
    && command -v node \
    && command -v python3 \
    && command -v cargo \
    && command -v docker

CMD ["/bin/bash"]
