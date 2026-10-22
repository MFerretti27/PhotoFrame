#!/usr/bin/env bash
# Internal remote installer, invoked by install.sh as the normal Pi user.
set -euo pipefail
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ $(id -u) != 0 ]] || die 'Run as a normal Pi user, not root.'
app="$HOME/epaper-frame"

hardware_ready() {
    [[ -e /dev/spidev0.0 ]] || return 1
    local manager_pid group gid
    manager_pid=$(systemctl show "user@$(id -u).service" -p MainPID --value)
    [[ "$manager_pid" =~ ^[1-9][0-9]*$ && -r "/proc/$manager_pid/status" ]] || return 1
    for group in spi gpio; do
        gid=$(getent group "$group" | cut -d: -f3)
        [[ -n "$gid" ]] || return 1
        grep '^Groups:' "/proc/$manager_pid/status" | grep -qw "$gid" || return 1
    done
}

case "${1:-}" in
    ready) hardware_ready ;;
    install)
        stage=${2:?Missing staging directory}
        timezone=${3:-}
        [[ -r /proc/device-tree/model ]] && grep -qi 'Raspberry Pi' /proc/device-tree/model ||
            die 'This installer requires a Raspberry Pi running Raspberry Pi OS.'
        command -v raspi-config >/dev/null || die 'raspi-config is missing; install Raspberry Pi OS first.'
        sudo -n true
        if [[ -n "$timezone" ]]; then
            [[ "$timezone" != /* && "$timezone" != *..* && -f "/usr/share/zoneinfo/$timezone" ]] || die 'Unknown timezone'
            sudo -n timedatectl set-timezone "$timezone"
        fi
        printf 'Installing system packages...\n'
        sudo -n apt-get update
        sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y \
            python3-venv python3-pip python3-pil python3-gpiozero python3-lgpio python3-spidev curl unzip \
            build-essential python3-dev libjpeg-dev zlib1g-dev libtiff-dev libwebp-dev libopenjp2-7-dev
        python3 -c 'import sys; assert sys.version_info >= (3, 10), "Python 3.10+ required; use a newer Raspberry Pi OS"'
        for group in spi gpio; do
            getent group "$group" >/dev/null || die "Missing hardware group: $group"
        done
        sudo -n usermod -a -G spi,gpio "$(id -un)"
        sudo -n raspi-config nonint do_spi 0
        # Stop our timer and finish any in-flight refresh before replacing code.
        export XDG_RUNTIME_DIR="/run/user/$(id -u)"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
        systemctl --user stop epaper-frame.timer 2>/dev/null || true
        if systemctl --user is-active --quiet epaper-frame.service; then
            die 'A frame refresh is running. Wait for it to finish, then rerun the installer.'
        fi
        mkdir -p "$app/scripts" "$app/systemd" "$app/photos" "$app/vendor"
        cp "$stage/frame.py" "$stage/requirements.txt" "$app/"
        cp "$stage/scripts/setup-pi.sh" "$app/scripts/"
        cp "$stage/systemd/epaper-frame.service" "$stage/systemd/epaper-frame.timer" "$app/systemd/"
        cp -R "$stage/photos/." "$app/photos/"
        python3 -m venv --system-site-packages "$app/.venv"
        "$app/.venv/bin/python" -m pip install -r "$app/requirements.txt"
        printf 'Downloading official Waveshare PhotoPainter driver (retains its vendor license)...\n'
        curl --fail --location --retry 3 --connect-timeout 20 --max-time 300 \
            https://files.waveshare.com/wiki/RPi_Zero_PhotoPainter/Demo/RPi_Zero_PhotoPainter.zip \
            -o "$stage/photopainter.zip"
        unzip -q -o "$stage/photopainter.zip" '7in3_e-Paper_E/python/lib/*' -d "$stage/driver"
        config="$stage/driver/7in3_e-Paper_E/python/lib/waveshare_epd/epdconfig.py"
        [[ -f "$config" ]] || die 'Official archive does not contain the expected driver'
        grep -Eq '^[[:space:]]*PWR_PIN[[:space:]]*=[[:space:]]*27([[:space:]#]|$)' "$config" ||
            die 'Driver does not declare the PhotoPainter power pin BCM 27'
        cp -R "$stage/driver/7in3_e-Paper_E" "$app/vendor/"
        sudo -n loginctl enable-linger "$(id -un)"
        printf 'Pi timezone: %s\n' "$(timedatectl show -p Timezone --value)"
        ;;
    finish)
        hardware_ready || die 'SPI or user-manager hardware group access is missing; reboot and rerun.'
        mkdir -p "$HOME/.config/systemd/user"
        cp "$app/systemd/epaper-frame.service" "$app/systemd/epaper-frame.timer" "$HOME/.config/systemd/user/"
        export XDG_RUNTIME_DIR="/run/user/$(id -u)"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
        systemctl --user daemon-reload
        # Preview validates photos without GPIO or advancing rotation.
        if find "$app/photos" -type f \( -iname '*.jpg' -o -iname '*.jpeg' \
            -o -iname '*.png' -o -iname '*.bmp' -o -iname '*.webp' \
            -o -iname '*.tif' -o -iname '*.tiff' \) -print -quit | grep -q .; then
            "$app/.venv/bin/python" "$app/frame.py" --preview "$app/preview.png"
            printf 'Displaying initial photo (a refresh flickers; do not interrupt)...\n'
            systemctl --user start epaper-frame.service
        else
            printf 'No photos uploaded. Add supported photos locally and rerun the installer.\n'
        fi
        systemctl --user enable --now epaper-frame.timer
        systemctl --user list-timers epaper-frame.timer --no-pager
        ;;
    *) die 'Expected install, ready, or finish phase' ;;
esac