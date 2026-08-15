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
    local config
    local configs
    local subvolume

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
    local config="$1"
    local setting="$2"

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
    local config="$1"
    local target_user="$2"
    local allow_users

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

next_backup_path() {
    local file="$1"
    local backup="$file.backup.$(date +%Y%m%d%H%M%S)"

    while sudo test -e "$backup"; do
        backup="$backup.1"
    done

    printf '%s\n' "$backup"
}

replace_root_file() {
    local target="$1"
    local temp_file="$2"
    local mode="$3"
    local backup

    if sudo test -e "$target" && sudo cmp -s -- "$target" "$temp_file"; then
        sudo rm -f -- "$temp_file"
        return 0
    fi

    if sudo test -e "$target"; then
        backup="$(next_backup_path "$target")"
        sudo cp -a -- "$target" "$backup"
        sudo chown --reference="$target" "$temp_file"
        sudo chmod --reference="$target" "$temp_file"
    else
        sudo chown root:root "$temp_file"
        sudo chmod "$mode" "$temp_file"
    fi

    sudo mv -f -- "$temp_file" "$target"
}

configure_snap_pac() {
    local config="$1"
    local target=/etc/snap-pac.ini
    local temp_file

    if ! sudo test -f "$target"; then
        printf '%s\n' "$target is missing after installing snap-pac." >&2
        return 1
    fi

    temp_file="$(sudo mktemp /etc/.snap-pac.ini.XXXXXX)"

    sudo awk -v target_section="[$config]" '
        BEGIN {
            in_target = 0
            section_found = 0
            setting_found = 0
        }
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            if (in_target && !setting_found) {
                print "snapshot = True"
                setting_found = 1
            }
            section = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", section)
            in_target = section == target_section
            if (in_target) {
                section_found = 1
            }
            print
            next
        }
        in_target && /^[[:space:]]*snapshot[[:space:]]*=/ {
            if (!setting_found) {
                print "snapshot = True"
                setting_found = 1
            }
            next
        }
        {
            print
        }
        END {
            if (in_target && !setting_found) {
                print "snapshot = True"
            }
            if (!section_found) {
                print ""
                print target_section
                print "snapshot = True"
            }
        }
    ' "$target" | sudo tee "$temp_file" >/dev/null

    replace_root_file "$target" "$temp_file" 0644
}

read_assignment() {
    local file="$1"
    local setting="$2"
    local value

    if ! sudo test -f "$file"; then
        return 1
    fi

    value="$(sudo awk -F= -v setting="$setting" '
        $0 ~ "^[[:space:]]*" setting "[[:space:]]*=" {
            print substr($0, index($0, "=") + 1)
            exit
        }
    ' "$file")"
    value="${value%%#*}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value#\"}"
    value="${value%\"}"

    [[ -n "$value" ]] || return 1
    printf '%s\n' "$value"
}

find_limine_config() {
    local configured_esp
    local candidate

    configured_esp="$(read_assignment /etc/default/limine ESP_PATH || read_assignment /etc/limine-snapper-sync.conf ESP_PATH || true)"

    if [[ -n "$configured_esp" ]] && sudo test -f "$configured_esp/limine.conf"; then
        printf '%s\n' "$configured_esp/limine.conf"
        return 0
    fi

    candidate="$(bootctl --print-esp-path 2>/dev/null || true)"

    if [[ -n "$candidate" ]] && sudo test -f "$candidate/limine.conf"; then
        printf '%s\n' "$candidate/limine.conf"
        return 0
    fi

    for candidate in /boot /efi /boot/efi /limine; do
        if findmnt --target "$candidate" >/dev/null 2>&1 && sudo test -f "$candidate/limine.conf"; then
            printf '%s\n' "$candidate/limine.conf"
            return 0
        fi
    done

    while IFS= read -r candidate; do
        if sudo test -f "$candidate/limine.conf"; then
            printf '%s\n' "$candidate/limine.conf"
            return 0
        fi
    done < <(findmnt -rn -o TARGET)

    return 1
}

configure_limine_settings() {
    local esp_path="$1"
    local snapper_config="$2"
    local target=/etc/default/limine
    local source=/dev/null
    local temp_file

    sudo install -d -m 0755 /etc/default

    if sudo test -f "$target"; then
        source="$target"
    fi

    temp_file="$(sudo mktemp /etc/default/.limine.tmp.XXXXXX)"

    sudo awk -v esp_path="$esp_path" -v snapper_config="$snapper_config" '
        BEGIN {
            esp_done = 0
            snapper_done = 0
        }
        /^[[:space:]]*ESP_PATH[[:space:]]*=/ {
            if (!esp_done) {
                print "ESP_PATH=\"" esp_path "\""
                esp_done = 1
            }
            next
        }
        /^[[:space:]]*SNAPPER_CONFIG_NAME[[:space:]]*=/ {
            if (!snapper_done) {
                print "SNAPPER_CONFIG_NAME=\"" snapper_config "\""
                snapper_done = 1
            }
            next
        }
        {
            print
        }
        END {
            if (!esp_done) {
                print "ESP_PATH=\"" esp_path "\""
            }
            if (!snapper_done) {
                print "SNAPPER_CONFIG_NAME=\"" snapper_config "\""
            }
        }
    ' "$source" | sudo tee "$temp_file" >/dev/null

    replace_root_file "$target" "$temp_file" 0600
}

