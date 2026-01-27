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

# Generate container name for agentbox
# Arguments:
#   $1 - Working directory
#   $2 - Custom name (optional)
# Outputs:
#   Container name
# Globals:
#   AGENTBOX_WORKTREE_BRANCH (optional)
docker_generate_container_name() {
    local workdir="$1"
    local custom_name="${2:-}"

    # If custom name provided, use it
    if [[ -n "$custom_name" ]]; then
        echo "agentbox-${custom_name}"
        return
    fi

    local branch="${AGENTBOX_WORKTREE_BRANCH:-}"

    if [[ -n "$branch" ]]; then
        # Worktree: extract project from agents dir
        # Path looks like: /path/myapp-agents/wt-xxx
        local agents_dir
        agents_dir="$(dirname "$workdir")"
        local project_name="${agents_dir##*/}"
        project_name="${project_name%-agents}"

        # Extract branch suffix (last component after /)
        local branch_suffix="${branch##*/}"

        # Sanitize: replace non-alphanumeric with dash, collapse multiple dashes
        branch_suffix="$(echo "$branch_suffix" | tr -cs 'a-zA-Z0-9' '-' | sed 's/^-//;s/-$//')"

        echo "agentbox-${project_name}-${branch_suffix}"
    else
        echo "agentbox-$(basename "$workdir")"
    fi
}

# Execute docker run
# Arguments:
#   $1 - Image name
#   $2 - Working directory
#   $3 - Command to run in container (optional)
#   $4 - Keep alive flag (0 or 1)
#   $5 - Custom container name (optional)
#   $@ - Additional docker args (passed before image)
# Globals:
#   AGENTBOX_MOUNTS
#   AGENTBOX_ENV
#   AGENTBOX_WORKTREE_BRANCH (optional, used for labels)
docker_run() {
    local image="$1"
    local workdir="$2"
    local container_cmd="${3:-}"
    local keep_alive="${4:-0}"
    local custom_name="${5:-}"
    shift 5 || shift $#
    local -a extra_args=("$@")

    require_command docker "Please install Docker."

    # Generate container name
    local container_name
    container_name="$(docker_generate_container_name "$workdir" "$custom_name")"

    local -a cmd=()

    # Build base command
    # Note: no --user flag; entrypoint handles privilege dropping via HOST_UID/HOST_GID
    if [[ "$keep_alive" -eq 1 ]]; then
        cmd+=(docker run -d --name "$container_name")
    else
        cmd+=(docker run --rm -it)
    fi

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

    # Labels for container identification
    cmd+=(--label "com.agentbox.workdir=${workdir}")
    cmd+=(--label "com.agentbox.created=$(date -Iseconds)")
    if [[ -n "${AGENTBOX_WORKTREE_BRANCH:-}" ]]; then
        cmd+=(--label "com.agentbox.branch=${AGENTBOX_WORKTREE_BRANCH}")
        # Extract project name from agents dir path
        local agents_dir
        agents_dir="$(dirname "$workdir")"
        local project_name="${agents_dir##*/}"
        project_name="${project_name%-agents}"
        cmd+=(--label "com.agentbox.project=${project_name}")
    else
        cmd+=(--label "com.agentbox.project=$(basename "$workdir")")
    fi

    # Extra args
    cmd+=("${extra_args[@]}")

    # Image
    cmd+=("$image")

    # Container command
    if [[ "$keep_alive" -eq 1 ]]; then
        # Keep-alive mode: run sleep infinity as PID 1
        cmd+=(sleep infinity)
    elif [[ -n "$container_cmd" ]]; then
        # Use bash -l -c to properly handle multi-word commands with arguments
        # -l (login shell) ensures /etc/profile.d/ scripts are sourced (e.g., PATH setup)
        # See docs/known-issues.md for background
        cmd+=(bash -l -c "$container_cmd")
    fi

    log_debug "Docker command: ${cmd[*]}"

    if [[ "$keep_alive" -eq 1 ]]; then
        log_info "Starting persistent container: $container_name"

        # Check if container already exists
        if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
            if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
                log_info "Container already running, attaching..."
            else
                log_info "Container exists but stopped, starting..."
                docker start "$container_name" >/dev/null
            fi
        else
            # Start new container
            "${cmd[@]}" >/dev/null
        fi

        echo ""
        log_info "To reattach later: docker exec -it $container_name bash"
        log_info "To stop: docker stop $container_name && docker rm $container_name"
        echo ""

        # Exec into the container
        exec docker exec -it "$container_name" bash
    else
        log_info "Launching Docker container..."
        exec "${cmd[@]}"
    fi
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
