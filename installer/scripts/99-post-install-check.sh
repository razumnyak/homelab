#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-functions.sh"

# Set default values if not already set
HOMELAB_DIR="${HOMELAB_DIR:-$HOME/homelab}"
CONFIG_DIR="${CONFIG_DIR:-$HOMELAB_DIR/configs}"
LOGS_DIR="${LOGS_DIR:-$HOMELAB_DIR/logs}"
DOCS_DIR="${DOCS_DIR:-$HOMELAB_DIR/docs}"
NODE_INFO="${NODE_INFO:-$HOMELAB_DIR/node.info}"
INSTALLED_CSV="${INSTALLED_CSV:-$HOMELAB_DIR/installed.csv}"

# Load .env file if it exists (for auto-install support)
if [[ -f "$HOMELAB_DIR/.env" ]]; then
    set -a
    source <(grep -v '^#' "$HOMELAB_DIR/.env" | grep -v '^$')
    set +a
fi

if [[ -f "$NODE_INFO" ]]; then
    source "$NODE_INFO"
fi

# Set default NODE_TYPE if not loaded
NODE_TYPE="${NODE_TYPE:-master-node}"

CHECKS_PASSED=0
CHECKS_FAILED=0

run_check() {
    local check_name="$1"
    local check_command="$2"
    local is_warning="${3:-false}"
    
    echo -n "Checking $check_name... "
    
    if eval "$check_command" &>/dev/null; then
        echo -e "${GREEN}✓ PASSED${NC}"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
        return 0
    else
        if [[ "$is_warning" == "true" ]]; then
            echo -e "${YELLOW}⚠ WARNING${NC}"
            return 0
        else
            echo -e "${RED}✗ FAILED${NC}"
            CHECKS_FAILED=$((CHECKS_FAILED + 1))
            return 1
        fi
    fi
}

check_system_requirements() {
    log INFO "Checking system requirements..."
    
    run_check "Ubuntu OS" "[[ -f /etc/os-release ]] && source /etc/os-release && [[ \$ID == 'ubuntu' ]]"
    run_check "CPU cores (>=2)" "[[ \$(nproc) -ge 2 ]]"
    run_check "Memory (>=2GB)" "[[ \$(free -m | awk '/^Mem:/{print \$2}') -ge 2000 ]]"
    run_check "Disk space (>=20GB)" "[[ \$(df -BG / | awk 'NR==2 {print \$4}' | sed 's/G//') -ge 20 ]]"
    run_check "IP forwarding" "[[ \$(sysctl -n net.ipv4.ip_forward) -eq 1 ]]"
    run_check "Swap disabled" "[[ \$(free | grep -i swap | awk '{print \$2}') == '0' ]]" "true"
}

check_network_configuration() {
    log INFO "Checking network configuration..."
    
    run_check "Primary network interface" "ip route get 1.1.1.1 &>/dev/null"
    run_check "Internet connectivity" "ping -c 1 -W 2 1.1.1.1"
    run_check "DNS resolution" "nslookup google.com"
    
    if [[ "$NODE_TYPE" == "master-node" ]]; then
        # Проверяем либо настроенный LAN_INTERFACE, либо основной интерфейс
        if [[ -n "${LAN_INTERFACE:-}" ]]; then
            run_check "LAN interface configured" "ip link show '${LAN_INTERFACE}' | grep -q 'state UP'"
        else
            # Если LAN_INTERFACE не задан, проверяем что основной интерфейс работает
            run_check "LAN interface configured" "ip route | grep -q '^default'" "true"
        fi
    fi
}

check_kubernetes() {
    log INFO "Checking Kubernetes components..."
    
    if [[ "$NODE_TYPE" == "master-node" ]]; then
        run_check "K3s service running" "systemctl is-active --quiet k3s"
        run_check "kubectl accessible" "command -v kubectl"
        run_check "Kubernetes API responding" "kubectl version --short --request-timeout=10s" "true"
        run_check "Nodes ready" "kubectl get nodes | grep -q Ready"
        run_check "System pods running" "! kubectl get pods -A | grep -v Running | grep -v Completed | grep -q '^[a-z]'"
    else
        run_check "K3s agent running" "systemctl is-active --quiet k3s-agent"
    fi
}

check_ssh_agent() {
    log INFO "Checking SSH agent service..."
    
    run_check "SSH agent service running" "systemctl is-active --quiet ssh-agent"
    run_check "SSH agent socket exists" "[[ -S '/run/ssh-agent.socket' ]]"
    
    if [[ -S "/run/ssh-agent.socket" ]]; then
        local key_count=$(sudo SSH_AUTH_SOCK=/run/ssh-agent.socket ssh-add -l 2>/dev/null | wc -l || echo "0")
        run_check "SSH keys loaded ($key_count keys)" "[[ $key_count -gt 0 ]]"
        
        # Check for specific keys
        if sudo SSH_AUTH_SOCK=/run/ssh-agent.socket ssh-add -l 2>/dev/null | grep -q "argocd-deploy"; then
            run_check "ArgoCD deploy key loaded" "true"
        else
            run_check "ArgoCD deploy key loaded" "false"
        fi
    fi
}

