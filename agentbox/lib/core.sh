#!/usr/bin/env bash
# agentbox/lib/core.sh - Core utilities (logging, validation, errors)
#
# Source this file, do not execute directly.
# shellcheck shell=bash

set -euo pipefail

#######################################
# Constants
#######################################
readonly AGENTBOX_VERSION="1.0.0"
readonly AGENTBOX_DIR="${AGENTBOX_DIR:-${HOME}/.agentbox}"
readonly AGENTBOX_CONFIG="${AGENTBOX_DIR}/config.sh"
readonly AGENTBOX_POLICY_BIN="${AGENTBOX_DIR}/bin"

# Colors (disabled if not a terminal)
if [[ -t 2 ]]; then
    readonly _RED=$'\033[0;31m'
    readonly _GREEN=$'\033[0;32m'
    readonly _YELLOW=$'\033[0;33m'
    readonly _BLUE=$'\033[0;34m'
    readonly _RESET=$'\033[0m'
else
    readonly _RED=''
    readonly _GREEN=''
    readonly _YELLOW=''
    readonly _BLUE=''
    readonly _RESET=''
fi

#######################################
# Logging functions
#######################################

# Log an info message to stderr
# Arguments:
#   $@ - Message to log
log_info() {
    printf '%s[info]%s %s\n' "${_BLUE}" "${_RESET}" "$*" >&2
}

# Log a warning message to stderr
# Arguments:
#   $@ - Message to log
log_warn() {
    printf '%s[warn]%s %s\n' "${_YELLOW}" "${_RESET}" "$*" >&2
}

# Log an error message to stderr
# Arguments:
#   $@ - Message to log
log_error() {
    printf '%s[error]%s %s\n' "${_RED}" "${_RESET}" "$*" >&2
}

# Log a success message to stderr
# Arguments:
#   $@ - Message to log
log_success() {
    printf '%s[ok]%s %s\n' "${_GREEN}" "${_RESET}" "$*" >&2
}

# Log a debug message to stderr (only if AGENTBOX_DEBUG=1)
# Arguments:
#   $@ - Message to log
log_debug() {
    if [[ "${AGENTBOX_DEBUG:-0}" == "1" ]]; then
        printf '[debug] %s\n' "$*" >&2
    fi
}

#######################################
# Error handling
#######################################

# Exit with an error message
# Arguments:
#   $1 - Exit code
#   $2 - Error message
die() {
    local code="$1"
    shift
    log_error "$@"
    exit "$code"
}

# Exit with usage error
# Arguments:
#   $1 - Error message
die_usage() {
    log_error "$1"
    log_error "Run with --help for usage information."
    exit 2
}

#######################################
# Validation functions
#######################################

# Check if a command exists
# Arguments:
#   $1 - Command name
# Returns:
#   0 if command exists, 1 otherwise
command_exists() {
    command -v "$1" &>/dev/null
}

# Require a command to exist, die if not
# Arguments:
#   $1 - Command name
#   $2 - Optional package/install hint
require_command() {
    local cmd="$1"
    local hint="${2:-}"
    if ! command_exists "$cmd"; then
        if [[ -n "$hint" ]]; then
            die 1 "Required command '$cmd' not found. $hint"
        else
            die 1 "Required command '$cmd' not found."
        fi
    fi
}

# Validate that a path exists and is a directory
# Arguments:
#   $1 - Path to validate
#   $2 - Description for error message
require_directory() {
    local path="$1"
    local desc="${2:-Directory}"
    if [[ ! -d "$path" ]]; then
        die 1 "$desc does not exist or is not a directory: $path"
    fi
}

# Validate that a path exists and is a file
# Arguments:
#   $1 - Path to validate
#   $2 - Description for error message
require_file() {
    local path="$1"
    local desc="${2:-File}"
    if [[ ! -f "$path" ]]; then
        die 1 "$desc does not exist or is not a file: $path"
    fi
}

# Validate that a path contains a .git directory (is a git repo)
# Arguments:
#   $1 - Path to validate
#   $2 - Description for error message
require_git_repo() {
    local path="$1"
    local desc="${2:-Path}"
    require_directory "$path" "$desc"
    if [[ ! -d "${path}/.git" ]]; then
        die 1 "$desc is not a git repository (no .git directory): $path"
    fi
}

#######################################
# Path utilities
#######################################

# Resolve a path to its absolute form
# Arguments:
#   $1 - Path to resolve
# Outputs:
#   Absolute path
resolve_path() {
    local path="$1"
    if [[ -d "$path" ]]; then
        (cd "$path" && pwd)
    elif [[ -f "$path" ]]; then
        local dir
        dir="$(dirname "$path")"
        echo "$(cd "$dir" && pwd)/$(basename "$path")"
    else
        # Path doesn't exist yet, resolve parent
        local dir
        dir="$(dirname "$path")"
        if [[ -d "$dir" ]]; then
            echo "$(cd "$dir" && pwd)/$(basename "$path")"
        else
            die 1 "Cannot resolve path (parent does not exist): $path"
        fi
    fi
}

#######################################
# Configuration
#######################################

# Load user configuration
# Globals:
#   Sets various AGENTBOX_* variables from config
load_config() {
    if [[ -f "$AGENTBOX_CONFIG" ]]; then
        log_debug "Loading config from $AGENTBOX_CONFIG"
        # shellcheck source=/dev/null
        source "$AGENTBOX_CONFIG"
    else
        log_warn "No config file found at $AGENTBOX_CONFIG"
        log_warn "Run 'agentbox-init' to create one."
    fi
}

#######################################
# Array utilities
#######################################

# Join array elements with a delimiter
# Arguments:
#   $1 - Delimiter
#   $@ - Array elements
# Outputs:
#   Joined string
join_by() {
    local delimiter="$1"
    shift
    local first="$1"
    shift
    printf '%s' "$first"
    printf '%s' "${@/#/$delimiter}"
}
