import argparse
from datetime import date
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image

import frame


class FrameTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.photos = self.root / "photos"
        self.photos.mkdir()
        self.state = self.root / "state.json"
        self.args = argparse.Namespace(photos=self.photos, state=self.state,
                                      preview=None, force=False, fit="contain", rotate=0,
                                      driver_path=self.root / "driver")

    def photo(self, name, color="red", size=(120, 180)):
        path = self.photos / name
        Image.new("RGB", size, color).save(path)
        return path

    def test_fit_palette_and_rotation(self):
        photo = self.photo("portrait.jpg")
        image = frame.prepare_image(photo)
        self.assertEqual(image.size, (800, 480))
        self.assertEqual(image.getpixel((0, 0)), (255, 255, 255))
        filled = frame.prepare_image(photo, "cover", 90)
        self.assertEqual(filled.size, frame.SIZE)
        colors = frame.six_color(image).convert("RGB").getcolors(256)
        self.assertTrue({color for _, color in colors} <= set(frame.COLORS))

    def test_transparency_is_white(self):
        path = self.photos / "alpha.png"
        Image.new("RGBA", (800, 480), (0, 0, 0, 0)).save(path)
        self.assertEqual(frame.prepare_image(path).getpixel((0, 0)), (255, 255, 255))

    @patch("frame.display_image")
    def test_daily_guard_force_and_wrap(self, display):
        first = self.photo("a.jpg")
        second = self.photo("b.png")
        self.assertTrue(frame.update(self.args))
        self.assertEqual(json.loads(self.state.read_text())["photo"], str(first))
        self.assertFalse(frame.update(self.args))
        self.assertEqual(display.call_count, 1)
        self.args.force = True
        frame.update(self.args)
        self.assertEqual(json.loads(self.state.read_text())["photo"], str(second))
        frame.update(self.args)
        self.assertEqual(json.loads(self.state.read_text())["photo"], str(first))

    @patch("frame.display_image")
    def test_next_day_advances(self, display):
        first = self.photo("a.jpg")
        second = self.photo("b.jpg")
        self.state.write_text(json.dumps({"date": "2000-01-01", "photo": str(first)}))
        frame.update(self.args)
        self.assertEqual(json.loads(self.state.read_text()),
                         {"date": date.today().isoformat(), "photo": str(second)})

    @patch("frame.display_image", side_effect=RuntimeError("panel failed"))
    def test_failure_does_not_advance_state(self, display):
        self.photo("a.jpg")
        with self.assertRaises(RuntimeError):
            frame.update(self.args)
        self.assertFalse(self.state.exists())

    @patch("frame.display_image")
    def test_preview_never_calls_hardware_or_writes_state(self, display):
        self.photo("a.jpg")
        self.args.preview = self.root / "preview.png"
        frame.update(self.args)
        display.assert_not_called()
        self.assertFalse(self.state.exists())
        with Image.open(self.args.preview) as image:
            self.assertEqual(image.size, frame.SIZE)

    @patch("frame.display_image")
    def test_corrupt_photo_skipped_and_hidden_files_ignored(self, display):
        (self.photos / "a.jpg").write_bytes(b"not a jpeg")
        valid = self.photo("b.jpg")
        self.photo(".hidden.jpg")
        frame.update(self.args)
        self.assertEqual(json.loads(self.state.read_text())["photo"], str(valid))
        self.assertEqual(len(frame.find_photos(self.photos)), 2)

    def test_empty_folder_fails(self):
        with self.assertRaisesRegex(ValueError, "No supported photos"):
            frame.update(self.args)

    def test_malformed_state_fails_without_refresh(self):
        self.state.write_text("[]")
        with self.assertRaisesRegex(ValueError, "Invalid state"):
            frame.update(self.args)

    def test_lock_prevents_overlapping_updates(self):
        with frame.state_lock(self.state):
            with self.assertRaisesRegex(RuntimeError, "already running"):
                with frame.state_lock(self.state):
                    self.fail("Second lock acquired")


if __name__ == "__main__":
    unittest.main()