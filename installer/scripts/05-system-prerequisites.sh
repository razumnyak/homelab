#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-functions.sh"

# Set default values if not already set
HOMELAB_DIR="${HOMELAB_DIR:-$HOME/homelab}"
CONFIG_DIR="${CONFIG_DIR:-$HOMELAB_DIR/configs}"
LOGS_DIR="${LOGS_DIR:-$HOMELAB_DIR/logs}"

REQUIRED_PACKAGES=(
    "curl"
    "lsof"
    "tmux"
    "cron"
    "wget"
    "git"
    "jq"
    "htop"
    "net-tools"
    "iptables"
    "ca-certificates"
    "gnupg"
    "lsb-release"
    "software-properties-common"
    "apt-transport-https"
    "dnsutils"
    "iputils-ping"
    "traceroute"
    "tcpdump"
    "nmap"
    "vim"
    "tmux"
)

update_system() {
    log INFO "Updating system packages..."
    
    ensure_sudo
    
    if ! sudo apt-get update -qq; then
        error "Failed to update package index"
    fi
    
    # Пропускаем system upgrade для стабильности SSH соединения
    # Обновления можно выполнить вручную после установки кластера
    log INFO "Skipping system upgrade to maintain SSH stability"
    log INFO "Run 'sudo apt-get upgrade' manually after cluster setup if needed"
    
    add_to_installed "config" "system-update" "$(date +%Y%m%d)" "system" "apt" "Full system update"
}

install_packages() {
    log INFO "Installing required system packages..."
    
    for package in "${REQUIRED_PACKAGES[@]}"; do
        if dpkg -l | grep -q "^ii  $package "; then
            log INFO "Package already installed: $package"
        else
            log INFO "Installing package: $package"
            if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$package"; then
                local version=$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || echo "unknown")
                add_to_installed "package" "$package" "$version" "system" "apt" "System prerequisite"
            else
                log WARN "Failed to install $package, continuing..."
            fi
        fi
    done
}

configure_sysctl() {
    log INFO "Configuring kernel parameters..."
    
    local sysctl_config="$CONFIG_DIR/system/sysctl.conf"
    mkdir -p "$CONFIG_DIR/system"
    
    cat > "$sysctl_config" <<EOF
# Homelab sysctl configuration
# Enable IP forwarding for K3s
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

# Kubernetes requirements
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1

# Performance tuning
fs.file-max=${MAX_FILE_DESCRIPTORS:-655350}
fs.inotify.max_user_watches=${INOTIFY_WATCHES:-524288}
vm.swappiness=${VM_SWAPPINESS:-10}

# Network tuning
net.core.somaxconn=${NET_SOMAXCONN:-65535}
net.ipv4.tcp_max_syn_backlog=${TCP_SYN_BACKLOG:-65535}
net.core.netdev_max_backlog=${NETDEV_BACKLOG:-65535}
EOF
    
    create_symlink "$sysctl_config" "/etc/sysctl.d/99-homelab.conf"
    
    if ! sudo sysctl --system > /dev/null 2>&1; then
        log WARN "Some sysctl settings could not be applied"
    fi
    
    add_to_installed "config" "sysctl" "1.0" "/etc/sysctl.d/99-homelab.conf" "$sysctl_config" "Kernel parameters"
}

configure_modules() {
    log INFO "Loading required kernel modules..."
    
    local modules=("br_netfilter" "overlay" "ip_vs" "ip_vs_rr" "ip_vs_wrr" "ip_vs_sh" "nf_conntrack")
    
    for module in "${modules[@]}"; do
        if ! lsmod | grep -q "^$module "; then
            sudo modprobe "$module" || log WARN "Failed to load module: $module"
        fi
    done
    
    local modules_config="$CONFIG_DIR/system/modules-load.conf"
    printf '%s\n' "${modules[@]}" > "$modules_config"
    create_symlink "$modules_config" "/etc/modules-load.d/homelab.conf"
    
    add_to_installed "config" "kernel-modules" "1.0" "/etc/modules-load.d/homelab.conf" "$modules_config" "Required kernel modules"
}

