# Agentbox: Secure Container Workflow for AI Agents

A modular bash toolkit for launching secure, path-stable containers for AI agent workflows on both **Slurm/Pyxis** and **Docker**.

## The Problem

When running AI coding agents (Claude Code, Codex, etc.) in containers, several issues arise:

| Problem | Impact |
|---------|--------|
| Agents write hardcoded `/workspace` paths | Code breaks when run on host |
| Agents commit to dotfiles/tooling repos | Corrupts your development environment |
| Agents push to remote repos | Unauthorized code publication |
| Cryptic permission errors | Agents waste tokens debugging |
| UID/GID mismatch | File ownership issues, tools fail |
| Home directory not writable | Can't install tooling (stow, configs) |

## Solution Overview

**Agentbox** provides:
- **Mirror-mounts**: Project path identical inside/outside container (`$PROJ:$PROJ`)
- **Tooling protection**: Your dotfiles/scripts mounted with `.git` read-only
- **Git policy wrapper**: Baked into image, blocks push/fetch/pull/clone with clear messages
- **Entrypoint pattern**: Creates writable home directory, drops privileges correctly
- **UID/GID resolution**: Mounts `/etc/passwd` and `/etc/group`
- **Three modes**: `patch` (no commit), `yolo` (commit allowed), `lockdown` (no git)

## Directory Structure

```
~/.agentbox/
├── lib/
│   ├── core.sh          # Logging, validation, utilities
│   ├── mounts.sh        # Mount building (backend-agnostic)
│   ├── env.sh           # Environment variable handling
│   ├── docker.sh        # Docker-specific functions
│   └── slurm.sh         # Slurm/Pyxis-specific functions
├── launchers/
│   ├── agentbox-docker  # Docker launcher
│   └── agentbox-slurm   # Slurm launcher
├── config.sh            # User configuration
└── install.sh           # Installation script

# In the repo (for building the Docker image):
agentbox/
├── bin/git              # Git policy wrapper (copied into image)
└── docker/entrypoint.sh # Entrypoint script (copied into image)
```

## Installation

```bash
# Build the Docker images
docker build --target standard -t cuda-dev:standard .
docker build --target secure -t cuda-dev:secure .

# Install agentbox
./agentbox/install.sh

# Add to your shell rc file
export PATH="$HOME/.agentbox/launchers:$PATH"

# Edit config
vim ~/.agentbox/config.sh
```

## Configuration

Edit `~/.agentbox/config.sh`:

```bash
# Tooling repos (always mounted, .git read-only)
AGENTBOX_TOOLS=(
    "$HOME/scripts"
)

# Container images
AGENTBOX_IMAGE_STANDARD="cuda-dev:standard"
AGENTBOX_IMAGE_SECURE="cuda-dev:secure"

# Default mode: patch, yolo, or lockdown
AGENTBOX_DEFAULT_MODE="patch"
```

## Usage

### Docker

```bash
# Basic (patch mode, current directory)
agentbox-docker

# Explicit project path
agentbox-docker -p ~/projects/myapp

# Yolo mode (agents can commit)
agentbox-docker --yolo -p ~/projects/myapp

# With GPUs
agentbox-docker -p ~/projects/myapp --gpus all

# Pass extra docker args after --
agentbox-docker -p ~/projects/myapp -- --memory 32g --shm-size 16g
```

### Slurm

```bash
# Basic
agentbox-slurm -p ~/projects/myapp

# With resources (pass Slurm args after --)
agentbox-slurm -p ~/projects/myapp -- --gpus 4 --mem 64G --time 4:00:00

# Named container for reattachment
agentbox-slurm -n mydev -p ~/projects/myapp -- --gpus 4

# Reattach later
agentbox-slurm attach mydev
```

### Inside the Container

```bash
# Install your tooling (nvim, zsh config, etc.)
~/scripts/setup.sh

# Start working
claude  # or codex
```

## Modes

| Mode | Project `.git` | Can Commit | Can Push | Use Case |
|------|----------------|------------|----------|----------|
| `--patch` | RO | No | No | Targeted agent changes (default) |
| `--yolo` | RW | Yes | No | Full agent autonomy |
| `--lockdown` | RO | No | No | Secure image, git binary removed |

## Git Policy

The git wrapper is **baked into the Docker image** at `/usr/local/bin/git`, taking precedence over `/usr/bin/git` in PATH. Behavior is controlled by the `AGENT_ALLOW_COMMIT` environment variable.

**Always blocked:**
- `git push` — "AGENTBOX POLICY: 'git push' is forbidden in this container."
- `git fetch` — "AGENTBOX POLICY: 'git fetch' is forbidden in this container."
- `git pull` — "AGENTBOX POLICY: 'git pull' is forbidden in this container."
- `git clone` — "AGENTBOX POLICY: 'git clone' is forbidden in this container."

**Blocked in patch/lockdown mode:**
- `git commit` — "AGENTBOX POLICY: 'git commit' is disabled in this container."
- `git merge`, `git rebase`, `git cherry-pick`, `git reset`, `git stash`, `git tag`

**Always allowed:**
- `git status`, `git diff`, `git log`, `git show`, `git blame`, etc.

