# Talos Kubernetes Deployment Script

> Test, deploy, iterate your Talos configurations easily

Automated deployment script for Talos Linux on any VMs with Kubernetes and Cilium CNI.

---

## 📋 Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Deployment Process](#deployment-process)
- [Output Files](#output-files)
- [Usage After Deployment](#usage-after-deployment)
- [Troubleshooting](#troubleshooting)
- [Advanced Usage](#advanced-usage)
- [Security Notes](#security-notes)

---

## Prerequisites

### Required Tools

Ensure the following tools are installed on your system:

| Tool | Description | Installation Guide |
|------|-------------|-------------------|
| `talosctl` | Talos CLI tool | [Install](https://www.talos.dev/latest/introduction/getting-started/) |
| `kubectl` | Kubernetes CLI | [Install](https://kubernetes.io/docs/tasks/tools/) |
| `helm` | Kubernetes package manager | [Install](https://helm.sh/docs/intro/install/) |
| `envsubst` | Environment variable substitution | Part of `gettext` package |
| `yq` | YAML processor | [Install](https://github.com/mikefarah/yq) |

### Required Files

The following files must exist in the deployment directory:

```
.
├── deploy.sh                    # The deployment script
├── patch.yaml                   # Base Talos configuration patches
└── patch_controlplane.yaml      # Control plane specific patches
```

### Required Information

- ✅ IP address of the VM where Talos will be deployed, on my tests I used Bare-Metal Machine iso(metal-amd.iso) from https://factory.talos.dev 
- ✅ Harbor container registry credentials (username and password), If you dont have harbor or any proxy cache enabled repository you need to clean up it's definitions from patches.
- ✅ Network CIDR for your local network where sandbox VM will run.

---

## 🚀 Quick Start

### 1. Make the script executable

```bash
chmod +x deploy.sh
```

### 2. Set required environment variables

```bash
export MASTER_IP=192.168.105.128
export HARBOR_CONTAINERD_USERNAME=your-username-here
export HARBOR_CONTAINERD_PASSWORD=your-password-here
```

### 3. Run the deployment

```bash
./deploy.sh
```

That's it! The script will automatically handle the entire deployment process.

---

## ⚙️ Configuration

### Environment Variables

All configuration is done through environment variables. Here are the available options:

| Variable | Default | Required | Description |
|----------|---------|----------|-------------|
| `MASTER_IP` | `192.168.105.128` | **Yes** | IP address of the Talos control plane node |
| `KUBERNETES_VERSION` | `1.32.7` | **Yes** | Kubernetes version to deploy |
| `HARBOR_REGISTRY_URL` | - | **Yes** | Harbor registry address |
| `HARBOR_CONTAINERD_USERNAME` | - | **Yes** | Harbor registry username |
| `HARBOR_CONTAINERD_PASSWORD` | - | **Yes** | Harbor registry password |
| `TALOS_INSTALL_IMAGE` | `factory.talos.dev/installer/...` | **Yes** | Talos installer image |
| `LOCAL_CIDR` | `192.168.104.0/21` | **Yes** | Local network CIDR |
| `CILIUM_VERSION` | `1.18.3` | **Yes** | Cilium CNI version |
| `TALOS_VERSION` | `0.4.6` | **Yes** | Talos Cloud Controller Manager version |

### Configuration Examples

#### Example 1: Using a Configuration File

Create a file named `config.env`:

```bash
# Configuration
export MASTER_IP='192.168.0.18'
export KUBERNETES_VERSION='1.32.7'
export HARBOR_REGISTRY_URL='harbor.x.com'
export HARBOR_CONTAINERD_USERNAME='username'
export HARBOR_CONTAINERD_PASSWORD='password'
export TALOS_INSTALL_IMAGE='factory.talos.dev/installer/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515:v1.9.6'
export LOCAL_CIDR='192.168.0.0/24'
export KUBECONFIG=$PWD/kubeconfig
export TALOSCONFIG=$PWD/talosconfig

# Helm Configuration
export CILIUM_VERSION='1.18.3'
export TALOS_CCM_VERSION='0.4.6'
```

Then source it before running:

```bash
source config.env
./deploy.sh
```

---

## 🔄 Deployment Process

The script performs the following steps automatically:

1. **✓ Dependency Check** - Verifies all required tools are installed
2. **✓ IP Validation** - Ensures the provided IP address is valid
3. **✓ Secret Generation** - Creates Talos secrets for cluster authentication
4. **✓ Configuration Processing** - Processes patch files with environment variables
5. **✓ Talos Config Generation** - Generates Talos machine configurations
6. **✓ Config Application** - Applies configuration to the target node
7. **✓ Cluster Bootstrap** - Bootstraps the Talos Kubernetes cluster
8. **✓ Kubeconfig Generation** - Creates kubectl configuration file
9. **✓ Talos Cloud Controller Manager** - Installs Talos CCM
10. **✓ Cilium Installation** - Installs and configures Cilium CNI
11. **✓ Health Check** - Waits for all pods to become ready

---

## 📦 Output Files

After successful deployment, the following files will be created in the deployment directory:

| File | Description |
|------|-------------|
| `secrets.yaml` | Talos cluster secrets |
| `talosconfig` | Talos CLI configuration |
| `kubeconfig` | Kubernetes CLI configuration |
| `controlplane.yaml` | Generated control plane configuration |
| `worker.yaml` | Generated worker configuration (if applicable) |

---

## 💻 Usage After Deployment

### Using kubectl

```bash
# Export kubeconfig
export KUBECONFIG=/path/to/deployment/kubeconfig

# Check cluster status
kubectl get nodes
kubectl get pods -A

# Deploy applications
kubectl apply -f your-app.yaml
```

### Using talosctl

```bash
# Export talosconfig
export TALOSCONFIG=/path/to/deployment/talosconfig

# View cluster dashboard
talosctl -n <MASTER_IP> dashboard

# Check logs
talosctl -n <MASTER_IP> logs

# Get system information
talosctl -n <MASTER_IP> version
talosctl -n <MASTER_IP> health
talosctl -n <MASTER_IP> processes
```

---

## 🔧 Troubleshooting

### Node Not Reachable

If the script fails waiting for the node to become reachable:

**Possible Causes:**
- VM is not running
- Incorrect IP address
- Network connectivity issues
- Talos not booted properly
- Harbor setup problems

**Solutions:**

```bash
# Test connectivity
ping <MASTER_IP>

# Check if Talos is responding
talosctl --nodes <MASTER_IP> version --insecure

# Check Proxmox console for boot issues
```

### Kubernetes API Not Ready

If Kubernetes API doesn't become ready:

**Check Talos logs:**
```bash
talosctl -n <MASTER_IP> logs controller-runtime
```

**Verify bootstrap was successful:**
```bash
talosctl -n <MASTER_IP> service kubelet status
```

### Pods Not Starting

If pods fail to start after deployment:

**Check pod status:**
```bash
kubectl get pods -A
kubectl describe pod <pod-name> -n <namespace>
```

**Check Cilium status:**
```bash
cilium status
kubectl -n kube-system logs -l app.kubernetes.io/name=cilium
```

### Harbor Authentication Issues

If you see image pull errors:

- ✅ Verify credentials are correct
- ✅ Check Harbor registry is accessible from the cluster
- ✅ Verify the robot account has pull permissions

---

## 🎯 Advanced Usage

### Adding Worker Nodes

After the control plane is deployed, you can add worker nodes:

**1. Generate worker configuration:**
```bash
talosctl gen config talos1 https://<MASTER_IP>:6443 \
  --with-secrets secrets.yaml \
  --output-dir . \
  --config-patch @/tmp/patch_out.yaml
```

**2. Apply to worker node:**
```bash
talosctl apply-config --insecure \
  --nodes <WORKER_IP> \
  --file worker.yaml
```

### Customizing Patches

Edit `patch.yaml` or `patch_controlplane.yaml` to customize:

- 🔧 Network configuration
- 🔧 Kubelet settings
- 🔧 Container runtime options
- 🔧 System extensions

After editing, re-run the deployment script.

### Upgrading Kubernetes

To upgrade Kubernetes version:

```bash
export KUBERNETES_VERSION=1.33.0
talosctl -n <MASTER_IP> upgrade-k8s --to $KUBERNETES_VERSION
```

### Re-deploying / Iterating

The script is idempotent and can be run multiple times. To iterate on your configuration:

1. Modify your patch files
2. Update environment variables if needed
3. Re-run `./deploy.sh`

The `--force` flags ensure configurations are regenerated and reapplied.

---

## 📚 Resources

For issues and documentation related to:

- **Talos Linux**: [Documentation](https://www.talos.dev/latest/)
- **Kubernetes**: [Documentation](https://kubernetes.io/docs/)
- **Cilium**: [Documentation](https://docs.cilium.io/)
- **Helm**: [Documentation](https://helm.sh/docs/)

---

## 📝 License

GPLv3 License

---

<div align="center">
Made with ❤️ for easy Talos deployments
</div>
