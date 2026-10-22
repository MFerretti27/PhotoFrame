#!/usr/bin/env python3
"""Display one folder photo per day on the Waveshare RPi Zero PhotoPainter."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import date
import fcntl
import importlib
import json
import logging
from pathlib import Path
import sys
import tempfile

from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parent
SIZE = (800, 480)
EXTENSIONS = {".jpg", ".jpeg", ".png", ".bmp", ".webp", ".tif", ".tiff"}
COLORS = ((0, 0, 0), (255, 255, 255), (255, 255, 0),
          (255, 0, 0), (0, 0, 255), (0, 255, 0))


def prepare_image(path: Path, fit: str = "contain", rotate: int = 0) -> Image.Image:
    """Apply EXIF orientation, flatten transparency, and fit without stretching."""
    with Image.open(path) as source:
        image = ImageOps.exif_transpose(source).convert("RGBA")
        background = Image.new("RGBA", image.size, "white")
        image = Image.alpha_composite(background, image).convert("RGB")
    if rotate:
        image = image.rotate(rotate, expand=True)
    if fit == "cover":
        return ImageOps.fit(image, SIZE, method=Image.Resampling.LANCZOS)
    return ImageOps.pad(image, SIZE, method=Image.Resampling.LANCZOS, color="white")


def six_color(image: Image.Image) -> Image.Image:
    """Approximate the panel palette; real e-paper colors differ from a monitor."""
    palette = Image.new("P", (1, 1))
    palette.putpalette([channel for color in COLORS for channel in color]
                       + [0, 0, 0] * 250)
    return image.quantize(palette=palette, dither=Image.Dither.FLOYDSTEINBERG)


def find_photos(folder: Path) -> list[Path]:
    if not folder.is_dir():
        raise ValueError(f"Photo folder does not exist: {folder}")
    return sorted((p.resolve() for p in folder.rglob("*")
                   if p.is_file() and p.suffix.lower() in EXTENSIONS
                   and not any(part.startswith(".") for part in p.relative_to(folder).parts)),
                  key=lambda p: str(p).casefold())


def read_state(path: Path) -> dict:
    if not path.exists():
        return {}
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError(f"Invalid state in {path}; move it aside to restart rotation.")
    return value


def write_state(path: Path, state: dict) -> None:
    """Replace state atomically, only after the display operation succeeds."""
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as out:
        temp = Path(out.name)
        try:
            json.dump(state, out)
            out.flush()
        except BaseException:
            temp.unlink(missing_ok=True)
            raise
    try:
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)


@contextmanager
def state_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.with_suffix(path.suffix + ".lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError("Another frame update is already running.") from exc
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def display_image(image: Image.Image, driver_path: Path) -> None:
    """Load the PhotoPainter-specific official driver only on hardware runs."""
    config = driver_path / "waveshare_epd" / "epdconfig.py"
    if not config.is_file():
        raise ValueError(f"Official PhotoPainter driver missing at {driver_path}. See README.")
    sys.path.insert(0, str(driver_path.resolve()))
    driver = importlib.import_module("waveshare_epd.epd7in3e")
    if driver.epdconfig.PWR_PIN != 27:
        raise ValueError("Wrong driver: PhotoPainter requires PWR_PIN = 27. Use its dedicated demo.")
    panel = driver.EPD()
    try:
        if panel.init() != 0:
            raise RuntimeError("Display initialization failed.")
        panel.display(panel.getbuffer(image))
    finally:
        # No Clear(): preserve the photograph while putting the panel to sleep.
        panel.sleep()


def update(args: argparse.Namespace) -> bool:
    state = read_state(args.state)
    today = date.today().isoformat()
    if not args.preview and not args.force and state.get("date") == today:
        logging.info("Already updated today; leaving the photo unchanged.")
        return False
    photos = find_photos(args.photos)
    if not photos:
        raise ValueError(f"No supported photos found in {args.photos}.")
    previous = state.get("photo")
    paths = [str(p) for p in photos]
    start = (paths.index(previous) + 1) % len(photos) if previous in paths else 0
    for offset in range(len(photos)):
        photo = photos[(start + offset) % len(photos)]
        try:
            image = prepare_image(photo, args.fit, args.rotate)
        except (OSError, ValueError, Image.DecompressionBombError) as exc:
            logging.warning("Skipping unreadable image %s: %s", photo, exc)
            continue
        if args.preview:
            args.preview.parent.mkdir(parents=True, exist_ok=True)
            six_color(image).convert("RGB").save(args.preview, format="PNG")
            logging.info("Preview saved to %s (state unchanged).", args.preview)
        else:
            display_image(image, args.driver_path)
            write_state(args.state, {"date": today, "photo": str(photo)})
            logging.info("Displayed %s", photo)
        return True
    raise ValueError("None of the photos could be decoded; display and state unchanged.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--photos", type=Path, default=ROOT / "photos")
    parser.add_argument("--state", type=Path, default=ROOT / ".state" / "frame.json")
    parser.add_argument("--driver-path", type=Path,
                        default=ROOT / "vendor" / "7in3_e-Paper_E" / "python" / "lib")
    parser.add_argument("--fit", choices=("contain", "cover"), default="contain",
                        help="contain: white borders; cover: crop to fill")
    parser.add_argument("--rotate", type=int, choices=(0, 90, 180, 270), default=0,
                        help="Counterclockwise rotation before fitting")
    parser.add_argument("--preview", type=Path, metavar="OUTPUT.png",
                        help="Save a six-color PNG without loading GPIO or changing state")
    parser.add_argument("--force", action="store_true", help="Advance even if already updated today")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    try:
        if args.preview:
            update(args)
        else:
            with state_lock(args.state):
                update(args)
    except (OSError, ValueError, RuntimeError, ImportError) as exc:
        logging.error("%s", exc)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())