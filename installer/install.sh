#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$HOME/homelab"
CONFIG_DIR="$HOMELAB_DIR/configs"
DOCS_DIR="$HOMELAB_DIR/docs"
LOGS_DIR="$HOMELAB_DIR/logs"
INSTALLED_CSV="$HOMELAB_DIR/installed.csv"
NODE_INFO="$HOMELAB_DIR/node.info"
CREDENTIALS_FILE="$DOCS_DIR/credentials.txt"

source "$SCRIPT_DIR/scripts/common-functions.sh"

# Load .env file if it exists
if [[ -f "$HOMELAB_DIR/.env" ]]; then
    log INFO "Loading environment variables from .env file..."
    set -a
    source "$HOMELAB_DIR/.env"
    set +a
elif [[ -f "$SCRIPT_DIR/.env" ]]; then
    log INFO "Loading environment variables from installer .env file..."
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

MASTER_IP=""
NODE_TYPE=""
NODE_NAME=""

select_node_type() {
    log INFO "Selecting node type..."
    
    echo ""
    echo "Please select the node type to install:"
    echo "1) master-node - Central management node (K3s server, ArgoCD, Pi-hole, Traefik)"
    echo "2) slave-node  - Worker node (K3s agent only)"
    echo ""
    
    while true; do
        read -p "Enter your choice (1-2): " choice
        case $choice in
            1)
                NODE_TYPE="master-node"
                NODE_NAME="master-node"
                log INFO "Selected: master-node"
                break
                ;;
            2)
                NODE_TYPE="slave-node"
                read -p "Enter slave node number (e.g., 1 for slave-node-1): " node_num
                NODE_NAME="slave-node-$node_num"
                log INFO "Selected: $NODE_NAME"
                
                read -p "Enter master node IP address: " MASTER_IP
                if ! validate_ip "$MASTER_IP"; then
                    log ERROR "Invalid IP address format"
                    continue
                fi
                
                log INFO "Master node IP: $MASTER_IP"
                break
                ;;
            *)
                echo "Invalid choice. Please enter 1 or 2."
                ;;
        esac
    done
}

create_directory_structure() {
    log INFO "Creating homelab directory structure..."
    
    mkdir -p "$CONFIG_DIR"/{k3s,pihole,traefik,argocd,metallb,network}
    mkdir -p "$DOCS_DIR"
    mkdir -p "$LOGS_DIR"
    mkdir -p "$HOMELAB_DIR/scripts"
    
    if [[ ! -f "$INSTALLED_CSV" ]]; then
        echo "timestamp,type,name,version,location,config_path,notes" > "$INSTALLED_CSV"
    fi
    
    cat > "$NODE_INFO" <<EOF
NODE_TYPE=$NODE_TYPE
NODE_NAME=$NODE_NAME
INSTALL_DATE=$(date -Iseconds)
MASTER_IP=$MASTER_IP
EOF
    
    log INFO "Directory structure created"
}

