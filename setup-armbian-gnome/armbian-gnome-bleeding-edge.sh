#!/usr/bin/env bash
set -euo pipefail

# armbian-gnome-bleeding-edge.sh
# Purpose:
# - Update Armbian userspace safely
# - Optionally guide an interactive switch to "edge" via armbian-config
# - Install GNOME desktop via Armbian tooling when available
# - Add a polished baseline (Tweaks, extensions, Yaru)
# - Install Chromium (APT or Flatpak). Avoids claiming Google Chrome arm64 exists.
# - Optionally install Zoom only on amd64.

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

    # armbian-config is ncurses and not reliable to automate non-interactively.
    # Official guidance is to use armbian-config to select edge/rolling. :contentReference[oaicite:0]{index=0}
    need_cmd armbian-config
    pause_for_user "Interactive step required: run 'armbian-config' → System → (Rolling / Alternative kernels) → select EDGE. Reboot if prompted, then re-run this script with the same config."
}

install_gnome_desktop() {
    local method env
    method="$(read_json '.desktop.method // "auto"')"
    env="$(read_json '.desktop.environment // "gnome"')"

    [[ "$env" == "gnome" ]] || die "Only GNOME supported by this script."

    if [[ "$method" == "auto" || "$method" == "armbian-tool" ]]; then
        if command -v armbian-install-desktop >/dev/null 2>&1; then
            log "Installing GNOME via armbian-install-desktop (Armbian-supported path)."
            # Armbian documents desktop installs via its tooling. :contentReference[oaicite:1]{index=1}
            armbian-install-desktop
            return 0
        fi
        [[ "$method" == "armbian-tool" ]] && die "armbian-install-desktop not present."
    fi

    log "Installing GNOME via apt meta-packages (fallback path)."
    apt-get update

    # Armbian forum guidance mentions armbian-<codename>-desktop-gnome for some images. :contentReference[oaicite:2]{index=2}
    if [[ -n "${CODENAME:-}" ]] && apt-cache show "armbian-${CODENAME}-desktop-gnome" >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get -y install "armbian-${CODENAME}-desktop-gnome"
        return 0
    fi

    # Generic Debian/Ubuntu fallback.
    if apt-cache show gnome-desktop >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get -y install gnome-desktop
    elif apt-cache show task-gnome-desktop >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get -y install task-gnome-desktop
    else
        DEBIAN_FRONTEND=noninteractive apt-get -y install gnome-shell gdm3
    fi
}

install_polish() {
    local tweaks exts yaru
    tweaks="$(read_json '.themes.install_gnome_tweaks // true')"
    exts="$(read_json '.themes.install_shell_extensions // true')"
    yaru="$(read_json '.themes.install_yaru // true')"

    log "Installing UX baseline packages."
    apt-get update

    pkgs=()
    [[ "$tweaks" == "true" ]] && pkgs+=(gnome-tweaks)
    [[ "$exts" == "true" ]] && pkgs+=(gnome-shell-extensions)
    [[ "$yaru" == "true" ]] && pkgs+=(yaru-theme-gnome-shell yaru-theme-gtk yaru-theme-icon)

    # Always-useful fonts for a more polished UI.
    pkgs+=(fonts-cantarell fonts-inter)

    if [[ "${#pkgs[@]}" -gt 0 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get -y install "${pkgs[@]}"
    fi

    log "GNOME info: GNOME platform reference. :contentReference[oaicite:3]{index=3}"
    log "GNOME extensions site (for post-install toggles). :contentReference[oaicite:4]{index=4}"
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

    log "Installing Flatpak."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get -y install flatpak

    # On GNOME, the plugin helps GNOME Software manage Flatpaks (optional, but useful). :contentReference[oaicite:5]{index=5}
    if apt-cache show gnome-software-plugin-flatpak >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get -y install gnome-software-plugin-flatpak
    fi

    if [[ "$add_flathub" == "true" ]]; then
        log "Adding Flathub remote (system-wide)."
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    fi

    log "Flatpak references. :contentReference[oaicite:6]{index=6}"
}

install_browser() {
    local browser
    browser="$(read_json '.apps.browser // "chromium-apt"')"

    case "$browser" in
        none)
            log "Browser: none"
            ;;
        chromium-apt)
            log "Installing Chromium via APT."
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get -y install chromium ||
                DEBIAN_FRONTEND=noninteractive apt-get -y install chromium-browser
            log "Chromium project reference. :contentReference[oaicite:7]{index=7}"
            ;;
        chromium-flatpak)
            log "Installing Chromium via Flatpak (Flathub)."
            need_cmd flatpak
            flatpak install -y flathub org.chromium.Chromium
            log "Flathub Chromium app page. :contentReference[oaicite:8]{index=8}"
            ;;
        *)
            die "Unknown browser option: $browser"
            ;;
    esac
}

install_zoom_if_applicable() {
    local zoom
    zoom="$(read_json '.apps.zoom // "skip"')"
    [[ "$zoom" == "install-if-amd64" ]] || {
        log "Zoom: skipped"
        return 0
    }

    if [[ "$ARCH" != "amd64" ]]; then
        log "Zoom: skipped because arch=$ARCH (official Linux packages are documented for x86_64). :contentReference[oaicite:9]{index=9}"
        return 0
    fi

    log "Installing Zoom (amd64)."
    # Zoom download center provides the current deb; the exact filename can vary. :contentReference[oaicite:10]{index=10}
    # This uses the commonly documented 'latest' URL pattern for amd64.
    tmpdir="$(mktemp -d)"
    (cd "$tmpdir" && wget -q https://zoom.us/client/latest/zoom_amd64.deb && apt-get -y install ./zoom_amd64.deb)
    rm -rf "$tmpdir"
}

maybe_reboot() {
    local reboot_after
    reboot_after="$(read_json '.desktop.reboot_after // true')"
    if [[ "$reboot_after" == "true" ]]; then
        pause_for_user "Reboot is recommended to start GNOME cleanly."
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
    install_polish
    install_extra_apt_packages
    setup_flatpak_if_enabled
    install_browser
    install_zoom_if_applicable

    log "Done."
    maybe_reboot
}

main "$@"
