#!/usr/bin/env bash
# Run on your Mac/Linux computer; all Pi changes happen over SSH.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bash install.sh [options] [USER@]PI_ADDRESS

  --user USER       SSH user (otherwise SSH configuration/current user)
  --port PORT       SSH port (default: 22)
    --timezone ZONE   Set Pi timezone (default: America/Detroit)
  --no-reboot       Leave a required reboot to you; rerun afterward to finish
  -h, --help        Show help

Requires Raspberry Pi OS with networking, SSH key authentication, and
passwordless sudo already configured. Copies photos without deleting remote
photos or rotation state. Downloads the official Waveshare PhotoPainter driver.
By default reboots only if SPI is not available, then reconnects automatically.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
user='' port=22 timezone='America/Detroit' reboot=yes target=''
while (($#)); do
    case "$1" in
        --user|--port|--timezone)
            (($# >= 2)) || die "$1 requires a value"
            case "$1" in
                --user) user=$2 ;;
                --port) port=$2 ;;
                --timezone) timezone=$2 ;;
            esac
            shift 2 ;;
        --no-reboot) reboot=no; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "Unknown option: $1" ;;
        *) [[ -z "$target" ]] || die 'Specify one Pi address'; target=$1; shift ;;
    esac
done
[[ -n "$target" ]] || { usage >&2; exit 1; }
[[ "$port" =~ ^[0-9]{1,5}$ ]] || die 'Invalid SSH port'
((10#$port >= 1 && 10#$port <= 65535)) || die 'Invalid SSH port'
[[ -z "$user" || "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] || die 'Invalid SSH user'
if [[ -n "$user" ]]; then
    [[ "$target" != *@* ]] || die 'Use --user or USER@ADDRESS, not both'
    target="$user@$target"
fi
[[ "$target" =~ ^([a-z_][a-z0-9_-]*@)?[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die 'Use an IPv4 address or hostname, optionally prefixed with USER@'
[[ -z "$timezone" || "$timezone" =~ ^[a-zA-Z0-9_+/-]+$ ]] || die 'Invalid timezone'
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for cmd in ssh tar; do command -v "$cmd" >/dev/null || die "Missing command: $cmd"; done
ssh_opts=(-p "$port" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)

printf 'Checking SSH and passwordless sudo on %s...\n' "$target"
# Keep host-key checking enabled. Establish trust interactively before installing.
ssh "${ssh_opts[@]}" "$target" 'test "$(id -u)" != 0 && sudo -n true' ||
    die 'Connect once with SSH to verify the host key; configure an SSH key and passwordless sudo for a non-root Pi user.'
stage=$(ssh "${ssh_opts[@]}" "$target" 'mktemp -d /tmp/epaper-install.XXXXXXXX')
[[ "$stage" =~ ^/tmp/epaper-install\.[a-zA-Z0-9]+$ ]] || die 'Unexpected remote staging path'
cleanup() { ssh "${ssh_opts[@]}" "$target" "rm -rf -- '$stage'" >/dev/null 2>&1 || true; }
trap cleanup EXIT
printf 'Copying application and photos (existing remote photos/state are preserved)...\n'
COPYFILE_DISABLE=1 tar -C "$root" --exclude=.DS_Store --exclude='._*' -czf - \
    frame.py requirements.txt systemd scripts photos |
    ssh "${ssh_opts[@]}" "$target" "tar -xzf - -C '$stage'"
printf -v remote_command 'bash %q/scripts/setup-pi.sh install %q %q' "$stage" "$stage" "$timezone"
ssh "${ssh_opts[@]}" "$target" "$remote_command"

if ! ssh "${ssh_opts[@]}" "$target" 'bash "$HOME/epaper-frame/scripts/setup-pi.sh" ready'; then
    if [[ "$reboot" == no ]]; then
        printf 'SPI or hardware group access needs a reboot. Reboot the Pi, then rerun this installer to activate the timer.\n'
        exit 0
    fi
    cleanup
    trap - EXIT
    printf 'Rebooting to activate hardware access; waiting up to about five minutes for SSH...\n'
    # Schedule reboot after SSH can acknowledge the request.
    ssh "${ssh_opts[@]}" "$target" 'sudo -n shutdown -r +1' || die 'Could not schedule reboot'
    # Do not mistake the old, still-running SSH server for the rebooted Pi.
    ready=no
    for ((attempt=0; attempt<100; attempt++)); do
        if ssh "${ssh_opts[@]}" "$target" 'bash "$HOME/epaper-frame/scripts/setup-pi.sh" ready' 2>/dev/null; then
            ready=yes
            break
        fi
        sleep 3
    done
    [[ "$ready" == yes ]] || die 'Pi did not return with SPI available. Check power/network/SPI and rerun.'
fi
ssh "${ssh_opts[@]}" "$target" 'bash "$HOME/epaper-frame/scripts/setup-pi.sh" finish'
printf '\nInstallation complete. The frame updates daily at 08:00 in the Pi timezone.\n'