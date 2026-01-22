#!/usr/bin/env bash
# agentbox/lib/mounts.sh - Mount string building utilities
#
# Source this file, do not execute directly.
# Requires: core.sh to be sourced first
# shellcheck shell=bash

#######################################
# Mount specification builders
#
# These functions build mount specs in a backend-agnostic format.
# The actual translation to docker -v or pyxis --container-mounts
# happens in the backend-specific libraries.
#
# Mount spec format (internal):
#   "src:dst:flags"
#   flags: rw (default), ro
#######################################

# Global array to accumulate mounts
declare -a AGENTBOX_MOUNTS=()

# Reset mounts array
# Globals:
#   AGENTBOX_MOUNTS
mounts_reset() {
    AGENTBOX_MOUNTS=()
}

# Add a simple mount (src:dst, read-write)
# Arguments:
#   $1 - Source path on host
#   $2 - Destination path in container (optional, defaults to source)
# Globals:
#   AGENTBOX_MOUNTS
mount_add() {
    local src="$1"
    local dst="${2:-$1}"
    src="$(resolve_path "$src")"
    AGENTBOX_MOUNTS+=("${src}:${dst}:rw")
    log_debug "Mount added: ${src} -> ${dst} (rw)"
}

# Add a read-only mount
# Arguments:
#   $1 - Source path on host
#   $2 - Destination path in container (optional, defaults to source)
# Globals:
#   AGENTBOX_MOUNTS
mount_add_ro() {
    local src="$1"
    local dst="${2:-$1}"
    src="$(resolve_path "$src")"
    AGENTBOX_MOUNTS+=("${src}:${dst}:ro")
    log_debug "Mount added: ${src} -> ${dst} (ro)"
}

# Add a mirror mount (same path inside and outside container)
# Arguments:
#   $1 - Path to mirror-mount
#   $2 - Flags: "rw" or "ro" (default: rw)
# Globals:
#   AGENTBOX_MOUNTS
mount_mirror() {
    local path="$1"
    local flags="${2:-rw}"
    path="$(resolve_path "$path")"
    AGENTBOX_MOUNTS+=("${path}:${path}:${flags}")
    log_debug "Mirror mount added: ${path} (${flags})"
}

#######################################
# High-level mount builders
#######################################