collect_credentials() {
    log INFO "Collecting service credentials..."
    
    local services=()
    local missing_passwords=()
    
    if [[ "$NODE_TYPE" == "master-node" ]]; then
        services=("ArgoCD" "Pi-hole" "Traefik")
    fi
    
    # Check which passwords are missing
    for service in "${services[@]}"; do
        local var_name="${service^^}_PASSWORD"
        var_name="${var_name//-/_}"
        if [[ -z "${!var_name:-}" ]]; then
            missing_passwords+=("$service")
        fi
    done
    
    # If all passwords are already set, skip interactive collection
    if [[ ${#missing_passwords[@]} -eq 0 ]]; then
        log INFO "All service passwords found in environment"
        return 0
    fi
    
    echo ""
    echo "Please provide credentials for services (username: mozg)"
    echo "Missing passwords for: ${missing_passwords[*]}"
    echo ""
    
    > "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
    
    echo "# Homelab Service Credentials" >> "$CREDENTIALS_FILE"
    echo "# Generated: $(date)" >> "$CREDENTIALS_FILE"
    echo "# Username for all services: mozg" >> "$CREDENTIALS_FILE"
    echo "" >> "$CREDENTIALS_FILE"
    
    # Copy existing passwords from environment
    for service in "${services[@]}"; do
        local var_name="${service^^}_PASSWORD"
        var_name="${var_name//-/_}"
        if [[ -n "${!var_name:-}" ]]; then
            echo "${service}_PASSWORD=${!var_name}" >> "$CREDENTIALS_FILE"
            # Export for child scripts
            export "${service}_PASSWORD=${!var_name}"
        fi
    done
    
    # Collect missing passwords interactively
    for service in "${missing_passwords[@]}"; do
        while true; do
            read -s -p "Enter password for $service: " password1
            echo
            read -s -p "Confirm password for $service: " password2
            echo
            
            if [[ "$password1" == "$password2" ]]; then
                if [[ ${#password1} -lt 8 ]]; then
                    echo "Password must be at least 8 characters long"
                    continue
                fi
                echo "${service}_PASSWORD=$password1" >> "$CREDENTIALS_FILE"
                # Export for child scripts
                export "${service}_PASSWORD=$password1"
                break
            else
                echo "Passwords do not match. Please try again."
            fi
        done
    done
    
    log INFO "Credentials saved to $CREDENTIALS_FILE"
}

run_installation_scripts() {
    log INFO "Starting installation process for $NODE_TYPE..."
    
    local scripts=()
    
    if [[ "$NODE_TYPE" == "master-node" ]]; then
        scripts=(
            "00-cloud-init-reset.sh"
            "01-cleanup-existing.sh"
            "02-environment-setup.sh"
            "05-system-prerequisites.sh"
            "06-configure-network.sh"
            "07-install-k3s-master.sh"
            "09-install-metallb.sh"
            "10-install-pihole.sh"
            "11-install-traefik.sh"
            "12-install-argocd.sh"
            "13-configure-routing.sh"
            "14-setup-cron-jobs.sh"
            "99-post-install-check.sh"
        )
    else
        scripts=(
            "00-cloud-init-reset.sh"
            "01-cleanup-existing.sh"
            "02-environment-setup.sh"
            "05-system-prerequisites.sh"
            "06-configure-network.sh"
            "08-install-k3s-agent.sh"
            "14-setup-cron-jobs.sh"
            "99-post-install-check.sh"
        )
    fi
    
    for script in "${scripts[@]}"; do
        local script_path="$SCRIPT_DIR/scripts/$script"
        
        if [[ ! -f "$script_path" ]]; then
            log WARN "Script not found: $script_path, skipping..."
            continue
        fi
        
        if [[ "$script" == "01-cleanup-existing.sh" ]] && [[ "${HOMELAB_FACTORY_RESET_DONE:-false}" == "true" ]]; then
            log INFO "Skipping cleanup (factory reset was performed): $script"
            continue
        fi
        
        log INFO "Running: $script"
        
        if bash "$script_path"; then
            log INFO "Successfully completed: $script"
        else
            log ERROR "Failed to execute: $script"
            log ERROR "Check logs at: $LOGS_DIR/"
            exit 1
        fi
    done
}

show_summary() {
    log INFO "Installation completed successfully!"
    
    echo ""
    echo "================================================"
    echo "       Installation Summary"
    echo "================================================"
    echo "Node Type: $NODE_TYPE"
    echo "Node Name: $NODE_NAME"
    
    if [[ "$NODE_TYPE" == "master-node" ]]; then
        echo ""
        echo "Services installed:"
        echo "- K3s (Kubernetes)"
        echo "- ArgoCD (GitOps)"
        echo "- Pi-hole (DNS/DHCP)"
        echo "- Traefik (Ingress)"
        echo "- MetalLB (LoadBalancer)"
        echo ""
        echo "Credentials saved to: $CREDENTIALS_FILE"
        echo ""
        echo "Access URLs:"
        echo "- ArgoCD:  https://argocd.local"
        echo "- Pi-hole: http://pihole.local/admin"
        echo "- Traefik: http://traefik.local"
    else
        echo "Master Node: $MASTER_IP"
        echo ""
        echo "This node is configured as a K3s agent."
    fi
    
    echo ""
    echo "Installation log: $HOMELAB_DIR/logs/"
    echo "Configuration: $CONFIG_DIR/"
    echo "================================================"
}

main() {
    log INFO "Starting homelab installer..."
    
    if [[ $EUID -eq 0 ]]; then
        log ERROR "This script should not be run as root. Please run as a regular user with sudo privileges."
        exit 1
    fi
    
    select_node_type
    
    create_directory_structure
    
    if [[ "$NODE_TYPE" == "master-node" ]]; then
        collect_credentials
    fi
    
    echo ""
    echo "Ready to install $NODE_TYPE configuration."
    read -p "Continue with installation? (y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log INFO "Installation cancelled by user"
        exit 0
    fi
    
    run_installation_scripts
    
    show_summary
}

main "$@"