configure_firewall() {
    log INFO "Configuring basic firewall rules..."
    
    ensure_sudo
    
    if ! sudo iptables -L > /dev/null 2>&1; then
        log WARN "iptables not available, skipping firewall configuration"
        return
    fi
    
    sudo iptables -P INPUT ACCEPT
    sudo iptables -P FORWARD ACCEPT
    sudo iptables -P OUTPUT ACCEPT
    
    sudo iptables -A INPUT -i lo -j ACCEPT
    sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    local ssh_port="${SSH_PORT:-22}"
    local k3s_api_port="${K3S_API_PORT:-6443}"
    local kubelet_port="${KUBELET_PORT:-10250}"
    
    sudo iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
    sudo iptables -A INPUT -p tcp --dport "$k3s_api_port" -j ACCEPT
    sudo iptables -A INPUT -p tcp --dport "$kubelet_port" -j ACCEPT
    
    if check_command "iptables-save"; then
        sudo iptables-save > "$CONFIG_DIR/system/iptables.rules"
        add_to_installed "config" "iptables" "1.0" "system" "$CONFIG_DIR/system/iptables.rules" "Basic firewall rules"
    fi
}

disable_swap() {
    log INFO "Disabling swap for Kubernetes..."
    
    if [[ $(swapon -s | wc -l) -gt 1 ]]; then
        sudo swapoff -a
        sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
        add_to_installed "config" "swap" "disabled" "/etc/fstab" "none" "Swap disabled for K8s"
    else
        log INFO "Swap already disabled"
    fi
}

configure_networkd_wait() {
    log INFO "Configuring networkd-wait-online for faster boot..."
    
    # Получаем основной рабочий интерфейс
    local primary_interface=$(ip route | grep default | awk '{print $5}' | head -1)
    
    if [[ -n "$primary_interface" ]]; then
        log INFO "Limiting networkd-wait-online to interface: $primary_interface"
        
        sudo mkdir -p /etc/systemd/system/systemd-networkd-wait-online.service.d/
        cat <<EOF | sudo tee /etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf > /dev/null
[Service]
ExecStart=
ExecStart=/lib/systemd/systemd-networkd-wait-online --interface=$primary_interface --timeout=30
EOF
    else
        log WARN "Could not determine primary interface, disabling networkd-wait-online"
        sudo systemctl disable systemd-networkd-wait-online.service
    fi
    
    add_to_installed "config" "networkd-wait-online" "optimized" "systemd" "/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf" "Fast boot network wait"
}

ensure_ssh_service() {
    log INFO "Ensuring SSH service is enabled..."
    
    if ! systemctl is-enabled --quiet ssh; then
        log INFO "Enabling SSH service"
        sudo systemctl enable ssh
    fi
    
    if ! systemctl is-active --quiet ssh; then
        log INFO "Starting SSH service"
        sudo systemctl start ssh
    fi
    
    add_to_installed "service" "ssh" "enabled" "systemd" "ssh.service" "SSH remote access"
}

setup_timezone() {
    log INFO "Configuring timezone..."
    
    local timezone="${DEFAULT_TIMEZONE:-UTC}"
    
    if ! sudo timedatectl set-timezone "$timezone"; then
        log WARN "Failed to set timezone to $timezone"
    fi
    
    if ! sudo timedatectl set-ntp true; then
        log WARN "Failed to enable NTP"
    fi
}

main() {
    log INFO "Starting system prerequisites setup..."
    
    update_system
    
    install_packages
    
    configure_sysctl
    
    configure_modules
    
    configure_firewall
    
    disable_swap
    
    configure_networkd_wait
    
    ensure_ssh_service
    
    setup_timezone
    
    log INFO "System prerequisites completed successfully"
}

main "$@"