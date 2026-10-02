#!/usr/bin/env bash

# Orchestrator metadata (lower values run first).
PRIORITY=20
SCRIPT_NAME="Azure DevOps agent"

set -Eeuo pipefail

# ==============================================================================
# AZURE DEVOPS SELF-HOSTED AGENT INSTALLER
#
# Purpose:
#   Install and register a Microsoft Azure DevOps self-hosted Linux agent.
#
# This script:
#   - Detects the current Linux user
#   - Asks for Azure DevOps information
#   - Downloads the appropriate/current agent directly from Azure DevOps
#   - Registers the agent unattended
#   - Installs it as a systemd service
#   - Starts the service
#   - Verifies that the service is running
#
# SECURITY:
#   No credentials are stored in this script.
#   The Azure DevOps PAT is requested at runtime and hidden while typing.
#
# Intended usage:
#
#   chmod +x ado-agent.sh
#   sudo ./ado-agent.sh
#
# ==============================================================================


# ==============================================================================
# ROOT CHECK
# ==============================================================================

if [[ $EUID -ne 0 ]]; then
    echo
    echo "Please run this script with sudo:"
    echo
    echo "  sudo ./ado-agent.sh"
    echo
    exit 1
fi


# ==============================================================================
# DETERMINE TARGET USER
# ==============================================================================

if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    TARGET_USER="$SUDO_USER"
else
    TARGET_USER="$(logname 2>/dev/null || true)"
fi

if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    echo
    echo "[ERROR] Unable to determine the normal Linux user."
    echo
    echo "Run this script from your normal account using:"
    echo
    echo "  sudo ./ado-agent.sh"
    echo
    exit 1
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
    echo
    echo "[ERROR] Unable to determine the home directory for $TARGET_USER."
    exit 1
fi


# ==============================================================================
# INTRODUCTION
# ==============================================================================

if [[ "${ORCHESTRATOR_MODE:-0}" != "1" ]]; then
clear

echo "======================================================================"
echo "             Azure DevOps Self-Hosted Agent Installer"
echo "======================================================================"
echo
echo "This script will connect this Linux server to an Azure DevOps"
echo "Agent Pool."
echo
echo "You will need:"
echo
echo "  - Your Azure DevOps organization URL"
echo "  - The name of your Agent Pool"
echo "  - A Personal Access Token (PAT)"
echo
echo "The PAT should have:"
echo
echo "  Agent Pools -> Read & manage"
echo
echo "The PAT will NOT be saved in this script."
echo
echo "----------------------------------------------------------------------"
echo
fi


# ==============================================================================
# AZURE DEVOPS ORGANIZATION URL
# ==============================================================================

