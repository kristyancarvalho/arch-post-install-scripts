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

install_oh_my_zsh() {
    local target="$HOME/.oh-my-zsh"
    local temp_dir

    if [[ -e "$target" || -L "$target" ]]; then
        if [[ ! -f "$target/oh-my-zsh.sh" ]]; then
            printf '%s\n' "$target exists but is not a valid Oh My Zsh installation." >&2
            return 1
        fi

        return 0
    fi

    temp_dir="$(mktemp -d "$HOME/.oh-my-zsh.XXXXXX")"

    if ! git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$temp_dir"; then
        rm -rf -- "$temp_dir"
        return 1
    fi

    if ! mv -- "$temp_dir" "$target"; then
        rm -rf -- "$temp_dir"
        return 1
    fi
}

install_zshrc() {
    local source="$1"
    local target="$HOME/.zshrc"
    local backup
    local temp_file

    if [[ ! -f "$source" ]]; then
        printf '%s\n' 'The repository zshrc is missing.' >&2
        return 1
    fi

    if [[ -f "$target" && ! -L "$target" ]] && cmp -s -- "$source" "$target"; then
        return 0
    fi

    if [[ -e "$target" || -L "$target" ]]; then
        backup="$HOME/.zshrc.backup.$(date +%Y%m%d%H%M%S)"

        while [[ -e "$backup" || -L "$backup" ]]; do
            backup="$backup.1"
        done

        cp -a -- "$target" "$backup"
    fi

    temp_file="$(mktemp "$HOME/.zshrc.tmp.XXXXXX")"

    if ! install -m 0644 -- "$source" "$temp_file"; then
        rm -f -- "$temp_file"
        return 1
    fi

    if ! mv -f -- "$temp_file" "$target"; then
        rm -f -- "$temp_file"
        return 1
    fi
}

configure_login_shell() {
    local target_user
    local zsh_path
    local current_shell

    target_user="$(id -un)"
    zsh_path="$(command -v zsh)"
    current_shell="$(getent passwd "$target_user" | cut -d: -f7)"

    if [[ -z "$current_shell" ]]; then
        printf '%s\n' "Unable to determine the login shell for $target_user." >&2
        return 1
    fi

    if [[ "$(readlink -f -- "$current_shell")" != "$(readlink -f -- "$zsh_path")" ]]; then
        sudo chsh -s "$zsh_path" "$target_user"
    fi

    current_shell="$(getent passwd "$target_user" | cut -d: -f7)"

    if [[ "$(readlink -f -- "$current_shell")" != "$(readlink -f -- "$zsh_path")" ]]; then
        printf '%s\n' "Failed to set Zsh as the login shell for $target_user." >&2
        return 1
    fi
}

root_dir="$1"

install_oh_my_zsh
install_zshrc "$root_dir/dotfiles/zshrc"
configure_login_shell
