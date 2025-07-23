#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-functions.sh"

# Set default values if not already set
HOMELAB_DIR="${HOMELAB_DIR:-$HOME/homelab}"
CONFIG_DIR="${CONFIG_DIR:-$HOMELAB_DIR/configs}"
DOCS_DIR="${DOCS_DIR:-$HOMELAB_DIR/docs}"

PIHOLE_NAMESPACE="pihole"
PIHOLE_CONFIG_DIR="$CONFIG_DIR/pihole"
PIHOLE_IP="${PIHOLE_IP:-10.0.0.2}"
PI_HOLE_PASSWORD="${PI_HOLE_PASSWORD:-}"

create_pihole_namespace() {
    log INFO "Creating Pi-hole namespace..."
    
    kubectl create namespace "$PIHOLE_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
}

create_pihole_configmap() {
    log INFO "Creating Pi-hole configuration..."
    
    mkdir -p "$PIHOLE_CONFIG_DIR"
    
    local configmap="$PIHOLE_CONFIG_DIR/configmap.yaml"
    
    cat > "$configmap" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: pihole-config
  namespace: $PIHOLE_NAMESPACE
data:
  TZ: "UTC"
  WEBPASSWORD: "$PI_HOLE_PASSWORD"
  PIHOLE_DOMAIN: "local"
  ADMIN_EMAIL: "admin@homelab.local"
  PIHOLE_DNS_: "1.1.1.1;1.0.0.1"
  DNSSEC: "false"
  CONDITIONAL_FORWARDING: "true"
  CONDITIONAL_FORWARDING_IP: "${LAN_SUBNET%/*}"
  CONDITIONAL_FORWARDING_DOMAIN: "local"
  CONDITIONAL_FORWARDING_REVERSE: "0.0.10.in-addr.arpa"
  DHCP_ACTIVE: "true"
  DHCP_START: "${DHCP_RANGE_START:-10.0.0.51}"
  DHCP_END: "${DHCP_RANGE_END:-10.0.0.250}"
  DHCP_ROUTER: "${LAN_SUBNET%/*}"
  PIHOLE_DOMAIN: "local"
  DHCP_LEASETIME: "24"
EOF
    
    kubectl apply -f "$configmap"
    
    add_to_installed "config" "pihole-configmap" "1.0" "kubernetes" "$configmap" "Pi-hole configuration"
}

create_pihole_deployment() {
    log INFO "Creating Pi-hole deployment..."
    
    local deployment="$PIHOLE_CONFIG_DIR/deployment.yaml"
    
    cat > "$deployment" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pihole-etc-pvc
  namespace: $PIHOLE_NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pihole-dnsmasq-pvc
  namespace: $PIHOLE_NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 500Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pihole
  namespace: $PIHOLE_NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pihole
  template:
    metadata:
      labels:
        app: pihole
    spec:
      containers:
      - name: pihole
        image: pihole/pihole:latest
        imagePullPolicy: Always
        envFrom:
        - configMapRef:
            name: pihole-config
        ports:
        - containerPort: 80
          name: web
          protocol: TCP
        - containerPort: 53
          name: dns
          protocol: TCP
        - containerPort: 53
          name: dns-udp
          protocol: UDP
        - containerPort: 67
          name: dhcp
          protocol: UDP
        volumeMounts:
        - name: pihole-etc
          mountPath: /etc/pihole
        - name: pihole-dnsmasq
          mountPath: /etc/dnsmasq.d
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /admin/index.php
            port: 80
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /admin/index.php
            port: 80
          initialDelaySeconds: 15
          periodSeconds: 5
      volumes:
      - name: pihole-etc
        persistentVolumeClaim:
          claimName: pihole-etc-pvc
      - name: pihole-dnsmasq
        persistentVolumeClaim:
          claimName: pihole-dnsmasq-pvc
      dnsPolicy: None
      dnsConfig:
        nameservers:
        - 127.0.0.1
        - 1.1.1.1
EOF
    
    kubectl apply -f "$deployment"
    
    add_to_installed "service" "pihole-deployment" "latest" "kubernetes" "$deployment" "Pi-hole DNS/DHCP server"
}

