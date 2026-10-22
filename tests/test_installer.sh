#!/usr/bin/env bash
# Local orchestration tests: SSH is mocked; no Pi or network is used.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export INSTALL_TEST_LOG="$work/ssh.log" INSTALL_TEST_READY="$work/ready"
export INSTALL_TEST_MODE=ready

ssh() {
    local command=${!#}
    printf '%s\n' "$*" >> "$INSTALL_TEST_LOG"
    case "$command" in
        'mktemp -d '*) printf '/tmp/epaper-install.TEST1234\n' ;;
        'tar -xzf '*) cat >/dev/null ;;
        *'setup-pi.sh" ready')
            case "$INSTALL_TEST_MODE" in
                ready) return 0 ;;
                blocked) return 1 ;;
                reboot) [[ -f "$INSTALL_TEST_READY" ]] ;;
            esac ;;
        'sudo -n shutdown -r +1') touch "$INSTALL_TEST_READY" ;;
        *) return 0 ;;
    esac
}
sleep() { :; }
export -f ssh sleep

bash -n "$root/install.sh" "$root/scripts/setup-pi.sh"
bash "$root/install.sh" --help > "$work/help"
grep -q 'Usage:' "$work/help"
for arg in --unknown --port; do
    if bash "$root/install.sh" "$arg" > "$work/error" 2>&1; then
        printf 'Expected invalid arguments to fail: %s\n' "$arg" >&2; exit 1
    fi
done
for address in '-bad' 'host;id' 'user@host/escape'; do
    if bash "$root/install.sh" "$address" > "$work/error" 2>&1; then
        printf 'Expected invalid address to fail: %s\n' "$address" >&2; exit 1
    fi
done
if bash "$root/install.sh" --port 65536 pi@host > "$work/error" 2>&1; then
    printf 'Expected invalid port to fail\n' >&2; exit 1
fi

bash "$root/install.sh" --user frame --port 2222 --timezone Europe/London pi.local > "$work/output"
grep -q -- '-p 2222 .*frame@pi.local' "$INSTALL_TEST_LOG"
grep -q 'install /tmp/epaper-install.TEST1234 Europe/London' "$INSTALL_TEST_LOG"
grep -q 'setup-pi.sh" finish' "$INSTALL_TEST_LOG"
grep -q 'Installation complete' "$work/output"
if grep -q 'shutdown' "$INSTALL_TEST_LOG"; then exit 1; fi

: > "$INSTALL_TEST_LOG"
export INSTALL_TEST_MODE=blocked
bash "$root/install.sh" --no-reboot pi@host > "$work/output"
grep -q 'install /tmp/epaper-install.TEST1234 America/Detroit' "$INSTALL_TEST_LOG"
grep -q 'rerun this installer' "$work/output"
if grep -Eq 'shutdown|setup-pi.sh" finish' "$INSTALL_TEST_LOG"; then exit 1; fi
grep -q 'rm -rf' "$INSTALL_TEST_LOG"

: > "$INSTALL_TEST_LOG"
export INSTALL_TEST_MODE=reboot
bash "$root/install.sh" pi@host > "$work/output"
grep -q 'sudo -n shutdown -r +1' "$INSTALL_TEST_LOG"
grep -q 'setup-pi.sh" finish' "$INSTALL_TEST_LOG"
printf 'Installer orchestration tests passed.\n'