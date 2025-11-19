#!/bin/bash

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check required commands
check_dependencies() {
    local deps=("talosctl" "kubectl" "helm" "envsubst" "yq")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "$cmd is not installed. Please install it first."
            exit 1
        fi
    done
}

# Configuration
MASTER_IP="${MASTER_IP:-}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-}"
HARBOR_CONTAINERD_USERNAME="${HARBOR_CONTAINERD_USERNAME:-}"
HARBOR_CONTAINERD_PASSWORD="${HARBOR_CONTAINERD_PASSWORD:-}"
TALOS_INSTALL_IMAGE="${TALOS_INSTALL_IMAGE:-}"
LOCAL_CIDR="${LOCAL_CIDR:-}"

# Helm Configuration
CILIUM_VERSION="${CILIUM_VERSION:-}"
TALOS_CCM_VERSION="${TALOS_CCM_VERSION:-}"
LOCAL_PATH_PROVISIONER_VERSION="${LOCAL_PATH_PROVISIONER_VERSION:-}"
METALLB_VERSION="${METALLB_VERSION:-}"
METALLB_DEFAULT_IP_POOL="${METALLB_DEFAULT_IP_POOL:-}"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NLB_PUBLIC_IP="$MASTER_IP"
export TALOSCONFIG="${SCRIPT_DIR}/talosconfig"
export KUBECONFIG="${SCRIPT_DIR}/kubeconfig"