create_pihole_services() {
    log INFO "Creating Pi-hole services..."
    
    local services="$PIHOLE_CONFIG_DIR/services.yaml"
    
    cat > "$services" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: pihole-web
  namespace: $PIHOLE_NAMESPACE
spec:
  type: LoadBalancer
  loadBalancerIP: $PIHOLE_IP
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
    name: web
  selector:
    app: pihole
---
apiVersion: v1
kind: Service
metadata:
  name: pihole-dns
  namespace: $PIHOLE_NAMESPACE
spec:
  type: LoadBalancer
  loadBalancerIP: $PIHOLE_IP
  ports:
  - port: 53
    targetPort: 53
    protocol: TCP
    name: dns-tcp
  - port: 53
    targetPort: 53
    protocol: UDP
    name: dns-udp
  selector:
    app: pihole
---
apiVersion: v1
kind: Service
metadata:
  name: pihole-dhcp
  namespace: $PIHOLE_NAMESPACE
spec:
  type: LoadBalancer
  loadBalancerIP: $PIHOLE_IP
  ports:
  - port: 67
    targetPort: 67
    protocol: UDP
    name: dhcp
  selector:
    app: pihole
EOF
    
    kubectl apply -f "$services"
    
    add_to_installed "config" "pihole-services" "1.0" "kubernetes" "$services" "Pi-hole services configuration"
}

wait_for_pihole() {
    log INFO "Waiting for Pi-hole to be ready..."
    
    if ! kubectl wait --namespace "$PIHOLE_NAMESPACE" \
        --for=condition=ready pod \
        --selector=app=pihole \
        --timeout=60s; then
        log WARN "Pi-hole pod not ready after 60 seconds, continuing anyway..."
        log INFO "You can check status later with: kubectl get pods -n $PIHOLE_NAMESPACE"
    fi
}

create_custom_dns_entries() {
    log INFO "Adding custom DNS entries..."
    
    local custom_dns="$PIHOLE_CONFIG_DIR/custom-dns.yaml"
    
    cat > "$custom_dns" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: pihole-custom-dns
  namespace: $PIHOLE_NAMESPACE
data:
  custom.list: |
    10.0.0.2 pihole pihole.local
    10.0.0.3 traefik traefik.local
    10.0.0.4 argocd argocd.local
    10.0.0.5 registry registry.local
EOF
    
    kubectl apply -f "$custom_dns"
}

verify_pihole() {
    log INFO "Verifying Pi-hole installation..."
    
    echo ""
    echo "Pi-hole Status:"
    echo "==============="
    kubectl get pods -n "$PIHOLE_NAMESPACE"
    echo ""
    kubectl get svc -n "$PIHOLE_NAMESPACE"
    echo ""
    
    cat >> "$DOCS_DIR/credentials.txt" <<EOF

# Pi-hole Admin Interface
PIHOLE_URL="http://pihole.local/admin"
PIHOLE_USERNAME="admin"
PIHOLE_IP="$PIHOLE_IP"
EOF
    
    cat > "$DOCS_DIR/pihole-info.txt" <<EOF
Pi-hole DNS/DHCP Server Information
===================================

Admin Interface: http://pihole.local/admin (or http://$PIHOLE_IP/admin)
Username: mozg
Password: (see credentials.txt)

DNS Server: $PIHOLE_IP
DHCP Range: 10.0.0.51 - 10.0.0.250

Custom DNS entries added for:
- pihole.local → 10.0.0.2
- traefik.local → 10.0.0.3
- argocd.local → 10.0.0.4
- registry.local → 10.0.0.5

To use Pi-hole DNS on other devices:
1. Set DNS server to: $PIHOLE_IP
2. Or enable DHCP on Pi-hole and disable on your router
EOF
    
    log INFO "Pi-hole information saved to $DOCS_DIR/pihole-info.txt"
}

main() {
    log INFO "Starting Pi-hole installation..."
    
    if [[ -z "$PI_HOLE_PASSWORD" ]]; then
        error "Pi-hole password not found in credentials file"
    fi
    
    create_pihole_namespace
    
    create_pihole_configmap
    
    create_pihole_deployment
    
    create_pihole_services
    
    wait_for_pihole
    
    create_custom_dns_entries
    
    verify_pihole
    
    log INFO "Pi-hole installation completed successfully"
}

main "$@"