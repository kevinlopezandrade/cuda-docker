#!/bin/bash
# agentbox container entrypoint
#
# This script handles two scenarios:
# 1. Docker: Runs as root, creates home directory, drops privileges via gosu
# 2. Pyxis/Enroot: Already running as user, just ensures home directory exists
#
# Required environment variables (for Docker/root mode):
#   HOST_UID  - UID to run as (from host)
#   HOST_GID  - GID to run as (from host)
#
# Requires:
#   - gosu installed in the container (for Docker mode)
#   - /etc/passwd mounted from host (for username resolution)

set -euo pipefail

readonly SCRIPT_NAME="agentbox-entrypoint"

log_info() {
    echo "[$SCRIPT_NAME] $*" >&2
}

log_error() {
    echo "[$SCRIPT_NAME] ERROR: $*" >&2
}

die() {
    log_error "$@"
    exit 1
}

# If no command provided, default to bash
if [[ $# -eq 0 ]]; then
    set -- bash
fi

# Check if we're running as root
if [[ "$(id -u)" -eq 0 ]]; then
    # Running as root (Docker mode) - need to create home and drop privileges

    # Validate required environment variables
    [[ -z "${HOST_UID:-}" ]] && die "HOST_UID environment variable is required but not set"
    [[ -z "${HOST_GID:-}" ]] && die "HOST_GID environment variable is required but not set"

    # Validate gosu is available
    command -v gosu >/dev/null 2>&1 || die "gosu is not installed"

    # Resolve username from UID (requires /etc/passwd mounted from host)
    if getent passwd "$HOST_UID" >/dev/null 2>&1; then
        USERNAME=$(getent passwd "$HOST_UID" | cut -d: -f1)
        USER_HOME=$(getent passwd "$HOST_UID" | cut -d: -f6)
    else
        die "Cannot resolve username for UID $HOST_UID. Is /etc/passwd mounted from host?"
    fi

    # Validate we got reasonable values
    [[ -z "$USERNAME" ]] && die "Failed to resolve username for UID $HOST_UID"
    [[ -z "$USER_HOME" ]] && die "Failed to resolve home directory for UID $HOST_UID"

    # Create home directory if it doesn't exist
    if [[ ! -d "$USER_HOME" ]]; then
        log_info "Creating home directory: $USER_HOME"
        mkdir -p "$USER_HOME"
        chown "$HOST_UID:$HOST_GID" "$USER_HOME"
    elif [[ "$(stat -c %u "$USER_HOME")" != "$HOST_UID" ]]; then
        # Home exists but wrong owner (e.g., created by Docker for mount)
        log_info "Fixing ownership of home directory: $USER_HOME"
        chown "$HOST_UID:$HOST_GID" "$USER_HOME"
    fi

    # Create ~/.local/bin symlink for claude (Claude Code expects it there)
    local_bin="$USER_HOME/.local/bin"
    if [[ ! -d "$local_bin" ]]; then
        mkdir -p "$local_bin"
        chown "$HOST_UID:$HOST_GID" "$USER_HOME/.local" "$local_bin"
    fi
    if [[ ! -e "$local_bin/claude" ]] && [[ -x /usr/local/bin/claude ]]; then
        ln -sf /usr/local/bin/claude "$local_bin/claude"
    fi

    # Ensure ~/.config exists with correct ownership
    # (Docker may create it as root when mounting subdirs like ~/.config/marimo)
    config_dir="$USER_HOME/.config"
    if [[ -d "$config_dir" ]] && [[ "$(stat -c %u "$config_dir")" != "$HOST_UID" ]]; then
        log_info "Fixing ownership of .config directory"
        chown "$HOST_UID:$HOST_GID" "$config_dir"
    elif [[ ! -d "$config_dir" ]]; then
        mkdir -p "$config_dir"
        chown "$HOST_UID:$HOST_GID" "$config_dir"
    fi

    # Ensure ~/.local/share exists with correct ownership
    # (Docker may create it as root when mounting subdirs like ~/.local/share/uv)
    local_share_dir="$USER_HOME/.local/share"
    if [[ -d "$local_share_dir" ]] && [[ "$(stat -c %u "$local_share_dir")" != "$HOST_UID" ]]; then
        log_info "Fixing ownership of .local/share directory"
        chown "$HOST_UID:$HOST_GID" "$local_share_dir"
    elif [[ ! -d "$local_share_dir" ]]; then
        mkdir -p "$local_share_dir"
        chown "$HOST_UID:$HOST_GID" "$USER_HOME/.local" "$local_share_dir"
    fi

    # Drop privileges and execute the command
    log_info "Running as $USERNAME (UID=$HOST_UID, GID=$HOST_GID)"
    exec gosu "$HOST_UID:$HOST_GID" "$@"
else
    # Not running as root (Pyxis/Enroot mode) - already running as user
    CURRENT_UID=$(id -u)

    # Try to resolve home directory
    if getent passwd "$CURRENT_UID" >/dev/null 2>&1; then
        USER_HOME=$(getent passwd "$CURRENT_UID" | cut -d: -f6)
        USERNAME=$(getent passwd "$CURRENT_UID" | cut -d: -f1)

        # Try to create home directory (may fail if parent is not writable)
        if [[ -n "$USER_HOME" ]] && [[ ! -d "$USER_HOME" ]]; then
            if mkdir -p "$USER_HOME" 2>/dev/null; then
                log_info "Created home directory: $USER_HOME"
            else
                log_info "Warning: Could not create home directory $USER_HOME (parent not writable)"
            fi
        fi

        log_info "Running as $USERNAME (UID=$CURRENT_UID)"
    else
        log_info "Running as UID $CURRENT_UID"
    fi

    # Execute the command directly
    exec "$@"
fi