check_master_services() {
    if [[ "$NODE_TYPE" != "master-node" ]]; then
        return
    fi
    
    log INFO "Checking bootstrap services..."
    
    run_check "K3s cluster ready" "kubectl get nodes | grep -q Ready"
    
    # Check SSH agent first as it's required for ArgoCD
    check_ssh_agent
    echo ""
    
    run_check "ArgoCD deployed" "kubectl get pods -n argocd | grep -q Running"
    run_check "ArgoCD service available" "kubectl get svc -n argocd argocd-server | grep -q ClusterIP"
    
    # Check App-of-Apps for automated deployment
    run_check "App-of-Apps configured" "kubectl get application homelab-infrastructure -n argocd | grep -q homelab-infrastructure"
}

check_service_accessibility() {
    if [[ "$NODE_TYPE" != "master-node" ]]; then
        return
    fi
    
    log INFO "Checking bootstrap service accessibility..."
    
    # ArgoCD accessibility via port-forward (bootstrap phase)
    log INFO "ArgoCD is available via: kubectl port-forward -n argocd svc/argocd-server 8080:80"
    
    log INFO "Note: Pi-hole and Traefik will be accessible after ArgoCD deployment"
}

check_dns_resolution() {
    if [[ "$NODE_TYPE" != "master-node" ]]; then
        return
    fi
    
    log INFO "Checking basic DNS resolution..."
    
    run_check "External DNS working" "nslookup google.com 1.1.1.1"
    
    log INFO "Note: Local DNS (Pi-hole) will be available after ArgoCD deployment"
}

check_documentation() {
    log INFO "Checking documentation..."
    
    run_check "Homelab directory exists" "[[ -d '$HOMELAB_DIR' ]]"
    run_check "Configuration directory" "[[ -d '$CONFIG_DIR' ]]"
    run_check "Documentation directory" "[[ -d '$DOCS_DIR' ]]"
    run_check "Installation log" "[[ -d '$LOGS_DIR' ]]"
    run_check "Installed components CSV" "[[ -f '$INSTALLED_CSV' ]]"
    run_check "Node info file" "[[ -f '$NODE_INFO' ]]"
    
    # Credentials file is optional in bootstrap
}

generate_summary_report() {
    local report_file="$DOCS_DIR/installation-report-$(date +%Y%m%d-%H%M%S).txt"
    
    cat > "$report_file" <<EOF
Homelab Installation Report
==========================

Date: $(date)
Node Type: $NODE_TYPE
Node Name: $NODE_NAME
Hostname: $(hostname)

System Information:
- OS: $(source /etc/os-release && echo "$PRETTY_NAME")
- Kernel: $(uname -r)
- CPU: $(nproc) cores
- Memory: $(free -h | awk '/^Mem:/{print $2}')
- Disk: $(df -h / | awk 'NR==2 {print $4}' ) available

Check Results:
- Passed: $CHECKS_PASSED
- Failed: $CHECKS_FAILED
- Success Rate: $(( CHECKS_PASSED * 100 / (CHECKS_PASSED + CHECKS_FAILED) ))%

EOF
    
    if [[ "$NODE_TYPE" == "master-node" ]]; then
        cat >> "$report_file" <<EOF

Bootstrap Service URLs:
- ArgoCD: https://argocd.local (https://10.0.0.4)

Next Steps:
1. Access ArgoCD dashboard to monitor automatic deployments
2. Wait for Pi-hole and Traefik to be deployed by ArgoCD
3. Configure your devices to use Pi-hole DNS after deployment
4. Deploy your applications using ArgoCD GitOps workflow
5. Access services through Traefik ingress after deployment

Useful Commands:
- Check cluster: kubectl get nodes
- View all pods: kubectl get pods -A
- View services: kubectl get svc -A
- Check logs: kubectl logs -n <namespace> <pod-name>

EOF
    else
        cat >> "$report_file" <<EOF

Master Node: $MASTER_IP

To verify this node from the master:
ssh <master-node> "kubectl get node $NODE_NAME"

EOF
    fi
    
    cat >> "$report_file" <<EOF
Documentation Location:
- Installation logs: $LOGS_DIR/
- Configuration files: $CONFIG_DIR/
- Service information: $DOCS_DIR/
- Installed components: $INSTALLED_CSV

Report saved to: $report_file
EOF
    
    echo ""
    echo "Installation report saved to: $report_file"
}

print_summary() {
    echo ""
    echo "================================================"
    echo "       Installation Check Summary"
    echo "================================================"
    echo "Total Checks: $((CHECKS_PASSED + CHECKS_FAILED))"
    echo -e "Passed: ${GREEN}$CHECKS_PASSED${NC}"
    echo -e "Failed: ${RED}$CHECKS_FAILED${NC}"
    echo ""
    
    if [[ $CHECKS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}✓ All checks passed! Your homelab is ready.${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ Some checks failed. Please review the errors above.${NC}"
        return 1
    fi
}

main() {
    log INFO "Starting post-installation checks..."
    
    echo ""
    echo "Running Post-Installation Checks"
    echo "================================"
    echo ""
    
    check_system_requirements
    echo ""
    
    check_network_configuration
    echo ""
    
    check_kubernetes
    echo ""
    
    if [[ "$NODE_TYPE" == "master-node" ]]; then
        check_master_services
        echo ""
        
        check_service_accessibility
        echo ""
        
        check_dns_resolution
        echo ""
    fi
    
    check_documentation
    echo ""
    
    print_summary
    
    generate_summary_report
    
    log INFO "Post-installation check completed"
    
    if [[ $CHECKS_FAILED -gt 0 ]]; then
        exit 1
    fi
}

main "$@"