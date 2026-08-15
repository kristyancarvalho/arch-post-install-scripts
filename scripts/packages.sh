#!/usr/bin/env bash

set -euo pipefail

if (( EUID == 0 )); then
    printf '%s\n' 'Run this script as a normal user, not as root.' >&2
    exit 1
fi

if (( $# != 1 )); then
    printf '%s\n' 'Repository root argument is required.' >&2
    exit 1
fi

load_packages() {
    local manifest="$1"
    local -n result="$2"
    local line

    result=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n "$line" ]] && result+=("$line")
    done < "$manifest"
}

root_dir="$1"
pacman_manifest="$root_dir/packages/pacman.txt"
aur_manifest="$root_dir/packages/aur.txt"

if [[ ! -f "$pacman_manifest" || ! -f "$aur_manifest" ]]; then
    printf '%s\n' 'Package manifests are missing.' >&2
    exit 1
fi

declare -a pacman_packages
declare -a aur_packages

load_packages "$pacman_manifest" pacman_packages
load_packages "$aur_manifest" aur_packages

if (( ${#pacman_packages[@]} > 0 )); then
    sudo pacman -S --needed --noconfirm "${pacman_packages[@]}"
fi

if (( ${#aur_packages[@]} > 0 )); then
    if ! command -v paru >/dev/null 2>&1; then
        printf '%s\n' 'paru is required to install AUR packages.' >&2
        exit 1
    fi

    paru -S --needed --noconfirm "${aur_packages[@]}"
fi
