#!/usr/bin/env bash

set -Eeuo pipefail

# ==============================================================================
# TERMINAL CUSTOMIZATION - ZSH + PREZTO
# ==============================================================================

if [[ $EUID -ne 0 ]]; then
    echo "Please run this script with sudo:"
    echo "  sudo ./terminal-theme.sh"
    exit 1
fi

echo
echo "Installing Zsh + Prezto terminal customization..."

# Determine the actual user.
# If the script was started with sudo, configure the user who called sudo,
# not root.

if [[ $(id -u) -eq 0 ]]; then
    TARGET_USER=${SUDO_USER:-root}
else
    TARGET_USER=$(id -un)
fi

TARGET_HOME=$(getent passwd "$TARGET_USER" | awk -F: '{print $6}')

if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
    echo "Cannot determine home directory for $TARGET_USER."
    exit 1
fi


# ------------------------------------------------------------------------------
# Install Zsh
# ------------------------------------------------------------------------------

apt-get install -y zsh git

ZSH_PATH=$(command -v zsh)

if [[ -z "$ZSH_PATH" || ! -x "$ZSH_PATH" ]]; then
    echo "Zsh installation failed."
    exit 1
fi


# ------------------------------------------------------------------------------
# Helper: run commands as the actual user
# ------------------------------------------------------------------------------

run_as_target() {

    if [[ $(id -u) -eq 0 && "$TARGET_USER" != "root" ]]; then

        runuser -u "$TARGET_USER" -- \
            env HOME="$TARGET_HOME" "$@"

    else

        env HOME="$TARGET_HOME" "$@"

    fi
}


# ------------------------------------------------------------------------------
# Install Prezto
# ------------------------------------------------------------------------------

PREZTO_DIR="$TARGET_HOME/.zprezto"

echo
echo "Installing Prezto for $TARGET_USER..."

if [[ ! -d "$PREZTO_DIR/.git" ]]; then

    run_as_target git clone \
        --recursive \
        https://github.com/sorin-ionescu/prezto.git \
        "$PREZTO_DIR"

else

    echo "Prezto already installed."

    run_as_target git \
        -C "$PREZTO_DIR" \
        submodule update \
        --init \
        --recursive

fi


# ------------------------------------------------------------------------------
# Configure Prezto
# ------------------------------------------------------------------------------

backup_suffix=".before-prezto-$(date +%Y%m%d-%H%M%S)"

for rcfile in "$PREZTO_DIR"/runcoms/*; do

    name=$(basename "$rcfile")

    [[ "$name" == "README.md" ]] && continue

    destination="$TARGET_HOME/.$name"

    # Back up an existing configuration instead of destroying it.

    if [[ -e "$destination" || -L "$destination" ]]; then

        if [[ "$(readlink -f "$destination")" == "$(readlink -f "$rcfile")" ]]; then
            continue
        fi

        run_as_target mv \
            "$destination" \
            "${destination}${backup_suffix}"

        echo "Backed up $destination"

    fi

    run_as_target ln -s \
        "$rcfile" \
        "$destination"

done


# ------------------------------------------------------------------------------
# Make Zsh the default shell
# ------------------------------------------------------------------------------

echo
echo "Setting Zsh as the default shell for $TARGET_USER..."

CURRENT_SHELL=$(getent passwd "$TARGET_USER" | awk -F: '{print $7}')

if [[ "$CURRENT_SHELL" != "$ZSH_PATH" ]]; then

    chsh -s "$ZSH_PATH" "$TARGET_USER"

else

    echo "Zsh is already the default shell."

fi


# ------------------------------------------------------------------------------
# Finished
# ------------------------------------------------------------------------------

echo
echo "======================================================================"
echo "Terminal customization complete"
echo "======================================================================"
echo
echo "User:   $TARGET_USER"
echo "Shell:  Zsh"
echo "Theme:  Prezto"
echo
echo "Log out and reconnect through SSH to activate it."
echo
