#!/usr/bin/env bash

set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Please run this script with sudo: sudo ./orchestrator.sh"
    exit 1
fi

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$ROOT_DIR/scripts"

mapfile -t AVAILABLE_SCRIPTS < <(find "$SCRIPTS_DIR" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' | sort)
if (( ${#AVAILABLE_SCRIPTS[@]} == 0 )); then
    echo "[ERROR] No installers were found in $SCRIPTS_DIR."
    exit 1
fi

echo "Select installers to run (space-separated numbers, or 'all'):"
for i in "${!AVAILABLE_SCRIPTS[@]}"; do
    script="${AVAILABLE_SCRIPTS[$i]}"
    priority="$(sed -nE 's/^PRIORITY=([0-9]+)$/\1/p' "$SCRIPTS_DIR/$script" | head -n1)"
    name="$(sed -nE 's/^SCRIPT_NAME="(.*)"$/\1/p' "$SCRIPTS_DIR/$script" | head -n1)"
    [[ -n "$priority" && -n "$name" ]] || { echo "[ERROR] Invalid metadata in $script."; exit 1; }
    printf '  %d) %s (priority %s)\n' "$((i + 1))" "$name" "$priority"
done

read -rp "Selection: " -a CHOICES
(( ${#CHOICES[@]} > 0 )) || { echo "[ERROR] Nothing selected."; exit 1; }

SELECTED=()
if [[ "${CHOICES[0],,}" == "all" ]]; then
    SELECTED=("${AVAILABLE_SCRIPTS[@]}")
else
    declare -A SEEN=()
    for choice in "${CHOICES[@]}"; do
        [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#AVAILABLE_SCRIPTS[@]} )) || {
            echo "[ERROR] Invalid selection: $choice"; exit 1;
        }
        script="${AVAILABLE_SCRIPTS[$((choice - 1))]}"
        [[ -n "${SEEN[$script]:-}" ]] || SELECTED+=("$script")
        SEEN[$script]=1
    done
fi

is_selected() { local wanted="$1" item; for item in "${SELECTED[@]}"; do [[ "$item" == "$wanted" ]] && return 0; done; return 1; }
prompt_required() { local variable="$1" prompt="$2" secret="${3:-0}" value=""; while [[ -z "$value" ]]; do if [[ "$secret" == 1 ]]; then read -rsp "$prompt" value; echo; else read -rp "$prompt" value; fi; done; printf -v "$variable" '%s' "$value"; export "$variable"; }

echo
echo "Enter all required installation values. No installer will prompt after this stage."

if is_selected k3sbootstrap.sh; then
    DETECTED_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | grep -v '^127\.' | head -n1 || true)"
    read -rp "K3s server IP${DETECTED_IP:+ [$DETECTED_IP]}: " SERVER_IP
    SERVER_IP="${SERVER_IP:-$DETECTED_IP}"
    [[ -n "$SERVER_IP" ]] || { echo "[ERROR] A server IP is required."; exit 1; }
    if ! [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "[ERROR] Invalid IPv4 address: $SERVER_IP"
        exit 1
    fi
    IFS=. read -r -a IP_OCTETS <<<"$SERVER_IP"
    for octet in "${IP_OCTETS[@]}"; do
        (( 10#$octet <= 255 )) || { echo "[ERROR] Invalid IPv4 address: $SERVER_IP"; exit 1; }
    done
    read -rp "Rancher hostname [$SERVER_IP.sslip.io]: " RANCHER_HOST
    RANCHER_HOST="${RANCHER_HOST:-$SERVER_IP.sslip.io}"
    prompt_required RANCHER_PASSWORD "Initial Rancher administrator password: " 1
    export SERVER_IP RANCHER_HOST RANCHER_PASSWORD
fi

if is_selected ado-agent.sh; then
    prompt_required ADO_URL "Azure DevOps organization URL: "
    ADO_URL="${ADO_URL%/}"; export ADO_URL
    [[ "$ADO_URL" =~ ^https://dev\.azure\.com/[^/]+$ ]] || {
        echo "[ERROR] Expected an organization URL such as https://dev.azure.com/example"
        exit 1
    }
    prompt_required ADO_POOL "Azure DevOps Agent Pool: "
    read -rp "Agent name [$(hostname)]: " ADO_AGENT_NAME
    ADO_AGENT_NAME="${ADO_AGENT_NAME:-$(hostname)}"; export ADO_AGENT_NAME
    prompt_required ADO_PAT "Azure DevOps PAT: " 1
    TARGET_USER="${SUDO_USER:-root}"
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    read -rp "Agent directory [$TARGET_HOME/ado-agent]: " ADO_AGENT_DIR
    ADO_AGENT_DIR="${ADO_AGENT_DIR:-$TARGET_HOME/ado-agent}"; export ADO_AGENT_DIR
fi

mapfile -t ORDERED < <(for script in "${SELECTED[@]}"; do priority="$(sed -nE 's/^PRIORITY=([0-9]+)$/\1/p' "$SCRIPTS_DIR/$script" | head -n1)"; printf '%09d\t%s\n' "$priority" "$script"; done | sort -n -k1,1 -k2,2 | cut -f2-)

echo
echo "Installation order:"
printf '  - %s\n' "${ORDERED[@]}"
read -rp "Start all selected installations? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" == y || "${CONFIRM,,}" == yes ]] || { echo "Installation cancelled."; exit 0; }

export ORCHESTRATOR_MODE=1
for script in "${ORDERED[@]}"; do
    echo
    echo "======================================================================"
    echo "Running $script"
    echo "======================================================================"
    bash "$SCRIPTS_DIR/$script"
done

echo
echo "All selected installers completed successfully."
