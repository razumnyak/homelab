#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-functions.sh"

# Set default values if not already set
HOMELAB_DIR="${HOMELAB_DIR:-$HOME/homelab}"
CONFIG_DIR="${CONFIG_DIR:-$HOMELAB_DIR/configs}"
DOCS_DIR="${DOCS_DIR:-$HOMELAB_DIR/docs}"

K3S_VERSION="v1.30.5+k3s1"
K3S_CONFIG_DIR="$CONFIG_DIR/k3s"
K3S_TOKEN_FILE="$K3S_CONFIG_DIR/node-token"
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

configure_k3s_server() {
    log INFO "Preparing K3s server configuration..."
    
    mkdir -p "$K3S_CONFIG_DIR"
    
    local server_config="$K3S_CONFIG_DIR/config.yaml"
    local primary_ip=$(get_primary_ip)
    
    cat > "$server_config" <<EOF
write-kubeconfig-mode: "0644"
cluster-cidr: "10.42.0.0/16"
service-cidr: "10.43.0.0/16"
cluster-dns: "10.43.0.10"
tls-san:
  - "$primary_ip"
  - "master"
  - "master.local"
  - "localhost"
  - "127.0.0.1"
disable:
  - traefik
  - servicelb
kubelet-arg:
  - "eviction-hard=memory.available<100Mi,nodefs.available<10%,nodefs.inodesFree<5%"
  - "eviction-soft=memory.available<300Mi,nodefs.available<15%"
  - "eviction-soft-grace-period=memory.available=30s,nodefs.available=30s"
  - "max-pods=110"
EOF
    
    sudo mkdir -p /etc/rancher/k3s
    create_symlink "$server_config" "/etc/rancher/k3s/config.yaml"
    
    add_to_installed "config" "k3s-server" "$K3S_VERSION" "/etc/rancher/k3s/config.yaml" "$server_config" "K3s server configuration"
}

install_k3s_server() {
    log INFO "Installing K3s server..."
    
    ensure_sudo
    
    local install_cmd="INSTALL_K3S_VERSION=$K3S_VERSION $K3S_INSTALL_SCRIPT"
    
    if ! eval "sudo $install_cmd"; then
        error "Failed to install K3s server"
    fi
    
    if ! wait_for_service "k3s" 60 5; then
        error "K3s server failed to start"
    fi
    
    log INFO "Waiting for K3s to be ready..."
    local attempts=0
    while [ $attempts -lt 30 ]; do
        if sudo k3s kubectl get nodes 2>/dev/null | grep -q "Ready"; then
            break
        fi
        sleep 5
        attempts=$((attempts + 1))
    done
    
    if [ $attempts -eq 30 ]; then
        error "K3s failed to become ready"
    fi
    
    add_to_installed "service" "k3s-server" "$K3S_VERSION" "systemd" "/etc/systemd/system/k3s.service" "K3s Kubernetes server"
}

save_node_token() {
    log INFO "Saving node token for agent nodes..."
    
    # Wait for token file to be created
    local max_attempts=30
    local attempt=0
    
    while ! sudo test -f /var/lib/rancher/k3s/server/node-token && [[ $attempt -lt $max_attempts ]]; do
        log INFO "Waiting for K3s node token to be generated (attempt $((attempt+1))/$max_attempts)..."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    if sudo test -f /var/lib/rancher/k3s/server/node-token; then
        sudo cp /var/lib/rancher/k3s/server/node-token "$K3S_TOKEN_FILE"
        sudo chmod 644 "$K3S_TOKEN_FILE"
        log INFO "Node token saved to $K3S_TOKEN_FILE"
        
        # Also save to .env for convenience
        local token=$(sudo cat /var/lib/rancher/k3s/server/node-token)
        echo "K3S_TOKEN=$token" >> "$HOMELAB_DIR/.env"
        log INFO "K3s token added to .env file"
    else
        log WARN "Node token not found after waiting, agents will need manual configuration"
        log WARN "You can find the token later at: /var/lib/rancher/k3s/server/node-token"
    fi
}

configure_kubectl() {
    log INFO "Configuring kubectl access..."
    
    mkdir -p ~/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown $(id -u):$(id -g) ~/.kube/config
    chmod 600 ~/.kube/config
    
    if ! grep -q "alias k=" ~/.bashrc; then
        cat >> ~/.bashrc <<EOF

# K3s kubectl aliases
alias k='kubectl'
alias kgp='kubectl get pods'
alias kgs='kubectl get svc'
alias kgn='kubectl get nodes'
export KUBECONFIG=~/.kube/config
EOF
    fi
    
    add_to_installed "config" "kubectl" "1.0" "~/.kube/config" "$K3S_CONFIG_DIR/kubeconfig" "kubectl configuration"
}

verify_installation() {
    log INFO "Verifying K3s installation..."
    
    echo ""
    echo "K3s Cluster Status:"
    echo "==================="
    sudo k3s kubectl get nodes
    echo ""
    sudo k3s kubectl get pods -A
    echo ""
    
    local node_token=$(sudo cat "$K3S_TOKEN_FILE" 2>/dev/null || echo "Not available")
    local primary_ip=$(get_primary_ip)
    
    cat > "$DOCS_DIR/k3s-info.txt" <<EOF
K3s Master Node Information
==========================

Version: $K3S_VERSION
API Server: https://$primary_ip:6443
Node Token Location: $K3S_TOKEN_FILE

To join agent nodes, use:
K3S_URL=https://$primary_ip:6443 K3S_TOKEN=<token> k3s agent

Kubectl access:
export KUBECONFIG=~/.kube/config
kubectl get nodes
EOF
    
    log INFO "K3s information saved to $DOCS_DIR/k3s-info.txt"
}

main() {
    log INFO "Starting K3s master installation..."
    
    download_k3s_installer
    
    configure_k3s_server
    
    install_k3s_server
    
    save_node_token
    
    configure_kubectl
    
    # Setup SSH key management for cluster
    log INFO "Setting up SSH key management..."
    "$SCRIPT_DIR/ssh-key-manager.sh" setup
    
    verify_installation
    
    log INFO "K3s master installation completed successfully"
}

main "$@"