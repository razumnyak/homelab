#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-functions.sh"

# Set default values if not already set
HOMELAB_DIR="${HOMELAB_DIR:-$HOME/homelab}"
CONFIG_DIR="${CONFIG_DIR:-$HOMELAB_DIR/configs}"
DOCS_DIR="${DOCS_DIR:-$HOMELAB_DIR/docs}"

# Load .env file if it exists (for auto-install support)
if [[ -f "$HOMELAB_DIR/.env" ]]; then
    set -a
    source <(grep -v '^#' "$HOMELAB_DIR/.env" | grep -v '^$')
    set +a
fi

ARGOCD_NAMESPACE="argocd"
ARGOCD_CONFIG_DIR="$CONFIG_DIR/argocd"
# ArgoCD will use ClusterIP and be accessible via Traefik after deployment
ARGOCD_VERSION="v2.11.7"
ARGOCD_PASSWORD="${ARGOCD_PASSWORD:-}"

create_argocd_namespace() {
    log INFO "Creating ArgoCD namespace..."
    
    kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
}

install_argocd() {
    log INFO "Installing ArgoCD $ARGOCD_VERSION..."
    
    mkdir -p "$ARGOCD_CONFIG_DIR"
    
    local manifest_url="https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"
    local manifest_file="$ARGOCD_CONFIG_DIR/install.yaml"
    
    if ! curl -fsSL "$manifest_url" -o "$manifest_file"; then
        error "Failed to download ArgoCD manifest"
    fi
    
    if ! kubectl apply -n "$ARGOCD_NAMESPACE" -f "$manifest_file"; then
        error "Failed to apply ArgoCD manifest"
    fi
    
    add_to_installed "service" "argocd" "$ARGOCD_VERSION" "kubernetes" "$manifest_file" "ArgoCD GitOps tool"
}

# ArgoCD will be accessible through Traefik ingress after deployment
# No LoadBalancer configuration needed in bootstrap

wait_for_argocd() {
    log INFO "Waiting for ArgoCD to be ready..."
    
    if ! kubectl wait --namespace "$ARGOCD_NAMESPACE" \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/name=argocd-server \
        --timeout=300s; then
        log WARN "ArgoCD server pod not ready after 5 minutes"
    fi
    
    sleep 20
}

configure_argocd_password() {
    log INFO "Configuring ArgoCD admin password..."
    
    log INFO "Installing ArgoCD CLI..."
    local argocd_cli="/usr/local/bin/argocd"
    
    if [[ ! -f "$argocd_cli" ]]; then
        local cli_url="https://github.com/argoproj/argo-cd/releases/download/$ARGOCD_VERSION/argocd-linux-amd64"
        if ! sudo curl -fsSL "$cli_url" -o "$argocd_cli"; then
            log WARN "Failed to download ArgoCD CLI"
            return
        fi
        sudo chmod +x "$argocd_cli"
    fi
    
    local initial_password=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "")
    
    if [[ -z "$initial_password" ]]; then
        log WARN "Could not retrieve initial ArgoCD password"
        return
    fi
    
    log INFO "Updating ArgoCD admin password..."
    
    local bcrypt_password=$(htpasswd -bnBC 10 "" "$ARGOCD_PASSWORD" | tr -d ':\n' | sed 's/$2y/$2a/')
    
    kubectl -n "$ARGOCD_NAMESPACE" patch secret argocd-secret \
        -p '{"stringData": {"admin.password": "'$bcrypt_password'", "admin.passwordMtime": "'$(date +%FT%T%Z)'"}}'
    
    kubectl -n "$ARGOCD_NAMESPACE" delete pods -l app.kubernetes.io/name=argocd-server
    
    cat >> "$DOCS_DIR/credentials.txt" <<EOF

# ArgoCD Initial Password (if custom password fails)
ARGOCD_INITIAL_PASSWORD="$initial_password"
EOF
}

