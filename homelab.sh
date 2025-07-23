#!/bin/bash

set -euo pipefail

GITHUB_KEYS_URL="https://github.com/razumnyak.keys"
INSTALLER_REPO="https://github.com/razumnyak/homelab"
INSTALLER_DIR="$HOME/installer"
LOG_DIR="$INSTALLER_DIR/logs"
LOG_FILE="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        INFO)  echo -e "${GREEN}[INFO]${NC} $message" ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC} $message" ;;
        ERROR) echo -e "${RED}[ERROR]${NC} $message" ;;
    esac
    
    if [[ -d "$LOG_DIR" ]]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
}

check_os() {
    log INFO "Checking operating system compatibility..."
    
    if [[ ! -f /etc/os-release ]]; then
        log ERROR "Cannot detect operating system. /etc/os-release not found"
        exit 1
    fi
    
    source /etc/os-release
    
    if [[ "$ID" != "ubuntu" ]]; then
        log ERROR "This installer only supports Ubuntu. Detected: $ID"
        exit 1
    fi
    
    if [[ "$VERSION_ID" != "22.04" && "$VERSION_ID" != "24.04" ]]; then
        log WARN "This installer is tested on Ubuntu 22.04 and 24.04. Detected: $VERSION_ID"
    fi
    
    log INFO "OS check passed: $PRETTY_NAME"
}

setup_ssh_keys() {
    log INFO "Setting up SSH keys from GitHub (one-time sync)..."
    
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    
    if [[ -f ~/.ssh/authorized_keys ]] && [[ -s ~/.ssh/authorized_keys ]]; then
        log INFO "Authorized keys already exist, performing smart update..."
        
        local temp_keys="/tmp/github_keys_$$"
        if ! curl -fsSL "$GITHUB_KEYS_URL" > "$temp_keys" 2>/dev/null; then
            log ERROR "Failed to download SSH keys from $GITHUB_KEYS_URL"
            rm -f "$temp_keys"
            exit 1
        fi
        
        if [[ ! -s "$temp_keys" ]]; then
            log ERROR "Downloaded SSH keys file is empty"
            rm -f "$temp_keys"
            exit 1
        fi
        
        cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.backup.$(date +%Y%m%d-%H%M%S)
        
        while IFS= read -r key; do
            if ! grep -qF "$key" ~/.ssh/authorized_keys 2>/dev/null; then
                echo "$key" >> ~/.ssh/authorized_keys
                log INFO "Added new key: ${key:0:50}..."
            fi
        done < "$temp_keys"
        
        rm -f "$temp_keys"
    else
        log INFO "No existing authorized keys, performing initial setup..."
        
        if ! curl -fsSL "$GITHUB_KEYS_URL" > ~/.ssh/authorized_keys 2>/dev/null; then
            log ERROR "Failed to download SSH keys from $GITHUB_KEYS_URL"
            exit 1
        fi
        
        if [[ ! -s ~/.ssh/authorized_keys ]]; then
            log ERROR "Downloaded SSH keys file is empty"
            exit 1
        fi
    fi
    
    chmod 600 ~/.ssh/authorized_keys
    log INFO "SSH keys setup completed successfully"
}

install_git() {
    log INFO "Checking for git installation..."
    
    if command -v git &> /dev/null; then
        log INFO "Git is already installed: $(git --version)"
        return
    fi
    
    log INFO "Installing git..."
    
    if ! sudo apt-get update -qq; then
        log ERROR "Failed to update package index"
        exit 1
    fi
    
    if ! sudo apt-get install -y git; then
        log ERROR "Failed to install git"
        exit 1
    fi
    
    log INFO "Git installed successfully"
}

clone_installer_repo() {
    log INFO "Preparing installer repository..."
    
    if [[ -d "$INSTALLER_DIR" ]]; then
        log INFO "Removing existing installer directory"
        rm -rf "$INSTALLER_DIR"
    fi
    
    log INFO "Cloning installer from $INSTALLER_REPO..."
    
    local temp_dir="/tmp/homelab-repo-$$"
    
    if ! git clone "$INSTALLER_REPO" "$temp_dir"; then
        log ERROR "Failed to clone repository"
        exit 1
    fi
    
    if [[ ! -d "$temp_dir/installer" ]]; then
        log ERROR "Installer directory not found in repository"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    mv "$temp_dir/installer" "$INSTALLER_DIR"
    rm -rf "$temp_dir"
    
    log INFO "Setting executable permissions on scripts..."
    find "$INSTALLER_DIR" -name "*.sh" -type f -exec chmod +x {} \;
    
    log INFO "Installer prepared successfully"
}

main() {
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}       Homelab Automated Installation${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo ""
    
    mkdir -p "$LOG_DIR"
    
    log INFO "Starting homelab installation process..."
    log INFO "Installation log: $LOG_FILE"
    
    check_os
    
    setup_ssh_keys
    
    install_git
    
    clone_installer_repo
    
    log INFO "Launching main installer..."
    
    if [[ ! -f "$INSTALLER_DIR/install.sh" ]]; then
        log ERROR "Main installer script not found at $INSTALLER_DIR/install.sh"
        exit 1
    fi
    
    cd "$INSTALLER_DIR"
    exec bash "$INSTALLER_DIR/install.sh" "$@"
}

trap 'log ERROR "Installation interrupted"; exit 1' INT TERM

main "$@"