while true; do

    if [[ -z "${ADO_URL:-}" ]]; then
        read -rp "Azure DevOps organization URL: " ADO_URL
    fi

    # Remove trailing slash if entered.

    ADO_URL="${ADO_URL%/}"

    if [[ "$ADO_URL" =~ ^https://dev\.azure\.com/[^/]+$ ]]; then
        break
    fi

    echo
    echo "Please enter the organization URL in this format:"
    echo
    echo "  https://dev.azure.com/your-organization"
    echo

done


# ==============================================================================
# AGENT POOL
# ==============================================================================

echo
echo "Enter the Azure DevOps Agent Pool this server should join."
echo
echo "Example:"
echo
echo "  Homelab"
echo

while [[ -z "${ADO_POOL:-}" ]]; do
    read -rp "Agent Pool name: " ADO_POOL
done


# ==============================================================================
# AGENT NAME
# ==============================================================================

DEFAULT_AGENT_NAME="$(hostname)"

echo
echo "Each machine in the pool needs an agent name."
echo
echo "The server hostname is usually a good choice."
echo

if [[ -z "${ADO_AGENT_NAME:-}" ]]; then
    read -rp "Agent name [$DEFAULT_AGENT_NAME]: " ADO_AGENT_NAME
fi

ADO_AGENT_NAME="${ADO_AGENT_NAME:-$DEFAULT_AGENT_NAME}"


# ==============================================================================
# PAT
# ==============================================================================

echo
echo "Enter the Azure DevOps Personal Access Token."
echo
echo "The token will be hidden while you type."
echo

ADO_PAT="${ADO_PAT:-}"

while [[ -z "$ADO_PAT" ]]; do

    read -rsp "Azure DevOps PAT: " ADO_PAT
    echo

done


# ==============================================================================
# INSTALLATION DIRECTORY
# ==============================================================================

DEFAULT_AGENT_DIR="$TARGET_HOME/ado-agent"

echo
echo "The Azure DevOps agent needs a directory on this server."
echo

if [[ -z "${ADO_AGENT_DIR:-}" ]]; then
    read -rp "Agent directory [$DEFAULT_AGENT_DIR]: " ADO_AGENT_DIR
fi

ADO_AGENT_DIR="${ADO_AGENT_DIR:-$DEFAULT_AGENT_DIR}"


# ==============================================================================
# SUMMARY
# ==============================================================================

echo
echo "======================================================================"
echo "                       INSTALLATION PLAN"
echo "======================================================================"
echo
echo "Linux:"
echo "  User             $TARGET_USER"
echo "  Hostname         $(hostname)"
echo
echo "Azure DevOps:"
echo "  Organization     $ADO_URL"
echo "  Agent Pool       $ADO_POOL"
echo "  Agent Name       $ADO_AGENT_NAME"
echo
echo "Installation:"
echo "  Directory        $ADO_AGENT_DIR"
echo "  Run as service   Yes"
echo "  Start on boot    Yes"
echo
echo "The PAT is intentionally NOT displayed."
echo
echo "Nothing has been changed yet."
echo
echo "======================================================================"
echo

if [[ "${ORCHESTRATOR_MODE:-0}" == "1" ]]; then
    CONFIRM=yes
else
    read -rp "Install Azure DevOps agent? [y/N]: " CONFIRM
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
# 1/7 - INSTALL REQUIRED PACKAGES
# ==============================================================================

echo
echo "======================================================================"
echo "[1/7] Installing required packages"
echo "======================================================================"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    jq \
    tar

echo
echo "[OK] Required packages installed."


# ==============================================================================
# 2/7 - DETERMINE SYSTEM ARCHITECTURE
# ==============================================================================

echo
echo "======================================================================"
echo "[2/7] Detecting system architecture"
echo "======================================================================"

ARCH="$(uname -m)"

case "$ARCH" in

    x86_64|amd64)
        ADO_PLATFORM="linux-x64"
        ;;

    aarch64|arm64)
        ADO_PLATFORM="linux-arm64"
        ;;

    *)
        echo
        echo "[ERROR] Unsupported architecture:"
        echo "  $ARCH"
        exit 1
        ;;

esac

echo
echo "Architecture:"
echo "  $ARCH"
echo
echo "Azure DevOps platform:"
echo "  $ADO_PLATFORM"

echo
echo "[OK] Architecture detected."


# ==============================================================================
# 3/7 - FIND CURRENT AZURE DEVOPS AGENT
# ==============================================================================

echo
echo "======================================================================"
echo "[3/7] Finding the current Azure DevOps agent"
echo "======================================================================"

# Azure DevOps provides an API that returns the appropriate agent package.
#
# This means NO agent version is hardcoded in this script.

AGENT_RESPONSE="$(
    curl -fsSL \
        -u "user:${ADO_PAT}" \
        -H "Accept: application/json" \
        "${ADO_URL}/_apis/distributedtask/packages/agent?platform=${ADO_PLATFORM}&top=1"
)"

AGENT_DOWNLOAD_URL="$(
    printf '%s' "$AGENT_RESPONSE" |
        jq -r '.value[0].downloadUrl'
)"

AGENT_VERSION="$(
    printf '%s' "$AGENT_RESPONSE" |
        jq -r '.value[0].version'
)"

if [[ -z "$AGENT_DOWNLOAD_URL" || "$AGENT_DOWNLOAD_URL" == "null" ]]; then

    echo
    echo "[ERROR] Azure DevOps did not return an agent package."
    echo
    echo "Check:"
    echo
    echo "  - Organization URL"
    echo "  - PAT"
    echo "  - PAT Agent Pools permissions"
    echo
    exit 1

fi

echo
echo "Azure DevOps selected agent:"
echo
echo "  Version: $AGENT_VERSION"
echo
echo "[OK] Agent package found."


# ==============================================================================
# 4/7 - DOWNLOAD AGENT
# ==============================================================================

echo
echo "======================================================================"
echo "[4/7] Downloading Azure DevOps agent"
echo "======================================================================"

if [[ -e "$ADO_AGENT_DIR" ]]; then

    if [[ -n "$(ls -A "$ADO_AGENT_DIR" 2>/dev/null)" ]]; then

        echo
        echo "[ERROR] Agent directory already exists and is not empty:"
        echo
        echo "  $ADO_AGENT_DIR"
        echo
        echo "The installer will not overwrite an existing agent."
        exit 1

    fi

