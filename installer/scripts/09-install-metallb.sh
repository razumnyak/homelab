#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-functions.sh"

# Set default values if not already set
HOMELAB_DIR="${HOMELAB_DIR:-$HOME/homelab}"
CONFIG_DIR="${CONFIG_DIR:-$HOMELAB_DIR/configs}"
DOCS_DIR="${DOCS_DIR:-$HOMELAB_DIR/docs}"

METALLB_VERSION="v0.14.8"
METALLB_CONFIG_DIR="$CONFIG_DIR/metallb"
METALLB_NAMESPACE="metallb-system"
IP_POOL_RANGE="10.0.0.10-10.0.0.50"

install_metallb() {
    log INFO "Installing MetalLB $METALLB_VERSION..."
    
    mkdir -p "$METALLB_CONFIG_DIR"
    
    local manifest_url="https://raw.githubusercontent.com/metallb/metallb/$METALLB_VERSION/config/manifests/metallb-native.yaml"
    local manifest_file="$METALLB_CONFIG_DIR/metallb-native.yaml"
    
    if ! curl -fsSL "$manifest_url" -o "$manifest_file"; then
        error "Failed to download MetalLB manifest"
    fi
    
    if ! sudo k3s kubectl apply -f "$manifest_file"; then
        error "Failed to apply MetalLB manifest"
    fi
    
    log INFO "Waiting for MetalLB controller to be ready..."
    if ! sudo k3s kubectl wait --namespace "$METALLB_NAMESPACE" \
        --for=condition=ready pod \
        --selector=component=controller \
        --timeout=300s 2>/dev/null; then
        log WARN "MetalLB controller not ready after 5 minutes, continuing anyway..."
    fi
    
    log INFO "Waiting for MetalLB webhook service..."
    local attempts=0
    local webhook_ready=false
    
    while [[ $attempts -lt 30 ]]; do
        if sudo k3s kubectl get endpoints metallb-webhook-service -n "$METALLB_NAMESPACE" 2>/dev/null | grep -q "[0-9]"; then
            # Double check webhook is really ready
            if sudo k3s kubectl get pods -n "$METALLB_NAMESPACE" -l component=controller 2>/dev/null | grep -q "1/1.*Running"; then
                log INFO "MetalLB webhook service is ready"
                webhook_ready=true
                break
            fi
        fi
        log INFO "Waiting for webhook service... (attempt $((attempts+1))/30)"
        sleep 10
        attempts=$((attempts + 1))
    done
    
    if [[ "$webhook_ready" != "true" ]]; then
        log WARN "MetalLB webhook service not ready after 5 minutes"
        log WARN "Attempting to proceed without webhook validation..."
    fi
    
    add_to_installed "service" "metallb" "$METALLB_VERSION" "kubernetes" "$manifest_file" "MetalLB load balancer"
}

configure_ip_pool() {
    log INFO "Configuring MetalLB IP address pool..."
    
    local pool_config="$METALLB_CONFIG_DIR/ip-pool.yaml"
    
    cat > "$pool_config" <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: homelab-pool
  namespace: $METALLB_NAMESPACE
spec:
  addresses:
  - $IP_POOL_RANGE
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
  namespace: $METALLB_NAMESPACE
spec:
  ipAddressPools:
  - homelab-pool
EOF
    
    # Try to apply config with retries
    local config_attempts=0
    local config_applied=false
    
    while [[ $config_attempts -lt 5 ]]; do
        if sudo k3s kubectl apply -f "$pool_config" 2>&1; then
            config_applied=true
            log INFO "MetalLB IP pool configured successfully"
            break
        else
            config_attempts=$((config_attempts + 1))
            log WARN "Failed to apply IP pool config (attempt $config_attempts/5), waiting..."
            sleep 30
        fi
    done
    
    if [[ "$config_applied" != "true" ]]; then
        log ERROR "Failed to configure MetalLB IP pool after multiple attempts"
        log ERROR "You may need to apply the config manually later:"
        log ERROR "sudo k3s kubectl apply -f $pool_config"
        # Don't exit with error, allow installation to continue
    fi
    
    add_to_installed "config" "metallb-pool" "1.0" "kubernetes" "$pool_config" "MetalLB IP address pool: $IP_POOL_RANGE"
}

verify_metallb() {
    log INFO "Verifying MetalLB installation..."
    
    echo ""
    echo "MetalLB Status:"
    echo "==============="
    sudo k3s kubectl get pods -n "$METALLB_NAMESPACE"
    echo ""
    echo "IP Address Pool:"
    sudo k3s kubectl get ipaddresspool -n "$METALLB_NAMESPACE"
    echo ""
    
    cat > "$DOCS_DIR/metallb-info.txt" <<EOF
MetalLB Load Balancer Information
=================================

Version: $METALLB_VERSION
Namespace: $METALLB_NAMESPACE
IP Pool: $IP_POOL_RANGE

Available IPs for LoadBalancer services:
- Range: 10.0.0.10 to 10.0.0.50
- Total IPs: 41

Reserved IPs:
- 10.0.0.2: Pi-hole
- 10.0.0.3: Traefik
- 10.0.0.4: ArgoCD
- 10.0.0.5: Registry

To create a LoadBalancer service:
sudo k3s kubectl expose deployment my-app --type=LoadBalancer --port=80
EOF
    
    log INFO "MetalLB information saved to $DOCS_DIR/metallb-info.txt"
}

main() {
    log INFO "Starting MetalLB installation..."
    
    # Use k3s kubectl command directly
    if ! command -v k3s >/dev/null 2>&1; then
        error "k3s not available. Please ensure K3s is installed first."
    fi
    
    # Check k3s kubectl access
    if ! sudo k3s kubectl get nodes >/dev/null 2>&1; then
        log WARN "K3s cluster not immediately accessible, waiting..."
        sleep 10
        if ! sudo k3s kubectl get nodes >/dev/null 2>&1; then
            error "K3s cluster not accessible. Please ensure K3s is running."
        fi
    fi
    
    # Set KUBECONFIG for current user if not set
    export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
    
    install_metallb
    
    configure_ip_pool
    
    verify_metallb
    
    log INFO "MetalLB installation completed successfully"
}

main "$@"