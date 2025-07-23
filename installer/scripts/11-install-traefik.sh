#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-functions.sh"

# Set default values if not already set
HOMELAB_DIR="${HOMELAB_DIR:-$HOME/homelab}"
CONFIG_DIR="${CONFIG_DIR:-$HOMELAB_DIR/configs}"
DOCS_DIR="${DOCS_DIR:-$HOMELAB_DIR/docs}"

TRAEFIK_NAMESPACE="traefik"
TRAEFIK_CONFIG_DIR="$CONFIG_DIR/traefik"
TRAEFIK_IP="${TRAEFIK_IP:-10.0.0.3}"
TRAEFIK_VERSION="3.1.6"
TRAEFIK_PASSWORD="${TRAEFIK_PASSWORD:-}"

create_traefik_namespace() {
    log INFO "Creating Traefik namespace..."
    
    kubectl create namespace "$TRAEFIK_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
}

generate_dashboard_auth() {
    log INFO "Generating Traefik dashboard authentication..."
    
    if ! check_command "htpasswd"; then
        log INFO "Installing apache2-utils for htpasswd..."
        sudo apt-get install -y apache2-utils
    fi
    
    local htpasswd_output=$(htpasswd -nb mozg "$TRAEFIK_PASSWORD" | sed -e 's/\$/\$\$/g')
    
    local secret="$TRAEFIK_CONFIG_DIR/dashboard-auth-secret.yaml"
    mkdir -p "$TRAEFIK_CONFIG_DIR"
    
    cat > "$secret" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: traefik-dashboard-auth
  namespace: $TRAEFIK_NAMESPACE
type: Opaque
data:
  users: $(echo -n "$htpasswd_output" | base64 -w0)
EOF
    
    kubectl apply -f "$secret"
    
    add_to_installed "config" "traefik-auth" "1.0" "kubernetes" "$secret" "Traefik dashboard authentication"
}

install_traefik_crds() {
    log INFO "Installing Traefik CRDs..."
    
    local crds_url="https://raw.githubusercontent.com/traefik/traefik/v${TRAEFIK_VERSION}/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml"
    local crds_file="$TRAEFIK_CONFIG_DIR/crds.yaml"
    
    if ! curl -fsSL "$crds_url" -o "$crds_file"; then
        error "Failed to download Traefik CRDs"
    fi
    
    kubectl apply -f "$crds_file"
    
    add_to_installed "config" "traefik-crds" "$TRAEFIK_VERSION" "kubernetes" "$crds_file" "Traefik Custom Resource Definitions"
}

create_traefik_config() {
    log INFO "Creating Traefik configuration..."
    
    local config="$TRAEFIK_CONFIG_DIR/config.yaml"
    
    cat > "$config" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: traefik-config
  namespace: $TRAEFIK_NAMESPACE
data:
  traefik.yml: |
    global:
      checkNewVersion: false
      sendAnonymousUsage: false
    
    api:
      dashboard: true
      debug: true
    
    entryPoints:
      web:
        address: ":80"
        http:
          redirections:
            entryPoint:
              to: websecure
              scheme: https
      websecure:
        address: ":443"
        http:
          tls:
            certResolver: default
    
    providers:
      kubernetesCRD:
        allowCrossNamespace: true
      kubernetesIngress:
        allowEmptyServices: true
    
    log:
      level: INFO
    
    accessLog: {}
    
    metrics:
      prometheus:
        addEntryPointsLabels: true
        addServicesLabels: true
EOF
    
    kubectl apply -f "$config"
    
    add_to_installed "config" "traefik-config" "$TRAEFIK_VERSION" "kubernetes" "$config" "Traefik configuration"
}