# Resolve the git directory that needs to be mounted for a repo/worktree/submodule
# Arguments:
#   $1 - Path to git repo, worktree, or submodule
# Outputs:
#   Path to the .git directory that controls this repo
#   Empty string if not a git repo
# Returns:
#   0 if found, 1 if not a git repo
_resolve_git_dir() {
    local path="$1"

    if [[ -d "${path}/.git" ]]; then
        # Regular git repo - .git is a directory
        echo "${path}/.git"
        return 0
    elif [[ -f "${path}/.git" ]]; then
        # Worktree or submodule - .git is a file
        local gitdir_line
        gitdir_line="$(head -1 "${path}/.git")"

        if [[ "$gitdir_line" =~ ^gitdir:\ (.+)$ ]]; then
            local gitdir="${BASH_REMATCH[1]}"

            # Handle relative paths
            if [[ "$gitdir" != /* ]]; then
                gitdir="$(cd "$path" && cd "$gitdir" && pwd)"
            fi

            # If this is a worktree, strip the /worktrees/<name> suffix first
            # This handles both:
            #   - Regular worktrees: /repo/.git/worktrees/name -> /repo/.git
            #   - Submodule worktrees: /parent/.git/modules/sub/worktrees/name -> /parent/.git/modules/sub
            if [[ "$gitdir" == */worktrees/* ]]; then
                gitdir="${gitdir%/worktrees/*}"
            fi

            # Return the resolved git directory
            # Could be: main .git, or submodule's git database in /modules/
            echo "$gitdir"
            return 0
        fi
    fi

    return 1
}

# Add project mounts based on mode
# Arguments:
#   $1 - Project path
#   $2 - Mode: "patch", "yolo", or "lockdown"
# Globals:
#   AGENTBOX_MOUNTS
mount_project() {
    local proj="$1"
    local mode="$2"

    require_directory "$proj" "Project directory"

    proj="$(resolve_path "$proj")"

    # Always mirror-mount the project directory
    mount_mirror "$proj" "rw"

    # Resolve the git directory (handles regular repos, worktrees, and submodules)
    local git_dir
    if git_dir="$(_resolve_git_dir "$proj")"; then
        case "$mode" in
            patch|lockdown)
                mount_mirror "$git_dir" "ro"
                log_info "Git directory mounted read-only (mode: $mode): $git_dir"
                ;;
            yolo)
                # Mount the git directory read-write
                # For regular repos, it's already in the project mount
                # For worktrees/submodules, we need to explicitly mount it
                if [[ "$git_dir" != "${proj}/.git" ]]; then
                    mount_mirror "$git_dir" "rw"
                fi
                log_info "Git directory is writable (mode: yolo): $git_dir"
                ;;
            *)
                die 1 "Unknown mode: $mode"
                ;;
        esac
    else
        log_warn "Project has no .git: $proj"
    fi
}

# Add tooling repo mount (worktree RW, .git RO)
# Handles regular repos, worktrees, and submodules
# Arguments:
#   $1 - Tooling repo path
# Globals:
#   AGENTBOX_MOUNTS
mount_tooling() {
    local tool="$1"

    require_directory "$tool" "Tooling directory"

    tool="$(resolve_path "$tool")"

    # Mount working directory read-write
    mount_mirror "$tool" "rw"

    # Mount .git read-only (prevents commits)
    # Use the same resolver as mount_project for consistency
    local git_dir
    if git_dir="$(_resolve_git_dir "$tool")"; then
        mount_mirror "$git_dir" "ro"
        log_debug "Tooling git directory mounted read-only: $git_dir"
    else
        log_warn "Tooling directory has no .git: $tool"
    fi
}

# Add all configured tooling repos
# Globals:
#   AGENTBOX_TOOLS (from config)
#   AGENTBOX_MOUNTS
mount_all_tooling() {
    if [[ -z "${AGENTBOX_TOOLS[*]:-}" ]]; then
        log_debug "No tooling repos configured"
        return 0
    fi

    for tool in "${AGENTBOX_TOOLS[@]}"; do
        if [[ -d "$tool" ]]; then
            mount_tooling "$tool"
        else
            log_warn "Configured tooling directory not found, skipping: $tool"
        fi
    done
}

# Add a manual volume mount
# Supports formats:
#   /host/path                     -> mounts as /host/path (rw)
#   /host/path:ro                  -> mounts as /host/path (ro)
#   /host/path:/container/path     -> mounts at /container/path (rw)
#   /host/path:/container/path:ro  -> mounts at /container/path (ro)
# Arguments:
#   $1 - Volume specification
# Globals:
#   AGENTBOX_MOUNTS
mount_volume() {
    local spec="$1"
    local src dst flags
    local mirror=0

    # Parse the volume spec
    IFS=':' read -ra parts <<< "$spec"

    if [[ ${#parts[@]} -eq 1 ]]; then
        # Just source path - mirror mount, rw
        src="${parts[0]}"
        mirror=1
        flags="rw"
    elif [[ ${#parts[@]} -eq 2 ]]; then
        # Could be src:dst or src:flags
        if [[ "${parts[1]}" == "ro" || "${parts[1]}" == "rw" ]]; then
            # src:flags - mirror mount with explicit flags
            src="${parts[0]}"
            mirror=1
            flags="${parts[1]}"
        else
            # src:dst - rw by default
            src="${parts[0]}"
            dst="${parts[1]}"
            flags="rw"
        fi
    elif [[ ${#parts[@]} -ge 3 ]]; then
        # src:dst:flags
        src="${parts[0]}"
        dst="${parts[1]}"
        flags="${parts[2]}"
    fi

    # Validate flags
    if [[ "$flags" != "rw" && "$flags" != "ro" ]]; then
        log_warn "Invalid mount flags '$flags' for volume $spec, using 'rw'"
        flags="rw"
    fi

    # Resolve source path
    if [[ ! -e "$src" ]]; then
        log_warn "Volume source does not exist, skipping: $src"
        return 0
    fi
    src="$(resolve_path "$src")"

    # For mirror mounts, set dst after resolving src
    if [[ $mirror -eq 1 ]]; then
        dst="$src"
    fi

    AGENTBOX_MOUNTS+=("${src}:${dst}:${flags}")
    log_debug "Volume mount added: ${src} -> ${dst} (${flags})"
}

# Add all configured volumes
# Globals:
#   AGENTBOX_VOLUMES (from config)
#   AGENTBOX_MOUNTS
mount_all_volumes() {
    if [[ -z "${AGENTBOX_VOLUMES[*]:-}" ]]; then
        log_debug "No volumes configured"
        return 0
    fi

    for vol in "${AGENTBOX_VOLUMES[@]}"; do
        mount_volume "$vol"
    done
}

# Mount codex config directory
# Globals:
#   AGENTBOX_MOUNTS
mount_codex_config() {
    local codex_dir="$HOME/.codex"
    if [[ -d "$codex_dir" ]]; then
        mount_mirror "$codex_dir" "rw"
        log_debug "Mounted ~/.codex for codex config"
    fi
}

# Mount claude config directory
# Globals:
#   AGENTBOX_MOUNTS
mount_claude_config() {
    local claude_dir="$HOME/.claude"
    if [[ -d "$claude_dir" ]]; then
        mount_mirror "$claude_dir" "rw"
        log_debug "Mounted ~/.claude for claude config"
    fi
}

# Mount marimo config directory
# Globals:
#   AGENTBOX_MOUNTS
mount_marimo_config() {
    local marimo_dir="$HOME/.config/marimo"
    if [[ -d "$marimo_dir" ]]; then
        mount_mirror "$marimo_dir" "rw"
        log_debug "Mounted ~/.config/marimo for marimo config"
    fi
}

# Mount uv cache directory (experimental)
# This shares the host's uv cache with containers to reuse
# downloaded packages and installed Python versions.
# Globals:
#   AGENTBOX_MOUNTS
mount_uv_cache() {
    local uv_dir="$HOME/.local/share/uv"
    if [[ -d "$uv_dir" ]]; then
        mount_mirror "$uv_dir" "rw"
        log_debug "Mounted ~/.local/share/uv for uv cache (experimental)"
    else
        log_warn "UV cache directory does not exist: $uv_dir"
    fi
}

# Mount /etc/passwd and /etc/group for UID/GID resolution
# This fixes "cannot find name for user ID" errors and makes tools
# like `id`, `whoami`, `ls -la` show proper usernames instead of numeric IDs.
# Globals:
#   AGENTBOX_MOUNTS
mount_user_identity() {
    # Mount /etc/passwd read-only
    if [[ -f /etc/passwd ]]; then
        AGENTBOX_MOUNTS+=("/etc/passwd:/etc/passwd:ro")
        log_debug "Mounted /etc/passwd (ro) for user identity resolution"
    else
        log_warn "/etc/passwd not found, skipping identity mount"
    fi

    # Mount /etc/group read-only
    if [[ -f /etc/group ]]; then
        AGENTBOX_MOUNTS+=("/etc/group:/etc/group:ro")
        log_debug "Mounted /etc/group (ro) for group identity resolution"
    else
        log_warn "/etc/group not found, skipping group mount"
    fi
}

#######################################
# Mount output formatters
# (Used by backend-specific libraries)
#######################################

# Get mounts as newline-separated list (for debugging)
# Globals:
#   AGENTBOX_MOUNTS
# Outputs:
#   One mount spec per line
mounts_dump() {
    printf '%s\n' "${AGENTBOX_MOUNTS[@]}"
}

# Get number of mounts
# Globals:
#   AGENTBOX_MOUNTS
# Outputs:
#   Count
mounts_count() {
    echo "${#AGENTBOX_MOUNTS[@]}"
}
