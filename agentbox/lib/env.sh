#!/usr/bin/env bash
# agentbox/lib/env.sh - Environment variable handling
#
# Source this file, do not execute directly.
# Requires: core.sh to be sourced first
# shellcheck shell=bash

#######################################
# Environment variable builders
#
# These functions build environment variables for the container.
# The actual passing mechanism (docker -e or srun --export)
# is handled by backend-specific libraries.
#######################################

# Global associative array to accumulate environment variables
declare -A AGENTBOX_ENV=()

# Reset environment array
# Globals:
#   AGENTBOX_ENV
env_reset() {
    AGENTBOX_ENV=()
}

# Set an environment variable
# Arguments:
#   $1 - Variable name
#   $2 - Variable value
# Globals:
#   AGENTBOX_ENV
env_set() {
    local name="$1"
    local value="$2"
    AGENTBOX_ENV["$name"]="$value"
    log_debug "Env set: ${name}=${value}"
}

# Unset an environment variable (mark for removal)
# Arguments:
#   $1 - Variable name
# Globals:
#   AGENTBOX_ENV
env_unset() {
    local name="$1"
    # Use special marker for "unset this var"
    AGENTBOX_ENV["$name"]="__AGENTBOX_UNSET__"
    log_debug "Env unset: ${name}"
}

#######################################
# Policy environment setup
#######################################

# Set up git lockdown environment variables
# These prevent git from using network protocols
# Globals:
#   AGENTBOX_ENV
env_git_lockdown() {
    # Only allow file:// protocol (local repos)
    env_set "GIT_ALLOW_PROTOCOL" "file"

    # Disable interactive prompts
    env_set "GIT_TERMINAL_PROMPT" "0"

    # Ignore global git config (credential helpers, etc.)
    env_set "GIT_CONFIG_GLOBAL" "/dev/null"

    # Avoid lock-taking side effects (useful when .git is read-only)
    env_set "GIT_OPTIONAL_LOCKS" "0"

    # Remove SSH agent socket (no ssh-based auth)
    env_unset "SSH_AUTH_SOCK"

    log_debug "Git lockdown environment configured"
}

# Set up agent mode environment
# Arguments:
#   $1 - Mode: "patch", "yolo", or "lockdown"
# Globals:
#   AGENTBOX_ENV
env_agent_mode() {
    local mode="$1"

    case "$mode" in
        patch|lockdown)
            env_set "AGENT_ALLOW_COMMIT" "0"
            env_set "AGENTBOX_MODE" "$mode"
            ;;
        yolo)
            env_set "AGENT_ALLOW_COMMIT" "1"
            env_set "AGENTBOX_MODE" "yolo"
            ;;
        *)
            die 1 "Unknown mode: $mode"
            ;;
    esac

    log_debug "Agent mode set: $mode"
}

# Set up PATH (no manipulation needed - git wrapper is baked into the image)
# Globals:
#   AGENTBOX_ENV
env_policy_path() {
    # No PATH manipulation needed - the git wrapper is installed at
    # /usr/local/bin/git in the Docker image, which takes precedence
    # over /usr/bin/git in standard PATH
    log_debug "PATH unchanged (git wrapper baked into image)"
}

# Set up host user identity for entrypoint privilege dropping
# Globals:
#   AGENTBOX_ENV
env_host_identity() {
    env_set "HOST_UID" "$(id -u)"
    env_set "HOST_GID" "$(id -g)"
    log_debug "Host identity: UID=$(id -u), GID=$(id -g)"
}

# Set up all standard agentbox environment
# Arguments:
#   $1 - Mode: "patch", "yolo", or "lockdown"
# Globals:
#   AGENTBOX_ENV
env_setup_all() {
    local mode="$1"

    env_git_lockdown
    env_agent_mode "$mode"
    env_policy_path
    env_host_identity

    # Add agentbox marker
    env_set "AGENTBOX" "1"
    env_set "AGENTBOX_VERSION" "$AGENTBOX_VERSION"
}

#######################################
# Environment output helpers
# (Used by backend-specific libraries)
#######################################

# Get all environment variable names
# Globals:
#   AGENTBOX_ENV
# Outputs:
#   Space-separated list of variable names
env_names() {
    echo "${!AGENTBOX_ENV[*]}"
}

# Get value for a specific environment variable
# Arguments:
#   $1 - Variable name
# Globals:
#   AGENTBOX_ENV
# Outputs:
#   Variable value
env_get() {
    local name="$1"
    echo "${AGENTBOX_ENV[$name]:-}"
}

# Check if a variable is marked for unsetting
# Arguments:
#   $1 - Variable name
# Returns:
#   0 if marked for unset, 1 otherwise
env_is_unset() {
    local name="$1"
    [[ "${AGENTBOX_ENV[$name]:-}" == "__AGENTBOX_UNSET__" ]]
}

# Dump environment for debugging
# Globals:
#   AGENTBOX_ENV
# Outputs:
#   One "NAME=value" per line
env_dump() {
    for name in "${!AGENTBOX_ENV[@]}"; do
        if env_is_unset "$name"; then
            echo "unset $name"
        else
            echo "${name}=${AGENTBOX_ENV[$name]}"
        fi
    done
}