ensure_snapshots_marker() {
    local limine_config="$1"

    if sudo grep -Eq '^[[:space:]]*/{1,2}Snapshots[[:space:]]*$' "$limine_config"; then
        return 0
    fi

    if ! sudo grep -Eq '^[[:space:]]*(protocol|kernel_path|path):[[:space:]]*' "$limine_config"; then
        printf '%s\n' "$limine_config does not contain a recognizable Limine boot entry." >&2
        return 1
    fi

    if ! sudo test -f /usr/lib/limine/limine-mutex; then
        printf '%s\n' 'The limine-snapper-sync mutex library is missing.' >&2
        return 1
    fi

    sudo bash -c '
        set -euo pipefail
        source /usr/lib/limine/limine-mutex
        mutex_lock arch-post-install
        trap mutex_unlock EXIT
        config="$1"
        grep -Eq "^[[:space:]]*/{1,2}Snapshots[[:space:]]*$" "$config" && exit 0
        backup="$config.backup.$(date +%Y%m%d%H%M%S)"
        while [[ -e "$backup" ]]; do
            backup="$backup.1"
        done
        cp -- "$config" "$backup"
        temp_file="$(mktemp "$(dirname "$config")/.limine.conf.XXXXXX")"
        cp -- "$config" "$temp_file"
        printf "\n/Snapshots\n" >> "$temp_file"
        mv -f -- "$temp_file" "$config"
    ' bash "$limine_config"
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
    local source="$1"
    local target="$HOME/.local/bin/snaplimine"
    local backup
    local temp_file

    if [[ ! -f "$source" ]]; then
        printf '%s\n' 'The snaplimine source command is missing.' >&2
        return 1
    fi

    install -d -m 0755 "$HOME/.local/bin"

    if [[ -f "$target" && ! -L "$target" ]] && cmp -s -- "$source" "$target"; then
        return 0
    fi

    if [[ -e "$target" || -L "$target" ]]; then
        backup="$target.backup.$(date +%Y%m%d%H%M%S)"

        while [[ -e "$backup" || -L "$backup" ]]; do
            backup="$backup.1"
        done

        cp -a -- "$target" "$backup"
    fi

    temp_file="$(mktemp "$HOME/.local/bin/.snaplimine.XXXXXX")"

    if ! install -m 0755 -- "$source" "$temp_file"; then
        rm -f -- "$temp_file"
        return 1
    fi

    if ! mv -f -- "$temp_file" "$target"; then
        rm -f -- "$temp_file"
        return 1
    fi
}

root_dir="$1"
target_user="$(id -un)"

require_command snapper 'Snapper is required and should have been installed with Arch Linux.'
require_command limine 'Limine is required and should have been installed with Arch Linux.'
require_command btrfs 'btrfs-progs is required for Snapper configuration.'
require_command findmnt 'findmnt is required to detect mounted filesystems.'
require_command bootctl 'bootctl is required to detect the EFI system partition.'
require_command limine-snapper-sync 'limine-snapper-sync was not installed from the AUR manifest.'

if [[ "$(findmnt -no FSTYPE --target /)" != btrfs ]]; then
    printf '%s\n' 'The root filesystem must be Btrfs for Snapper integration.' >&2
    exit 1
fi

if ! pacman -Q snap-pac >/dev/null 2>&1; then
    printf '%s\n' 'snap-pac was not installed from the pacman manifest.' >&2
    exit 1
fi

if ! pacman -Q limine-snapper-sync >/dev/null 2>&1; then
    printf '%s\n' 'limine-snapper-sync is not registered as an installed package.' >&2
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
    if ! root_config="$(find_root_config)"; then
        printf '%s\n' 'The new Snapper configuration for / is not available.' >&2
        exit 1
    fi
fi

if [[ -z "$root_config" || ! "$root_config" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    printf '%s\n' 'Unable to establish a safe Snapper configuration for /.' >&2
    exit 1
fi

if ! sudo snapper -c "$root_config" list --disable-used-space >/dev/null; then
    printf '%s\n' "Snapper configuration $root_config is not functional." >&2
    exit 1
fi

configure_snapper "$root_config" "$target_user"
configure_snap_pac "$root_config"

if ! snapper -c "$root_config" list --disable-used-space >/dev/null; then
    printf '%s\n' "User $target_user cannot access Snapper configuration $root_config." >&2
    exit 1
fi

limine_config="$(find_limine_config || true)"

if [[ -z "$limine_config" ]]; then
    printf '%s\n' 'Unable to find the active limine.conf on a mounted boot filesystem.' >&2
    exit 1
fi

esp_path="$(dirname -- "$limine_config")"

ensure_snapshots_marker "$limine_config"
configure_limine_settings "$esp_path" "$root_config"
enable_unit snapper-timeline.timer
enable_unit snapper-cleanup.timer
enable_unit limine-snapper-sync.service
install_snaplimine "$root_dir/commands/snaplimine"

if ! sudo limine-snapper-sync --no-force-save; then
    printf '%s\n' 'Limine snapshot synchronization failed.' >&2
    exit 1
fi

printf '%s\n' 'Snapper and Limine snapshot integration configured.'
