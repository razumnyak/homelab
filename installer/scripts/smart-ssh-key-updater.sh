#!/bin/bash

set -euo pipefail

GITHUB_KEYS_URL="${GITHUB_KEYS_URL:-https://github.com/razumnyak.keys}"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
TEMP_KEYS="/tmp/github_keys_$$"
BACKUP_DIR="$HOME/.ssh/backups"
LOG_FILE="${LOG_FILE:-$HOME/homelab/logs/ssh-key-updater.log}"

log() {
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$LOG_FILE" 2>/dev/null || echo "[$timestamp] $message"
}

ensure_ssh_directory() {
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    touch "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
}

fetch_github_keys() {
    log "Fetching keys from $GITHUB_KEYS_URL"
    
    if ! curl -fsSL "$GITHUB_KEYS_URL" > "$TEMP_KEYS" 2>/dev/null; then
        log "ERROR: Failed to fetch keys from GitHub"
        rm -f "$TEMP_KEYS"
        return 1
    fi
    
    if [[ ! -s "$TEMP_KEYS" ]]; then
        log "ERROR: Downloaded keys file is empty"
        rm -f "$TEMP_KEYS"
        return 1
    fi
    
    return 0
}

normalize_key() {
    echo "$1" | sed 's/[[:space:]]*$//' | tr -s ' '
}

update_authorized_keys() {
    log "Updating authorized keys..."
    
    local current_keys_file="/tmp/current_keys_$$"
    local new_keys_added=0
    local existing_keys=0
    
    cp "$AUTHORIZED_KEYS" "$current_keys_file"
    
    while IFS= read -r github_key; do
        [[ -z "$github_key" ]] && continue
        
        local normalized_github_key=$(normalize_key "$github_key")
        local key_found=false
        
        while IFS= read -r existing_key; do
            [[ -z "$existing_key" ]] && continue
            
            local normalized_existing_key=$(normalize_key "$existing_key")
            
            if [[ "$normalized_github_key" == "$normalized_existing_key" ]]; then
                key_found=true
                ((existing_keys++))
                break
            fi
        done < "$current_keys_file"
        
        if [[ "$key_found" == false ]]; then
            echo "$github_key" >> "$AUTHORIZED_KEYS"
            ((new_keys_added++))
            log "Added new key: ${github_key:0:50}..."
        fi
    done < "$TEMP_KEYS"
    
    rm -f "$current_keys_file"
    
    log "Summary: $new_keys_added new keys added, $existing_keys keys already existed"
    
    return 0
}

create_backup() {
    local backup_file="$BACKUP_DIR/authorized_keys.$(date +%Y%m%d-%H%M%S)"
    cp "$AUTHORIZED_KEYS" "$backup_file"
    chmod 600 "$backup_file"
    
    find "$BACKUP_DIR" -name "authorized_keys.*" -mtime +30 -delete 2>/dev/null || true
    
    log "Backup created: $backup_file"
}

cleanup() {
    rm -f "$TEMP_KEYS" "/tmp/current_keys_$$"
}

main() {
    log "Starting smart SSH key update"
    
    trap cleanup EXIT
    
    ensure_ssh_directory
    
    if [[ ! -f "$AUTHORIZED_KEYS" ]]; then
        log "Creating new authorized_keys file"
        touch "$AUTHORIZED_KEYS"
        chmod 600 "$AUTHORIZED_KEYS"
    fi
    
    create_backup
    
    if ! fetch_github_keys; then
        log "Failed to fetch GitHub keys, keeping existing keys unchanged"
        exit 1
    fi
    
    update_authorized_keys
    
    cleanup
    
    log "Smart SSH key update completed successfully"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi