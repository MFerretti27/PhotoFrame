# Daily e-paper photo frame

For the **Waveshare RPi Zero PhotoPainter**, SKU 33137, with the 7.3-inch E6
800 × 480 display and a Raspberry Pi Zero / Zero 2 W. Python 3.10+ required.
The ACCE option does **not** include the Raspberry Pi; check your purchased bundle.

Displays the next photo in filename order each day at **08:00 local time**,
wrapping back to the beginning. Recursively reads JPEG, PNG, BMP, WebP and TIFF.
HEIC is not supported: export iPhone photos as JPEG first.
Applies camera orientation, preserves aspect ratio, flattens transparency onto white,
and uses the panel's six-color dithering. No AI models or internet connection are
needed during normal operation. Corrupt images are skipped.

## Preview on the Mac

Put photos in `photos/`. From this project directory:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python frame.py --preview preview.png
open preview.png
```

The preview is an approximation of e-paper colors, not a calibrated simulation.
It never loads GPIO or advances the rotation state. Original photographs are unchanged.

## Raspberry Pi installation

### Automatic installation from your Mac or Linux computer

Flash a current **Raspberry Pi OS Lite** image first. In Raspberry Pi Imager,
configure your username, Wi-Fi, and SSH with your public key. Boot the Pi and
connect once with SSH to verify its host key. The installer requires SSH key
authentication and passwordless sudo for that normal (non-root) user. It cannot
flash the SD card or configure networking before the Pi is reachable.

Put your pictures in this project's `photos/` folder, then run
`bash install.sh YOUR_USER@192.168.1.42` from this project directory, replacing
the username and address. SSH aliases/hostnames also work. For a timezone, use
`bash install.sh --timezone Europe/London YOUR_USER@192.168.1.42`.
Use `bash install.sh --help` for custom SSH port/user options and `--no-reboot`.
Without `--timezone`, the installer sets the Pi to **America/Detroit** (Eastern
Time, automatically adjusting for daylight saving time).

The installer copies the application to `~/epaper-frame`, installs system and
Python dependencies, downloads the **official PhotoPainter-specific Waveshare
driver**, enables SPI, adds hardware permissions, and enables the lingering user
timer. It schedules a reboot when necessary (one-minute delay), reconnects, creates
a preview, and displays the first photo before enabling daily updates. This executes
downloaded vendor code; review the official archive beforehand if required by your
security policy. Internet access on the Pi is required during installation.

Rerunning updates application files and copies new/changed photos, without deleting
remote-only photos, the virtual environment, or rotation state. The daily guard
prevents another refresh on the same date. If no photos are present, the installer
configures the timer but skips the initial refresh; add photos and rerun before the
next scheduled update to avoid a no-photos error. If interrupted or a reboot times
out, rerun after the Pi is reachable. A failed install may leave the timer stopped
until a successful rerun. Stop any vendor/demo refresh job before installing;
the installer does not disable unrelated services. SPI/GPIO and the actual panel
still need validation on your hardware. RTC/UPS configuration is not automated.

### Manual installation

1. Install Raspberry Pi OS Lite, configure Wi-Fi/SSH as needed, and transfer this
   project to **~/epaper-frame** on the Pi. Copy your photos into its `photos/` folder.
   Do not copy the Mac's `.venv`; create a separate environment on the Pi.
2. Use `sudo raspi-config` to enable **SPI** and set your local timezone. Reboot.
   Verify `/dev/spidev0.0` exists. Stop any vendor/demo job already refreshing the panel.
3. In a terminal on the Pi, from `~/epaper-frame`:

```sh
sudo apt update
sudo apt install python3-venv python3-pip python3-pil python3-gpiozero python3-lgpio python3-spidev curl unzip
python3 -m venv --system-site-packages .venv
.venv/bin/python -m pip install -r requirements.txt
mkdir -p vendor
curl -fL https://files.waveshare.com/wiki/RPi_Zero_PhotoPainter/Demo/RPi_Zero_PhotoPainter.zip -o /tmp/photopainter.zip
unzip /tmp/photopainter.zip '7in3_e-Paper_E/python/lib/*' -d vendor
.venv/bin/python frame.py --preview preview.png
.venv/bin/python frame.py
```

Review downloaded vendor code before running it. The driver is obtained separately
from Waveshare and retains its original license. **Use the PhotoPainter-specific
archive**, not the generic e-Paper HAT driver: this board's power pin is **BCM 27**.
The script checks the driver's exported power pin before initializing the panel
(the vendor import itself initializes GPIO). GPIO 17/25/24 are reset/DC/busy;
the interface is SPI0 CE0. No rewiring is required for the assembled frame.

The hardware refresh takes approximately 12 seconds and flickers normally. It is
followed by panel sleep, without clearing the photograph. Do not interrupt a refresh.
Hardware operation must be tested on your Pi; a Mac preview cannot verify wiring.

Run as your normal Pi user, with access to the `spi` and `gpio` groups. If permissions
are missing, an administrator can add that user to those groups; log out and back in.
Do not solve permission errors by running the entire project as root.

## Daily scheduling (on the Pi)

These are **user** systemd units. `%h` refers to your Pi user's home directory, so no
hardcoded `pi` username is needed. The project must be at `~/epaper-frame` or the
service paths must be edited. From the project directory:

```sh
mkdir -p ~/.config/systemd/user
cp systemd/epaper-frame.service systemd/epaper-frame.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now epaper-frame.timer
sudo loginctl enable-linger "$USER"
systemctl --user list-timers epaper-frame.timer
```

Lingering allows the user timer to run while you are logged out and after boot.
The manual run above displays the initial photo; the timer subsequently updates at
08:00. `Persistent=true` runs one missed update when the timer starts again, not
one refresh for every missed day. State records successful updates only, preventing
repeat refreshes on the same calendar date. If a refresh fails, inspect the logs
and retry manually; automatic failure retries are not configured.

```sh
journalctl --user -u epaper-frame.service -n 50 --no-pager
systemctl --user start epaper-frame.service
systemctl --user disable --now epaper-frame.timer
```

To change the time, edit `OnCalendar` in the installed timer, reload the user daemon,
and restart the timer. Keep the Pi's clock/timezone correct; for offline use configure
the onboard DS3231 RTC following Waveshare's documentation.

## Options

```sh
# Use a different photo directory (also add this option to the service if desired).
.venv/bin/python frame.py --photos /home/YOUR_USER/Pictures
# Crop to fill the screen instead of adding white borders.
.venv/bin/python frame.py --fit cover
# Advance immediately, overriding the once-per-day guard.
.venv/bin/python frame.py --force
# Rotate counterclockwise before resizing; use 180 for an upside-down frame.
.venv/bin/python frame.py --rotate 180 --preview preview.png
```

State is stored at `.state/frame.json`; deleting it restarts from the first photo.
Do not modify it while an update is running. A lock prevents overlapping hardware
updates from this script; it cannot prevent unrelated vendor software using GPIO.
Keep preview output outside your photo folder so it is not picked up as a new photo.

## Power and battery limitations

**Panel sleep is not Raspberry Pi shutdown.** This version keeps the Pi powered on
and uses a timer rather than a continuously running Python process. The display
retains its photo without power, but that does not make the Pi itself ultra-low-power.
Use USB power for unattended operation unless you have configured and tested battery
monitoring and safe shutdown separately. This script does not implement UPS monitoring,
low-battery shutdown, RTC wake/power cycling, or battery-life guarantees. Do not assume
the onboard RTC can power the Pi back on after shutdown. Those functions require a
separately verified power-control design.

## Tests

```sh
.venv/bin/python -m unittest discover -s tests -v
```

Tests use temporary synthetic photos and mocked hardware; no physical refreshes occur.
Run `bash tests/test_installer.sh` for the installer's local orchestration tests;
SSH is mocked, so these do not connect to or change a Pi.

## References

- [Product](https://www.waveshare.com/rpi-zero-photopainter-acce.htm?sku=33137)
- [Official setup, driver, pinout, RTC and UPS documentation](https://www.waveshare.com/wiki/RPi_Zero_PhotoPainter)