Additionally, `GIT_ALLOW_PROTOCOL=file` is set, preventing network protocols at the git level.

## Docker Image

The included `Dockerfile` builds two targets:

### Build

```bash
docker build --target standard -t cuda-dev:standard .
docker build --target secure -t cuda-dev:secure .
```

### Contents

| Component | Version/Details |
|-----------|-----------------|
| Base | NVIDIA CUDA 12.8.1 + cuDNN on Ubuntu 24.04 |
| Python | python3, pip, venv |
| Build tools | build-essential, cmake, ninja-build |
| Node.js | 22.x LTS |
| Claude Code | Latest (binary in `/usr/local/bin/claude`) |
| Codex | Latest (binary in `/usr/local/bin/codex`) |
| uv | Latest (fast Python package manager) |
| CLI tools | ripgrep, fd, fzf, jq, htop, tmux, vim, zsh, stow, gosu |
| Git wrapper | Baked in at `/usr/local/bin/git` |
| Entrypoint | Handles home directory creation and privilege dropping |

### Image Design

- **Entrypoint pattern**: Container starts as root, entrypoint creates `/home/$USER` with correct ownership, then drops privileges via `gosu`
- **Git wrapper baked in**: No PATH manipulation needed, wrapper at `/usr/local/bin/git` takes precedence
- **Identity from host**: `/etc/passwd` and `/etc/group` mounted for UID/GID resolution
- **Tooling from host**: Your `~/scripts` mounted and available
- **Writable home**: `stow` and other tools can create files in `$HOME`
- **Secure stage**: Git completely purged, stub scripts return clear errors

## How It Works

### Entrypoint Flow (Docker)

1. Container starts as **root**
2. Entrypoint reads `HOST_UID` and `HOST_GID` from environment
3. Resolves username and home directory from mounted `/etc/passwd`
4. Creates `/home/$USER` with correct ownership (or fixes ownership if exists)
5. Uses `gosu` to drop privileges to the target user
6. Executes the command as the unprivileged user

### Entrypoint Flow (Pyxis/Slurm)

1. Container starts as **your user** (via `--no-container-remap-root`)
2. Entrypoint detects non-root execution
3. Attempts to create home directory (may fail if `/home` not writable)
4. Executes the command directly

### Mount Strategy

```
# Project (mirror-mount for path stability)
$PROJ:$PROJ:rw
$PROJ/.git:$PROJ/.git:ro  # (in patch/lockdown mode)

# Tooling (editable, but agents can't commit)
~/scripts:~/scripts:rw
~/scripts/.git:~/scripts/.git:ro

# Identity resolution
/etc/passwd:/etc/passwd:ro
/etc/group:/etc/group:ro
```

### Environment Variables

```bash
HOST_UID=1000                # Your UID (for entrypoint)
HOST_GID=1000                # Your GID (for entrypoint)
GIT_ALLOW_PROTOCOL=file      # Block network git protocols
GIT_TERMINAL_PROMPT=0        # No interactive prompts
GIT_CONFIG_GLOBAL=/dev/null  # Ignore global git config
AGENT_ALLOW_COMMIT=0|1       # Controls git wrapper behavior
```

## Security Model

1. **Privilege dropping**: Container starts as root, drops to your user via `gosu`
2. **Writable home**: Created at runtime with correct ownership
3. **No credentials mounted**: `$HOME` not auto-mounted (Slurm cluster config)
4. **Git network ops blocked**: Wrapper + `GIT_ALLOW_PROTOCOL=file`
5. **Commits controlled by mode**: `.git:ro` + wrapper
6. **Tooling protected**: `.git:ro` on all tooling repos
7. **Clear error messages**: Agents don't waste tokens on permission errors

## Typical Workflow

```bash
# 1. Launch container
agentbox-docker -p ~/projects/myapp

# 2. Inside container: install your tools (home is writable!)
~/scripts/setup.sh

# 3. Run your agent
claude

# 4. Agent works on code, can git diff/status, but cannot:
#    - Commit (patch mode)
#    - Push/fetch/pull (ever)
#    - Modify your ~/scripts repo's git history

# 5. Exit container, review changes on host
cd ~/projects/myapp
git diff
git add -p && git commit  # You control commits
```

## Troubleshooting

### "HOST_UID environment variable is required but not set"
The entrypoint requires `HOST_UID` and `HOST_GID`. Agentbox sets these automatically. If running manually, add `-e HOST_UID=$(id -u) -e HOST_GID=$(id -g)`.

### "cannot find name for user ID"
Check that `/etc/passwd` is mounted. Agentbox does this automatically.

### "Cannot create home directory"
In Pyxis/Slurm mode, the container doesn't start as root, so it may not be able to create `/home/$USER` if the parent directory isn't writable. This is a known limitation.

### Git commands fail silently
Run with `--debug` to see what's happening:
```bash
AGENTBOX_DEBUG=1 agentbox-docker -p ~/project
```

### Tooling repo not found
Verify paths in `~/.agentbox/config.sh` are absolute and exist on the host.

### "gosu is not installed"
Rebuild the Docker image — `gosu` should be installed automatically.
