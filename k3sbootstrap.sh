#!/usr/bin/env bash

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
# Does NOT install:
#   - Azure DevOps Agent
#   - Monitoring
#   - Applications
#   - Terminal customization (reserved at the bottom)
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

    read -rp "Server IP address [$DETECTED_IP]: " SERVER_IP
    SERVER_IP="${SERVER_IP:-$DETECTED_IP}"

else

    echo "The server IP address could not be detected automatically."

    while [[ -z "${SERVER_IP:-}" ]]; do
        read -rp "Server IP address: " SERVER_IP
    done

fi


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

read -rp "Rancher hostname [$DEFAULT_RANCHER_HOST]: " RANCHER_HOST
RANCHER_HOST="${RANCHER_HOST:-$DEFAULT_RANCHER_HOST}"


# ------------------------------------------------------------------------------
# Rancher bootstrap password
# ------------------------------------------------------------------------------

echo
echo "Choose the initial Rancher administrator password."
echo "Your typing will be hidden."
echo

RANCHER_PASSWORD=""

while [[ -z "$RANCHER_PASSWORD" ]]; do

    read -rsp "Rancher bootstrap password: " RANCHER_PASSWORD
    echo

done


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
echo "The Rancher password is intentionally not displayed."
echo
echo "Nothing has been changed yet."
echo
echo "======================================================================"
echo

read -rp "Start installation? [y/N]: " CONFIRM

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
# 1/9 - UPDATE UBUNTU
# ==============================================================================

echo
echo "======================================================================"
echo "[1/9] Updating Ubuntu"
echo "======================================================================"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get full-upgrade -y
apt-get autoremove -y

echo
echo "[OK] Ubuntu updated."


# ==============================================================================
# 2/9 - BASIC UTILITIES
# ==============================================================================

echo
echo "======================================================================"
echo "[2/9] Installing basic utilities"
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
# 3/9 - QEMU GUEST AGENT
# ==============================================================================

echo
echo "======================================================================"
echo "[3/9] Installing QEMU Guest Agent"
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
# 4/9 - PREPARE UBUNTU FOR K3S
# ==============================================================================

echo
echo "======================================================================"
echo "[4/9] Preparing Ubuntu for K3s"
echo "======================================================================"


# ------------------------------------------------------------------------------
# Disable swap
# ------------------------------------------------------------------------------

echo
echo "Disabling swap..."

swapoff -a

if [[ ! -f /etc/fstab.pre-k3s ]]; then
    cp /etc/fstab /etc/fstab.pre-k3s
fi

sed -ri \
    '/^[^#].*[[:space:]]swap[[:space:]]/ s/^/# disabled-by-k3s-bootstrap: /' \
    /etc/fstab


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
# 5/9 - INSTALL K3S
# ==============================================================================

echo
echo "======================================================================"
echo "[5/9] Installing K3s"
echo "======================================================================"

echo
echo "Installing the current stable K3s release..."

curl -sfL https://get.k3s.io | sh -

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

until [[ "$(k3s kubectl get nodes --no-headers 2>/dev/null | wc -l)" -gt 0 ]]; do

    sleep 2

done

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
# 6/9 - CONFIGURE KUBECTL
# ==============================================================================

echo
echo "======================================================================"
echo "[6/9] Configuring Kubernetes access"
echo "======================================================================"

if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then

    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"

    mkdir -p "$USER_HOME/.kube"

    cp /etc/rancher/k3s/k3s.yaml \
        "$USER_HOME/.kube/config"

    chown -R "$SUDO_USER:$SUDO_USER" \
        "$USER_HOME/.kube"

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
# 7/9 - INSTALL HELM
# ==============================================================================

echo
echo "======================================================================"
echo "[7/9] Installing Helm"
echo "======================================================================"

HELM_INSTALLER="$(mktemp)"

curl -fsSL \
    https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    -o "$HELM_INSTALLER"

chmod 700 "$HELM_INSTALLER"

"$HELM_INSTALLER"

rm -f "$HELM_INSTALLER"

echo
echo "[OK] Helm installed."

helm version --short


# ==============================================================================
# 8/9 - INSTALL CERT-MANAGER
# ==============================================================================

echo
echo "======================================================================"
echo "[8/9] Installing cert-manager"
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
# 9/9 - INSTALL RANCHER
# ==============================================================================

echo
echo "======================================================================"
echo "[9/9] Installing Rancher"
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

helm upgrade --install rancher \
    rancher-stable/rancher \
    --namespace cattle-system \
    --create-namespace \
    --set hostname="$RANCHER_HOST" \
    --set replicas=1 \
    --set bootstrapPassword="$RANCHER_PASSWORD" \
    --wait \
    --timeout 10m

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
echo "Kubernetes node:"
echo "----------------------------------------------------------------------"

kubectl get nodes -o wide


echo
echo "cert-manager:"
echo "----------------------------------------------------------------------"

kubectl get pods \
    --namespace cert-manager


echo
echo "Rancher:"
echo "----------------------------------------------------------------------"

kubectl get pods \
    --namespace cattle-system


echo
echo "Rancher ingress:"
echo "----------------------------------------------------------------------"

kubectl get ingress \
    --namespace cattle-system


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
