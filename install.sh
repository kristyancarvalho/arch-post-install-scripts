#!/usr/bin/env bash

set -euo pipefail

if (( EUID == 0 )); then
    printf '%s\n' 'Run this installer as a normal user, not as root.' >&2
    exit 1
fi

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

"$root_dir/scripts/bootstrap.sh"
"$root_dir/scripts/packages.sh" "$root_dir"
"$root_dir/scripts/zsh.sh" "$root_dir"
"$root_dir/scripts/snapshots.sh" "$root_dir"

printf '%s\n' 'Arch Linux post-install setup completed.'
