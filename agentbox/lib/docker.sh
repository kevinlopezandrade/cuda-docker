#!/usr/bin/env bash
# agentbox/lib/docker.sh - Docker-specific functions
#
# Source this file, do not execute directly.
# Requires: core.sh, mounts.sh, env.sh to be sourced first
# shellcheck shell=bash

#######################################
# Docker mount formatting
#######################################

# Convert internal mount spec to docker -v format
# Arguments:
#   $1 - Mount spec "src:dst:flags"
# Outputs:
#   Docker mount argument
_docker_format_mount() {
    local spec="$1"
    local src dst flags

    IFS=':' read -r src dst flags <<< "$spec"

    case "$flags" in
        ro)
            echo "${src}:${dst}:ro"
            ;;
        rw|*)
            echo "${src}:${dst}"
            ;;
    esac
}

# Build docker -v arguments from AGENTBOX_MOUNTS
# Globals:
#   AGENTBOX_MOUNTS
# Outputs:
#   Docker -v arguments, one per line
docker_mount_args() {
    for spec in "${AGENTBOX_MOUNTS[@]}"; do
        echo "-v"
        _docker_format_mount "$spec"
    done
}

#######################################
# Docker environment formatting
#######################################

# Build docker -e arguments from AGENTBOX_ENV
# Globals:
#   AGENTBOX_ENV
# Outputs:
#   Docker -e arguments, one per line
docker_env_args() {
    for name in "${!AGENTBOX_ENV[@]}"; do
        if env_is_unset "$name"; then
            # Docker uses -e NAME (without value) to unset
            echo "-e"
            echo "$name"
        else
            echo "-e"
            echo "${name}=${AGENTBOX_ENV[$name]}"
        fi
    done
}

#######################################
# Docker run builder
#######################################

# Build complete docker run command
# Arguments:
#   $1 - Image name
#   $2 - Working directory
#   $@ - Additional docker args (after --)
# Globals:
#   AGENTBOX_MOUNTS
#   AGENTBOX_ENV
# Outputs:
#   Complete docker run command (one arg per line)
docker_build_command() {
    local image="$1"
    local workdir="$2"
    shift 2
    local -a extra_args=("$@")

    echo "docker"
    echo "run"
    echo "--rm"
    echo "-it"

    # Note: no --user flag; entrypoint handles privilege dropping via HOST_UID/HOST_GID

    # Working directory
    echo "-w"
    echo "$workdir"

    # Mounts
    docker_mount_args

    # Environment
    docker_env_args

    # Extra args passed by user
    for arg in "${extra_args[@]}"; do
        echo "$arg"
    done

    # Image
    echo "$image"
}

# Execute docker run
# Arguments:
#   $1 - Image name
#   $2 - Working directory
#   $3 - Command to run in container (optional)
#   $@ - Additional docker args (passed before image)
# Globals:
#   AGENTBOX_MOUNTS
#   AGENTBOX_ENV
docker_run() {
    local image="$1"
    local workdir="$2"
    local container_cmd="${3:-}"
    shift 3 || shift $#
    local -a extra_args=("$@")

    require_command docker "Please install Docker."

    local -a cmd=()

    # Build base command
    # Note: no --user flag; entrypoint handles privilege dropping via HOST_UID/HOST_GID
    cmd+=(docker run --rm -it)

    # Working directory
    cmd+=(-w "$workdir")

    # Mounts
    for spec in "${AGENTBOX_MOUNTS[@]}"; do
        cmd+=(-v "$(_docker_format_mount "$spec")")
    done

    # Environment
    for name in "${!AGENTBOX_ENV[@]}"; do
        if env_is_unset "$name"; then
            cmd+=(-e "$name")
        else
            cmd+=(-e "${name}=${AGENTBOX_ENV[$name]}")
        fi
    done

    # Extra args
    cmd+=("${extra_args[@]}")

    # Image
    cmd+=("$image")

    # Container command (if specified)
    if [[ -n "$container_cmd" ]]; then
        cmd+=("$container_cmd")
    fi

    log_debug "Docker command: ${cmd[*]}"
    log_info "Launching Docker container..."

    exec "${cmd[@]}"
}

#######################################
# Docker utilities
#######################################

# Check if docker daemon is running
# Returns:
#   0 if running, 1 otherwise
docker_is_running() {
    docker info &>/dev/null
}

# Validate docker is available and running
docker_validate() {
    require_command docker "Please install Docker."

    if ! docker_is_running; then
        die 1 "Docker daemon is not running. Please start Docker."
    fi

    log_debug "Docker is available and running"
}
