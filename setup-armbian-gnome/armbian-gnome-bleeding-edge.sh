#!/usr/bin/env bash
set -euo pipefail

# setup-armbian-gnome/armbian-gnome-bleeding-edge.sh
#
# One-time workstation bootstrap for Armbian (Rock Pi 4B / RK3399 friendly).
#
# Purpose:
# - Upgrade userspace packages
# - Optionally guide an interactive switch to Armbian "edge" via armbian-config
# - Install GNOME + GDM3 + force Xorg (Wayland off; RK3399 stable path)
# - Install a usable desktop payload (GNOME Software, Flatpak integration)
# - Enable Flatpak + Flathub
# - Install GNOME Tweaks + extensions + baseline theming/fonts
# - Install Google Chrome (ARM64) if available, otherwise fallback to Chromium
# - Install common baseline apps (terminal, PDF, media, audio control)
#
# Usage:
#   sudo ./setup-armbian-gnome/armbian-gnome-bleeding-edge.sh [./armbian-gnome-setup.json]
#
# Notes:
# - If .switch_branch == "edge", the script pauses to run armbian-config interactively.
# - After the branch switch + reboot, re-run the script.

CONFIG_PATH="${1:-./armbian-gnome-setup.json}"

log() { printf "\n[%s] %s\n" "$(date -Is)" "$*"; }
die() {
    printf "\nERROR: %s\n" "$*" >&2
    exit 1
}
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

ensure_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "Run as root (e.g., sudo $0 $CONFIG_PATH)."
    fi
}

read_json() {
    local jq_expr="$1"
    jq -r "$jq_expr" "$CONFIG_PATH"
}

pause_for_user() {
    local msg="$1"
    log "$msg"
    read -r -p "Press Enter to continue..."
}

detect_platform() {
    ARCH="$(dpkg --print-architecture)"
    CODENAME="$(
        . /etc/os-release
        echo "${VERSION_CODENAME:-}"
    )"
    DISTRO_ID="$(
        . /etc/os-release
        echo "${ID:-}"
    )"
    log "Platform: distro=${DISTRO_ID:-unknown} codename=${CODENAME:-unknown} arch=$ARCH"
}

apt_update_upgrade() {
    log "Updating APT indexes + upgrading packages."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade
    apt-get -y autoremove
}

maybe_switch_branch_edge() {
    local switch_branch
    switch_branch="$(read_json '.switch_branch // "no-change"')"

    if [[ "$switch_branch" != "edge" ]]; then
        log "Branch switch: no-change"
        return 0
    fi

    need_cmd armbian-config
    pause_for_user "Interactive step: run 'armbian-config' → System → (Rolling / Alternative kernels) → select EDGE. Reboot if prompted, then re-run this script."
}

install_gnome_desktop() {
    local method env
    method="$(read_json '.desktop.method // "auto"')"
    env="$(read_json '.desktop.environment // "gnome"')"
    [[ "$env" == "gnome" ]] || die "Only GNOME supported by this script."

    log "Installing GNOME desktop."
    apt-get update

    if [[ "$method" == "auto" || "$method" == "armbian-tool" ]]; then
        if command -v armbian-install-desktop >/dev/null 2>&1; then
            log "Using armbian-install-desktop (interactive). Select: GNOME + gdm3 + extras."
            armbian-install-desktop
            return 0
        fi
        [[ "$method" == "armbian-tool" ]] && die "armbian-install-desktop not present."
    fi

    # Fallbacks
    if [[ -n "${CODENAME:-}" ]] && apt-cache show "armbian-${CODENAME}-desktop-gnome" >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get -y install "armbian-${CODENAME}-desktop-gnome"
    elif apt-cache show gnome-desktop >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get -y install gnome-desktop
    elif apt-cache show task-gnome-desktop >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get -y install task-gnome-desktop
    else
        DEBIAN_FRONTEND=noninteractive apt-get -y install gnome-shell gnome-session
    fi

    # Ensure a display manager exists.
    if ! dpkg -s gdm3 >/dev/null 2>&1; then
        log "Installing gdm3."
        DEBIAN_FRONTEND=noninteractive apt-get -y install gdm3
    fi
}

configure_gdm_xorg() {
    log "Configuring GDM for Xorg (Wayland disabled)."
    install -d -m 755 /etc/gdm3

    cat >/etc/gdm3/daemon.conf <<'EOF'
[daemon]
WaylandEnable=false
DefaultSession=gnome-xorg.desktop
EOF

    systemctl enable gdm3 || true
}

install_desktop_payload() {
    log "Installing GNOME desktop payload (Software Center, Flatpak plugin, Tweaks, tools)."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get -y install \
        gnome-software \
        gnome-software-plugin-flatpak \
        gnome-tweaks \
        gnome-shell-extensions \
        dconf-editor \
        gnome-terminal \
        nautilus \
        evince
}

