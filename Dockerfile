# CUDA + Ubuntu base
ARG CUDA_VERSION=12.8.1
ARG UBUNTU_VERSION=24.04
ARG BASE_IMAGE=nvcr.io/nvidia/cuda:${CUDA_VERSION}-cudnn-devel-ubuntu${UBUNTU_VERSION}
ARG DEBIAN_FRONTEND=noninteractive

FROM ${BASE_IMAGE} AS base

# More robust shell for RUN commands
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Core environment
ENV TZ=Europe/Zurich \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

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
        curl \
        # --- Python + build toolchain ---
        python3 \
        python3-dev \
        python3-pip \
        python3-venv \
        build-essential \
        cmake \
        ninja-build \
        pkg-config \
        # --- CLI + dev QoL tools (optional, but nice) ---
        apt-utils \
        # software-properties-common (Add extra PPA repos) \
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
    && git lfs install --system \
    && rm -rf /var/lib/apt/lists/*

# fd-find uses 'fdfind' binary; many people expect 'fd'
RUN ln -s /usr/bin/fdfind /usr/local/bin/fd || true

# CUDA Location
ENV CUDA_HOME=/usr/local/cuda

# GIT Defense
# Dont' allow to push or pull from the internet.
RUN git config --system protocol.file.allow always \
 && git config --system protocol.http.allow never \
 && git config --system protocol.https.allow never \
 && git config --system protocol.ssh.allow never \
 && git config --system protocol.git.allow never

RUN git config --global user.email "kevin@tufalabs.ai"
RUN git config --global user.name "Kev"

# Install Node.js LTS (22.x) from NodeSource
RUN set -eux; \
    ARCH=$(dpkg --print-architecture); \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -rf /var/lib/apt/lists/*

# Install Codex CLI from npm
RUN set -eux; \
    npm install -g @openai/codex \
    npm cache clean --force

# Install uv
ADD https://astral.sh/uv/install.sh /uv-installer.sh
RUN sh /uv-installer.sh && rm /uv-installer.sh; \
    install -m 0755 /root/.local/bin/uv /usr/local/bin/uv

# Optional: avoid noisy bells; provide a simple notifier noop
RUN set -eux; echo '#!/bin/sh' > /usr/local/bin/afplay && chmod +x /usr/local/bin/afplay

# Create a non-root user for development
ARG USERNAME=dev
ARG UID=1001
ARG GID=1001

RUN groupadd -g "${GID}" "${USERNAME}" && \
    useradd -m -u "${UID}" -g "${GID}" -s /usr/bin/zsh "${USERNAME}"

ENV CODEX_HOME=/home/"${USERNAME}"/.codex \
    NODE_OPTIONS=--unhandled-rejections=strict \
    UV_LINK_MODE=copy \
    UV_PYTHON_PREFERENCE=managed

# Default workdir

USER "${USERNAME}"
WORKDIR /workspace

# Healthcheck is a no-op (Codex runs via exec)
HEALTHCHECK NONE

# Use tini as init to handle signals/zombies correctly
ENTRYPOINT ["/usr/bin/tini", "--"]

# ==========================================
# STAGE 1: STANDARD (The full dev image)
# ==========================================
FROM base AS standard
CMD ["zsh"]


# ==========================================
# STAGE 2: SECURE (Git/Tools Disabled)
# ==========================================
FROM standard AS secure

# Switch to root temporarily to write to /usr/local/bin
USER root

# Uninstall Git and Git-LFS to free space and remove the binaries
RUN apt-get -y purge git git-lfs \
    && apt-get -y autoremove \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    echo '#!/bin/sh\necho "git is disabled in this container" >&2; exit 127' > /usr/local/bin/git && chmod +x /usr/local/bin/git; \
    echo '#!/bin/sh\necho "git-lfs is disabled in this container" >&2; exit 127' > /usr/local/bin/git-lfs && chmod +x /usr/local/bin/git-lfs; \
    echo '#!/bin/sh\necho "GitHub CLI (gh) is disabled in this container" >&2; exit 127' > /usr/local/bin/gh && chmod +x /usr/local/bin/gh

RUN set -eux; \
    mkdir -p /etc/apt/preferences.d; \
    printf 'Package: git*\nPin: release *\nPin-Priority: -1\n' > /etc/apt/preferences.d/deny-git

# Switch back to the dev user for runtime
USER "${USERNAME}"
CMD ["zsh"]
