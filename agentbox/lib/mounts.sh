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

    # Handle .git based on mode
    # Note: Regular repos have .git as directory, worktrees have .git as file
    if [[ -d "${proj}/.git" ]]; then
        # Regular git repo - .git is a directory
        case "$mode" in
            patch|lockdown)
                # Read-only .git prevents commits
                mount_mirror "${proj}/.git" "ro"
                log_info "Project .git mounted read-only (mode: $mode)"
                ;;
            yolo)
                # .git stays read-write (already included in project mount)
                log_info "Project .git is writable (mode: yolo)"
                ;;
            *)
                die 1 "Unknown mode: $mode"
                ;;
        esac
    elif [[ -f "${proj}/.git" ]]; then
        # Git worktree - .git is a file pointing to main repo
        # Parse the .git file to find the main repo's .git directory
        local gitdir_line
        gitdir_line="$(head -1 "${proj}/.git")"

        if [[ "$gitdir_line" =~ ^gitdir:\ (.+)$ ]]; then
            local gitdir="${BASH_REMATCH[1]}"
            # gitdir is something like /home/kev/pylance/.git/worktrees/name
            # We need the main .git directory: /home/kev/pylance/.git
            local main_gitdir="${gitdir%/worktrees/*}"

            if [[ -d "$main_gitdir" ]]; then
                case "$mode" in
                    patch|lockdown)
                        mount_mirror "$main_gitdir" "ro"
                        log_info "Worktree: main .git mounted read-only (mode: $mode)"
                        ;;
                    yolo)
                        mount_mirror "$main_gitdir" "rw"
                        log_info "Worktree: main .git mounted read-write (mode: yolo)"
                        ;;
                    *)
                        die 1 "Unknown mode: $mode"
                        ;;
                esac
            else
                log_warn "Could not find main repo .git directory: $main_gitdir"
            fi
        else
            log_warn "Could not parse worktree .git file: ${proj}/.git"
        fi
    else
        log_warn "Project has no .git: $proj"
    fi
}

# Add tooling repo mount (worktree RW, .git RO)
# Arguments:
#   $1 - Tooling repo path
# Globals:
#   AGENTBOX_MOUNTS
mount_tooling() {
    local tool="$1"

    require_directory "$tool" "Tooling directory"

    tool="$(resolve_path "$tool")"

    # Mount worktree read-write
    mount_mirror "$tool" "rw"

    # Mount .git read-only (prevents commits)
    if [[ -d "${tool}/.git" ]]; then
        mount_mirror "${tool}/.git" "ro"
        log_debug "Tooling .git mounted read-only: $tool"
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

# Add policy bin mount
# Globals:
#   AGENTBOX_POLICY_BIN
#   AGENTBOX_MOUNTS
mount_policy_bin() {
    local policy_bin="${AGENTBOX_POLICY_BIN}"

    if [[ ! -d "$policy_bin" ]]; then
        log_warn "Policy bin directory not found: $policy_bin"
        log_warn "Git wrapper will not be available."
        return 0
    fi

    if [[ ! -x "${policy_bin}/git" ]]; then
        log_warn "Git wrapper not found or not executable: ${policy_bin}/git"
    fi

    mount_add_ro "$policy_bin" "/opt/agentbox/bin"
    log_debug "Policy bin mounted at /opt/agentbox/bin"
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
