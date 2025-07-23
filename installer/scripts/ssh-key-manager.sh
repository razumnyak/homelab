#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-functions.sh"

# Set default values if not already set
HOMELAB_DIR="${HOMELAB_DIR:-$HOME/homelab}"
CONFIG_DIR="${CONFIG_DIR:-$HOMELAB_DIR/configs}"

SSH_CONFIG_DIR="$CONFIG_DIR/ssh"
SSH_KEYS_DIR="$SSH_CONFIG_DIR/keys"
AUTHORIZED_KEYS_FILE="$SSH_CONFIG_DIR/authorized_keys"
GITHUB_KEYS_URL="${GITHUB_KEYS_URL:-https://github.com/razumnyak.keys}"
GITHUB_USER="${GITHUB_USER:-$(echo "$GITHUB_KEYS_URL" | sed 's|.*/\([^/]*\)\.keys$|\1|')}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$HOMELAB_DIR/scripts}"
DOCS_DIR="${DOCS_DIR:-$HOMELAB_DIR/docs}"

create_ssh_directories() {
    log INFO "Creating SSH directories structure..."
    
    mkdir -p "$SSH_KEYS_DIR"
    mkdir -p "$SCRIPTS_DIR"
    mkdir -p "$DOCS_DIR"
    chmod 700 "$SSH_CONFIG_DIR"
    chmod 700 "$SSH_KEYS_DIR"
}

generate_master_ssh_key() {
    log INFO "Generating master node SSH key..."
    
    local master_key="$SSH_KEYS_DIR/homelab-master"
    
    if [[ ! -f "$master_key" ]]; then
        ssh-keygen -t ed25519 -C "homelab-master@$(hostname)" -f "$master_key" -N ""
        chmod 600 "$master_key"
        chmod 644 "${master_key}.pub"
        
        log INFO "Master SSH key generated: ${master_key}.pub"
    else
        log INFO "Master SSH key already exists"
    fi
    
    echo "$master_key"
}

generate_argocd_deploy_keys() {
    log INFO "Generating ArgoCD deploy keys..."
    
    local argocd_key="$SSH_KEYS_DIR/argocd-deploy"
    
    if [[ ! -f "$argocd_key" ]]; then
        ssh-keygen -t ed25519 -C "argocd-deploy@homelab" -f "$argocd_key" -N ""
        chmod 600 "$argocd_key"
        chmod 644 "${argocd_key}.pub"
        
        log INFO "ArgoCD deploy key generated: ${argocd_key}.pub"
    else
        log INFO "ArgoCD deploy key already exists"
    fi
    
    echo "$argocd_key"
}

setup_github_ssh_keys() {
    log INFO "Setting up GitHub SSH keys..."
    
    local github_key="$SSH_KEYS_DIR/github-personal"
    
    if [[ ! -f "$github_key" ]]; then
        ssh-keygen -t ed25519 -C "${GITHUB_USER}@homelab" -f "$github_key" -N ""
        chmod 600 "$github_key"
        chmod 644 "${github_key}.pub"
        
        log INFO "GitHub personal key generated: ${github_key}.pub"
    else
        log INFO "GitHub personal key already exists"
    fi
    
    echo "$github_key"
}

sync_github_authorized_keys() {
    log INFO "Syncing authorized keys from GitHub..."
    
    local temp_keys="/tmp/github_keys_$$"
    
    if curl -fsSL "$GITHUB_KEYS_URL" -o "$temp_keys"; then
        if [[ -s "$temp_keys" ]]; then
            cat "$temp_keys" > "$AUTHORIZED_KEYS_FILE"
            chmod 600 "$AUTHORIZED_KEYS_FILE"
            log INFO "GitHub keys synced for user: $GITHUB_USER"
        else
            log WARN "No public keys found for GitHub user: $GITHUB_USER"
        fi
    else
        log WARN "Failed to fetch GitHub keys for user: $GITHUB_USER"
    fi
    
    rm -f "$temp_keys"
}

create_ssh_config() {
    log INFO "Creating SSH configuration..."
    
    local ssh_config="$SSH_CONFIG_DIR/config"
    
    cat > "$ssh_config" <<EOF
# Homelab SSH Configuration
Host github.com
    HostName github.com
    User git
    IdentityFile $SSH_KEYS_DIR/github-personal
    IdentitiesOnly yes

Host argocd-github
    HostName github.com
    User git
    IdentityFile $SSH_KEYS_DIR/argocd-deploy
    IdentitiesOnly yes

Host gitlab.com
    HostName gitlab.com
    User git
    IdentityFile $SSH_KEYS_DIR/argocd-deploy
    IdentitiesOnly yes

Host bitbucket.org
    HostName bitbucket.org
    User git
    IdentityFile $SSH_KEYS_DIR/argocd-deploy
    IdentitiesOnly yes

Host homelab-*
    IdentityFile $SSH_KEYS_DIR/homelab-master
    User homelab
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
    
    chmod 600 "$ssh_config"
    
    add_to_installed "config" "ssh-config" "1.0" "file" "$ssh_config" "SSH configuration for homelab"
}

