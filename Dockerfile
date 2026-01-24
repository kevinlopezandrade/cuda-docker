# CUDA + Ubuntu development container for agentbox
#
# Build targets:
#   standard - Full dev environment with git (default)
#   secure   - Git completely removed (for lockdown mode)
#
# Usage:
#   docker build --target standard -t cuda-dev:standard .
#   docker build --target secure -t cuda-dev:secure .

ARG CUDA_VERSION=12.8.1
ARG UBUNTU_VERSION=24.04
ARG BASE_IMAGE=nvcr.io/nvidia/cuda:${CUDA_VERSION}-cudnn-devel-ubuntu${UBUNTU_VERSION}

FROM ${BASE_IMAGE} AS base

# Robust shell for RUN commands
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Build-time variables
ARG DEBIAN_FRONTEND=noninteractive

# Core environment
ENV TZ=Europe/Zurich \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    CUDA_HOME=/usr/local/cuda

# System packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        # --- essentials / networking ---
        ca-certificates \
        curl \
        wget \
        git \
        git-lfs \
        net-tools \
        # --- Python + build toolchain ---
        python3 \
        python3-dev \
        python3-pip \
        python3-venv \
        build-essential \
        cmake \
        ninja-build \
        pkg-config \
        # --- CLI + dev tools ---
        jq \
        htop \
        tmux \
        vim \
        less \
        ripgrep \
        fd-find \
        fzf \
        tree \
        unzip \
        zip \
        zsh \
        stow \
        nvtop \
        tini \
        gosu \
    && git lfs install --system \
    && rm -rf /var/lib/apt/lists/*

# fd-find uses 'fdfind' binary; many people expect 'fd'
RUN ln -s /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true

# Install Claude Code (installs to $HOME/.local/bin/claude, copy to /usr/local/bin)
RUN curl -fsSL https://claude.ai/install.sh | bash && \
    install -m 0755 /root/.local/bin/claude /usr/local/bin/claude

# Install Codex CLI (same location as Claude)
RUN set -eux; \
    curl -fsSL -o /tmp/codex.tar.gz \
        https://github.com/openai/codex/releases/latest/download/codex-x86_64-unknown-linux-musl.tar.gz; \
    tar -xzf /tmp/codex.tar.gz -C /tmp; \
    install -m 0755 /tmp/codex-x86_64-unknown-linux-musl /usr/local/bin/codex; \
    rm -f /tmp/codex.tar.gz /tmp/codex-x86_64-unknown-linux-musl

# Install uv (fast Python package manager)
ADD https://astral.sh/uv/install.sh /uv-installer.sh
RUN sh /uv-installer.sh && rm /uv-installer.sh && \
    install -m 0755 /root/.local/bin/uv /usr/local/bin/uv

# Silence bell (noop afplay for tools that expect macOS)
RUN echo '#!/bin/sh' > /usr/local/bin/afplay && chmod +x /usr/local/bin/afplay

# Add ~/.local/bin to PATH for all login shells (Claude Code, uv, etc. install there)
RUN echo 'export PATH="$HOME/.local/bin:$PATH"' > /etc/profile.d/local-bin.sh

# Environment for tools
ENV UV_PYTHON_PREFERENCE=managed \
    EDITOR=vim

# Entrypoint script handles user home directory creation and privilege dropping
COPY agentbox/docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Use tini as init (signal handling, zombie reaping), then our entrypoint
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

# No healthcheck needed (interactive container)
HEALTHCHECK NONE

# ==========================================
# STAGE: STANDARD (Full dev image with git)
# ==========================================
FROM base AS standard

# Git policy wrapper - intercepts git commands and enforces agentbox policies
# Placed at /usr/local/bin/git which takes precedence over /usr/bin/git in PATH
# Behavior controlled by AGENT_ALLOW_COMMIT env var (0=block commits, 1=allow)
COPY agentbox/bin/git /usr/local/bin/git
RUN chmod +x /usr/local/bin/git

CMD ["bash", "-l"]


# ==========================================
# STAGE: SECURE (Git completely removed)
# ==========================================
FROM standard AS secure

# Remove git entirely
RUN apt-get update && \
    apt-get -y purge git git-lfs && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/*

# Stub scripts with clear error messages
RUN set -eux; \
    for cmd in git git-lfs gh; do \
        printf '#!/bin/sh\necho "ERROR: %s is disabled in this container (secure mode)" >&2\nexit 127\n' "$cmd" \
            > "/usr/local/bin/$cmd"; \
        chmod +x "/usr/local/bin/$cmd"; \
    done

# Prevent reinstallation via apt
RUN mkdir -p /etc/apt/preferences.d && \
    printf 'Package: git*\nPin: release *\nPin-Priority: -1\n' \
        > /etc/apt/preferences.d/deny-git

CMD ["bash", "-l"]
