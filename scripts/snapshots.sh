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

require_command() {
    local command_name="$1"
    local message="$2"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

find_root_config() {
    local config configs subvolume
    if ! configs="$(snapper --csvout --no-headers list-configs --columns config,subvolume)"; then
        printf '%s\n' 'Unable to list existing Snapper configurations.' >&2
        return 2
    fi
    while IFS=, read -r config subvolume; do
        if [[ "$subvolume" == / ]]; then
            printf '%s\n' "$config"
            return 0
        fi
    done <<< "$configs"
    return 1
}

create_root_config() {
    local config_path=/etc/snapper/configs/root
    local template=/usr/share/snapper/config-templates/default
    if sudo test -e "$config_path"; then
        printf '%s\n' "$config_path exists but does not provide a functional configuration for /." >&2
        return 1
    fi
    if sudo test -e /.snapshots; then
        if ! sudo test -d /.snapshots || ! sudo btrfs subvolume show /.snapshots >/dev/null 2>&1; then
            printf '%s\n' '/.snapshots exists but is not a usable Btrfs subvolume.' >&2
            return 1
        fi
        if [[ ! -f "$template" ]]; then
            printf '%s\n' 'The default Snapper configuration template is missing.' >&2
            return 1
        fi
        sudo install -d -m 0755 /etc/snapper/configs
        sudo install -m 0600 "$template" "$config_path"
    else
        sudo snapper -c root create-config /
    fi
}

read_snapper_setting() {
    local config="$1" setting="$2"
    sudo awk -F= -v setting="$setting" '
        $1 == setting {
            value = substr($0, index($0, "=") + 1)
            gsub(/^[[:space:]]*"/, "", value)
            gsub(/"[[:space:]]*$/, "", value)
            print value
            exit
        }
    ' "/etc/snapper/configs/$config"
}

configure_snapper() {
    local config="$1" target_user="$2" allow_users
    allow_users="$(read_snapper_setting "$config" ALLOW_USERS)"
    if [[ " $allow_users " != *" $target_user "* ]]; then
        allow_users="${allow_users:+$allow_users }$target_user"
    fi
    sudo snapper -c "$config" set-config \
        "ALLOW_USERS=$allow_users" \
        "SYNC_ACL=yes" \
        "NUMBER_CLEANUP=yes" \
        "NUMBER_MIN_AGE=3600" \
        "NUMBER_LIMIT=20" \
        "NUMBER_LIMIT_IMPORTANT=10" \
        "TIMELINE_CREATE=yes" \
        "TIMELINE_CLEANUP=yes" \
        "TIMELINE_MIN_AGE=3600" \
        "TIMELINE_LIMIT_HOURLY=10" \
        "TIMELINE_LIMIT_DAILY=7" \
        "TIMELINE_LIMIT_WEEKLY=4" \
        "TIMELINE_LIMIT_MONTHLY=6" \
        "TIMELINE_LIMIT_QUARTERLY=0" \
        "TIMELINE_LIMIT_YEARLY=2" \
        "EMPTY_PRE_POST_CLEANUP=yes" \
        "EMPTY_PRE_POST_MIN_AGE=3600"
}

replace_root_file() {
    local target="$1" temp_file="$2" mode="$3" backup
    if sudo test -e "$target" && sudo cmp -s -- "$target" "$temp_file"; then
        sudo rm -f -- "$temp_file"
        return 0
    fi
    if sudo test -e "$target"; then
        backup="$target.hyprism-backup"
        if ! sudo test -e "$backup"; then
            sudo cp -a -- "$target" "$backup"
        fi
    fi
    sudo chown root:root "$temp_file"
    sudo chmod "$mode" "$temp_file"
    sudo mv -f -- "$temp_file" "$target"
}

configure_snap_pac() {
    local config="$1" target=/etc/snap-pac.ini temp_file
    if ! sudo test -f "$target"; then
        printf '%s\n' "$target is missing after installing snap-pac." >&2
        return 1
    fi
    temp_file="$(sudo mktemp /etc/.snap-pac.ini.XXXXXX)"
    sudo awk -v target_section="[$config]" '
        BEGIN { in_target = 0; section_found = 0; setting_found = 0 }
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            if (in_target && !setting_found) { print "snapshot = True"; setting_found = 1 }
            section = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", section)
            in_target = section == target_section
            if (in_target) section_found = 1
            print
            next
        }
        in_target && /^[[:space:]]*snapshot[[:space:]]*=/ {
            if (!setting_found) { print "snapshot = True"; setting_found = 1 }
            next
        }
        { print }
        END {
            if (in_target && !setting_found) print "snapshot = True"
            if (!section_found) { print ""; print target_section; print "snapshot = True" }
        }
    ' "$target" | sudo tee "$temp_file" >/dev/null
    replace_root_file "$target" "$temp_file" 0644
}

find_limine_config() {
    local configured mountpoint candidate
    local -a configs=()
    configured="$(sudo awk -F= '$1 == "LIMINE_CONFIG" { print substr($0, index($0, "=") + 1); exit }' /etc/arch-snapper-limine.conf 2>/dev/null || true)"
    if [[ -n "$configured" ]] && sudo test -f "$configured"; then
        printf '%s\n' "$configured"
        return 0
    fi
    while IFS= read -r mountpoint; do
        while IFS= read -r candidate; do
            configs+=("$candidate")
        done < <(sudo find "$mountpoint" -maxdepth 5 -type f -name limine.conf -print 2>/dev/null)
    done < <(findmnt -rn -t vfat,fat,exfat -o TARGET)
    if (( ${#configs[@]} == 1 )); then
        printf '%s\n' "${configs[0]}"
        return 0
    fi
    for candidate in "${configs[@]}"; do
        if [[ "$candidate" == */EFI/BOOT/limine.conf ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    if (( ${#configs[@]} > 1 )); then
        printf '%s\n' 'Multiple Limine configurations were found; set LIMINE_CONFIG in /etc/arch-snapper-limine.conf.' >&2
    fi
    return 1
}

install_root_file() {
    local source="$1" target="$2" mode="$3" temp_file
    temp_file="$(sudo mktemp "$(dirname "$target")/.arch-post-install.XXXXXX")"
    sudo install -m "$mode" "$source" "$temp_file"
    replace_root_file "$target" "$temp_file" "$mode"
}

install_settings() {
    local snapper_config="$1" limine_config="$2" temp_file
    temp_file="$(sudo mktemp /etc/.arch-snapper-limine.XXXXXX)"
    printf 'SNAPPER_CONFIG=%s\nLIMINE_CONFIG=%s\n' "$snapper_config" "$limine_config" | sudo tee "$temp_file" >/dev/null
    replace_root_file /etc/arch-snapper-limine.conf "$temp_file" 0644
}

install_sudoers() {
    local target_user="$1" target=/etc/sudoers.d/arch-post-install-snaplimine temp_file
    temp_file="$(sudo mktemp /etc/sudoers.d/.arch-post-install-snaplimine.XXXXXX)"
    printf '%s ALL=(root) NOPASSWD: /usr/local/libexec/arch-snapper-limine-sync\n' "$target_user" | sudo tee "$temp_file" >/dev/null
    sudo chmod 0440 "$temp_file"
    sudo visudo -cf "$temp_file" >/dev/null
    replace_root_file "$target" "$temp_file" 0440
}

enable_unit() {
    local unit="$1"
    if ! systemctl cat "$unit" >/dev/null 2>&1; then
        printf '%s\n' "Required systemd unit $unit is not installed." >&2
        return 1
    fi
    sudo systemctl enable --now "$unit"
}

install_snaplimine() {
    local source="$1" target="$HOME/.local/bin/snaplimine" temp_file backup
    install -d -m 0755 "$HOME/.local/bin"
    if [[ -f "$target" ]] && cmp -s -- "$source" "$target"; then
        return 0
    fi
    if [[ -e "$target" || -L "$target" ]]; then
        backup="$target.hyprism-backup"
        if [[ ! -e "$backup" && ! -L "$backup" ]]; then
            cp -a -- "$target" "$backup"
        fi
    fi
    temp_file="$(mktemp "$HOME/.local/bin/.snaplimine.XXXXXX")"
    install -m 0755 -- "$source" "$temp_file"
    mv -f -- "$temp_file" "$target"
}

root_dir="$1"
target_user="$(id -un)"

require_command snapper 'Snapper is required.'
require_command limine 'Limine is required.'
require_command btrfs 'btrfs-progs is required.'
require_command findmnt 'findmnt is required.'
require_command visudo 'sudo is required.'

if [[ "$(findmnt -no FSTYPE --target /)" != btrfs ]]; then
    printf '%s\n' 'The root filesystem must be Btrfs for Snapper integration.' >&2
    exit 1
fi
if ! pacman -Q snap-pac >/dev/null 2>&1; then
    printf '%s\n' 'snap-pac is not installed.' >&2
    exit 1
fi

sudo -v
root_config=''
root_config_status=0
root_config="$(find_root_config)" || root_config_status=$?
if (( root_config_status == 2 )); then
    exit 1
fi
if [[ -z "$root_config" ]]; then
    create_root_config
    root_config="$(find_root_config)"
fi
if [[ -z "$root_config" || ! "$root_config" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    printf '%s\n' 'Unable to establish a safe Snapper configuration for /.' >&2
    exit 1
fi

sudo snapper -c "$root_config" list --disable-used-space >/dev/null
configure_snapper "$root_config" "$target_user"
configure_snap_pac "$root_config"
if ! snapper -c "$root_config" list --disable-used-space >/dev/null; then
    printf '%s\n' "User $target_user cannot access Snapper configuration $root_config." >&2
    exit 1
fi

limine_config="$(find_limine_config || true)"
if [[ -z "$limine_config" ]]; then
    printf '%s\n' 'Unable to find one active limine.conf on a mounted FAT boot filesystem.' >&2
    exit 1
fi

install_settings "$root_config" "$limine_config"
sudo install -d -m 0755 /usr/local/libexec
install_root_file "$root_dir/commands/limine-snapshot-sync" /usr/local/libexec/arch-snapper-limine-sync 0755
install_root_file "$root_dir/systemd/arch-snapper-limine-sync.service" /etc/systemd/system/arch-snapper-limine-sync.service 0644
install_root_file "$root_dir/systemd/arch-snapper-limine-sync.path" /etc/systemd/system/arch-snapper-limine-sync.path 0644
install_sudoers "$target_user"
install_snaplimine "$root_dir/commands/snaplimine"

sudo systemctl daemon-reload
enable_unit snapper-timeline.timer
enable_unit snapper-cleanup.timer
enable_unit arch-snapper-limine-sync.path
sudo systemctl start arch-snapper-limine-sync.service
sudo systemctl is-active --quiet snapper-timeline.timer
sudo systemctl is-active --quiet snapper-cleanup.timer
sudo systemctl is-active --quiet arch-snapper-limine-sync.path
sudo systemctl --no-pager --full status snapper-timeline.timer snapper-cleanup.timer arch-snapper-limine-sync.path
sudo systemctl show arch-snapper-limine-sync.service --property=LoadState --property=ActiveState --property=Result --property=ExecMainStatus --no-pager

printf '%s\n' 'Snapper and Limine snapshot integration configured.'
