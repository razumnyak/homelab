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

if [[ -f "$NODE_INFO" ]]; then
    source "$NODE_INFO"
fi

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

check_master_services() {
    if [[ "$NODE_TYPE" != "master-node" ]]; then
        return
    fi
    
    log INFO "Checking master node services..."
    
    run_check "MetalLB deployed" "kubectl get pods -n metallb-system | grep -q Running"
    run_check "Pi-hole deployed" "kubectl get pods -n pihole | grep -q Running"
    run_check "Traefik deployed" "kubectl get pods -n traefik | grep -q Running"
    run_check "ArgoCD deployed" "kubectl get pods -n argocd | grep -q Running"
    
    run_check "Pi-hole LoadBalancer IP" "kubectl get svc -n pihole pihole-web | grep -q '10.0.0.2'"
    run_check "Traefik LoadBalancer IP" "kubectl get svc -n traefik traefik | grep -q '10.0.0.3'"
    run_check "ArgoCD LoadBalancer IP" "kubectl get svc -n argocd argocd-server | grep -q '10.0.0.4'"
}

check_service_accessibility() {
    if [[ "$NODE_TYPE" != "master-node" ]]; then
        return
    fi
    
    log INFO "Checking service accessibility..."
    
    run_check "Pi-hole web interface" "curl -s -o /dev/null -w '%{http_code}' http://10.0.0.2/admin/ | grep -q '200'"
    run_check "Traefik dashboard" "curl -s -o /dev/null -w '%{http_code}' http://10.0.0.3/ | grep -E '(401|200)'"
    run_check "ArgoCD server" "curl -k -s -o /dev/null -w '%{http_code}' https://10.0.0.4/ | grep -E '(200|307)'"
}

check_dns_resolution() {
    if [[ "$NODE_TYPE" != "master-node" ]]; then
        return
    fi
    
    log INFO "Checking DNS resolution..."
    
    run_check "Pi-hole DNS responding" "nslookup google.com 10.0.0.2"
    run_check "Local domain resolution" "nslookup pihole.local 10.0.0.2 | grep -q '10.0.0.2'"
}

check_documentation() {
    log INFO "Checking documentation..."
    
    run_check "Homelab directory exists" "[[ -d '$HOMELAB_DIR' ]]"
    run_check "Configuration directory" "[[ -d '$CONFIG_DIR' ]]"
    run_check "Documentation directory" "[[ -d '$DOCS_DIR' ]]"
    run_check "Installation log" "[[ -d '$LOGS_DIR' ]]"
    run_check "Installed components CSV" "[[ -f '$INSTALLED_CSV' ]]"
    run_check "Node info file" "[[ -f '$NODE_INFO' ]]"
    
    if [[ "$NODE_TYPE" == "master-node" ]]; then
        run_check "Credentials file" "[[ -f '$CREDENTIALS_FILE' ]]"
        run_check "Credentials permissions" "[[ \$(stat -c %a '$CREDENTIALS_FILE' 2>/dev/null) == '600' ]]"
    fi
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

Service URLs:
- Pi-hole: http://pihole.local/admin (http://10.0.0.2/admin)
- Traefik: http://traefik.local (http://10.0.0.3)
- ArgoCD: https://argocd.local (https://10.0.0.4)

Next Steps:
1. Access service dashboards using the URLs above
2. Configure your devices to use Pi-hole DNS (10.0.0.2)
3. Deploy your applications using ArgoCD
4. Monitor services through their dashboards

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