create_argocd_ingress_template() {
    log INFO "Creating ArgoCD ingress template (for post-Traefik deployment)..."
    
    local ingress_template="$ARGOCD_CONFIG_DIR/ingress-template.yaml"
    
    cat > "$ingress_template" <<EOF
# ArgoCD Ingress Template
# Apply this after Traefik is deployed by ArgoCD
# kubectl apply -f ingress-template.yaml

apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-server
  namespace: $ARGOCD_NAMESPACE
spec:
  entryPoints:
    - web
    - websecure
  routes:
    - match: Host(\`argocd.local\`)
      kind: Rule
      services:
        - name: argocd-server
          port: 80
      middlewares:
        - name: argocd-server-headers
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: argocd-server-headers
  namespace: $ARGOCD_NAMESPACE
spec:
  headers:
    customRequestHeaders:
      X-Forwarded-Proto: "https"
    sslRedirect: true
    sslTemporaryRedirect: false
EOF
    
    log INFO "ArgoCD ingress template created at $ingress_template"
    log INFO "Apply manually after Traefik deployment: kubectl apply -f $ingress_template"
    
    add_to_installed "config" "argocd-ingress-template" "1.0" "kubernetes" "$ingress_template" "ArgoCD ingress template (for post-deployment)"
}

configure_argocd_rbac() {
    log INFO "Configuring ArgoCD RBAC..."
    
    local rbac_config="$ARGOCD_CONFIG_DIR/rbac-cm.yaml"
    
    cat > "$rbac_config" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: $ARGOCD_NAMESPACE
data:
  policy.default: role:readonly
  policy.csv: |
    p, role:admin, applications, *, */*, allow
    p, role:admin, clusters, *, *, allow
    p, role:admin, repositories, *, *, allow
    p, role:admin, certificates, *, *, allow
    p, role:admin, projects, *, *, allow
    p, role:admin, accounts, *, *, allow
    p, role:admin, gpgkeys, *, *, allow
    g, mozg, role:admin
  scopes: '[groups]'
EOF
    
    kubectl apply -f "$rbac_config"
    
    add_to_installed "config" "argocd-rbac" "1.0" "kubernetes" "$rbac_config" "ArgoCD RBAC configuration"
}

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
    log INFO "Verifying SSH agent service..."
    
    # Check if SSH agent service exists and is running
    if systemctl is-active --quiet ssh-agent 2>/dev/null; then
        log INFO "SSH agent service is already running"
    else
        log WARN "SSH agent service is not running"
        log WARN "This should have been set up by 11-setup-ssh-agent.sh"
        return 1
    fi
    
    # Check if SSH agent socket exists
    if [[ -S "/run/ssh-agent.socket" ]]; then
        log INFO "SSH agent socket found at /run/ssh-agent.socket"
        
        # Verify keys are loaded
        local key_count=$(SSH_AUTH_SOCK=/run/ssh-agent.socket ssh-add -l 2>/dev/null | wc -l || echo "0")
        log INFO "SSH agent has $key_count keys loaded"
        
        if [[ "$key_count" -eq 0 ]]; then
            log WARN "No SSH keys loaded in agent"
        fi
        
        return 0
    else
        log ERROR "SSH agent socket not found at /run/ssh-agent.socket"
        return 1
    fi
}

configure_argocd_ssh_agent() {
    log INFO "Configuring ArgoCD with host SSH agent..."
    
    # Setup SSH agent service first
    setup_ssh_agent_service
    
    # Verify SSH agent socket exists before patching
    if [[ ! -S "/run/ssh-agent.socket" ]]; then
        log ERROR "SSH agent socket not found at /run/ssh-agent.socket"
        log ERROR "Cannot configure ArgoCD SSH agent integration"
        return 1
    fi
    
    # Patch ArgoCD repo-server to use host SSH agent
    local ssh_agent_patch="$ARGOCD_CONFIG_DIR/ssh-agent-patch.yaml"
    
    cat > "$ssh_agent_patch" <<EOF
spec:
  template:
    spec:
      containers:
      - name: argocd-repo-server
        env:
        - name: SSH_AUTH_SOCK
          value: /run/ssh-agent.socket
        volumeMounts:
        - name: ssh-agent
          mountPath: /run/ssh-agent.socket
      volumes:
      - name: ssh-agent
        hostPath:
          path: /run/ssh-agent.socket
          type: Socket
EOF
    
    kubectl patch deployment argocd-repo-server -n "$ARGOCD_NAMESPACE" --patch-file "$ssh_agent_patch"
    
    log INFO "ArgoCD configured to use host SSH agent at /run/ssh-agent.socket"
    add_to_installed "config" "argocd-ssh-agent" "1.0" "kubernetes" "$ssh_agent_patch" "ArgoCD SSH agent configuration"
}

setup_argocd_ssh_keys() {
    log INFO "Setting up ArgoCD SSH keys..."
    
    local ssh_keys_dir="$CONFIG_DIR/ssh/keys"
    local ssh_private_key="$ssh_keys_dir/argocd-deploy"
    local ssh_public_key="$ssh_keys_dir/argocd-deploy.pub"
    
    # Check if SSH keys already exist
    if [[ -f "$ssh_private_key" && -f "$ssh_public_key" ]]; then
        log INFO "ArgoCD SSH keys already exist, using existing keys"
        log INFO "Private key: $ssh_private_key"
        log INFO "Public key: $ssh_public_key"
    else
        log INFO "Generating new ArgoCD SSH keys..."
        
        # Create SSH keys directory
        mkdir -p "$ssh_keys_dir"
        chmod 700 "$ssh_keys_dir"
        
        # Generate SSH key pair for ArgoCD
        ssh-keygen -t rsa -b 4096 -f "$ssh_private_key" -N "" -C "argocd-deploy@$(hostname)"
        
        # Set proper permissions
        chmod 600 "$ssh_private_key"
        chmod 644 "$ssh_public_key"
        
        log INFO "Generated new ArgoCD SSH key pair"
        log INFO "Private key: $ssh_private_key"
        log INFO "Public key: $ssh_public_key"
    fi
    
    # Verify keys exist before proceeding
    if [[ ! -f "$ssh_private_key" || ! -f "$ssh_public_key" ]]; then
        log ERROR "ArgoCD SSH keys not found after generation"
        return 1
    fi
    
    # Create ArgoCD SSH secret
    kubectl create secret generic argocd-ssh-key \
        --from-file=sshPrivateKey="$ssh_private_key" \
        --from-file=sshPublicKey="$ssh_public_key" \
        -n "$ARGOCD_NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Setup known_hosts for GitHub
    local known_hosts_file="$CONFIG_DIR/ssh/known_hosts"
    if [[ ! -f "$known_hosts_file" ]]; then
        log INFO "Creating known_hosts for GitHub..."
        mkdir -p "$CONFIG_DIR/ssh"
        ssh-keyscan github.com > "$known_hosts_file" 2>/dev/null
    fi
    
    if [[ -f "$known_hosts_file" ]]; then
        kubectl create configmap argocd-ssh-known-hosts-cm \
            --from-file=ssh_known_hosts="$known_hosts_file" \
            -n "$ARGOCD_NAMESPACE" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi
    
    add_to_installed "config" "argocd-ssh-keys" "1.0" "kubernetes" "$ssh_keys_dir/argocd-deploy" "ArgoCD SSH keys"
}

setup_argocd_repository() {
    local repo_url="$1"
    
    if [[ ! "$repo_url" =~ ^git@ ]]; then
        log INFO "Public repository, no SSH setup needed"
        return 0
    fi
    
    log INFO "Setting up ArgoCD repository with SSH authentication..."
    
    local ssh_key_file="$CONFIG_DIR/ssh/keys/argocd-deploy"
    if [[ ! -f "$ssh_key_file" ]]; then
        log ERROR "SSH private key not found: $ssh_key_file"
        return 1
    fi
    
    local repo_secret="$ARGOCD_CONFIG_DIR/repository-secret.yaml"
    
    cat > "$repo_secret" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: homelab-k8s-repo
  namespace: $ARGOCD_NAMESPACE
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: $repo_url
  sshPrivateKey: |
$(cat "$ssh_key_file" | sed 's/^/    /')
EOF
    
    kubectl apply -f "$repo_secret"
    
    log INFO "Repository secret created for: $repo_url"
    add_to_installed "config" "argocd-repository" "1.0" "kubernetes" "$repo_secret" "ArgoCD repository configuration"
}

create_sample_app() {
    log INFO "Creating sample ArgoCD application..."
    
    local sample_app="$ARGOCD_CONFIG_DIR/sample-app.yaml"
    
    cat > "$sample_app" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: $ARGOCD_NAMESPACE
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
    - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF
    
    kubectl apply -f "$sample_app"
    
    add_to_installed "config" "argocd-sample-app" "1.0" "kubernetes" "$sample_app" "ArgoCD sample application"
}

confirm_ssh_key_setup() {
    local public_key_file="$1"
    local repo_url="$2"
    
    if [[ ! -f "$public_key_file" ]]; then
        log ERROR "SSH public key not found: $public_key_file"
        return 1
    fi
    
    echo ""
    echo "=========================================="
    echo "🔑 ArgoCD SSH Key Setup Required"
    echo "=========================================="
    echo ""
    echo "For private repository access, you need to add this SSH public key"
    echo "as a deploy key to your GitHub repository: $repo_url"
    echo ""
    echo "📋 SSH Public Key:"
    echo "---"
    cat "$public_key_file"
    echo "---"
    echo ""
    echo "📖 Steps to add deploy key:"
    echo "1. Copy the SSH key above"
    echo "2. Go to: $repo_url/settings/keys"
    echo "3. Click 'Add deploy key'"
    echo "4. Paste the key and give it a title (e.g., 'ArgoCD Deploy Key')"
    echo "5. ✅ Check 'Allow write access' if you want ArgoCD to push changes"
    echo "6. Click 'Add key'"
    echo ""
    
    while true; do
        read -p "Have you added this SSH key to your repository? (Y/n): " confirm
        case $confirm in
            [Yy]|[Yy][Ee][Ss]|"")
                log INFO "SSH key confirmed. Proceeding with App-of-Apps setup..."
                return 0
                ;;
            [Nn]|[Nn][Oo])
                echo ""
                echo "Please add the SSH key to your repository before continuing."
                echo "The key is also saved at: $public_key_file"
                echo ""
                ;;
            *)
                echo "Please answer yes (y) or no (n)."
                ;;
        esac
    done
}

setup_app_of_apps() {
    log INFO "Setting up App-of-Apps for homelab-k8s repository..."
    
    local app_of_apps="$ARGOCD_CONFIG_DIR/app-of-apps.yaml"
    local repo_url="$HOMELAB_K8S_REPO"
    local is_ssh_repo=false
    
    # Convert HTTPS to SSH for private repos authentication
    if [[ "$repo_url" =~ ^https://github.com/ ]]; then
        repo_url=$(echo "$repo_url" | sed 's|https://github.com/|git@github.com:|' | sed 's|\.git$||').git
        is_ssh_repo=true
        log INFO "Using SSH URL for private repo support: $repo_url"
    elif [[ "$repo_url" =~ ^git@ ]]; then
        is_ssh_repo=true
    fi
    
    # For SSH repositories, confirm the deploy key is added
    if [[ "$is_ssh_repo" == true ]]; then
        local public_key_file="$CONFIG_DIR/ssh/keys/argocd-deploy.pub"
        
        if [[ "${AUTO_CONFIRM:-false}" == "true" ]]; then
            log INFO "AUTO_CONFIRM enabled. Skipping SSH key confirmation."
            log INFO "SSH public key location: $public_key_file"
            echo "🔑 ArgoCD SSH Public Key for deploy key:"
            cat "$public_key_file"
            echo ""
        else
            confirm_ssh_key_setup "$public_key_file" "$HOMELAB_K8S_REPO"
        fi
        
        # Setup repository secret in ArgoCD
        setup_argocd_repository "$repo_url"
    fi
    
    cat > "$app_of_apps" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: homelab-infrastructure
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: $repo_url
    path: infrastructure
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
    - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF
    
    # Wait for ArgoCD to be ready before applying
    sleep 30
    kubectl apply -f "$app_of_apps"
    
    log INFO "App-of-Apps configured to deploy from $repo_url"
}

verify_argocd() {
    log INFO "Verifying ArgoCD installation..."
    
    echo ""
    echo "ArgoCD Status:"
    echo "=============="
    kubectl get pods -n "$ARGOCD_NAMESPACE"
    echo ""
    kubectl get svc -n "$ARGOCD_NAMESPACE"
    echo ""
    kubectl get applications -n "$ARGOCD_NAMESPACE" 2>/dev/null || true
    echo ""
    
    cat >> "$DOCS_DIR/credentials.txt" <<EOF

# ArgoCD Web UI
ARGOCD_URL="https://argocd.local"
ARGOCD_ALT_URL="http://localhost:8080 (kubectl port-forward)"
ARGOCD_USERNAME="admin"
EOF
    
    cat > "$DOCS_DIR/argocd-info.txt" <<EOF
ArgoCD GitOps Information
=========================

Web UI: https://argocd.local (after Traefik deployment)
Temporary access: kubectl port-forward -n argocd svc/argocd-server 8080:80
Username: admin
Password: (see credentials.txt)

Version: $ARGOCD_VERSION

ArgoCD CLI:
1. Download: https://github.com/argoproj/argo-cd/releases
2. Login: argocd login argocd.local --username admin

Bootstrap Configuration:
- App-of-Apps: homelab-infrastructure
- Repository: $HOMELAB_K8S_REPO
- Auto-sync: enabled

Applications will be automatically deployed from homelab-k8s repository.
EOF
    
    log INFO "ArgoCD information saved to $DOCS_DIR/argocd-info.txt"
}

main() {
    log INFO "Starting ArgoCD installation..."
    
    if [[ -z "$ARGOCD_PASSWORD" ]]; then
        error "ArgoCD password not found in credentials file"
    fi
    
    create_argocd_namespace
    
    install_argocd
    
    wait_for_argocd
    
    configure_argocd_password
    
    setup_argocd_ssh_keys
    
    create_argocd_ingress_template
    
    configure_argocd_rbac
    
    configure_argocd_ssh_agent
    
    create_sample_app
    
    setup_app_of_apps
    
    verify_argocd
    
    log INFO "ArgoCD installation completed successfully"
}

main "$@"