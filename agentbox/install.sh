#!/usr/bin/env bash
# agentbox/install.sh - Install agentbox to ~/.agentbox
#
# Usage: ./install.sh [OPTIONS]
#
# shellcheck shell=bash

set -euo pipefail

#######################################
# Configuration
#######################################
INSTALL_DIR="${AGENTBOX_INSTALL_DIR:-${HOME}/.agentbox}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    RESET=$'\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    RESET=''
fi

#######################################
# Helpers
#######################################
log_info() {
    printf '%s[info]%s %s\n' "${BLUE}" "${RESET}" "$*"
}

log_success() {
    printf '%s[ok]%s %s\n' "${GREEN}" "${RESET}" "$*"
}

log_warn() {
    printf '%s[warn]%s %s\n' "${YELLOW}" "${RESET}" "$*"
}

log_error() {
    printf '%s[error]%s %s\n' "${RED}" "${RESET}" "$*" >&2
}

die() {
    log_error "$@"
    exit 1
}

#######################################
# Usage
#######################################
usage() {
    cat <<EOF
Usage: ./install.sh [OPTIONS]

Install agentbox to ~/.agentbox

OPTIONS:
  --prefix PATH     Install to PATH instead of ~/.agentbox
  --link            Create symlinks instead of copying (for development)
  --force           Overwrite existing installation
  --no-config       Don't create config.sh (preserve existing)
  -h, --help        Show this help

After installation, add to your shell rc file:
  export PATH="\$HOME/.agentbox/launchers:\$PATH"

EOF
}

#######################################
# Parse arguments
#######################################
USE_LINKS=0
FORCE=0
SKIP_CONFIG=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --link)
            USE_LINKS=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --no-config)
            SKIP_CONFIG=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

#######################################
# Main installation
#######################################
main() {
    log_info "Installing agentbox to $INSTALL_DIR"

    # Check if already installed
    if [[ -d "$INSTALL_DIR" ]] && [[ $FORCE -eq 0 ]]; then
        log_warn "Installation directory already exists: $INSTALL_DIR"
        log_warn "Use --force to overwrite, or --no-config to preserve config."
        read -rp "Continue and merge? [y/N] " answer
        if [[ ! "$answer" =~ ^[Yy] ]]; then
            die "Installation cancelled."
        fi
    fi

    # Create directory structure
    log_info "Creating directories..."
    mkdir -p "$INSTALL_DIR"/{bin,lib,launchers}

    # Install libraries
    log_info "Installing libraries..."
    if [[ $USE_LINKS -eq 1 ]]; then
        for lib in core.sh mounts.sh env.sh docker.sh slurm.sh; do
            ln -sf "${SCRIPT_DIR}/lib/${lib}" "${INSTALL_DIR}/lib/${lib}"
        done
    else
        cp "${SCRIPT_DIR}"/lib/*.sh "${INSTALL_DIR}/lib/"
    fi
    log_success "Libraries installed"

    # Install bin (git wrapper)
    log_info "Installing git wrapper..."
    if [[ $USE_LINKS -eq 1 ]]; then
        ln -sf "${SCRIPT_DIR}/bin/git" "${INSTALL_DIR}/bin/git"
    else
        cp "${SCRIPT_DIR}/bin/git" "${INSTALL_DIR}/bin/git"
        chmod +x "${INSTALL_DIR}/bin/git"
    fi
    log_success "Git wrapper installed"

    # Install launchers
    log_info "Installing launchers..."
    if [[ $USE_LINKS -eq 1 ]]; then
        ln -sf "${SCRIPT_DIR}/launchers/agentbox-docker" "${INSTALL_DIR}/launchers/agentbox-docker"
        ln -sf "${SCRIPT_DIR}/launchers/agentbox-slurm" "${INSTALL_DIR}/launchers/agentbox-slurm"
    else
        cp "${SCRIPT_DIR}/launchers/agentbox-docker" "${INSTALL_DIR}/launchers/"
        cp "${SCRIPT_DIR}/launchers/agentbox-slurm" "${INSTALL_DIR}/launchers/"
        chmod +x "${INSTALL_DIR}/launchers/"*
    fi
    log_success "Launchers installed"

    # Install config template
    if [[ $SKIP_CONFIG -eq 0 ]]; then
        if [[ -f "${INSTALL_DIR}/config.sh" ]]; then
            log_warn "Config file already exists, not overwriting: ${INSTALL_DIR}/config.sh"
            log_info "Template saved to: ${INSTALL_DIR}/config.sh.template"
            cp "${SCRIPT_DIR}/config.sh.template" "${INSTALL_DIR}/config.sh.template"
        else
            log_info "Creating config file..."
            cp "${SCRIPT_DIR}/config.sh.template" "${INSTALL_DIR}/config.sh"
            log_success "Config file created: ${INSTALL_DIR}/config.sh"
        fi
    fi

    # Print post-install instructions
    echo ""
    log_success "Installation complete!"
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Add to your shell rc file (~/.bashrc or ~/.zshrc):"
    echo ""
    echo "   ${BLUE}export PATH=\"\$HOME/.agentbox/launchers:\$PATH\"${RESET}"
    echo ""
    echo "2. Edit your config file:"
    echo ""
    echo "   ${BLUE}${INSTALL_DIR}/config.sh${RESET}"
    echo ""
    echo "   - Set AGENTBOX_TOOLS to your tooling repos"
    echo "   - Set AGENTBOX_IMAGE_STANDARD to your container image"
    echo ""
    echo "3. Usage:"
    echo ""
    echo "   ${BLUE}agentbox-docker -p ~/project${RESET}        # Docker"
    echo "   ${BLUE}agentbox-slurm -p ~/project${RESET}         # Slurm"
    echo "   ${BLUE}agentbox-slurm --yolo -p ~/project${RESET}  # Allow commits"
    echo ""
}

main "$@"
