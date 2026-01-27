#!/usr/bin/env bash
# agentbox/lib/launcher.sh - Shared launcher logic
#
# Source this file, do not execute directly.
# Requires: core.sh, mounts.sh, env.sh to be sourced first
# shellcheck shell=bash

#######################################
# Shared global variables
#######################################
PROJ=""
MODE=""
IMAGE=""
CMD=""
USE_WORKTREE=0
BRANCH=""
FROM_REF=""
KEEP_ALIVE=0
SHARE_UV_CACHE=1
declare -a EXTRA_TOOLS=()
declare -a EXTRA_VOLUMES=()
declare -a BACKEND_EXTRA_ARGS=()

#######################################
# Common argument parsing
#######################################

# Parse common arguments shared by all backends
# Arguments:
#   $@ - Command line arguments
# Returns:
#   Remaining unparsed arguments in LAUNCHER_REMAINING_ARGS
# Globals:
#   Sets PROJ, MODE, IMAGE, CMD, USE_WORKTREE, BRANCH, EXTRA_TOOLS, BACKEND_EXTRA_ARGS
declare -a LAUNCHER_REMAINING_ARGS=()

parse_common_args() {
    LAUNCHER_REMAINING_ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--proj)
                PROJ="$2"
                shift 2
                ;;
            -t|--tools)
                EXTRA_TOOLS+=("$2")
                shift 2
                ;;
            -v|--volume)
                EXTRA_VOLUMES+=("$2")
                shift 2
                ;;
            -m|--mode)
                MODE="$2"
                shift 2
                ;;
            --patch)
                MODE="patch"
                shift
                ;;
            --yolo)
                MODE="yolo"
                shift
                ;;
            --lockdown)
                MODE="lockdown"
                shift
                ;;
            -w|--worktree)
                USE_WORKTREE=1
                shift
                ;;
            --branch)
                BRANCH="$2"
                shift 2
                ;;
            -f|--from)
                FROM_REF="$2"
                shift 2
                ;;
            -k|--keep)
                KEEP_ALIVE=1
                shift
                ;;
            --image)
                IMAGE="$2"
                shift 2
                ;;
            --cmd)
                CMD="$2"
                shift 2
                ;;
            --debug)
                export AGENTBOX_DEBUG=1
                shift
                ;;
            --no-uv-cache)
                SHARE_UV_CACHE=0
                shift
                ;;
            --)
                shift
                BACKEND_EXTRA_ARGS=("$@")
                break
                ;;
            *)
                # Unknown arg - could be backend-specific or positional
                LAUNCHER_REMAINING_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

#######################################
# Image selection
#######################################

# Select container image based on mode
# Globals:
#   IMAGE, MODE
#   Reads AGENTBOX_IMAGE_STANDARD, AGENTBOX_IMAGE_SECURE from config
select_image_for_mode() {
    if [[ -z "$IMAGE" ]]; then
        case "$MODE" in
            lockdown)
                IMAGE="${AGENTBOX_IMAGE_SECURE:-}"
                ;;
            *)
                IMAGE="${AGENTBOX_IMAGE_STANDARD:-}"
                ;;
        esac
    fi

    if [[ -z "$IMAGE" ]]; then
        die 1 "No image specified and no default configured. Use --image or set AGENTBOX_IMAGE_STANDARD in config."
    fi
}

#######################################
# Worktree handling
#######################################

# Handle worktree creation if requested
# Globals:
#   USE_WORKTREE, PROJ, BRANCH, FROM_REF
#   Sets PROJ to worktree path if created
handle_worktree() {
    if [[ $USE_WORKTREE -eq 1 ]]; then
        require_git_repo "$PROJ" "Project directory"
        create_agent_worktree "$PROJ" "$BRANCH" "$FROM_REF"
        PROJ="$AGENTBOX_WORKTREE_PATH"
        log_info "Using worktree: $PROJ"
        log_info "Branch: $AGENTBOX_WORKTREE_BRANCH"
        echo ""
        log_info "After container exits, review changes with:"
        log_info "  cd $PROJ && git diff main"
        log_info "Cleanup with:"
        log_info "  git worktree remove $PROJ"
        echo ""
    fi
}

#######################################
# Mount and environment setup
#######################################

# Build all mounts for the container
# Globals:
#   PROJ, MODE, EXTRA_TOOLS, EXTRA_VOLUMES
build_mounts() {
    mounts_reset
    mount_project "$PROJ" "$MODE"
    mount_all_tooling

    # Mount extra tools specified on command line
    for tool in "${EXTRA_TOOLS[@]}"; do
        mount_tooling "$tool"
    done

    # Mount configured volumes from config
    mount_all_volumes

    # Mount extra volumes specified on command line
    for vol in "${EXTRA_VOLUMES[@]}"; do
        mount_volume "$vol"
    done

    # Mount /etc/passwd and /etc/group for UID/GID resolution
    mount_user_identity

    # Mount agent config directories
    mount_codex_config
    mount_claude_config
    mount_marimo_config

    # Mount uv cache if requested (experimental)
    if [[ $SHARE_UV_CACHE -eq 1 ]]; then
        log_warn "[EXPERIMENTAL] Mounting UV cache (~/.local/share/uv) - this feature is experimental"
        mount_uv_cache
    fi

    log_debug "Mounts ($(mounts_count)):"
    if [[ "${AGENTBOX_DEBUG:-0}" == "1" ]]; then
        mounts_dump | while read -r line; do log_debug "  $line"; done
    fi
}

