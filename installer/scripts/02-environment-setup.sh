#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="${HOMELAB_DIR:-$HOME/homelab}"
ENV_FILE="$HOMELAB_DIR/.env"
ENV_TEMPLATE="$SCRIPT_DIR/../.env.template"

source "$SCRIPT_DIR/common-functions.sh"

# Load .env file if it exists (for auto-install support)
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
fi

create_env_file() {
    mkdir -p "$HOMELAB_DIR"
    
    # Create required subdirectories
    mkdir -p "$HOMELAB_DIR/logs"
    mkdir -p "$HOMELAB_DIR/scripts"
    mkdir -p "$HOMELAB_DIR/configs"
    mkdir -p "$HOMELAB_DIR/backups"
    
    if [[ ! -f "$ENV_FILE" ]]; then
        log INFO "Creating .env file from template..."
        if [[ -f "$ENV_TEMPLATE" ]]; then
            cp "$ENV_TEMPLATE" "$ENV_FILE"
        else
            touch "$ENV_FILE"
        fi
        chmod 600 "$ENV_FILE"
    fi
}

load_environment() {
    if [[ -f "$ENV_FILE" ]]; then
        set -a
        source "$ENV_FILE"
        set +a
        log INFO "Environment loaded from $ENV_FILE"
    fi
}

validate_required_vars() {
    local missing=()
    
    [[ -z "${NODE_TYPE:-}" ]] && missing+=("NODE_TYPE")
    [[ "${NODE_TYPE:-}" == "slave-node" && -z "${MASTER_IP:-}" ]] && missing+=("MASTER_IP")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log ERROR "Missing required variables: ${missing[*]}"
        return 1
    fi
    
    return 0
}

interactive_setup() {
    echo ""
    echo "=== Interactive Environment Setup ==="
    
    if [[ -z "${NODE_TYPE:-}" ]]; then
        if [[ "${AUTO_CONFIRM:-false}" == "true" ]]; then
            log WARN "AUTO_CONFIRM enabled but NODE_TYPE not set in environment"
            log ERROR "Please set NODE_TYPE in ~/homelab/.env"
            exit 1
        fi
        
        echo ""
        echo "Select node type:"
        echo "1) master-node"
        echo "2) slave-node"
        read -p "Choice (1-2): " choice
        
        case $choice in
            1) echo "NODE_TYPE=master-node" >> "$ENV_FILE" ;;
            2) 
                echo "NODE_TYPE=slave-node" >> "$ENV_FILE"
                read -p "Enter master node IP: " master_ip
                echo "MASTER_IP=$master_ip" >> "$ENV_FILE"
                ;;
            *) log ERROR "Invalid choice"; exit 1 ;;
        esac
    fi
    
    if [[ "${NODE_TYPE:-}" == "slave-node" && -z "${MASTER_IP:-}" ]]; then
        if [[ "${AUTO_CONFIRM:-false}" == "true" ]]; then
            log ERROR "MASTER_IP is required for slave-node when AUTO_CONFIRM is enabled"
            exit 1
        fi
        
        read -p "Enter master node IP: " master_ip
        echo "MASTER_IP=$master_ip" >> "$ENV_FILE"
    fi
}

main() {
    log INFO "Environment setup..."
    
    create_env_file
    load_environment
    
    if ! validate_required_vars; then
        if [[ "${AUTO_CONFIRM:-false}" == "true" ]]; then
            log ERROR "Auto-confirm mode requires all variables in ~/homelab/.env"
            log ERROR "Copy template: cp installer/.env.template ~/homelab/.env"
            exit 1
        else
            interactive_setup
            load_environment
            validate_required_vars || exit 1
        fi
    fi
    
    log INFO "Environment setup completed"
    log INFO "Node type: ${NODE_TYPE}"
    if [[ "${NODE_TYPE}" == "slave-node" ]] && [[ -n "${MASTER_IP:-}" ]]; then
        log INFO "Master IP: ${MASTER_IP}"
    fi
}

main "$@"