install_polish() {
    local tweaks exts yaru
    tweaks="$(read_json '.themes.install_gnome_tweaks // true')"
    exts="$(read_json '.themes.install_shell_extensions // true')"
    yaru="$(read_json '.themes.install_yaru // true')"

    log "Installing polish (themes, fonts)."
    apt-get update

    pkgs=()
    [[ "$tweaks" == "true" ]] && pkgs+=(gnome-tweaks)
    [[ "$exts" == "true" ]] && pkgs+=(gnome-shell-extensions)
    [[ "$yaru" == "true" ]] && pkgs+=(yaru-theme-gnome-shell yaru-theme-gtk yaru-theme-icon)

    pkgs+=(fonts-cantarell fonts-inter)

    if [[ "${#pkgs[@]}" -gt 0 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get -y install "${pkgs[@]}"
    fi
}

install_extra_apt_packages() {
    log "Installing extra APT packages from config."
    mapfile -t extra < <(jq -r '.packages.extra_apt[]? // empty' "$CONFIG_PATH")
    if [[ "${#extra[@]}" -gt 0 ]]; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get -y install "${extra[@]}"
    fi
}

setup_flatpak_if_enabled() {
    local enable add_flathub
    enable="$(read_json '.flatpak.enable // true')"
    add_flathub="$(read_json '.flatpak.add_flathub // true')"
    [[ "$enable" == "true" ]] || {
        log "Flatpak: disabled"
        return 0
    }

    log "Installing Flatpak + wiring GNOME Software."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get -y install flatpak gnome-software-plugin-flatpak

    if [[ "$add_flathub" == "true" ]]; then
        log "Adding Flathub remote (system-wide)."
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    fi
}

install_chrome_or_fallback() {
    local want
    want="$(read_json '.apps.browser // "chrome"')"

    case "$want" in
        none)
            log "Browser: none"
            ;;
        chrome | google-chrome | google-chrome-stable)
            log "Installing Google Chrome if available (fallback to Chromium if not)."
            tmpdir="$(mktemp -d)"
            if command -v wget >/dev/null 2>&1; then
                (cd "$tmpdir" && wget -q -O chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_arm64.deb) || true
            else
                apt-get update
                DEBIAN_FRONTEND=noninteractive apt-get -y install wget
                (cd "$tmpdir" && wget -q -O chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_arm64.deb) || true
            fi

            if [[ -s "$tmpdir/chrome.deb" ]]; then
                apt-get update
                DEBIAN_FRONTEND=noninteractive apt-get -y install "$tmpdir/chrome.deb"
                rm -rf "$tmpdir"
                return 0
            fi

            rm -rf "$tmpdir"
            log "Chrome arm64 package not retrieved; installing Chromium."
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get -y install chromium ||
                DEBIAN_FRONTEND=noninteractive apt-get -y install chromium-browser
            ;;
        chromium-apt)
            log "Installing Chromium via APT."
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get -y install chromium ||
                DEBIAN_FRONTEND=noninteractive apt-get -y install chromium-browser
            ;;
        chromium-flatpak)
            log "Installing Chromium via Flatpak."
            need_cmd flatpak
            flatpak install -y flathub org.chromium.Chromium
            ;;
        *)
            die "Unknown browser option: $want"
            ;;
    esac
}

install_baseline_apps() {
    log "Installing baseline workstation apps."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get -y install \
        pipewire pipewire-pulse wireplumber \
        pavucontrol \
        vlc \
        mesa-utils vainfo \
        curl ca-certificates \
        xdg-utils \
        unzip
}

install_zoom_if_applicable() {
    local zoom
    zoom="$(read_json '.apps.zoom // "skip"')"
    [[ "$zoom" == "install-if-amd64" ]] || {
        log "Zoom: skipped"
        return 0
    }

    if [[ "$ARCH" != "amd64" ]]; then
        log "Zoom: skipped because arch=$ARCH"
        return 0
    fi

    log "Installing Zoom (amd64)."
    tmpdir="$(mktemp -d)"
    (cd "$tmpdir" && wget -q https://zoom.us/client/latest/zoom_amd64.deb && apt-get -y install ./zoom_amd64.deb)
    rm -rf "$tmpdir"
}

enable_graphical_boot() {
    log "Setting default target to graphical."
    systemctl set-default graphical.target
}

maybe_reboot() {
    local reboot_after
    reboot_after="$(read_json '.desktop.reboot_after // true')"
    if [[ "$reboot_after" == "true" ]]; then
        pause_for_user "Reboot recommended to start GNOME + GDM cleanly."
        reboot
    else
        log "Reboot: disabled by config."
    fi
}

main() {
    ensure_root
    need_cmd jq
    [[ -f "$CONFIG_PATH" ]] || die "Config not found: $CONFIG_PATH"

    detect_platform
    apt_update_upgrade
    maybe_switch_branch_edge

    install_gnome_desktop
    configure_gdm_xorg
    install_desktop_payload

    install_polish
    setup_flatpak_if_enabled
    install_chrome_or_fallback
    install_baseline_apps
    install_extra_apt_packages
    install_zoom_if_applicable

    enable_graphical_boot

    log "Done."
    maybe_reboot
}

main "$@"
