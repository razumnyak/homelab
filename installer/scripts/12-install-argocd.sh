#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-functions.sh"

# Set default values if not already set
HOMELAB_DIR="${HOMELAB_DIR:-$HOME/homelab}"
CONFIG_DIR="${CONFIG_DIR:-$HOMELAB_DIR/configs}"
DOCS_DIR="${DOCS_DIR:-$HOMELAB_DIR/docs}"

ARGOCD_NAMESPACE="argocd"
ARGOCD_CONFIG_DIR="$CONFIG_DIR/argocd"
ARGOCD_IP="${ARGOCD_IP:-10.0.0.4}"
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

patch_argocd_server() {
    log INFO "Configuring ArgoCD server for LoadBalancer..."
    
    local patch_file="$ARGOCD_CONFIG_DIR/server-patch.yaml"
    
    cat > "$patch_file" <<EOF
spec:
  type: LoadBalancer
  loadBalancerIP: $ARGOCD_IP
EOF
    
    kubectl patch svc argocd-server -n "$ARGOCD_NAMESPACE" --patch-file "$patch_file"
    
    add_to_installed "config" "argocd-loadbalancer" "1.0" "kubernetes" "$patch_file" "ArgoCD LoadBalancer configuration"
}

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

create_argocd_ingress() {
    log INFO "Creating ArgoCD ingress route..."
    
    local ingress="$ARGOCD_CONFIG_DIR/ingress.yaml"
    
    cat > "$ingress" <<EOF
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
    
    kubectl apply -f "$ingress"
    
    add_to_installed "config" "argocd-ingress" "1.0" "kubernetes" "$ingress" "ArgoCD ingress route"
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

setup_argocd_ssh_keys() {
    log INFO "Setting up ArgoCD SSH keys..."
    
    local ssh_keys_dir="$CONFIG_DIR/ssh/keys"
    
    if [[ ! -f "$ssh_keys_dir/argocd-deploy" ]]; then
        log WARN "ArgoCD SSH keys not found. Please run ssh-key-manager.sh first"
        return
    fi
    
    kubectl create secret generic argocd-ssh-key \
        --from-file=sshPrivateKey="$ssh_keys_dir/argocd-deploy" \
        --from-file=sshPublicKey="$ssh_keys_dir/argocd-deploy.pub" \
        -n "$ARGOCD_NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    local known_hosts="$CONFIG_DIR/ssh/known_hosts"
    if [[ -f "$known_hosts" ]]; then
        kubectl create configmap argocd-ssh-known-hosts-cm \
            --from-file=ssh_known_hosts="$known_hosts" \
            -n "$ARGOCD_NAMESPACE" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi
    
    add_to_installed "config" "argocd-ssh-keys" "1.0" "kubernetes" "$ssh_keys_dir/argocd-deploy" "ArgoCD SSH keys"
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
ARGOCD_ALT_URL="https://$ARGOCD_IP"
ARGOCD_USERNAME="admin"
EOF
    
    cat > "$DOCS_DIR/argocd-info.txt" <<EOF
ArgoCD GitOps Information
=========================

Web UI: https://argocd.local (or https://$ARGOCD_IP)
Username: admin
Password: (see credentials.txt)

Load Balancer IP: $ARGOCD_IP
Version: $ARGOCD_VERSION

ArgoCD CLI:
1. Download: https://github.com/argoproj/argo-cd/releases
2. Login: argocd login argocd.local --username admin

Getting started:
1. Access the Web UI
2. Add your Git repository
3. Create applications from your manifests
4. Enable auto-sync for GitOps workflow

Sample application deployed:
- Name: guestbook
- Namespace: default
- Auto-sync: enabled
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
    
    patch_argocd_server
    
    wait_for_argocd
    
    configure_argocd_password
    
    setup_argocd_ssh_keys
    
    create_argocd_ingress
    
    configure_argocd_rbac
    
    create_sample_app
    
    verify_argocd
    
    log INFO "ArgoCD installation completed successfully"
}

main "$@"