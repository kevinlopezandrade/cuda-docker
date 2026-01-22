# Agentbox

Secure container workflow for AI coding agents (Claude Code, Codex, etc.) on Docker and Slurm.

## Quick Start

```bash
# Build Docker images
docker build --target standard -t cuda-dev:standard .

# Install agentbox
./agentbox/install.sh
export PATH="$HOME/.agentbox/launchers:$PATH"

# Edit config
vim ~/.agentbox/config.sh

# Launch container
box -p ~/projects/myapp
```

## Features

- **Mirror-mounts**: Same paths inside/outside container
- **Git policy**: Agents can't push (ever) or commit (in patch mode)
- **Worktree support**: Run multiple agents in parallel via `box -w`
- **Submodule support**: `wt-init` links submodules as worktrees
- **API key passthrough**: Configure `AGENTBOX_PASSTHROUGH_ENV`
- **Agent configs mounted**: `~/.claude` and `~/.codex` available in container

## Documentation

See [AGENTS.md](AGENTS.md) for full documentation.
