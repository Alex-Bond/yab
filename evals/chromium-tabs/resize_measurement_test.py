#!/usr/bin/env python3
"""Keep transparent capture padding distinct from opaque page backing."""
import tempfile
import unittest
from pathlib import Path
from PIL import Image, ImageDraw
from resize_film import exposure


class ResizeMeasurementTests(unittest.TestCase):
    def measure(self, backing=False):
        image = Image.new('RGBA', (120, 100), (0, 0, 0, 0))
        draw = ImageDraw.Draw(image)
        draw.rectangle((0, 0, 99, 79), fill=(120, 30, 30, 255))
        draw.rectangle((20, 4, 95, 75), fill=(18, 120, 60, 255))
        if backing:
            draw.rectangle((90, 4, 95, 75), fill=(0, 0, 0, 255))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'capture.png'
            image.save(path)
            return exposure(path, [20, 4, 76, 72], [100, 80], 1)

    def test_transparent_stream_padding_is_outside_the_window(self):
        result = self.measure()
        self.assertEqual(result['right'], 0)
        self.assertEqual(result['bottom'], 0)
        self.assertEqual(result['captureExtent'], [0, 0, 100, 80])

    def test_opaque_backing_inside_the_page_is_still_a_failure(self):
        result = self.measure(backing=True)
        self.assertEqual(result['right'], 6)
        self.assertEqual(result['bottom'], 0)


if __name__ == '__main__':
    unittest.main()
