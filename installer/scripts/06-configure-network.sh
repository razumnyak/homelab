#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-functions.sh"

# Set default values if not already set
HOMELAB_DIR="${HOMELAB_DIR:-$HOME/homelab}"
NODE_INFO="${NODE_INFO:-$HOMELAB_DIR/node.info}"

# Source node info if exists
if [[ -f "$NODE_INFO" ]]; then
    source "$NODE_INFO"
fi

# Ensure CONFIG_DIR is set
CONFIG_DIR="${CONFIG_DIR:-$HOMELAB_DIR/configs}"

WAN_INTERFACE=""
LAN_INTERFACE=""
LAN_NETWORK="${LAN_SUBNET:-10.0.0.0/24}"
LAN_IP="${LAN_NETWORK%/*}"

detect_interfaces() {
    log INFO "Detecting network interfaces..."
    
    local interfaces=($(ip -o link show | awk -F': ' '{print $2}' | grep -v lo))
    
    if [[ ${#interfaces[@]} -lt 1 ]]; then
        error "No network interfaces found"
    fi
    
    echo ""
    echo "Available network interfaces:"
    echo "----------------------------"
    
    for i in "${!interfaces[@]}"; do
        local iface="${interfaces[$i]}"
        local ip_addr=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | head -1 || echo "No IP")
        local state=$(ip link show "$iface" | grep -oP '(?<=state\s)\w+' || echo "UNKNOWN")
        echo "$((i+1))) $iface - IP: $ip_addr, State: $state"
    done
    
    echo ""
    
    if [[ "$NODE_TYPE" == "master-node" && ${#interfaces[@]} -ge 2 ]]; then
        while true; do
            read -p "Select WAN interface (1-${#interfaces[@]}): " wan_choice
            if [[ "$wan_choice" =~ ^[0-9]+$ ]] && (( wan_choice >= 1 && wan_choice <= ${#interfaces[@]} )); then
                WAN_INTERFACE="${interfaces[$((wan_choice-1))]}"
                break
            fi
            echo "Invalid selection"
        done
        
        while true; do
            read -p "Select LAN interface (1-${#interfaces[@]}): " lan_choice
            if [[ "$lan_choice" =~ ^[0-9]+$ ]] && (( lan_choice >= 1 && lan_choice <= ${#interfaces[@]} )) && [[ "$lan_choice" != "$wan_choice" ]]; then
                LAN_INTERFACE="${interfaces[$((lan_choice-1))]}"
                break
            fi
            echo "Invalid selection or same as WAN interface"
        done
    else
        WAN_INTERFACE="${interfaces[0]}"
        log INFO "Using single interface: $WAN_INTERFACE"
    fi
}

configure_netplan() {
    log INFO "Configuring network with netplan..."
    
    local netplan_config="$CONFIG_DIR/network/01-homelab.yaml"
    mkdir -p "$CONFIG_DIR/network"
    
    if [[ "$NODE_TYPE" == "master-node" && -n "$LAN_INTERFACE" ]]; then
        cat > "$netplan_config" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $WAN_INTERFACE:
      dhcp4: true
      dhcp6: false
    $LAN_INTERFACE:
      addresses:
        - $LAN_IP/24
      dhcp4: false
      dhcp6: false
EOF
    else
        cat > "$netplan_config" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $WAN_INTERFACE:
      dhcp4: true
      dhcp6: false
EOF
    fi
    
    backup_file "/etc/netplan/01-netcfg.yaml"
    create_symlink "$netplan_config" "/etc/netplan/01-homelab.yaml"
    
    # Fix permissions for netplan config
    sudo chmod 600 "$netplan_config"
    sudo chmod 600 "/etc/netplan/01-homelab.yaml"
    
    log INFO "Applying netplan configuration..."
    if ! sudo netplan apply; then
        log WARN "Netplan apply failed, network might need manual configuration"
    fi
    
    add_to_installed "config" "netplan" "1.0" "/etc/netplan/01-homelab.yaml" "$netplan_config" "Network configuration"
}

configure_hosts() {
    log INFO "Configuring /etc/hosts..."
    
    local hosts_entries="$CONFIG_DIR/network/hosts.homelab"
    local primary_ip=$(get_primary_ip)
    
    cat > "$hosts_entries" <<EOF
# Homelab hosts
$primary_ip $(hostname) $(hostname).local

# Master node services
EOF
    
    if [[ "$NODE_TYPE" == "master-node" ]]; then
        cat >> "$hosts_entries" <<EOF
10.0.0.2 pihole pihole.local
10.0.0.3 traefik traefik.local
10.0.0.4 argocd argocd.local
10.0.0.5 registry registry.local
EOF
    else
        cat >> "$hosts_entries" <<EOF
$MASTER_IP master master.local
$MASTER_IP pihole pihole.local
$MASTER_IP traefik traefik.local
$MASTER_IP argocd argocd.local
EOF
    fi
    
    if ! grep -q "# Homelab hosts" /etc/hosts; then
        echo "" | sudo tee -a /etc/hosts > /dev/null
        cat "$hosts_entries" | sudo tee -a /etc/hosts > /dev/null
    fi
    
    add_to_installed "config" "hosts" "1.0" "/etc/hosts" "$hosts_entries" "Local DNS entries"
}

configure_dns() {
    log INFO "Configuring DNS resolution..."
    
    if [[ "$NODE_TYPE" == "slave-node" && -n "$MASTER_IP" ]]; then
        local resolved_config="$CONFIG_DIR/network/resolved.conf"
        cat > "$resolved_config" <<EOF
[Resolve]
DNS=$MASTER_IP
FallbackDNS=1.1.1.1 1.0.0.1
Domains=local
DNSSEC=no
EOF
        
        create_symlink "$resolved_config" "/etc/systemd/resolved.conf.d/homelab.conf"
        sudo systemctl restart systemd-resolved
        
        add_to_installed "config" "systemd-resolved" "1.0" "/etc/systemd/resolved.conf.d/homelab.conf" "$resolved_config" "DNS configuration"
    fi
}

save_network_config() {
    log INFO "Saving network configuration..."
    
    cat > "$CONFIG_DIR/network/interfaces.conf" <<EOF
WAN_INTERFACE=$WAN_INTERFACE
LAN_INTERFACE=$LAN_INTERFACE
LAN_NETWORK=$LAN_NETWORK
LAN_IP=$LAN_IP
PRIMARY_IP=$(get_primary_ip)
EOF
    
    add_to_installed "config" "network-interfaces" "1.0" "system" "$CONFIG_DIR/network/interfaces.conf" "Network interface configuration"
}

main() {
    log INFO "Starting network configuration..."
    
    detect_interfaces
    
    configure_netplan
    
    configure_hosts
    
    configure_dns
    
    save_network_config
    
    log INFO "Network configuration completed successfully"
}

main "$@"