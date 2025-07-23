#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-functions.sh"

# Set default values if not already set
HOMELAB_DIR="${HOMELAB_DIR:-$HOME/homelab}"
CONFIG_DIR="${CONFIG_DIR:-$HOMELAB_DIR/configs}"
NODE_INFO="${NODE_INFO:-$HOMELAB_DIR/node.info}"

# Source node info if exists
if [[ -f "$NODE_INFO" ]]; then
    source "$NODE_INFO"
fi

K3S_VERSION="v1.30.5+k3s1"
K3S_CONFIG_DIR="$CONFIG_DIR/k3s"
K3S_INSTALL_SCRIPT="/usr/local/bin/k3s-install.sh"

download_k3s_installer() {
    log INFO "Downloading K3s installation script..."
    
    if [[ -f "$K3S_INSTALL_SCRIPT" ]]; then
        log INFO "K3s installer already downloaded"
        return
    fi
    
    if ! sudo curl -sfL https://get.k3s.io -o "$K3S_INSTALL_SCRIPT"; then
        error "Failed to download K3s installation script"
    fi
    
    sudo chmod +x "$K3S_INSTALL_SCRIPT"
    add_to_installed "dependency" "k3s-installer" "latest" "$K3S_INSTALL_SCRIPT" "none" "K3s installation script"
}

get_node_token() {
    log INFO "Retrieving node token from master..."
    
    local token_file="$K3S_CONFIG_DIR/node-token"
    mkdir -p "$K3S_CONFIG_DIR"
    
    echo ""
    echo "Please provide the K3s node token from the master node."
    echo "You can find it at: ~/homelab/configs/k3s/node-token on the master"
    echo ""
    
    read -p "Enter K3s node token: " node_token
    
    if [[ -z "$node_token" ]]; then
        error "Node token cannot be empty"
    fi
    
    echo "$node_token" > "$token_file"
    chmod 600 "$token_file"
    
    K3S_TOKEN="$node_token"
}

configure_k3s_agent() {
    log INFO "Preparing K3s agent configuration..."
    
    local agent_config="$K3S_CONFIG_DIR/config.yaml"
    
    cat > "$agent_config" <<EOF
node-name: "$NODE_NAME"
kubelet-arg:
  - "eviction-hard=memory.available<100Mi,nodefs.available<10%,nodefs.inodesFree<5%"
  - "eviction-soft=memory.available<300Mi,nodefs.available<15%"
  - "eviction-soft-grace-period=memory.available=30s,nodefs.available=30s"
  - "max-pods=110"
node-label:
  - "node-role.kubernetes.io/worker=true"
  - "homelab/node-type=worker"
EOF
    
    sudo mkdir -p /etc/rancher/k3s
    create_symlink "$agent_config" "/etc/rancher/k3s/config.yaml"
    
    add_to_installed "config" "k3s-agent" "$K3S_VERSION" "/etc/rancher/k3s/config.yaml" "$agent_config" "K3s agent configuration"
}

install_k3s_agent() {
    log INFO "Installing K3s agent..."
    
    ensure_sudo
    
    local k3s_url="https://$MASTER_IP:6443"
    local install_cmd="K3S_URL=$k3s_url K3S_TOKEN=$K3S_TOKEN INSTALL_K3S_VERSION=$K3S_VERSION $K3S_INSTALL_SCRIPT agent"
    
    log INFO "Connecting to K3s server at $k3s_url"
    
    if ! eval "sudo $install_cmd"; then
        error "Failed to install K3s agent"
    fi
    
    if ! wait_for_service "k3s-agent" 60 5; then
        error "K3s agent failed to start"
    fi
    
    add_to_installed "service" "k3s-agent" "$K3S_VERSION" "systemd" "/etc/systemd/system/k3s-agent.service" "K3s Kubernetes agent"
}

verify_agent_status() {
    log INFO "Verifying K3s agent status..."
    
    sleep 10
    
    if systemctl is-active --quiet k3s-agent; then
        log INFO "K3s agent is running"
        
        echo ""
        echo "K3s Agent Status:"
        echo "================="
        sudo systemctl status k3s-agent --no-pager | head -10
        echo ""
        
        cat > "$DOCS_DIR/k3s-agent-info.txt" <<EOF
K3s Agent Node Information
=========================

Node Name: $NODE_NAME
Master Server: https://$MASTER_IP:6443
Version: $K3S_VERSION
Service: k3s-agent

To check node status from master:
kubectl get node $NODE_NAME
EOF
        
        log INFO "K3s agent information saved to $DOCS_DIR/k3s-agent-info.txt"
    else
        log WARN "K3s agent is not running, check logs with: sudo journalctl -u k3s-agent"
    fi
}

main() {
    log INFO "Starting K3s agent installation..."
    
    if [[ -z "$MASTER_IP" ]]; then
        error "Master IP not configured. Please run the installer again."
    fi
    
    download_k3s_installer
    
    get_node_token
    
    configure_k3s_agent
    
    install_k3s_agent
    
    # Register this slave node with master
    log INFO "Registering with master node..."
    "$SCRIPT_DIR/update-nodes-list.sh" register "$MASTER_IP"
    
    verify_agent_status
    
    log INFO "K3s agent installation completed successfully"
}

main "$@"