# Validate IP address
validate_ip() {
    if [[ ! $MASTER_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_error "Invalid IP address: $MASTER_IP"
        exit 1
    fi
}

# Wait for node to be reachable
wait_for_node() {
    log_info "Waiting for node $MASTER_IP to be reachable..."
    local retries=60
    local count=0
    while ! talosctl --talosconfig "$TALOSCONFIG" --nodes "$MASTER_IP" version &>/dev/null; do
        count=$((count + 1))
        if [ $count -ge $retries ]; then
            log_error "Node did not become reachable after $retries attempts"
            exit 1
        fi
        echo -n "."
        sleep 5
    done
    echo
    log_info "Node is reachable!"
}

# Wait for Kubernetes API
wait_for_k8s_api() {
    log_info "Waiting for Kubernetes API to be ready..."
    local retries=60
    local count=0
    while ! kubectl --kubeconfig "$KUBECONFIG" get nodes &>/dev/null; do
        count=$((count + 1))
        if [ $count -ge $retries ]; then
            log_error "Kubernetes API did not become ready after $retries attempts"
            exit 1
        fi
        echo -n "."
        sleep 5
    done
    echo
    log_info "Kubernetes API is ready!"
}

# Wait for control plane pods to be running
wait_for_control_plane() {
    log_info "Waiting for control plane components to be ready..."
    local retries=60
    local count=0
    
    while true; do
        count=$((count + 1))
        if [ $count -ge $retries ]; then
            log_error "Control plane did not become ready after $retries attempts"
            kubectl get pods -n kube-system || true
            exit 1
        fi
        
        # Check if kube-apiserver, kube-controller-manager, and kube-scheduler are running
        local api_ready=$(kubectl get pods -n kube-system -l component=kube-apiserver --no-headers 2>/dev/null | grep "Running" | wc -l)
        local controller_ready=$(kubectl get pods -n kube-system -l component=kube-controller-manager --no-headers 2>/dev/null | grep "Running" | wc -l)
        local scheduler_ready=$(kubectl get pods -n kube-system -l component=kube-scheduler --no-headers 2>/dev/null | grep "Running" | wc -l)
        
        # Trim whitespace
        api_ready=$(echo "$api_ready" | tr -d '[:space:]')
        controller_ready=$(echo "$controller_ready" | tr -d '[:space:]')
        scheduler_ready=$(echo "$scheduler_ready" | tr -d '[:space:]')
        
        if [ "$api_ready" -ge 1 ] 2>/dev/null && [ "$controller_ready" -ge 1 ] 2>/dev/null && [ "$scheduler_ready" -ge 1 ] 2>/dev/null; then
            echo
            log_info "Control plane components are running!"
            break
        fi
        
        echo -n "."
        sleep 5
    done
    
    # Additional wait to ensure API server is fully stable
    log_info "Waiting for API server to stabilize..."
    sleep 10
}

# Wait for API resources to be available
wait_for_api_resources() {
    log_info "Waiting for Kubernetes API resources to be available..."
    local retries=30
    local count=0
    
    while true; do
        count=$((count + 1))
        if [ $count -ge $retries ]; then
            log_error "API resources did not become available after $retries attempts"
            kubectl api-resources || true
            exit 1
        fi
        
        # Check if ServiceAccount API is available
        if kubectl api-resources --api-group="" -o name 2>/dev/null | grep -q "serviceaccounts"; then
            echo
            log_info "API resources are available!"
            break
        fi
        
        echo -n "."
        sleep 2
    done
}

# Wait for pods to be ready
wait_for_pods() {
    log_info "Waiting for all pods to be ready..."
    kubectl wait --for=condition=ready pods --all --all-namespaces --timeout=600s || {
        log_warn "Some pods may not be ready yet, continuing..."
    }
}

# Wait for test pods to be in ready state
run_tests() {
    log_info "Running Tests"
    kubectl apply -f nginx_test_deployment.yaml

    # Wait for deployment with warning
    kubectl wait --for=condition=available deployment/nginx-deployment -n default --timeout=600s || {
        log_warn "Deployment not fully ready within timeout"
        log_warn "Current status:"
        kubectl get deployment nginx-deployment -n default
        kubectl get pods -l app=nginx -n default
    }

    log_info "Test deployment completed"
    kubectl get pvc -n default
    kubectl get svc -n default nginx-service
    log_info "Deleting test deployment"
    kubectl delete -f nginx_test_deployment.yaml

}

# Main deployment
main() {
    log_info "Starting Talos Kubernetes deployment"

    check_dependencies
    validate_ip

    if [ -z "$HARBOR_CONTAINERD_PASSWORD" ]; then
        log_error "HARBOR_CONTAINERD_PASSWORD is not set"
        exit 1
    fi

    cd "$SCRIPT_DIR"

    # Export variables for envsubst
    export MASTER_IP KUBERNETES_VERSION HARBOR_CONTAINERD_USERNAME
    export HARBOR_CONTAINERD_PASSWORD TALOS_INSTALL_IMAGE LOCAL_CIDR

    # Generate secrets
    log_info "Generating Talos secrets..."
    talosctl gen secrets --force

    # Process patch files
    log_info "Processing patch files..."
    envsubst < patch_controlplane.yaml > /tmp/patch_controlplane_out.yaml
    envsubst < patch.yaml > /tmp/patch_out.yaml
    yq -y --arg subnet "$LOCAL_CIDR" \
        '.machine.kubelet.nodeIP.validSubnets += [$subnet]' \
        /tmp/patch_out.yaml > /tmp/patch_out.yaml.$$ && \
        mv /tmp/patch_out.yaml.$$ /tmp/patch_out.yaml

    # Generate Talos configuration
    log_info "Generating Talos configuration..."
    talosctl gen config talos1 "https://$MASTER_IP:6443" \
        --with-secrets secrets.yaml \
        --output-dir . \
        --config-patch-control-plane @/tmp/patch_controlplane_out.yaml \
        --config-patch @/tmp/patch_out.yaml \
        --force \
        --kubernetes-version "$KUBERNETES_VERSION"

    # Configure talosctl
    log_info "Configuring talosctl endpoints..."
    talosctl config endpoint "$MASTER_IP"
    talosctl config node "$MASTER_IP"

    # Apply configuration
    log_info "Applying Talos configuration to $MASTER_IP..."
    talosctl apply-config --insecure --nodes "$MASTER_IP" --file controlplane.yaml

    # Wait for node to be ready after config application
    sleep 10
    wait_for_node

    # Bootstrap cluster
    log_info "Bootstrapping Talos cluster..."
    talosctl bootstrap -n "$MASTER_IP"

    # Generate kubeconfig
    log_info "Generating kubeconfig..."
    rm -f kubeconfig
    talosctl kubeconfig . --force

    # Wait for Kubernetes API
    wait_for_k8s_api

    # Wait for control plane to be fully ready
    wait_for_control_plane

    # Wait for API resources to be available
    wait_for_api_resources

    # Apply cloud controller manager if manifest exists
    if ! [ -z "$TALOS_CCM_VERSION" ]; then
        log_info "Applying Talos Cloud Controller Manager..."

        helm install talos-cloud-controller-manager \
            oci://ghcr.io/siderolabs/charts/talos-cloud-controller-manager \
            --version "$TALOS_CCM_VERSION" \
            --namespace kube-system \
	    --wait --wait-for-jobs \
            --set logVerbosityLevel=4 \
            --set enabledControllers[0]=cloud-node \
            --set enabledControllers[1]=node-csr-approval \
            --set enabledControllers[2]=node-ipam-controller \
            --set extraArgs[0]=--allocate-node-cidrs \
            --set extraArgs[1]=--cidr-allocator-type=RangeAllocator \
            --set extraArgs[2]=--node-cidr-mask-size-ipv4=24 \
            --set extraArgs[3]=--node-cidr-mask-size-ipv6=80 \
            --set daemonSet.enabled=true \
            --set tolerations[0].effect=NoSchedule \
            --set tolerations[0].operator=Exists

    else
        log_warn "Cloud controller manifest not found at: $CLOUD_CONTROLLER_MANIFEST"
        log_warn "Skipping cloud controller deployment"
    fi

    # Install Cilium
    if ! [ -z "$CILIUM_VERSION" ]; then
        log_info "Installing Cilium CNI..."

        # Add Cilium Helm repository
        helm repo add cilium https://helm.cilium.io/ &>/dev/null || true
        helm repo update

        helm upgrade --install \
            cilium \
            cilium/cilium \
            --version "$CILIUM_VERSION" \
            --namespace kube-system \
	    --wait --wait-for-jobs \
            --set ipam.mode=kubernetes \
            --set kubeProxyReplacement=true \
            --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
            --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
            --set cgroup.autoMount.enabled=false \
            --set cgroup.hostRoot=/sys/fs/cgroup \
            --set k8sServiceHost=localhost \
            --set k8sServicePort=7445 \
            --set operator.replicas=1
    fi

    # Install Local Path Provisioner
    if ! [ -z "$LOCAL_PATH_PROVISIONER_VERSION" ]; then
        log_info "Installing Local Path Provisioner..."

        rm -rf local-path-provisioner
        git clone https://github.com/rancher/local-path-provisioner -b "${LOCAL_PATH_PROVISIONER_VERSION}"
        cat << EOF > local-path-provisioner/values.yaml
nodePathMap:
  - node: DEFAULT_PATH_FOR_NON_LISTED_NODES
    paths:
      - /var/mnt/local-path-provisioner

storageClass:
  defaultClass: true
  name: local-path
  reclaimPolicy: Delete
  volumeBindingMode: WaitForFirstConsumer

helperPod:
  image: busybox:latest

namespace: local-path-provisioner
EOF

        helm upgrade --install local-path-storage \
          --create-namespace --namespace local-path-provisioner \
	  --wait --wait-for-jobs \
          ./local-path-provisioner/deploy/chart/local-path-provisioner \
          -f local-path-provisioner/values.yaml

        rm -rf local-path-provisioner
    fi

    # Deploy metallb for LoadBalancer Support
    if ! [ -z "$METALLB_VERSION" ]; then
        log_info "Installing MetalLB LoadBalancer Controller"

        helm repo add metallb https://metallb.github.io/metallb
        helm repo update

        helm upgrade --install \
          --version $METALLB_VERSION \
          --create-namespace --namespace metallb \
	  --wait --wait-for-jobs \
          --set speaker.ignoreExcludeLB=true \
          metallb metallb/metallb
    fi

    # Wait for all pods to be ready
    wait_for_pods

    # Customisation which needs to be run after CRDs are deployed
    if ! [ -z "$METALLB_DEFAULT_IP_POOL" ]; then
        cat << EOF > /tmp/metallb_L2Advertisement$$
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-ip
  namespace: metallb
spec:
  ipAddressPools:
  - default-ip-pool
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-ip-pool
  namespace: metallb
spec:
  addresses:
  - $METALLB_DEFAULT_IP_POOL
EOF

        kubectl apply -f /tmp/metallb_L2Advertisement$$
        rm -f /tmp/metallb_L2Advertisement$$
    fi

    # Run tests to check nginx deployed successfully
    run_tests

    log_info "Kubeconfig: $KUBECONFIG"
    log_info "Talosconfig: $TALOSCONFIG"
    log_info ""
    log_info "You can now use kubectl with: export KUBECONFIG=$KUBECONFIG"
}

# Run main function
main "$@"
