#!/usr/bin/env bash

# Orchestrator metadata (lower values run first).
PRIORITY=10
SCRIPT_NAME="K3s and Rancher"

set -Eeuo pipefail

# ==============================================================================
# FIRST K3S / RANCHER SERVER BOOTSTRAP
#
# Installs:
#   - Ubuntu updates
#   - Basic utilities
#   - QEMU Guest Agent
#   - Kubernetes/K3s prerequisites
#   - K3s (stable)
#   - Helm
#   - cert-manager
#   - Rancher
#
# ==============================================================================


# ==============================================================================
# ROOT CHECK
# ==============================================================================

if [[ $EUID -ne 0 ]]; then
    echo
    echo "Please run this script with sudo:"
    echo
    echo "  sudo ./bootstrap.sh"
    echo
    exit 1
fi


# ==============================================================================
# COLLECT REQUIRED INFORMATION
# ==============================================================================

if [[ "${ORCHESTRATOR_MODE:-0}" != "1" ]]; then
clear

echo "======================================================================"
echo "                  K3s / Rancher Bootstrap"
echo "======================================================================"
echo
echo "This script will prepare this Ubuntu VM as your first K3s server."
echo
echo "It will install:"
echo
echo "  - Ubuntu updates"
echo "  - Basic command-line utilities"
echo "  - QEMU Guest Agent for Proxmox"
echo "  - K3s"
echo "  - Helm"
echo "  - cert-manager"
echo "  - Rancher"
echo
echo "After this completes, the server will be ready for the"
echo "Azure DevOps phase."
echo
echo "----------------------------------------------------------------------"
echo
fi


# ------------------------------------------------------------------------------
# Detect server IP
# ------------------------------------------------------------------------------

DETECTED_IP="$(
    hostname -I 2>/dev/null |
    tr ' ' '\n' |
    grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' |
    grep -v '^127\.' |
    head -n1 || true
)"

if [[ -n "$DETECTED_IP" ]]; then

    if [[ -z "${SERVER_IP:-}" ]]; then
        read -rp "Server IP address [$DETECTED_IP]: " SERVER_IP
    fi
    SERVER_IP="${SERVER_IP:-$DETECTED_IP}"

else

    echo "The server IP address could not be detected automatically."

    while [[ -z "${SERVER_IP:-}" ]]; do
        read -rp "Server IP address: " SERVER_IP
    done

fi

