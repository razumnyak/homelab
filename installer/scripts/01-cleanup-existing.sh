#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-functions.sh"

cleanup_k3s() {
    log INFO "Cleaning up K3s installation..."
    
    if command -v k3s-uninstall.sh &>/dev/null; then
        log WARN "Removing K3s server..."
        sudo k3s-uninstall.sh || true
    fi
    
    if command -v k3s-agent-uninstall.sh &>/dev/null; then
        log WARN "Removing K3s agent..."
        sudo k3s-agent-uninstall.sh || true
    fi
    
    sudo rm -rf /etc/rancher /var/lib/rancher
    sudo rm -f /usr/local/bin/k3s* /usr/local/bin/kubectl
    sudo rm -f /etc/systemd/system/k3s*.service
    
    log INFO "K3s cleanup completed"
}

cleanup_network() {
    log INFO "Cleaning up network configurations..."
    
    sudo ip link delete cni0 2>/dev/null || true
    sudo ip link delete flannel.1 2>/dev/null || true
    
    sudo rm -rf /etc/cni /var/lib/cni /opt/cni
    
    sudo iptables -F || true
    sudo iptables -t nat -F || true
    sudo iptables -t mangle -F || true
    
    log INFO "Network cleanup completed"
}

cleanup_ssh_agent() {
    log INFO "Cleaning up SSH agent service..."
    
    # Stop and disable SSH agent service if it exists
    if systemctl is-active --quiet ssh-agent 2>/dev/null; then
        log INFO "Stopping SSH agent service..."
        sudo systemctl stop ssh-agent || true
    fi
    
    if systemctl is-enabled --quiet ssh-agent 2>/dev/null; then
        log INFO "Disabling SSH agent service..."
        sudo systemctl disable ssh-agent || true
    fi
    
    # Remove SSH agent socket if it exists
    sudo rm -f /run/ssh-agent.socket || true
    
    log INFO "SSH agent cleanup completed"
}

main() {
    log INFO "Starting system cleanup..."
    
    if [[ "${HOMELAB_FACTORY_RESET_DONE:-false}" == "true" ]]; then
        log INFO "Factory reset was performed, skipping cleanup"
        return 0
    fi
    
    cleanup_k3s
    cleanup_network
    cleanup_ssh_agent
    
    log INFO "System cleanup completed"
}

main "$@"