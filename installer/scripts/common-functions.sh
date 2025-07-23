#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

HOMELAB_DIR="${HOMELAB_DIR:-$HOME/homelab}"
LOGS_DIR="${LOGS_DIR:-$HOMELAB_DIR/logs}"
INSTALLED_CSV="${INSTALLED_CSV:-$HOMELAB_DIR/installed.csv}"

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_file="$LOGS_DIR/install-$(date +%Y%m%d).log"
    
    case "$level" in
        INFO)  echo -e "${GREEN}[INFO]${NC} $message" ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC} $message" ;;
        ERROR) echo -e "${RED}[ERROR]${NC} $message" ;;
        DEBUG) [[ -n "$DEBUG" ]] && echo -e "${BLUE}[DEBUG]${NC} $message" ;;
    esac
    
    if [[ -d "$LOGS_DIR" ]]; then
        echo "[$timestamp] [$level] $message" >> "$log_file"
    fi
}

error() {
    log ERROR "$@"
    exit 1
}

validate_ip() {
    local ip=$1
    local valid_ip_regex='^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$'
    
    if [[ $ip =~ $valid_ip_regex ]]; then
        return 0
    else
        return 1
    fi
}

check_command() {
    local cmd=$1
    if command -v "$cmd" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

add_to_installed() {
    local type="$1"
    local name="$2"
    local version="$3"
    local location="$4"
    local config_path="$5"
    local notes="${6:-}"
    local timestamp=$(date -Iseconds)
    
    if [[ -f "$INSTALLED_CSV" ]]; then
        echo "$timestamp,$type,$name,$version,$location,$config_path,$notes" >> "$INSTALLED_CSV"
    fi
}

backup_file() {
    local file="$1"
    local backup_suffix="${2:-.original}"
    
    if [[ -f "$file" && ! -f "${file}${backup_suffix}" ]]; then
        cp "$file" "${file}${backup_suffix}"
        log INFO "Backed up $file to ${file}${backup_suffix}"
    fi
}

create_symlink() {
    local source="$1"
    local target="$2"
    
    if [[ -e "$target" && ! -L "$target" ]]; then
        backup_file "$target"
        sudo rm -f "$target"
    fi
    
    sudo ln -sf "$source" "$target"
    log INFO "Created symlink: $target -> $source"
}

wait_for_service() {
    local service="$1"
    local max_attempts="${2:-30}"
    local delay="${3:-2}"
    local attempt=0
    
    log INFO "Waiting for $service to be ready..."
    
    while [ $attempt -lt $max_attempts ]; do
        if systemctl is-active --quiet "$service"; then
            log INFO "$service is ready"
            return 0
        fi
        
        attempt=$((attempt + 1))
        sleep "$delay"
    done
    
    log ERROR "$service failed to start within $((max_attempts * delay)) seconds"
    return 1
}

get_primary_ip() {
    ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[^ ]+'
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    
    if [[ "$default" == "y" ]]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    
    read -p "$prompt" response
    
    if [[ -z "$response" ]]; then
        response="$default"
    fi
    
    [[ "$response" =~ ^[Yy]$ ]]
}

ensure_sudo() {
    if ! sudo -n true 2>/dev/null; then
        log INFO "This operation requires sudo privileges."
        sudo -v
    fi
}

get_ubuntu_version() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "$VERSION_ID"
    else
        echo "unknown"
    fi
}

export -f log error validate_ip check_command add_to_installed backup_file create_symlink wait_for_service get_primary_ip prompt_yes_no ensure_sudo get_ubuntu_version