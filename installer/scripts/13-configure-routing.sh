#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-functions.sh"

# Set default values if not already set
HOMELAB_DIR="${HOMELAB_DIR:-$HOME/homelab}"
CONFIG_DIR="${CONFIG_DIR:-$HOMELAB_DIR/configs}"
DOCS_DIR="${DOCS_DIR:-$HOMELAB_DIR/docs}"

if [[ -f "$CONFIG_DIR/network/interfaces.conf" ]]; then
    source "$CONFIG_DIR/network/interfaces.conf"
fi

ROUTING_CONFIG_DIR="$CONFIG_DIR/routing"

configure_ip_forwarding() {
    log INFO "Enabling IP forwarding..."
    
    if [[ $(sysctl -n net.ipv4.ip_forward) -ne 1 ]]; then
        sudo sysctl -w net.ipv4.ip_forward=1
    fi
    
    if [[ $(sysctl -n net.ipv6.conf.all.forwarding) -ne 1 ]]; then
        sudo sysctl -w net.ipv6.conf.all.forwarding=1
    fi
    
    log INFO "IP forwarding enabled"
}

configure_nat_rules() {
    log INFO "Configuring NAT rules..."
    
    mkdir -p "$ROUTING_CONFIG_DIR"
    
    if [[ -z "$LAN_INTERFACE" ]]; then
        log INFO "No LAN interface configured, skipping NAT setup"
        return
    fi
    
    ensure_sudo
    
    sudo iptables -t nat -F
    sudo iptables -t filter -F FORWARD
    
    sudo iptables -t nat -A POSTROUTING -o "$WAN_INTERFACE" -j MASQUERADE
    
    sudo iptables -A FORWARD -i "$LAN_INTERFACE" -o "$WAN_INTERFACE" -j ACCEPT
    sudo iptables -A FORWARD -i "$WAN_INTERFACE" -o "$LAN_INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    
    sudo iptables -A FORWARD -i "$LAN_INTERFACE" -j ACCEPT
    
    save_iptables_rules
    
    add_to_installed "config" "nat-rules" "1.0" "iptables" "$ROUTING_CONFIG_DIR/nat.rules" "NAT masquerading rules"
}

configure_port_forwarding() {
    log INFO "Configuring port forwarding rules..."
    
    local rules_file="$ROUTING_CONFIG_DIR/port-forward.rules"
    
    cat > "$rules_file" <<EOF
# Port forwarding rules for homelab services
# Format: PROTO:EXTERNAL_PORT:INTERNAL_IP:INTERNAL_PORT

# Web services
tcp:80:10.0.0.3:80
tcp:443:10.0.0.3:443

# SSH to internal machines (optional, uncomment if needed)
# tcp:2222:10.0.0.101:22
# tcp:2223:10.0.0.102:22
EOF
    
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        
        IFS=':' read -r proto ext_port int_ip int_port <<< "$line"
        
        sudo iptables -t nat -A PREROUTING -i "$WAN_INTERFACE" -p "$proto" --dport "$ext_port" -j DNAT --to-destination "$int_ip:$int_port"
        sudo iptables -A FORWARD -p "$proto" -d "$int_ip" --dport "$int_port" -j ACCEPT
        
        log INFO "Added port forward: $proto:$ext_port -> $int_ip:$int_port"
    done < "$rules_file"
    
    save_iptables_rules
    
    add_to_installed "config" "port-forwarding" "1.0" "iptables" "$rules_file" "Port forwarding rules"
}

configure_firewall_rules() {
    log INFO "Configuring firewall rules..."
    
    sudo iptables -A INPUT -i lo -j ACCEPT
    sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    
    sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    sudo iptables -A INPUT -p tcp --dport 6443 -j ACCEPT
    sudo iptables -A INPUT -p tcp --dport 10250 -j ACCEPT
    
    if [[ -n "$LAN_INTERFACE" ]]; then
        sudo iptables -A INPUT -i "$LAN_INTERFACE" -j ACCEPT
    fi
    
    sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    
    sudo iptables -A INPUT -p udp --dport 53 -j ACCEPT
    sudo iptables -A INPUT -p tcp --dport 53 -j ACCEPT
    
    sudo iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
    
    sudo iptables -P INPUT DROP
    sudo iptables -P FORWARD DROP
    
    save_iptables_rules
    
    add_to_installed "config" "firewall-rules" "1.0" "iptables" "$ROUTING_CONFIG_DIR/firewall.rules" "Firewall security rules"
}

