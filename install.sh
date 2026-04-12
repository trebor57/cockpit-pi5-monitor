#!/usr/bin/env bash
set -euo pipefail

# Pi 5 Hardware Monitor installer
# Installs the Cockpit plugin plus the history collector script, service, and timer.
# Intended to be run from the project root.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="/usr/local/share/cockpit/pi-monitor"
HISTORY_SCRIPT_SRC="$PROJECT_ROOT/tools/pi-monitor-history"
SERVICE_SRC="$PROJECT_ROOT/packaging/pi-monitor-history.service"
TIMER_SRC="$PROJECT_ROOT/packaging/pi-monitor-history.timer"
HISTORY_SCRIPT_DST="/usr/local/bin/pi-monitor-history"
SERVICE_DST="/etc/systemd/system/pi-monitor-history.service"
TIMER_DST="/etc/systemd/system/pi-monitor-history.timer"

APT_UPDATED=0

say() {
    printf '%s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_file() {
    local path="$1"
    [[ -f "$path" ]] || fail "required file not found: $path"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

is_raspberry_pi_5() {
    local model=""

    if [[ -r /proc/device-tree/model ]]; then
        model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
    elif [[ -r /sys/firmware/devicetree/base/model ]]; then
        model="$(tr -d '\0' </sys/firmware/devicetree/base/model 2>/dev/null || true)"
    fi

    [[ "$model" == *"Raspberry Pi 5"* ]]
}

apt_update_once() {
    if [[ $APT_UPDATED -eq 0 ]]; then
        say "Running apt update..."
        apt-get update
        APT_UPDATED=1
    fi
}

install_required_packages() {
    local packages=("$@")

    [[ ${#packages[@]} -gt 0 ]] || return 0

    command_exists apt-get || fail "apt-get is not available. Install the required packages manually, then re-run this installer."

    say ""
    say "Installing required packages:"
    printf '  %s\n' "${packages[@]}"

    export DEBIAN_FRONTEND=noninteractive
    apt_update_once
    apt-get install -y "${packages[@]}"
}

maybe_install_optional_package() {
    local command_name="$1"
    local package_name="$2"
    local feature_text="$3"
    local reply=""

    if command_exists "$command_name"; then
        return 0
    fi

    say ""
    say "Optional package not found: $package_name"
    say "Feature: $feature_text"

    if [[ -t 0 ]]; then
        while true; do
            read -r -p "Install optional package $package_name now? [y/N]: " reply
            case "$reply" in
                [Yy]|[Yy][Ee][Ss])
                    export DEBIAN_FRONTEND=noninteractive
                    apt_update_once
                    apt-get install -y "$package_name"
                    return 0
                    ;;
                [Nn]|[Nn][Oo]|"")
                    say "Skipping optional package $package_name."
                    return 0
                    ;;
                *)
                    say "Please answer y or n."
                    ;;
            esac
        done
    fi

    say "Skipping optional package $package_name because no interactive terminal is available."
}

if [[ $EUID -ne 0 ]]; then
    fail "Please run this installer with sudo or as root."
fi

if [[ ! -f "$PROJECT_ROOT/package.json" || ! -f "$PROJECT_ROOT/Makefile" ]]; then
    fail "run this script from the Pi 5 Hardware Monitor project root."
fi

require_file "$HISTORY_SCRIPT_SRC"
require_file "$SERVICE_SRC"
require_file "$TIMER_SRC"

if ! is_raspberry_pi_5; then
    fail "Pi 5 Hardware Monitor only supports Raspberry Pi 5 systems. This installer will not continue on non-Pi-5 hardware."
fi

if ! command_exists cockpit-bridge; then
    fail "Cockpit is not installed or cockpit-bridge is missing. Pi 5 Hardware Monitor is a Cockpit plugin and requires Cockpit first."
fi

# Required command -> package mapping.
required_commands=(make node npm python3 systemctl)
required_packages=(make nodejs npm python3 systemd)
required_features=(
    "build/install support used by the Cockpit starter-kit Makefile"
    "JavaScript runtime required to build the Cockpit plugin during install"
    "package manager required to download and build the Cockpit plugin dependencies"
    "runtime required by the pi-monitor-history collector script"
    "service manager required for the pi-monitor-history service and timer"
)

missing_packages=()
missing_features=()

for i in "${!required_commands[@]}"; do
    if ! command_exists "${required_commands[$i]}"; then
        missing_packages+=("${required_packages[$i]}")
        missing_features+=("${required_packages[$i]}: ${required_features[$i]}")
    fi
done

if [[ ${#missing_packages[@]} -gt 0 ]]; then
    say ""
    say "Missing required dependencies detected:"
    printf '  %s\n' "${missing_features[@]}"
    install_required_packages "${missing_packages[@]}"
fi

# Re-verify every required command after package installation.
for cmd in "${required_commands[@]}"; do
    command_exists "$cmd" || fail "required command still not found after package installation: $cmd"
done

if ! command_exists vcgencmd; then
    fail "vcgencmd is missing. Pi 5 Hardware Monitor needs Raspberry Pi firmware utilities for temperatures, clocks, voltages, and throttling data. Install the package that provides vcgencmd on this system, then re-run this installer."
fi

maybe_install_optional_package \
    smartctl \
    smartmontools \
    "full NVMe SMART health details, including SMART status, SMART temperature, percentage used, power-on hours, unsafe shutdowns, and media/data integrity errors"

say ""
say "Building and installing the Cockpit plugin..."
make -C "$PROJECT_ROOT" install

say "Installing history collector and systemd units..."
install -m 755 "$HISTORY_SCRIPT_SRC" "$HISTORY_SCRIPT_DST"
install -m 644 "$SERVICE_SRC" "$SERVICE_DST"
install -m 644 "$TIMER_SRC" "$TIMER_DST"

say "Reloading systemd and starting the history timer/service..."
systemctl daemon-reload
systemctl enable --now pi-monitor-history.timer
systemctl start pi-monitor-history.service

cat <<MSG

Pi 5 Hardware Monitor install complete.

Installed paths:
  Cockpit plugin:   $PLUGIN_DIR
  History script:   $HISTORY_SCRIPT_DST
  Service unit:     $SERVICE_DST
  Timer unit:       $TIMER_DST

Next checks:
  cockpit-bridge --packages | grep -A3 -B2 'pi-monitor\\|Pi 5 Hardware Monitor'
  systemctl status pi-monitor-history.timer --no-pager
  systemctl status pi-monitor-history.service --no-pager
  ls -ld /var/lib/pi-monitor /var/lib/pi-monitor/history.ndjson

Notes:
  - The installer does NOT restart Cockpit automatically.
  - Refresh your Cockpit browser tab or sign back in if needed.
  - A first history snapshot is created during install so History / Trends is not blank on a fresh install.
  - /var/lib/pi-monitor/history.ndjson is runtime data and should not be shipped with personal node history.
  - Existing history data is preserved if it is already present.
  - smartmontools is optional but recommended for full NVMe SMART health details.

MSG