setup_known_hosts() {
    log INFO "Setting up SSH known hosts..."
    
    local known_hosts="$SSH_CONFIG_DIR/known_hosts"
    
    cat > "$known_hosts" <<EOF
# GitHub
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=

# GitLab
gitlab.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf
gitlab.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFSMqzJeV9rUzU4kWitGjeR4PWSa29SPqJ1fVkhtj3Hw9xjLVXVYrU9QlYWrOLXBpQ6KWjbjTDTdDkoohFzgbEY=

# Bitbucket
bitbucket.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIazEu89wgQZ4bqs3d63QSMzYVa0MuJ2e2gKTKqu+UUO
bitbucket.org ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBPIQmuzMBuKdWeF4+a2sjSSpBK0iqitSQ+5BM9KhpexuGt20JpTVM7u5BDZngncgrqDMbWdxMWWOGtZ9UgbqgZE=
EOF
    
    chmod 644 "$known_hosts"
    
    add_to_installed "config" "ssh-known-hosts" "1.0" "file" "$known_hosts" "SSH known hosts file"
}

distribute_keys_to_slaves() {
    log INFO "Distributing SSH keys to slave nodes..."
    
    local master_key="$SSH_KEYS_DIR/homelab-master"
    local node_list="$CONFIG_DIR/nodes.list"
    
    if [[ ! -f "$node_list" ]]; then
        log WARN "No slave nodes list found at $node_list"
        return
    fi
    
    while IFS= read -r slave_ip; do
        [[ -z "$slave_ip" || "$slave_ip" =~ ^#.* ]] && continue
        
        log INFO "Distributing keys to slave node: $slave_ip"
        
        if distribute_to_slave "$slave_ip"; then
            log INFO "Successfully distributed keys to $slave_ip"
        else
            log WARN "Failed to distribute keys to $slave_ip"
        fi
    done < "$node_list"
}

distribute_to_slave() {
    local slave_ip="$1"
    local master_key="$SSH_KEYS_DIR/homelab-master"
    local temp_script="/tmp/setup_keys_$$"
    
    cat > "$temp_script" <<'EOF'
#!/bin/bash
set -e

SLAVE_SSH_DIR="/home/homelab/.ssh"
SLAVE_CONFIG_DIR="/home/homelab/homelab/configs/ssh"

mkdir -p "$SLAVE_SSH_DIR" "$SLAVE_CONFIG_DIR/keys"
chown -R homelab:homelab "$SLAVE_SSH_DIR" "$SLAVE_CONFIG_DIR"
chmod 700 "$SLAVE_SSH_DIR" "$SLAVE_CONFIG_DIR"

# Setup authorized_keys for master → slave access
if [[ -f "/tmp/authorized_keys" ]]; then
    cp /tmp/authorized_keys "$SLAVE_SSH_DIR/authorized_keys"
    chown homelab:homelab "$SLAVE_SSH_DIR/authorized_keys"
    chmod 600 "$SLAVE_SSH_DIR/authorized_keys"
fi

# Copy SSH keys
if [[ -d "/tmp/ssh_keys" ]]; then
    cp -r /tmp/ssh_keys/* "$SLAVE_CONFIG_DIR/keys/"
    chown -R homelab:homelab "$SLAVE_CONFIG_DIR/keys"
    chmod 600 "$SLAVE_CONFIG_DIR/keys"/*
    chmod 644 "$SLAVE_CONFIG_DIR/keys"/*.pub
fi

# Copy SSH config
if [[ -f "/tmp/ssh_config" ]]; then
    cp /tmp/ssh_config "$SLAVE_CONFIG_DIR/config"
    chown homelab:homelab "$SLAVE_CONFIG_DIR/config"
    chmod 600 "$SLAVE_CONFIG_DIR/config"
fi

# Create symlink for convenience
ln -sf "$SLAVE_CONFIG_DIR" "$SLAVE_SSH_DIR/homelab" || true

echo "SSH keys distributed successfully"
EOF
    
    chmod +x "$temp_script"
    
    # Copy files to slave
    scp -i "$master_key" -o StrictHostKeyChecking=no \
        "$AUTHORIZED_KEYS_FILE" "homelab@${slave_ip}:/tmp/authorized_keys" || return 1
    
    scp -i "$master_key" -o StrictHostKeyChecking=no -r \
        "$SSH_KEYS_DIR" "homelab@${slave_ip}:/tmp/ssh_keys" || return 1
    
    scp -i "$master_key" -o StrictHostKeyChecking=no \
        "$SSH_CONFIG_DIR/config" "homelab@${slave_ip}:/tmp/ssh_config" || return 1
    
    scp -i "$master_key" -o StrictHostKeyChecking=no \
        "$temp_script" "homelab@${slave_ip}:/tmp/setup_keys.sh" || return 1
    
    ssh -i "$master_key" -o StrictHostKeyChecking=no \
        "homelab@${slave_ip}" "sudo bash /tmp/setup_keys.sh" || return 1
    
    ssh -i "$master_key" -o StrictHostKeyChecking=no \
        "homelab@${slave_ip}" "rm -f /tmp/setup_keys.sh /tmp/authorized_keys /tmp/ssh_config && rm -rf /tmp/ssh_keys" || true
    
    rm -f "$temp_script"
    return 0
}

create_ssh_sync_service() {
    log INFO "Creating SSH key sync service..."
    
    local sync_script="$SCRIPTS_DIR/sync-ssh-keys.sh"
    local service_file="/etc/systemd/system/homelab-ssh-sync.service"
    local timer_file="/etc/systemd/system/homelab-ssh-sync.timer"
    
    cat > "$sync_script" <<EOF
#!/bin/bash
set -e

source "$SCRIPT_DIR/common-functions.sh"

log INFO "Starting SSH keys sync..."

# Sync GitHub keys
if curl -fsSL "$GITHUB_KEYS_URL" -o "/tmp/github_keys"; then
    if [[ -s "/tmp/github_keys" ]]; then
        cp "/tmp/github_keys" "$AUTHORIZED_KEYS_FILE"
        chmod 600 "$AUTHORIZED_KEYS_FILE"
        log INFO "GitHub keys updated"
        
        # Distribute to slave nodes
        $SCRIPT_DIR/ssh-key-manager.sh distribute
    fi
fi

rm -f "/tmp/github_keys"
log INFO "SSH keys sync completed"
EOF
    
    chmod +x "$sync_script"
    
    sudo tee "$service_file" > /dev/null <<EOF
[Unit]
Description=Homelab SSH Keys Sync
After=network.target

[Service]
Type=oneshot
User=root
ExecStart=$sync_script
EOF
    
    sudo tee "$timer_file" > /dev/null <<EOF
[Unit]
Description=Homelab SSH Keys Sync Timer
Requires=homelab-ssh-sync.service

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    sudo systemctl daemon-reload || log WARN "Failed to reload systemd daemon"
    sudo systemctl enable homelab-ssh-sync.timer || log WARN "Failed to enable SSH sync timer"
    sudo systemctl start homelab-ssh-sync.timer || log WARN "Failed to start SSH sync timer"
    
    add_to_installed "service" "ssh-sync" "1.0" "systemd" "$service_file" "SSH keys sync service"
}

create_ssh_docs() {
    log INFO "Creating SSH documentation..."
    
    cat > "$DOCS_DIR/ssh-keys-info.txt" <<EOF
Homelab SSH Keys Management
===========================

## Key Locations:
Master Key:    $SSH_KEYS_DIR/homelab-master
ArgoCD Key:    $SSH_KEYS_DIR/argocd-deploy  
GitHub Key:    $SSH_KEYS_DIR/github-personal

## Public Keys for Git Repositories:

### ArgoCD Deploy Key (Read-only access to private repos):
$(cat "$SSH_KEYS_DIR/argocd-deploy.pub" 2>/dev/null || echo "Key not generated yet")

### GitHub Personal Key (For personal repositories):
$(cat "$SSH_KEYS_DIR/github-personal.pub" 2>/dev/null || echo "Key not generated yet")

## How to Add Keys to Repositories:

### GitHub:
1. Go to Repository → Settings → Deploy keys
2. Add the ArgoCD public key above
3. Title: "Homelab ArgoCD Deploy Key"
4. Keep "Allow write access" UNCHECKED

### GitLab:
1. Go to Project → Settings → Repository → Deploy Keys
2. Add the ArgoCD public key
3. Title: "Homelab ArgoCD Deploy Key"

### Bitbucket:
1. Go to Repository → Settings → Access keys
2. Add the ArgoCD public key
3. Label: "Homelab ArgoCD Deploy Key"

## SSH Access:
- Master node can SSH to all slave nodes using: $SSH_KEYS_DIR/homelab-master
- Your GitHub keys are synced daily to authorized_keys
- SSH config located at: $SSH_CONFIG_DIR/config

## Sync Service:
- Service: homelab-ssh-sync.timer
- Runs: Daily
- Syncs: GitHub authorized keys to all nodes
EOF
    
    log INFO "SSH documentation saved to $DOCS_DIR/ssh-keys-info.txt"
}

main() {
    local command="${1:-setup}"
    
    case "$command" in
        setup)
            log INFO "Setting up SSH key management system..."
            create_ssh_directories
            local master_key=$(generate_master_ssh_key)
            local argocd_key=$(generate_argocd_deploy_keys) 
            local github_key=$(setup_github_ssh_keys)
            sync_github_authorized_keys
            create_ssh_config
            setup_known_hosts
            create_ssh_sync_service
            create_ssh_docs
            log INFO "SSH key management system setup completed"
            ;;
        distribute)
            log INFO "Distributing SSH keys to slave nodes..."
            distribute_keys_to_slaves
            ;;
        sync)
            log INFO "Syncing GitHub authorized keys..."
            sync_github_authorized_keys
            distribute_keys_to_slaves
            ;;
        *)
            echo "Usage: $0 {setup|distribute|sync}"
            echo "  setup      - Initial SSH key management setup"
            echo "  distribute - Distribute keys to slave nodes"
            echo "  sync       - Sync GitHub keys and distribute"
            exit 1
            ;;
    esac
}

main "$@"