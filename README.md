# Arch Linux Post-Install Scripts

A small, idempotent bootstrap for preparing a fresh Arch Linux installation. It installs the base package toolchain, bootstraps `paru`, installs package manifests, and configures a ready-to-use Zsh environment.

## Requirements

- Arch Linux with `pacman`
- A normal user with `sudo` access
- An active internet connection

Do not run the installer as root.

## Installation

```bash
git clone https://github.com/kristyancarvalho/arch-post-install-scripts.git
cd arch-post-install-scripts
./install.sh
```

The installer updates the system, installs `git`, `base-devel`, and `zsh`, and bootstraps `paru` from its AUR PKGBUILD when needed. It then installs the package manifests, clones Oh My Zsh into `$HOME/.oh-my-zsh`, copies `dotfiles/zshrc` to `$HOME/.zshrc`, and sets Zsh as the current user's login shell.

An existing different `$HOME/.zshrc` is backed up before replacement. An identical installed file is left unchanged.

## Package manifests

`packages/pacman.txt` contains one official repository package per line. Empty lines and an empty file are supported.

`packages/aur.txt` contains one AUR package per line. Empty lines and an empty file are supported. Packages in this file are installed together through `paru` as the normal user.

## Project structure

```text
.
├── install.sh
├── packages
│   ├── pacman.txt
│   └── aur.txt
├── dotfiles
│   └── zshrc
├── scripts
│   ├── bootstrap.sh
│   ├── packages.sh
│   └── zsh.sh
├── README.md
└── LICENSE
```

## Re-running

Run `./install.sh` again at any time. Already installed packages, Oh My Zsh, the login shell, and an identical `.zshrc` are left unchanged where possible.
