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

# Validate that a path is a git repo (has .git directory or file)
# Handles regular repos (.git directory), worktrees (.git file), and submodules (.git file)
# Arguments:
#   $1 - Path to validate
#   $2 - Description for error message
require_git_repo() {
    local path="$1"
    local desc="${2:-Path}"
    require_directory "$path" "$desc"
    # Accept .git as directory (regular repo) or file (worktree/submodule)
    if [[ ! -d "${path}/.git" && ! -f "${path}/.git" ]]; then
        die 1 "$desc is not a git repository (no .git): $path"
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

#######################################
# Git utilities
#######################################

# Find the root git directory for a repo, worktree, or submodule
# Arguments:
#   $1 - Path to git repo, worktree, or submodule
# Outputs:
#   Path to the root git directory (the one with actual .git directory)
# Returns:
#   0 on success, 1 if not a git repo
find_git_root() {
    local path="$1"

    # Use git rev-parse to find the toplevel and git-dir
    local toplevel
    toplevel="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || return 1

    local git_dir
    git_dir="$(git -C "$path" rev-parse --git-dir 2>/dev/null)" || return 1

    # If git_dir is relative, make it absolute
    if [[ "$git_dir" != /* ]]; then
        git_dir="$(cd "$path" && cd "$git_dir" && pwd)"
    fi

    # For regular repos: git_dir is /path/to/repo/.git
    # For worktrees: git_dir is /path/to/main/.git/worktrees/<name>
    # For submodules: git_dir is /path/to/parent/.git/modules/<name>

    # Check if this is a worktree (git_dir contains /worktrees/)
    if [[ "$git_dir" == */.git/worktrees/* ]]; then
        # Extract the main repo path: /path/to/repo/.git/worktrees/name -> /path/to/repo
        local main_git_dir="${git_dir%/worktrees/*}"
        echo "${main_git_dir%/.git}"
        return 0
    fi

    # Check if this is a submodule (git_dir contains /modules/)
    if [[ "$git_dir" == */.git/modules/* ]]; then
        # For submodules, return the submodule's working directory (not the parent)
        # because the user wants to work on the submodule itself
        echo "$toplevel"
        return 0
    fi

    # Regular repo - return toplevel
    echo "$toplevel"
}

#######################################
# Worktree utilities
#######################################

# Generate a short unique ID (4 hex chars based on timestamp + random)
# Outputs:
#   Short hex ID (e.g., "a3f2")
generate_short_id() {
    printf '%04x' $(( ($(date +%s) + RANDOM) % 65536 ))
}

# Create a git worktree for agent work
# Arguments:
#   $1 - Source git repo path
#   $2 - Branch name (optional, auto-generated if empty)
# Outputs:
#   Path to the created worktree
# Globals:
#   Sets AGENTBOX_WORKTREE_PATH and AGENTBOX_WORKTREE_BRANCH
create_agent_worktree() {
    local repo_path="$1"
    local branch="${2:-}"

    # Generate short ID for naming
    local short_id
    short_id="$(generate_short_id)"

    # Generate branch name if not provided
    if [[ -z "$branch" ]]; then
        branch="agent/${short_id}"
    fi

    # Generate worktree path inside {repo_name}-agents directory
    local repo_name
    repo_name="$(basename "$repo_path")"
    local repo_parent
    repo_parent="$(dirname "$repo_path")"

    # Use branch name suffix if provided, otherwise use short_id
    local wt_suffix
    if [[ "$branch" == "agent/${short_id}" ]]; then
        wt_suffix="$short_id"
    else
        # Use last component of branch name
        wt_suffix="${branch##*/}"
    fi

    # Create agents directory if it doesn't exist
    local agents_dir="${repo_parent}/${repo_name}-agents"
    if [[ ! -d "$agents_dir" ]]; then
        mkdir -p "$agents_dir" || die 1 "Failed to create agents directory: $agents_dir"
        log_info "Created agents directory: $agents_dir"
    fi

    local worktree_path="${agents_dir}/wt-${wt_suffix}"

    # Check if worktree path already exists
    if [[ -e "$worktree_path" ]]; then
        die 1 "Worktree path already exists: $worktree_path"
    fi

    # Check if branch exists
    local branch_exists=0
    if git -C "$repo_path" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
        branch_exists=1
    fi

    log_info "Creating worktree at: $worktree_path"
    log_info "Branch: $branch"

    # Create worktree
    if [[ $branch_exists -eq 1 ]]; then
        # Branch exists, use it
        git -C "$repo_path" worktree add "$worktree_path" "$branch" || \
            die 1 "Failed to create worktree"
    else
        # Create new branch from current HEAD
        git -C "$repo_path" worktree add -b "$branch" "$worktree_path" || \
            die 1 "Failed to create worktree with new branch"
    fi

    log_success "Worktree created"

    # Set globals for caller
    AGENTBOX_WORKTREE_PATH="$worktree_path"
    AGENTBOX_WORKTREE_BRANCH="$branch"
}
