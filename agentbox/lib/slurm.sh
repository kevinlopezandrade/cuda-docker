#!/usr/bin/env bash
# agentbox/lib/slurm.sh - Slurm/Pyxis-specific functions
#
# Source this file, do not execute directly.
# Requires: core.sh, mounts.sh, env.sh to be sourced first
# shellcheck shell=bash

#######################################
# Pyxis mount formatting
#######################################

# Convert internal mount spec to Pyxis format
# Pyxis uses: src:dst[:flags]
# Flags are separated by +, e.g., ro+rprivate
# Arguments:
#   $1 - Mount spec "src:dst:flags"
# Outputs:
#   Pyxis mount spec
_pyxis_format_mount() {
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

# Build comma-separated mount string for --container-mounts
# Globals:
#   AGENTBOX_MOUNTS
# Outputs:
#   Comma-separated mount string
pyxis_mount_string() {
    local result=""
    local first=1

    for spec in "${AGENTBOX_MOUNTS[@]}"; do
        if [[ $first -eq 1 ]]; then
            result="$(_pyxis_format_mount "$spec")"
            first=0
        else
            result="${result},$(_pyxis_format_mount "$spec")"
        fi
    done

    echo "$result"
}

#######################################
# Slurm environment formatting
#######################################

# Build --export argument for srun
# Pyxis/srun uses --export=VAR1=val1,VAR2=val2 or --export=ALL,VAR1=val1
# Globals:
#   AGENTBOX_ENV
# Outputs:
#   Export string for --export
slurm_export_string() {
    local result="ALL"  # Inherit current environment
    local has_vars=0

    for name in "${!AGENTBOX_ENV[@]}"; do
        if env_is_unset "$name"; then
            # Slurm doesn't have a direct "unset" - we set to empty
            # and rely on the wrapper to handle it
            continue
        else
            result="${result},${name}=${AGENTBOX_ENV[$name]}"
            has_vars=1
        fi
    done

    echo "$result"
}

#######################################
# Srun command builder
#######################################

# Build complete srun command with Pyxis options
# Arguments:
#   $1 - Image name
#   $2 - Working directory
#   $3 - Container name (optional, for reattachment)
#   $@ - Additional srun args (after --)
# Globals:
#   AGENTBOX_MOUNTS
#   AGENTBOX_ENV
# Outputs:
#   Command as array elements (one per line)
slurm_build_command() {
    local image="$1"
    local workdir="$2"
    local container_name="${3:-}"
    shift 3 || shift $#
    local -a extra_args=("$@")

    echo "srun"

    # Pyxis container options
    echo "--container-image=${image}"
    echo "--container-mounts=$(pyxis_mount_string)"
    echo "--container-workdir=${workdir}"

    # Container name for reattachment (if provided)
    if [[ -n "$container_name" ]]; then
        echo "--container-name=${container_name}"
    fi

    # Environment export
    echo "--export=$(slurm_export_string)"

    # Don't remap to root (keeps UID/GID consistent)
    echo "--no-container-remap-root"

    # Extra args passed by user (Slurm options like --gpus, --mem, etc.)
    for arg in "${extra_args[@]}"; do
        echo "$arg"
    done
}

# Execute srun with Pyxis
# Arguments:
#   $1 - Image name
#   $2 - Working directory
#   $3 - Container name (optional)
#   $4 - Command to run in container (optional)
#   $@ - Additional srun args
# Globals:
#   AGENTBOX_MOUNTS
#   AGENTBOX_ENV
slurm_run() {
    local image="$1"
    local workdir="$2"
    local container_name="${3:-}"
    local container_cmd="${4:-bash}"
    shift 4 || shift $#
    local -a extra_args=("$@")

    require_command srun "Slurm is not available on this system."

    local -a cmd=()

    # Base srun command
    cmd+=(srun)

    # Pyxis options
    cmd+=("--container-image=${image}")
    cmd+=("--container-mounts=$(pyxis_mount_string)")
    cmd+=("--container-workdir=${workdir}")

    # Container name
    if [[ -n "$container_name" ]]; then
        cmd+=("--container-name=${container_name}")
    fi

    # Environment
    cmd+=("--export=$(slurm_export_string)")

    # UID/GID handling
    cmd+=(--no-container-remap-root)

    # Extra Slurm args
    cmd+=("${extra_args[@]}")

    # Interactive terminal
    cmd+=(--pty)

    # Container command
    cmd+=("$container_cmd")

    log_debug "Slurm command: ${cmd[*]}"
    log_info "Launching Slurm container job..."

    exec "${cmd[@]}"
}

#######################################
# Slurm utilities
#######################################

# Check if we're on a Slurm cluster
# Returns:
#   0 if srun is available, 1 otherwise
slurm_is_available() {
    command_exists srun
}

# Validate Slurm/Pyxis is available
slurm_validate() {
    require_command srun "Slurm (srun) is not available on this system."

    # Check if Pyxis plugin is available by looking for container options
    if ! srun --help 2>&1 | grep -q -- '--container-image'; then
        die 1 "Pyxis plugin does not appear to be installed. --container-image option not found."
    fi

    log_debug "Slurm with Pyxis is available"
}

#######################################
# Container reattachment
#######################################

# Attach to an existing named container
# Arguments:
#   $1 - Container name
#   $@ - Additional srun args
slurm_attach() {
    local container_name="$1"
    shift
    local -a extra_args=("$@")

    require_command srun

    local -a cmd=(
        srun
        "--container-name=${container_name}"
        --no-container-remap-root
        --pty
        "${extra_args[@]}"
        bash
    )

    log_debug "Attach command: ${cmd[*]}"
    log_info "Attaching to container: $container_name"

    exec "${cmd[@]}"
}
