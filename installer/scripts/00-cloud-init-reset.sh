#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-functions.sh"

main() {
    log INFO "System initialization check..."
    
    if [[ "${HOMELAB_RESET:-false}" == "true" ]] || [[ -f "$HOME/.homelab-reset" ]]; then
        log WARN "Factory reset requested - performing cloud-init reset..."
        export HOMELAB_FACTORY_RESET_DONE=true
        sudo cloud-init clean --logs --reboot
        exit 0
    fi
    
    if [[ "${AUTO_CONFIRM:-false}" == "true" ]]; then
        log INFO "Auto-confirm mode: Continuing with normal installation"
        return 0
    fi
    
    echo ""
    echo "Do you want to start with a completely clean system?"
    echo "This will reset everything to factory defaults and reboot."
    echo ""
    
    read -p "Factory reset now? (y/N): " response
    
    if [[ "$response" =~ ^[Yy]$ ]]; then
        log WARN "Starting factory reset..."
        export HOMELAB_FACTORY_RESET_DONE=true
        sudo cloud-init clean --logs --reboot
        exit 0
    else
        log INFO "Continuing with normal installation"
    fi
}

main "$@"