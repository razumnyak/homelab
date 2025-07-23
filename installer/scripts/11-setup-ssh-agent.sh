#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-functions.sh"

# Set default values if not already set
HOMELAB_DIR="${HOMELAB_DIR:-$HOME/homelab}"
CONFIG_DIR="${CONFIG_DIR:-$HOMELAB_DIR/configs}"

create_ssh_agent_systemd_units() {
    log INFO "Creating SSH agent systemd units..."
    
    # Create SSH agent service
    sudo tee /etc/systemd/system/ssh-agent.service > /dev/null <<'EOF'
[Unit]
Description=SSH agent
After=network.target

[Service]
Type=simple
Environment=SSH_AUTH_SOCK=/run/ssh-agent.socket
ExecStart=/usr/bin/ssh-agent -D -a /run/ssh-agent.socket
User=root
Restart=always
TimeoutStartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # Create keys loader service
    local current_user=$(logname 2>/dev/null || echo "$SUDO_USER" || echo "$USER")
    sudo tee /etc/systemd/system/ssh-keys-loader.service > /dev/null <<EOF
[Unit]
Description=Load SSH keys into agent
After=ssh-agent.service
Wants=ssh-agent.service

[Service]
Type=oneshot
Environment=SSH_AUTH_SOCK=/run/ssh-agent.socket
ExecStartPre=/bin/sleep 2
ExecStart=/bin/bash -c 'for key in /home/${current_user}/homelab/configs/ssh/keys/argocd-deploy /home/${current_user}/homelab/configs/ssh/keys/github-personal /home/${current_user}/homelab/configs/ssh/keys/homelab-master; do [ -f "\$key" ] && ssh-add "\$key" 2>/dev/null || true; done'
User=root
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd and enable services
    sudo systemctl daemon-reload
    sudo systemctl enable ssh-agent.service ssh-keys-loader.service
    
    add_to_installed "service" "ssh-agent" "1.0" "systemd" "/etc/systemd/system/ssh-agent.service" "SSH agent service"
    add_to_installed "service" "ssh-keys-loader" "1.0" "systemd" "/etc/systemd/system/ssh-keys-loader.service" "SSH keys loader service"
}

setup_ssh_agent_service() {
    log INFO "Setting up SSH agent service..."
    
    # Check if SSH agent service exists and is running
    if systemctl is-active --quiet ssh-agent 2>/dev/null; then
        log INFO "SSH agent service is already running"
        
        # Check if socket exists
        if [[ -S "/run/ssh-agent.socket" ]]; then
            local key_count=$(SSH_AUTH_SOCK=/run/ssh-agent.socket ssh-add -l 2>/dev/null | wc -l || echo "0")
            log INFO "SSH agent has $key_count keys loaded"
            return 0
        fi
    fi
    
    # Create systemd units if they don't exist
    if ! systemctl list-unit-files | grep -q "ssh-agent.service"; then
        log INFO "Creating SSH agent systemd units..."
        create_ssh_agent_systemd_units
    fi
    
    # Start services
    if ! systemctl is-active --quiet ssh-agent; then
        log INFO "Starting SSH agent service..."
        sudo systemctl start ssh-agent || {
            log ERROR "Failed to start SSH agent service"
            return 1
        }
    fi
    
    if ! systemctl is-active --quiet ssh-keys-loader; then
        log INFO "Starting SSH keys loader service..."
        sudo systemctl start ssh-keys-loader || {
            log WARN "Failed to start SSH keys loader service"
        }
    fi
    
    # Wait a moment for socket to be created
    sleep 3
    
    if [[ -S "/run/ssh-agent.socket" ]]; then
        log INFO "SSH agent service started successfully"
        
        # Verify keys are loaded
        if SSH_AUTH_SOCK=/run/ssh-agent.socket ssh-add -l >/dev/null 2>&1; then
            local key_count=$(SSH_AUTH_SOCK=/run/ssh-agent.socket ssh-add -l 2>/dev/null | grep -c "^[0-9]" || echo "0")
            log INFO "SSH agent has $key_count keys loaded"
        else
            log WARN "No SSH keys loaded in agent"
            log WARN "Check that SSH keys exist in $CONFIG_DIR/ssh/keys/"
        fi
    else
        log ERROR "SSH agent socket not found after service start"
        return 1
    fi
}

main() {
    log INFO "Starting SSH agent setup..."
    
    setup_ssh_agent_service
    
    log INFO "SSH agent setup completed successfully"
}

main "$@"