create_traefik_deployment() {
    log INFO "Creating Traefik deployment..."
    
    local deployment="$TRAEFIK_CONFIG_DIR/deployment.yaml"
    
    cat > "$deployment" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: traefik
  namespace: $TRAEFIK_NAMESPACE
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: traefik
rules:
  - apiGroups: [""]
    resources: ["services", "endpoints", "secrets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["extensions", "networking.k8s.io"]
    resources: ["ingresses", "ingressclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["extensions", "networking.k8s.io"]
    resources: ["ingresses/status"]
    verbs: ["update"]
  - apiGroups: ["traefik.io"]
    resources: ["middlewares", "middlewaretcps", "ingressroutes", "traefikservices", "ingressroutetcps", "ingressrouteudps", "tlsoptions", "tlsstores", "serverstransports", "serverstransporttcps"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: traefik
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: traefik
subjects:
  - kind: ServiceAccount
    name: traefik
    namespace: $TRAEFIK_NAMESPACE
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: traefik
  namespace: $TRAEFIK_NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: traefik
  template:
    metadata:
      labels:
        app: traefik
    spec:
      serviceAccountName: traefik
      containers:
      - name: traefik
        image: traefik:v${TRAEFIK_VERSION}
        args:
          - --configfile=/config/traefik.yml
        ports:
        - name: web
          containerPort: 80
        - name: websecure
          containerPort: 443
        - name: dashboard
          containerPort: 8080
        volumeMounts:
        - name: config
          mountPath: /config
        resources:
          requests:
            memory: "100Mi"
            cpu: "100m"
          limits:
            memory: "300Mi"
            cpu: "500m"
      volumes:
      - name: config
        configMap:
          name: traefik-config
EOF
    
    kubectl apply -f "$deployment"
    
    add_to_installed "service" "traefik" "$TRAEFIK_VERSION" "kubernetes" "$deployment" "Traefik ingress controller"
}

create_traefik_services() {
    log INFO "Creating Traefik services..."
    
    local services="$TRAEFIK_CONFIG_DIR/services.yaml"
    
    cat > "$services" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: traefik
  namespace: $TRAEFIK_NAMESPACE
spec:
  type: LoadBalancer
  loadBalancerIP: $TRAEFIK_IP
  ports:
  - port: 80
    name: web
    targetPort: 80
  - port: 443
    name: websecure
    targetPort: 443
  selector:
    app: traefik
---
apiVersion: v1
kind: Service
metadata:
  name: traefik-dashboard
  namespace: $TRAEFIK_NAMESPACE
spec:
  type: ClusterIP
  ports:
  - port: 8080
    name: dashboard
    targetPort: 8080
  selector:
    app: traefik
EOF
    
    kubectl apply -f "$services"
    
    add_to_installed "config" "traefik-services" "1.0" "kubernetes" "$services" "Traefik services configuration"
}

create_dashboard_ingress() {
    log INFO "Creating Traefik dashboard ingress..."
    
    local ingress="$TRAEFIK_CONFIG_DIR/dashboard-ingress.yaml"
    
    cat > "$ingress" <<EOF
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: traefik-dashboard
  namespace: $TRAEFIK_NAMESPACE
spec:
  entryPoints:
    - web
  routes:
    - match: Host(\`traefik.local\`)
      kind: Rule
      services:
        - name: traefik-dashboard
          port: 8080
      middlewares:
        - name: traefik-dashboard-auth
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: traefik-dashboard-auth
  namespace: $TRAEFIK_NAMESPACE
spec:
  basicAuth:
    secret: traefik-dashboard-auth
EOF
    
    kubectl apply -f "$ingress"
    
    add_to_installed "config" "traefik-dashboard-ingress" "1.0" "kubernetes" "$ingress" "Traefik dashboard ingress route"
}

wait_for_traefik() {
    log INFO "Waiting for Traefik to be ready..."
    
    if ! kubectl wait --namespace "$TRAEFIK_NAMESPACE" \
        --for=condition=ready pod \
        --selector=app=traefik \
        --timeout=300s; then
        log WARN "Traefik pod not ready after 5 minutes"
    fi
}

verify_traefik() {
    log INFO "Verifying Traefik installation..."
    
    echo ""
    echo "Traefik Status:"
    echo "==============="
    kubectl get pods -n "$TRAEFIK_NAMESPACE"
    echo ""
    kubectl get svc -n "$TRAEFIK_NAMESPACE"
    echo ""
    kubectl get ingressroute -n "$TRAEFIK_NAMESPACE"
    echo ""
    
    cat >> "$DOCS_DIR/credentials.txt" <<EOF

# Traefik Dashboard
TRAEFIK_URL="http://traefik.local"
TRAEFIK_USERNAME="mozg"
TRAEFIK_IP="$TRAEFIK_IP"
EOF
    
    cat > "$DOCS_DIR/traefik-info.txt" <<EOF
Traefik Ingress Controller Information
======================================

Dashboard: http://traefik.local (or http://$TRAEFIK_IP)
Username: mozg
Password: (see credentials.txt)

Load Balancer IP: $TRAEFIK_IP
Version: $TRAEFIK_VERSION

EntryPoints:
- web (80) - HTTP with automatic HTTPS redirect
- websecure (443) - HTTPS

Providers enabled:
- Kubernetes Ingress
- Kubernetes CRD (IngressRoute)

To create an ingress for your app:
1. Using Kubernetes Ingress:
   kubectl create ingress myapp --rule="myapp.local/*=myapp:80"

2. Using Traefik IngressRoute:
   See examples in $TRAEFIK_CONFIG_DIR/examples/
EOF
    
    log INFO "Traefik information saved to $DOCS_DIR/traefik-info.txt"
}

main() {
    log INFO "Starting Traefik installation..."
    
    if [[ -z "$TRAEFIK_PASSWORD" ]]; then
        error "Traefik password not found in credentials file"
    fi
    
    create_traefik_namespace
    
    generate_dashboard_auth
    
    install_traefik_crds
    
    create_traefik_config
    
    create_traefik_deployment
    
    create_traefik_services
    
    wait_for_traefik
    
    create_dashboard_ingress
    
    verify_traefik
    
    log INFO "Traefik installation completed successfully"
}

main "$@"