if ! [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo
    echo "[ERROR] Server IP address is not a valid IPv4 address: $SERVER_IP"
    exit 1
fi

IFS=. read -r -a SERVER_IP_OCTETS <<<"$SERVER_IP"
for OCTET in "${SERVER_IP_OCTETS[@]}"; do
    if (( 10#$OCTET > 255 )); then
        echo
        echo "[ERROR] Server IP address is not a valid IPv4 address: $SERVER_IP"
        exit 1
    fi
done


# ------------------------------------------------------------------------------
# Rancher hostname
# ------------------------------------------------------------------------------

DEFAULT_RANCHER_HOST="${SERVER_IP}.sslip.io"

echo
echo "Rancher needs a hostname for its web interface."
echo
echo "For this initial setup, the following address can be used:"
echo
echo "  $DEFAULT_RANCHER_HOST"
echo
echo "This does NOT change the Ubuntu hostname."
echo "Your permanent DNS name can be configured later."
echo

if [[ -z "${RANCHER_HOST:-}" ]]; then
    read -rp "Rancher hostname [$DEFAULT_RANCHER_HOST]: " RANCHER_HOST
fi
RANCHER_HOST="${RANCHER_HOST:-$DEFAULT_RANCHER_HOST}"

if [[ ${#RANCHER_HOST} -gt 253 || ! "$RANCHER_HOST" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*$ ]]; then
    echo
    echo "[ERROR] Rancher hostname is not a valid DNS hostname: $RANCHER_HOST"
    exit 1
fi


# ------------------------------------------------------------------------------
# Installation summary
# ------------------------------------------------------------------------------

echo
echo "======================================================================"
echo "                       INSTALLATION PLAN"
echo "======================================================================"
echo
echo "Server:"
echo "  Hostname        $(hostname)"
echo "  IP address      $SERVER_IP"
echo
echo "K3s:"
echo "  Release         Stable channel"
echo
echo "Rancher:"
echo "  Address         https://$RANCHER_HOST"
echo
echo "For a new Rancher installation, the bootstrap password will be requested later."
echo
echo "Nothing has been changed yet."
echo
echo "======================================================================"
echo

if [[ "${ORCHESTRATOR_MODE:-0}" == "1" ]]; then
    CONFIRM=yes
else
    read -rp "Start installation? [y/N]: " CONFIRM
fi

case "${CONFIRM,,}" in

    y|yes)
        ;;

    *)
        echo
        echo "Installation cancelled."
        exit 0
        ;;

esac


# ==============================================================================
# INSTALLATION STARTS HERE
# ==============================================================================


# ==============================================================================
# 1/10 - UPDATE UBUNTU
# ==============================================================================

echo
echo "======================================================================"
echo "[1/10] Updating Ubuntu"
echo "======================================================================"

export DEBIAN_FRONTEND=noninteractive

OS_UPGRADE_MARKER="/var/lib/k3s-rancher-bootstrap-os-upgrade-complete"

if [[ -f "$OS_UPGRADE_MARKER" ]]; then
    echo
    echo "[INFO] Initial Ubuntu upgrade already completed by this bootstrap; skipping full-upgrade and autoremove."
else
    apt-get update
    apt-get full-upgrade -y
    apt-get autoremove -y
    touch "$OS_UPGRADE_MARKER"

    echo
    echo "[OK] Ubuntu updated."
fi


# ==============================================================================
# 2/10 - BASIC UTILITIES
# ==============================================================================

echo
echo "======================================================================"
echo "[2/10] Installing basic utilities"
echo "======================================================================"

apt-get install -y \
    ca-certificates \
    curl \
    git \
    gnupg \
    jq \
    openssl \
    tar \
    unzip

echo
echo "[OK] Basic utilities installed."


# ==============================================================================
# 3/10 - QEMU GUEST AGENT
# ==============================================================================

echo
echo "======================================================================"
echo "[3/10] Installing QEMU Guest Agent"
echo "======================================================================"

apt-get install -y qemu-guest-agent

systemctl enable qemu-guest-agent

# Depending on the Proxmox VM state, the guest-agent device may only become
# available after a reboot. Installation should not fail because of that.

if systemctl start qemu-guest-agent; then

    echo
    echo "[OK] QEMU Guest Agent is running."

else

    echo
    echo "[WARNING] QEMU Guest Agent is installed and enabled."
    echo "It may require a reboot before becoming active."

fi


# ==============================================================================
# 4/10 - CONFIGURE VIRTIOFS DATA MOUNT
# ==============================================================================

echo
echo "======================================================================"
echo "[4/10] Configuring VirtioFS data mount"
echo "======================================================================"

VIRTIOFS_TAG="data"
VIRTIOFS_MOUNT="/mnt/data"
VIRTIOFS_FSTAB_ENTRY="data /mnt/data virtiofs defaults,nofail 0 0"

mkdir -p "$VIRTIOFS_MOUNT"

# Preserve the original fstab before this bootstrap changes it.
if [[ ! -f /etc/fstab.pre-k3s ]]; then
    cp /etc/fstab /etc/fstab.pre-k3s
fi

# The guest kernel must support VirtioFS. Try loading the module first.
if ! grep -qw virtiofs /proc/filesystems; then
    modprobe virtiofs 2>/dev/null || true
fi

if ! grep -qw virtiofs /proc/filesystems; then
    echo
    echo "[ERROR] This Ubuntu kernel does not currently expose VirtioFS support."
    echo "Kernel: $(uname -r)"
    echo "Check the guest kernel/modules before continuing."
    exit 1
fi

# Refuse to interfere with an unexpected existing mount.
if findmnt -rn -M "$VIRTIOFS_MOUNT" >/dev/null; then
    MOUNT_TYPE="$(findmnt -rn -M "$VIRTIOFS_MOUNT" -o FSTYPE)"
    MOUNT_SOURCE="$(findmnt -rn -M "$VIRTIOFS_MOUNT" -o SOURCE)"

    if [[ "$MOUNT_TYPE" != "virtiofs" || "$MOUNT_SOURCE" != "$VIRTIOFS_TAG" ]]; then
        echo
        echo "[ERROR] $VIRTIOFS_MOUNT is already mounted from '$MOUNT_SOURCE' as '$MOUNT_TYPE'."
        echo "Expected VirtioFS source '$VIRTIOFS_TAG'. No changes were made to that mount."
        exit 1
    fi
else
    # Test the Proxmox VirtioFS device BEFORE writing a persistent fstab entry.
    # If the Proxmox mapping/device is missing, fail with diagnostics and leave
    # /etc/fstab unchanged.
    if ! mount -t virtiofs "$VIRTIOFS_TAG" "$VIRTIOFS_MOUNT"; then
        echo
        echo "[ERROR] Unable to mount VirtioFS tag '$VIRTIOFS_TAG' at $VIRTIOFS_MOUNT."
        echo "The mount command is valid, but the guest could not use the VirtioFS share."
        echo
        echo "Verify on the Proxmox host that this VM has a VirtioFS device using tag: $VIRTIOFS_TAG"
        echo "Then fully stop/start the VM if the VirtioFS device was added while it was running."
        echo
        echo "Guest diagnostics:"
        echo "  Kernel: $(uname -r)"
        echo "  VirtioFS support: $(grep -qw virtiofs /proc/filesystems && echo yes || echo no)"
        echo "  Recent kernel messages:"
        dmesg 2>/dev/null | tail -n 20 || true
        exit 1
    fi
fi

# Validate the live mount before making it persistent.
MOUNT_TYPE="$(findmnt -rn -M "$VIRTIOFS_MOUNT" -o FSTYPE)"
MOUNT_SOURCE="$(findmnt -rn -M "$VIRTIOFS_MOUNT" -o SOURCE)"
if [[ "$MOUNT_TYPE" != "virtiofs" || "$MOUNT_SOURCE" != "$VIRTIOFS_TAG" ]]; then
    echo
    echo "[ERROR] $VIRTIOFS_MOUNT is not mounted from VirtioFS source '$VIRTIOFS_TAG'."
    exit 1
fi

# Only now make the working mount persistent. Reject competing entries.
FSTAB_CORRECT_COUNT="$(awk '
    /^[[:space:]]*#/ || NF == 0 { next }
    $2 == "/mnt/data" && $1 == "data" && $3 == "virtiofs" && $4 == "defaults,nofail" && $5 == "0" && $6 == "0" { count++ }
    END { print count + 0 }
' /etc/fstab)"
FSTAB_TARGET_COUNT="$(awk '
    /^[[:space:]]*#/ || NF == 0 { next }
    $2 == "/mnt/data" { count++ }
    END { print count + 0 }
' /etc/fstab)"

if (( FSTAB_CORRECT_COUNT > 1 )); then
    echo
    echo "[ERROR] Multiple active VirtioFS entries for /mnt/data exist in /etc/fstab."
    exit 1
elif (( FSTAB_TARGET_COUNT > FSTAB_CORRECT_COUNT )); then
    echo
    echo "[ERROR] A conflicting active /mnt/data entry exists in /etc/fstab."
    echo "Resolve it manually; the bootstrap did not rewrite /etc/fstab."
    exit 1
elif (( FSTAB_CORRECT_COUNT == 0 )); then
    printf '%s\n' "$VIRTIOFS_FSTAB_ENTRY" >>/etc/fstab
    systemctl daemon-reload
fi

echo
echo "[OK] VirtioFS data share mounted at $VIRTIOFS_MOUNT."


# ==============================================================================
# 5/10 - PREPARE UBUNTU FOR K3S
# ==============================================================================

echo
echo "======================================================================"
echo "[5/10] Preparing Ubuntu for K3s"
echo "======================================================================"


# ------------------------------------------------------------------------------
# Disable swap
# ------------------------------------------------------------------------------

echo
echo "Disabling swap..."

swapoff -a

sed -ri \
    '/^[^#].*[[:space:]]swap[[:space:]]/ s/^/# disabled-by-k3s-bootstrap: /' \
    /etc/fstab

systemctl daemon-reload


# ------------------------------------------------------------------------------
# Kernel modules
# ------------------------------------------------------------------------------

echo "Loading required kernel modules..."

cat >/etc/modules-load.d/k3s.conf <<'EOF'
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter


# ------------------------------------------------------------------------------
# Kubernetes networking
# ------------------------------------------------------------------------------

echo "Configuring Kubernetes networking..."

cat >/etc/sysctl.d/99-k3s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF

sysctl --system >/dev/null

echo
echo "[OK] Ubuntu prepared for K3s."


# ==============================================================================
# 6/10 - INSTALL K3S
# ==============================================================================

echo
echo "======================================================================"
echo "[6/10] Installing K3s"
echo "======================================================================"

if command -v k3s >/dev/null 2>&1 || systemctl list-unit-files k3s.service --no-legend 2>/dev/null | grep -q '^k3s\.service'; then
    if ! command -v k3s >/dev/null 2>&1 || ! systemctl list-unit-files k3s.service --no-legend 2>/dev/null | grep -q '^k3s\.service'; then
        echo
        echo "[ERROR] An incomplete existing K3s installation was detected."
        echo "The bootstrap will not reinstall or reset it automatically."
        exit 1
    fi

    echo
    echo "Existing K3s installation detected; reusing it."
else
    echo
    echo "Installing the current stable K3s release..."
    curl -sfL https://get.k3s.io | sh -
fi

systemctl enable --now k3s

if ! timeout 300 bash -c 'until k3s kubectl get --raw=/readyz >/dev/null 2>&1; do sleep 2; done'; then
    echo
    echo "[ERROR] The K3s Kubernetes API did not become ready within 300 seconds."
    exit 1
fi

echo
echo "K3s has been installed."
echo
echo "Waiting for the Kubernetes node to register..."


# ------------------------------------------------------------------------------
# IMPORTANT:
#
# The Kubernetes API can become available slightly before the node itself
# appears in Kubernetes.
#
# We therefore wait until at least one node actually exists before asking
# Kubernetes to wait for the Ready condition.
# ------------------------------------------------------------------------------

if ! timeout 300 bash -c 'until k3s kubectl get nodes -o name 2>/dev/null | grep -q .; do sleep 2; done'; then
    echo
    echo "[ERROR] No Kubernetes node registered within 300 seconds."
    exit 1
fi

echo
echo "Node registered."
echo "Waiting for the node to become Ready..."

k3s kubectl wait \
    --for=condition=Ready \
    nodes \
    --all \
    --timeout=300s

echo
echo "[OK] K3s is running and the node is Ready."

echo
k3s kubectl get nodes -o wide


# ==============================================================================
# 7/10 - CONFIGURE KUBECTL
# ==============================================================================

echo
echo "======================================================================"
echo "[7/10] Configuring Kubernetes access"
echo "======================================================================"

if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then

    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"

    if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
        echo
        echo "[ERROR] Unable to determine a valid home directory for: $SUDO_USER"
        exit 1
    fi

    mkdir -p "$USER_HOME/.kube"

    cp /etc/rancher/k3s/k3s.yaml \
        "$USER_HOME/.kube/config"

    chown "$SUDO_USER:$SUDO_USER" \
        "$USER_HOME/.kube" \
        "$USER_HOME/.kube/config"

    chmod 600 \
        "$USER_HOME/.kube/config"

    echo
    echo "[OK] kubectl access configured for user: $SUDO_USER"

else

    echo
    echo "[INFO] Script is running directly as root."
    echo "User-specific kubectl configuration skipped."

fi


# Use the K3s administrator kubeconfig for the remainder of this script.

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml


# ==============================================================================
# 8/10 - INSTALL HELM
# ==============================================================================

echo
echo "======================================================================"
echo "[8/10] Installing Helm"
echo "======================================================================"

if command -v helm >/dev/null 2>&1; then
    if ! helm version --short >/dev/null 2>&1; then
        echo
        echo "[ERROR] Helm exists but is not operational."
        exit 1
    fi
    echo "Existing Helm installation detected; reusing it."
else
    HELM_INSTALLER="$(mktemp)"
    trap 'rm -f "${HELM_INSTALLER:-}"' EXIT

    curl -fsSL \
        https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
        -o "$HELM_INSTALLER"

    chmod 700 "$HELM_INSTALLER"
    "$HELM_INSTALLER"
    rm -f "$HELM_INSTALLER"
    trap - EXIT
fi

echo
echo "[OK] Helm installed."

helm version --short


# ==============================================================================
# 9/10 - INSTALL CERT-MANAGER
# ==============================================================================

echo
echo "======================================================================"
echo "[9/10] Installing cert-manager"
echo "======================================================================"

helm repo add jetstack \
    https://charts.jetstack.io \
    --force-update

helm repo update


# ------------------------------------------------------------------------------
# Discover the current cert-manager chart version.
#
# No cert-manager version is hardcoded into this bootstrap.
# ------------------------------------------------------------------------------

CERT_MANAGER_VERSION="$(
    helm search repo jetstack/cert-manager \
        --versions \
        -o json |
    jq -r '.[0].version'
)"

if [[ -z "$CERT_MANAGER_VERSION" || "$CERT_MANAGER_VERSION" == "null" ]]; then

    echo
    echo "[ERROR] Unable to determine the current cert-manager version."
    exit 1

fi

echo
echo "Current cert-manager chart:"
echo "  $CERT_MANAGER_VERSION"

echo
echo "Installing cert-manager..."

helm upgrade --install cert-manager \
    jetstack/cert-manager \
    --version "$CERT_MANAGER_VERSION" \
    --namespace cert-manager \
    --create-namespace \
    --set crds.enabled=true \
    --wait \
    --timeout 5m

echo
echo "[OK] cert-manager is running."

echo
kubectl get pods \
    --namespace cert-manager


# ==============================================================================
# 10/10 - INSTALL RANCHER
# ==============================================================================

echo
echo "======================================================================"
echo "[10/10] Installing Rancher"
echo "======================================================================"

helm repo add rancher-stable \
    https://releases.rancher.com/server-charts/stable \
    --force-update

helm repo update

echo
echo "Installing Rancher..."
echo
echo "Hostname:"
echo "  $RANCHER_HOST"
echo

RANCHER_HELM_ARGS=(
    upgrade --install rancher
    rancher-stable/rancher
    --namespace cattle-system
    --create-namespace
    --set-string "hostname=$RANCHER_HOST"
    --set replicas=1
    --wait
    --timeout 10m
)

# bootstrapPassword applies only to the initial Rancher installation. Omitting
# it on an upgrade avoids implying that it can reset an existing admin password.
RANCHER_RELEASE_EXISTS="$(
    helm list --all --namespace cattle-system -o json 2>/dev/null |
        jq -r 'any(.[]; .name == "rancher")'
)"
if [[ "$RANCHER_RELEASE_EXISTS" != "true" ]]; then
    echo "Choose the initial Rancher administrator password."
    echo "Your typing will be hidden."
    echo

    RANCHER_PASSWORD="${RANCHER_PASSWORD:-}"
    while [[ -z "$RANCHER_PASSWORD" ]]; do
        read -rsp "Rancher bootstrap password: " RANCHER_PASSWORD
        echo
    done

    RANCHER_HELM_ARGS+=(--set-string "bootstrapPassword=$RANCHER_PASSWORD")
fi

helm "${RANCHER_HELM_ARGS[@]}"

echo
echo "Waiting for Rancher to become ready..."

kubectl rollout status \
    deployment/rancher \
    --namespace cattle-system \
    --timeout=10m

echo
echo "[OK] Rancher is running."


# ==============================================================================
# TERMINAL / UBUNTU CUSTOMIZATION
# ==============================================================================
#
# TODO
# ----
#
# Terminal customization will be added here later.
#
# Possible future additions:
#
#   - Zsh
#   - Starship
#   - Oh My Zsh
#   - aliases
#   - .bashrc / .zshrc
#   - custom MOTD
#
# This section is intentionally kept separate from the infrastructure setup.
#
# ==============================================================================


# ==============================================================================
# FINAL VALIDATION
# ==============================================================================

echo
echo "======================================================================"
echo "                    FINAL VALIDATION"
echo "======================================================================"

echo
echo "VirtioFS data mount:"
echo "----------------------------------------------------------------------"

if [[ "$(findmnt -rn -M /mnt/data -o FSTYPE)" != "virtiofs" || \
      "$(findmnt -rn -M /mnt/data -o SOURCE)" != "data" ]]; then
    echo "[ERROR] /mnt/data is not mounted from VirtioFS source 'data'."
    exit 1
fi
echo "[OK] VirtioFS data share mounted at /mnt/data."

echo
echo "Kubernetes node:"
echo "----------------------------------------------------------------------"

if ! systemctl is-active --quiet k3s; then
    echo "[ERROR] K3s service is not active."
    exit 1
fi

if ! kubectl wait --for=condition=Ready nodes --all --timeout=30s; then
    echo "[ERROR] Kubernetes node Ready validation failed."
    exit 1
fi
kubectl get nodes -o wide


echo
echo "cert-manager:"
echo "----------------------------------------------------------------------"

kubectl rollout status deployment/cert-manager --namespace cert-manager --timeout=60s
kubectl rollout status deployment/cert-manager-cainjector --namespace cert-manager --timeout=60s
kubectl rollout status deployment/cert-manager-webhook --namespace cert-manager --timeout=60s
kubectl get pods \
    --namespace cert-manager


echo
echo "Rancher:"
echo "----------------------------------------------------------------------"

kubectl rollout status deployment/rancher --namespace cattle-system --timeout=60s
kubectl get pods \
    --namespace cattle-system


echo
echo "Rancher ingress:"
echo "----------------------------------------------------------------------"

if ! kubectl get ingress rancher --namespace cattle-system >/dev/null 2>&1; then
    echo "[ERROR] Rancher ingress does not exist."
    exit 1
fi
kubectl get ingress \
    --namespace cattle-system

if ! helm version --short >/dev/null 2>&1; then
    echo
    echo "[ERROR] Helm validation failed."
    exit 1
fi


# ==============================================================================
# COMPLETE
# ==============================================================================

echo
echo "======================================================================"
echo "                    INSTALLATION COMPLETE"
echo "======================================================================"
echo
echo "K3s:"
echo "  Status          Ready"
echo "  Release         $(k3s --version | head -n1)"
echo
echo "Server:"
echo "  Hostname        $(hostname)"
echo "  IP address      $SERVER_IP"
echo
echo "Rancher:"
echo "  https://$RANCHER_HOST"
echo
echo "Next phase:"
echo "  Azure DevOps"
echo
echo "======================================================================"
echo
echo "Bootstrap completed successfully."
echo
