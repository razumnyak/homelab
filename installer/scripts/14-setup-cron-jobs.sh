#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$HOME/homelab"
LOG_DIR="$HOMELAB_DIR/logs"

source "$SCRIPT_DIR/common-functions.sh"

# Set default values if not already set
HOMELAB_DIR="${HOMELAB_DIR:-$HOME/homelab}"
LOGS_DIR="${LOGS_DIR:-$HOMELAB_DIR/logs}"
LOG_DIR="$LOGS_DIR"  # Alias for backward compatibility

# Load .env file if it exists (for auto-install support)
if [[ -f "$HOMELAB_DIR/.env" ]]; then
    set -a
    source <(grep -v '^#' "$HOMELAB_DIR/.env" | grep -v '^$')
    set +a
fi

setup_ssh_key_updater() {
    local enable_sync="${ENABLE_SSH_KEY_SYNC:-true}"
    
    if [[ "$enable_sync" != "true" ]]; then
        log INFO "SSH key sync disabled via ENABLE_SSH_KEY_SYNC=false"
        return 0
    fi
    
    log INFO "Setting up smart SSH key updater..."
    
    local updater_script="$HOMELAB_DIR/scripts/smart-ssh-key-updater.sh"
    local github_keys_url="${GITHUB_KEYS_URL:-https://github.com/razumnyak.keys}"
    local sync_hour="${SSH_KEY_SYNC_HOUR:-3}"
    
    log INFO "Creating scripts directory: $HOMELAB_DIR/scripts"
    if ! mkdir -p "$HOMELAB_DIR/scripts"; then
        log ERROR "Failed to create scripts directory: $HOMELAB_DIR/scripts"
        return 1
    fi
    
    log INFO "Copying smart-ssh-key-updater.sh from $SCRIPT_DIR to $updater_script"
    if [[ ! -f "$SCRIPT_DIR/smart-ssh-key-updater.sh" ]]; then
        log ERROR "Source file not found: $SCRIPT_DIR/smart-ssh-key-updater.sh"
        return 1
    fi
    
    if ! cp "$SCRIPT_DIR/smart-ssh-key-updater.sh" "$updater_script"; then
        log ERROR "Failed to copy smart-ssh-key-updater.sh to $updater_script"
        return 1
    fi
    
    log INFO "Setting execute permissions on $updater_script"
    if ! chmod +x "$updater_script"; then
        log ERROR "Failed to set execute permissions on $updater_script"
        return 1
    fi
    
    log INFO "Configuring cron job for daily SSH key updates from $github_keys_url"
    
    local cron_cmd="0 $sync_hour * * * GITHUB_KEYS_URL='$github_keys_url' LOG_FILE='$LOG_DIR/ssh-key-updater.log' $updater_script >> $LOG_DIR/ssh-key-updater-cron.log 2>&1"
    
    log INFO "Adding cron job: $cron_cmd"
    if ! (crontab -l 2>/dev/null | grep -v "smart-ssh-key-updater.sh" ; echo "$cron_cmd") | crontab -; then
        log ERROR "Failed to add cron job for SSH key updater"
        return 1
    fi
    
    log INFO "SSH key updater cron job configured for $sync_hour:00 daily"
    
    if ! add_to_installed "service" "ssh-key-updater" "cron" "$updater_script" "$updater_script" "Daily smart SSH key sync from $github_keys_url"; then
        log ERROR "Failed to record installation for ssh-key-updater"
        return 1
    fi
}

setup_system_maintenance() {
    log INFO "Setting up system maintenance cron jobs..."
    
    local maintenance_crons=(
        "0 2 * * 0 sudo apt-get update && sudo apt-get upgrade -y >> $LOG_DIR/system-update.log 2>&1"
        "0 4 * * * docker system prune -af >> $LOG_DIR/docker-cleanup.log 2>&1"
        "*/30 * * * * kubectl get nodes >> $LOG_DIR/k3s-health.log 2>&1"
    )
    
    for cron in "${maintenance_crons[@]}"; do
        log INFO "Adding maintenance cron job: $cron"
        if ! (crontab -l 2>/dev/null | grep -F "$cron" || echo "$cron") | crontab -; then
            log ERROR "Failed to add maintenance cron job: $cron"
            return 1
        fi
    done
    
    log INFO "System maintenance cron jobs configured"
}