else

    mkdir -p "$ADO_AGENT_DIR"

fi

chown "$TARGET_USER:$TARGET_USER" "$ADO_AGENT_DIR"

TEMP_AGENT_PACKAGE="$(mktemp --suffix=.tar.gz)"

echo
echo "Downloading agent $AGENT_VERSION..."

curl -fL \
    "$AGENT_DOWNLOAD_URL" \
    -o "$TEMP_AGENT_PACKAGE"

echo
echo "Extracting agent..."

tar -xzf "$TEMP_AGENT_PACKAGE" \
    -C "$ADO_AGENT_DIR"

rm -f "$TEMP_AGENT_PACKAGE"

chown -R "$TARGET_USER:$TARGET_USER" \
    "$ADO_AGENT_DIR"

echo
echo "[OK] Azure DevOps agent downloaded and extracted."


# ==============================================================================
# 5/7 - INSTALL AGENT DEPENDENCIES
# ==============================================================================

echo
echo "======================================================================"
echo "[5/7] Installing Azure DevOps agent dependencies"
echo "======================================================================"

cd "$ADO_AGENT_DIR"

if [[ -x "./bin/installdependencies.sh" ]]; then

    ./bin/installdependencies.sh

else

    echo
    echo "[INFO] No additional dependency installer was provided."
    echo "Continuing..."

fi

echo
echo "[OK] Agent dependencies ready."


# ==============================================================================
# 6/7 - REGISTER AGENT
# ==============================================================================

echo
echo "======================================================================"
echo "[6/7] Registering agent with Azure DevOps"
echo "======================================================================"

# Keep the token out of the config.sh command line.
#
# Azure DevOps supports configuration values through
# VSTS_AGENT_INPUT_* environment variables.

export VSTS_AGENT_INPUT_TOKEN="$ADO_PAT"

sudo -u "$TARGET_USER" \
    env \
        HOME="$TARGET_HOME" \
        VSTS_AGENT_INPUT_TOKEN="$ADO_PAT" \
    ./config.sh \
        --unattended \
        --url "$ADO_URL" \
        --auth pat \
        --pool "$ADO_POOL" \
        --agent "$ADO_AGENT_NAME" \
        --work "_work" \
        --replace \
        --acceptTeeEula

# Remove PAT from our environment as soon as registration is complete.

unset VSTS_AGENT_INPUT_TOKEN
unset ADO_PAT

echo
echo "[OK] Agent registered with Azure DevOps."


# ==============================================================================
# 7/7 - INSTALL AS SYSTEMD SERVICE
# ==============================================================================

echo
echo "======================================================================"
echo "[7/7] Installing Azure DevOps agent service"
echo "======================================================================"

cd "$ADO_AGENT_DIR"

./svc.sh install "$TARGET_USER"

./svc.sh start

echo
echo "Checking service status..."

sleep 3

SERVICE_NAME="$(
    systemctl list-unit-files \
        --type=service \
        --no-legend |
    awk '/vsts\.agent\..*\.service/ {print $1}' |
    head -n1
)"

if [[ -n "$SERVICE_NAME" ]]; then

    if systemctl is-active --quiet "$SERVICE_NAME"; then

        echo
        echo "[OK] Azure DevOps agent service is running."

    else

        echo
        echo "[ERROR] Azure DevOps agent service is not running."
        echo
        echo "Check:"
        echo
        echo "  sudo systemctl status $SERVICE_NAME"
        exit 1

    fi

else

    echo
    echo "[WARNING] The agent was installed, but the service name"
    echo "could not be detected automatically."
    echo
    echo "Check the service manually with:"
    echo
    echo "  cd $ADO_AGENT_DIR"
    echo "  sudo ./svc.sh status"

fi


# ==============================================================================
# COMPLETE
# ==============================================================================

echo
echo "======================================================================"
echo "                       INSTALLATION COMPLETE"
echo "======================================================================"
echo
echo "Azure DevOps agent:"
echo
echo "  Agent Name       $ADO_AGENT_NAME"
echo "  Agent Pool       $ADO_POOL"
echo "  Linux User       $TARGET_USER"
echo "  Directory        $ADO_AGENT_DIR"
echo "  Agent Version    $AGENT_VERSION"
echo
echo "The agent has been:"
echo
echo "  - Downloaded"
echo "  - Configured"
echo "  - Registered"
echo "  - Installed as a systemd service"
echo "  - Started"
echo
echo "You should now see this agent as Online in Azure DevOps."
echo
echo "======================================================================"
