<div align="center">
  <h1>Arch Linux Post-Install</h1>
  <p>A small, idempotent bootstrap for packages, Zsh, and automatic Btrfs snapshots.</p>

  ![Arch Linux](https://img.shields.io/badge/Arch-1793D1?logo=archlinux&logoColor=fff)
  ![Bash](https://img.shields.io/badge/Bash-4EAA25?logo=gnubash&logoColor=fff)
  ![Zsh](https://img.shields.io/badge/Zsh-F15A24)
  ![Paru](https://img.shields.io/badge/AUR-Paru-1793D1)
  ![Snapper](https://img.shields.io/badge/Snapper-Btrfs-5A67D8)
  ![Limine](https://img.shields.io/badge/Limine-7C3AED)
  ![License](https://img.shields.io/github/license/kristyancarvalho/arch-post-install-scripts)
</div>

## Requirements

- Arch Linux with a Btrfs root filesystem
- Snapper and Limine installed during the Arch installation
- A normal user with `sudo` access and an internet connection

## Installation

```bash
git clone https://github.com/kristyancarvalho/arch-post-install-scripts.git
cd arch-post-install-scripts
./install.sh
```

## Usage

Optionally edit the package lists, then run `./install.sh`. It is safe to run again.

## Package lists

- `packages/pacman.txt` contains official repository packages, one per line.
- `packages/aur.txt` contains packages installed through Paru, one per line.

## Snapshots

The installer enables timeline cleanup, Pacman pre/post snapshots, and repository-owned Limine synchronization. It detects the mounted FAT boot filesystem and the active Limine 12 configuration, preserves existing entries, and manages only the `Snapshots (Hyprism generated)` menu.

Run `snaplimine` to create a writable manual snapshot and synchronize the available snapshots with Limine. Run `snaplimine sync` to synchronize without creating a snapshot.

## License

[MIT](LICENSE)