# Build environment variables for the container
# Globals:
#   MODE
build_environment() {
    env_reset
    env_setup_all "$MODE"

    log_debug "Environment:"
    if [[ "${AGENTBOX_DEBUG:-0}" == "1" ]]; then
        env_dump | while read -r line; do log_debug "  $line"; done
    fi
}

#######################################
# Security validation
#######################################

# Check if a path is or contains ~/.ssh
# Arguments:
#   $1 - Path to check
# Returns:
#   0 if path would expose .ssh, 1 otherwise
_path_exposes_ssh() {
    local path="$1"
    local ssh_dir="$HOME/.ssh"

    # Resolve to absolute path
    path="$(resolve_path "$path" 2>/dev/null || echo "$path")"

    # Check if path is ~/.ssh or contains it
    if [[ "$path" == "$ssh_dir" || "$path" == "$ssh_dir"/* ]]; then
        return 0
    fi

    # Check if path is a parent of ~/.ssh (would include it)
    if [[ "$ssh_dir" == "$path"/* ]]; then
        return 0
    fi

    return 1
}

# Check if a directory contains git credentials
# Arguments:
#   $1 - Path to check
# Returns:
#   0 if credentials found, 1 otherwise
_path_has_git_credentials() {
    local path="$1"

    [[ -d "$path" ]] || return 1

    # Check for .git-credentials file (fast check first)
    if [[ -f "$path/.git-credentials" ]]; then
        return 0
    fi

    # Recursive check for .git-credentials (limit depth for performance)
    if find "$path" -maxdepth 3 -name ".git-credentials" -type f 2>/dev/null | grep -q .; then
        return 0
    fi

    return 1
}

# Extract source path from a volume spec
# Arguments:
#   $1 - Volume specification (src, src:dst, or src:dst:flags)
# Outputs:
#   Source path
_extract_volume_source() {
    local spec="$1"
    # Just get the first part before any colon
    echo "${spec%%:*}"
}

# Validate that no sensitive credentials will be mounted
# Checks project, tooling, extra tools, and extra volumes
# Globals:
#   PROJ, EXTRA_TOOLS, AGENTBOX_TOOLS, EXTRA_VOLUMES, AGENTBOX_VOLUMES
validate_no_credentials() {
    local -a paths_to_check=()

    # Collect all paths that will be mounted
    [[ -n "$PROJ" ]] && paths_to_check+=("$PROJ")

    for tool in "${EXTRA_TOOLS[@]}"; do
        paths_to_check+=("$tool")
    done

    if [[ -n "${AGENTBOX_TOOLS[*]:-}" ]]; then
        for tool in "${AGENTBOX_TOOLS[@]}"; do
            paths_to_check+=("$tool")
        done
    fi

    # Check extra volumes (extract source path from spec)
    for vol in "${EXTRA_VOLUMES[@]}"; do
        paths_to_check+=("$(_extract_volume_source "$vol")")
    done

    if [[ -n "${AGENTBOX_VOLUMES[*]:-}" ]]; then
        for vol in "${AGENTBOX_VOLUMES[@]}"; do
            paths_to_check+=("$(_extract_volume_source "$vol")")
        done
    fi

    # Check each path
    for path in "${paths_to_check[@]}"; do
        # Check for .ssh exposure
        if _path_exposes_ssh "$path"; then
            die 1 "SECURITY: Refusing to mount path that would expose ~/.ssh: $path"
        fi

        # Check for .git-credentials
        if _path_has_git_credentials "$path"; then
            die 1 "SECURITY: Refusing to mount path containing .git-credentials: $path"
        fi
    done

    log_debug "Security validation passed"
}

#######################################
# Main launcher flow
#######################################

# Run the common launcher setup (config, defaults, worktree, mounts, env)
# Call this after parsing backend-specific args
# Arguments:
#   $1 - Default command (optional, e.g., "bash" for slurm)
# Globals:
#   PROJ, MODE, IMAGE, CMD
launcher_setup() {
    local default_cmd="${1:-}"

    # Load user config
    load_config

    # Apply defaults
    PROJ="${PROJ:-$(pwd)}"
    MODE="${MODE:-${AGENTBOX_DEFAULT_MODE:-patch}}"
    if [[ -n "$default_cmd" ]]; then
        CMD="${CMD:-$default_cmd}"
    fi

    # Select image based on mode
    select_image_for_mode

    # Resolve project path
    PROJ="$(resolve_path "$PROJ")"

    # Resolve symlinks to get the actual path
    # This ensures the container mounts the real path, not the symlink path
    if [[ -L "$PROJ" ]]; then
        local resolved
        resolved="$(readlink -f "$PROJ")"
        log_info "Resolved symlink: $PROJ -> $resolved"
        PROJ="$resolved"
    fi

    # Security: ensure no credentials will be mounted
    validate_no_credentials
}

# Run validation and setup after backend validation
# Arguments:
#   None
# Globals:
#   PROJ, MODE, IMAGE
launcher_prepare() {
    require_directory "$PROJ" "Project directory"

    # Handle worktree creation
    handle_worktree

    # Log startup info
    log_info "Mode: $MODE"
    log_info "Project: $PROJ"
    log_info "Image: $IMAGE"
}

# Build mounts and environment
launcher_build() {
    build_mounts
    build_environment
}
