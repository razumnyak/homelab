#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-functions.sh"

# Set default values if not already set
HOMELAB_DIR="${HOMELAB_DIR:-$HOME/homelab}"
CONFIG_DIR="${CONFIG_DIR:-$HOMELAB_DIR/configs}"
NODE_INFO="${NODE_INFO:-$HOMELAB_DIR/node.info}"

if [[ -f "$NODE_INFO" ]]; then
    source "$NODE_INFO"
fi

NODES_LIST="$CONFIG_DIR/nodes.list"

update_nodes_list() {
    local action="$1"
    local node_ip="$2"
    
    case "$action" in
        add)
            add_slave_node "$node_ip"
            ;;
        remove)
            remove_slave_node "$node_ip"
            ;;
        list)
            list_slave_nodes
            ;;
        *)
            echo "Usage: $0 {add|remove|list} [node_ip]"
            exit 1
            ;;
    esac
}

add_slave_node() {
    local node_ip="$1"
    
    log INFO "Adding slave node $node_ip to cluster list..."
    
    mkdir -p "$(dirname "$NODES_LIST")"
    
    if [[ -f "$NODES_LIST" ]] && grep -q "^$node_ip$" "$NODES_LIST"; then
        log INFO "Node $node_ip already in list"
        return
    fi
    
    echo "$node_ip" >> "$NODES_LIST"
    sort -u "$NODES_LIST" -o "$NODES_LIST"
    
    log INFO "Node $node_ip added to cluster list"
    
    if [[ "$NODE_TYPE" == "master-node" ]]; then
        log INFO "Distributing SSH keys to new slave node..."
        "$SCRIPT_DIR/ssh-key-manager.sh" distribute
    fi
}

remove_slave_node() {
    local node_ip="$1"
    
    log INFO "Removing slave node $node_ip from cluster list..."
    
    if [[ ! -f "$NODES_LIST" ]]; then
        log WARN "Nodes list file not found"
        return
    fi
    
    if ! grep -q "^$node_ip$" "$NODES_LIST"; then
        log WARN "Node $node_ip not found in list"
        return
    fi
    
    grep -v "^$node_ip$" "$NODES_LIST" > "${NODES_LIST}.tmp" || true
    mv "${NODES_LIST}.tmp" "$NODES_LIST"
    
    log INFO "Node $node_ip removed from cluster list"
}

list_slave_nodes() {
    if [[ ! -f "$NODES_LIST" ]]; then
        log INFO "No slave nodes configured"
        return
    fi
    
    echo "Slave nodes in cluster:"
    echo "======================"
    while IFS= read -r node_ip; do
        [[ -z "$node_ip" || "$node_ip" =~ ^#.* ]] && continue
        
        if ping -c 1 -W 1 "$node_ip" &>/dev/null; then
            status="✓ Online"
        else
            status="✗ Offline"
        fi
        
        echo "$node_ip - $status"
    done < "$NODES_LIST"
}

register_with_master() {
    local master_ip="$1"
    local slave_ip="$2"
    
    log INFO "Registering slave node with master..."
    
    local temp_script="/tmp/register_slave_$$"
    
    cat > "$temp_script" <<EOF
#!/bin/bash
set -e

# Add node to the list
echo "$slave_ip" >> "$CONFIG_DIR/nodes.list"
sort -u "$CONFIG_DIR/nodes.list" -o "$CONFIG_DIR/nodes.list"

echo "Slave node $slave_ip registered successfully"
EOF
    
    chmod +x "$temp_script"
    
    if scp -o StrictHostKeyChecking=no "$temp_script" "homelab@${master_ip}:/tmp/register_slave.sh" && \
       ssh -o StrictHostKeyChecking=no "homelab@${master_ip}" "bash /tmp/register_slave.sh"; then
        log INFO "Successfully registered with master node"
        
        ssh -o StrictHostKeyChecking=no "homelab@${master_ip}" "rm -f /tmp/register_slave.sh" || true
    else
        log WARN "Failed to register with master node. SSH keys may not be set up yet."
    fi
    
    rm -f "$temp_script"
}

main() {
    local command="${1:-}"
    
    case "$command" in
        add|remove|list)
            local node_ip="${2:-}"
            if [[ "$command" != "list" && -z "$node_ip" ]]; then
                echo "Error: node_ip required for $command operation"
                exit 1
            fi
            update_nodes_list "$command" "$node_ip"
            ;;
        register)
            local master_ip="${2:-$MASTER_IP}"
            local slave_ip="${3:-$(get_primary_ip)}"
            
            if [[ -z "$master_ip" ]]; then
                error "Master IP not provided"
            fi
            
            register_with_master "$master_ip" "$slave_ip"
            ;;
        *)
            echo "Usage: $0 {add|remove|list|register} [node_ip] [master_ip]"
            echo ""
            echo "Commands:"
            echo "  add <ip>        - Add slave node to cluster list"
            echo "  remove <ip>     - Remove slave node from cluster list"
            echo "  list            - List all slave nodes with status"
            echo "  register <master_ip> [slave_ip] - Register slave with master"
            exit 1
            ;;
    esac
}

main "$@"