setup_backup_jobs() {
    log INFO "Setting up backup cron jobs..."
    
    local backup_script="$HOMELAB_DIR/scripts/backup-configs.sh"
    
    log INFO "Creating backup script: $backup_script"
    if ! cat > "$backup_script" << 'EOF'
#!/bin/bash
set -euo pipefail

BACKUP_DIR="$HOME/homelab/backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

cp -r "$HOME/homelab/configs" "$BACKUP_DIR/"
cp "$HOME/homelab/installed.csv" "$BACKUP_DIR/"
cp "$HOME/homelab/node.info" "$BACKUP_DIR/"

kubectl get all -A > "$BACKUP_DIR/k8s-resources.txt" 2>/dev/null || true

find "$HOME/homelab/backups" -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true

echo "Backup completed: $BACKUP_DIR"
EOF
    then
        log ERROR "Failed to create backup script: $backup_script"
        return 1
    fi

    log INFO "Setting execute permissions on backup script"
    if ! chmod +x "$backup_script"; then
        log ERROR "Failed to set execute permissions on $backup_script"
        return 1
    fi
    
    local backup_cron="0 1 * * * $backup_script >> $LOG_DIR/backup.log 2>&1"
    log INFO "Adding backup cron job: $backup_cron"
    if ! (crontab -l 2>/dev/null | grep -v "backup-configs.sh" ; echo "$backup_cron") | crontab -; then
        log ERROR "Failed to add backup cron job"
        return 1
    fi
    
    log INFO "Backup cron job configured"
    
    if ! add_to_installed "service" "config-backup" "cron" "$backup_script" "$backup_script" "Daily configuration backup"; then
        log ERROR "Failed to record installation for config-backup"
        return 1
    fi
}

verify_cron_setup() {
    log INFO "Verifying cron setup..."
    
    log INFO "Checking cron service status"
    if ! systemctl is-active --quiet cron; then
        log WARN "Cron service is not running, attempting to start it..."
        if ! sudo systemctl start cron; then
            log ERROR "Failed to start cron service"
            return 1
        fi
        if ! sudo systemctl enable cron; then
            log ERROR "Failed to enable cron service"
            return 1
        fi
        log INFO "Cron service started and enabled"
    else
        log INFO "Cron service is running"
    fi
    
    log INFO "Current cron jobs:"
    if ! crontab -l 2>/dev/null; then
        log INFO "No cron jobs configured yet"
    fi
}

main() {
    log INFO "Setting up cron jobs..."
    
    log INFO "Setting up SSH key updater..."
    if ! setup_ssh_key_updater; then
        log ERROR "Failed to setup SSH key updater"
        return 1
    fi
    log INFO "SSH key updater setup completed"
    
    if [[ "$NODE_TYPE" == "master-node" ]]; then
        log INFO "Setting up system maintenance (master-node only)..."
        if ! setup_system_maintenance; then
            log ERROR "Failed to setup system maintenance"
            return 1
        fi
        log INFO "System maintenance setup completed"
        
        log INFO "Setting up backup jobs (master-node only)..."
        if ! setup_backup_jobs; then
            log ERROR "Failed to setup backup jobs"
            return 1
        fi
        log INFO "Backup jobs setup completed"
    else
        log INFO "Skipping system maintenance and backup jobs (not master-node)"
    fi
    
    log INFO "Verifying cron setup..."
    if ! verify_cron_setup; then
        log ERROR "Failed to verify cron setup"
        return 1
    fi
    log INFO "Cron setup verification completed"
    
    log INFO "Cron jobs setup completed successfully!"
}

main "$@"