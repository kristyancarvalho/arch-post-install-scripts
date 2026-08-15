#!/usr/bin/env bash

set -euo pipefail

if (( EUID == 0 )); then
    printf '%s\n' 'Run this script as a normal user, not as root.' >&2
    exit 1
fi

if ! command -v pacman >/dev/null 2>&1; then
    printf '%s\n' 'pacman is required. Run this installer on Arch Linux.' >&2
    exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
    printf '%s\n' 'sudo is required to install system packages.' >&2
    exit 1
fi

sudo -v
sudo pacman -Syu --needed --noconfirm git base-devel zsh

if command -v paru >/dev/null 2>&1; then
    exit 0
fi

temp_dir="$(mktemp -d)"

cleanup() {
    rm -rf -- "$temp_dir"
}

trap cleanup EXIT

git clone https://aur.archlinux.org/paru.git "$temp_dir/paru"
(
    cd -- "$temp_dir/paru"
    makepkg -si --needed --noconfirm
)

hash -r

if ! command -v paru >/dev/null 2>&1; then
    printf '%s\n' 'paru installation did not provide an executable.' >&2
    exit 1
fi