save_iptables_rules() {
    log INFO "Saving iptables rules..."
    
    sudo iptables-save > "$ROUTING_CONFIG_DIR/iptables.rules"
    
    sudo mkdir -p /etc/iptables
    sudo cp "$ROUTING_CONFIG_DIR/iptables.rules" /etc/iptables/rules.v4
}

create_iptables_restore_service() {
    log INFO "Creating iptables restore service..."
    
    local service_file="$ROUTING_CONFIG_DIR/iptables-restore.service"
    
    cat > "$service_file" <<EOF
[Unit]
Description=Restore iptables rules
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    
    create_symlink "$service_file" "/etc/systemd/system/iptables-restore.service"
    
    sudo systemctl daemon-reload
    sudo systemctl enable iptables-restore.service
    sudo systemctl start iptables-restore.service
    
    add_to_installed "service" "iptables-restore" "1.0" "systemd" "/etc/systemd/system/iptables-restore.service" "iptables restore on boot"
}

configure_routing_verification() {
    log INFO "Creating routing verification script..."
    
    local verify_script="$HOMELAB_DIR/scripts/verify-routing.sh"
    
    cat > "$verify_script" <<'EOF'
#!/bin/bash

echo "=== IP Forwarding Status ==="
sysctl net.ipv4.ip_forward
sysctl net.ipv6.conf.all.forwarding

echo -e "\n=== NAT Rules ==="
sudo iptables -t nat -L -n -v

echo -e "\n=== Filter Rules ==="
sudo iptables -L -n -v

echo -e "\n=== Active Connections ==="
sudo conntrack -L 2>/dev/null | head -20 || echo "conntrack not available"

echo -e "\n=== Routing Table ==="
ip route show
EOF
    
    chmod +x "$verify_script"
    
    log INFO "Routing verification script created at: $verify_script"
}

verify_routing() {
    log INFO "Verifying routing configuration..."
    
    echo ""
    echo "Routing Configuration:"
    echo "====================="
    echo "WAN Interface: $WAN_INTERFACE"
    echo "LAN Interface: ${LAN_INTERFACE:-none}"
    echo "LAN Network: ${LAN_NETWORK:-none}"
    echo ""
    echo "IP Forwarding: $(sysctl -n net.ipv4.ip_forward)"
    echo ""
    echo "NAT Rules:"
    sudo iptables -t nat -L POSTROUTING -n -v | grep MASQUERADE || echo "No NAT rules"
    echo ""
    
    cat > "$DOCS_DIR/routing-info.txt" <<EOF
Routing and Firewall Configuration
===================================

Network Interfaces:
- WAN: $WAN_INTERFACE
- LAN: ${LAN_INTERFACE:-not configured}

NAT Configuration:
- Masquerading enabled for LAN to WAN traffic
- LAN network: ${LAN_NETWORK:-not configured}

Port Forwarding:
- HTTP (80) -> Traefik (10.0.0.3)
- HTTPS (443) -> Traefik (10.0.0.3)

Firewall Rules:
- Default policy: DROP (except for established connections)
- Allowed inbound: SSH, K3s API, HTTP/HTTPS, DNS, ICMP
- Full access from LAN interface

Configuration files:
- iptables rules: /etc/iptables/rules.v4
- Port forwards: $ROUTING_CONFIG_DIR/port-forward.rules

To verify routing:
$HOMELAB_DIR/scripts/verify-routing.sh
EOF
    
    log INFO "Routing information saved to $DOCS_DIR/routing-info.txt"
}

main() {
    log INFO "Starting routing configuration..."
    
    configure_ip_forwarding
    
    if [[ -n "${LAN_INTERFACE:-}" ]]; then
        configure_nat_rules
        configure_port_forwarding
    fi
    
    configure_firewall_rules
    
    create_iptables_restore_service
    
    configure_routing_verification
    
    verify_routing
    
    log INFO "Routing configuration completed successfully"
}

main "$@"