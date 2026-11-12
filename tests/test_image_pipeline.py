"""Pixel-preparation tests; no board, model, network, or GUI is required."""

from pathlib import Path
import tempfile
import unittest

import numpy as np
from PIL import Image, ImageDraw, ImageOps

from scripts.image_pipeline import load_image, load_image_bytes, prepare_image


def digit_image():
    image = Image.new("RGB", (100, 120), "white")
    draw = ImageDraw.Draw(image)
    draw.line([(35, 25), (65, 25), (65, 57), (35, 57), (35, 90), (65, 90)],
              fill="black", width=8)
    return image


class PrepareImageTests(unittest.TestCase):
    def test_auto_and_explicit_polarities_are_equivalent(self):
        dark = digit_image()
        light = ImageOps.invert(dark)
        expected = prepare_image(dark, polarity="dark")
        for image, polarity in ((dark, "auto"), (light, "auto"), (light, "light")):
            with self.subTest(polarity=polarity):
                np.testing.assert_array_equal(expected, prepare_image(image, polarity=polarity))

    def test_blank_and_nearly_uniform_images_are_rejected(self):
        for color in (0, 128, 255):
            with self.subTest(color=color), self.assertRaisesRegex(ValueError, "blank|uniform"):
                prepare_image(Image.new("L", (64, 64), color))
        faint = Image.new("L", (64, 64), 245)
        ImageDraw.Draw(faint).line([(20, 10), (20, 50)], fill=236, width=4)
        with self.assertRaisesRegex(ValueError, "uniform"):
            prepare_image(faint)
        speck = Image.new("L", (64, 64), 255)
        speck.putpixel((30, 30), 0)
        with self.assertRaisesRegex(ValueError, "too little"):
            prepare_image(speck)

    def test_output_geometry_type_and_mass_center(self):
        result = prepare_image(digit_image())
        self.assertEqual(result.shape, (16, 16))
        self.assertEqual(result.dtype, np.uint8)
        self.assertTrue(result.flags.c_contiguous)
        self.assertEqual(len(result.tobytes()), 256)
        self.assertGreater(int(result.max()), 200)
        self.assertEqual(int(result.min()), 0)
        y, x = np.indices(result.shape)
        self.assertAlmostEqual(float((y * result).sum() / result.sum()), 7.5, delta=0.08)
        self.assertAlmostEqual(float((x * result).sum() / result.sum()), 7.5, delta=0.08)
        ys, xs = np.nonzero(result > 40)
        self.assertLessEqual(ys.max() - ys.min() + 1, 13)
        self.assertLessEqual(xs.max() - xs.min() + 1, 13)

    def test_tall_digit_preserves_aspect_ratio(self):
        image = Image.new("L", (60, 100), 255)
        ImageDraw.Draw(image).rectangle((25, 10, 34, 89), fill=0)
        result = prepare_image(image)
        ys, xs = np.nonzero(result > 40)
        self.assertGreater(ys.max() - ys.min(), 8)
        self.assertLess(xs.max() - xs.min(), 4)

    def test_crop_is_applied_before_statistics_and_ignores_other_content(self):
        source = digit_image()
        sheet = Image.new("RGB", (250, 160), "black")
        sheet.paste(source, (20, 20))
        result = prepare_image(sheet, crop_box=(20, 20, 120, 140))
        np.testing.assert_array_equal(result, prepare_image(source))

    def test_crop_cannot_be_blank_even_if_digit_exists_elsewhere(self):
        with self.assertRaisesRegex(ValueError, "blank|uniform"):
            prepare_image(digit_image(), crop_box=(0, 0, 20, 20))

    def test_low_contrast_speck_does_not_enlarge_ink_box(self):
        clean = digit_image()
        noisy = clean.copy()
        noisy.putpixel((5, 5), (230, 230, 230))
        np.testing.assert_array_equal(prepare_image(noisy), prepare_image(clean))

    def test_input_is_not_modified(self):
        source = digit_image()
        original = source.tobytes()
        prepare_image(source, (10, 10, 90, 110))
        self.assertEqual(source.tobytes(), original)

    def test_invalid_options_are_rejected(self):
        source = digit_image()
        for box in ((-1, 0, 50, 50), (0, 0, 101, 120), (10, 10, 5, 20),
                    (0.5, 0, 30, 30), (0, 0, 30), (0, 0, 1, 20), "abcd"):
            with self.subTest(box=box), self.assertRaises(ValueError):
                prepare_image(source, crop_box=box)
        with self.assertRaisesRegex(ValueError, "Polarity"):
            prepare_image(source, polarity="guess")


class LoadImageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)

    def test_byte_decoder_matches_path_decoder_and_preserves_captured_file(self):
        for format_name in ("PNG", "JPEG"):
            with self.subTest(format=format_name):
                source = digit_image().convert("RGBA" if format_name == "PNG" else "RGB")
                if format_name == "PNG":
                    source.putpixel((0, 0), (0, 0, 0, 0))
                exif = source.getexif()
                exif[274] = 6
                path = self.directory / f"capture.{format_name.lower()}"
                source.save(path, exif=exif)
                captured = path.read_bytes()
                expected = load_image(path)
                path.write_bytes(b"the file changed after its bytes were captured")
                actual = load_image_bytes(captured)
                self.assertEqual(actual.mode, "RGB")
                self.assertEqual(actual.size, expected.size)
                self.assertNotIn(274, actual.getexif())
                np.testing.assert_array_equal(np.asarray(actual), np.asarray(expected))

    def test_byte_decoder_rejects_invalid_and_unsupported_content(self):
        for data in (b"", b"not an image"):
            with self.subTest(data=data), self.assertRaisesRegex(ValueError, "readable"):
                load_image_bytes(data)
        unsupported = self.directory / "unsupported.gif"
        digit_image().save(unsupported, format="GIF")
        with self.assertRaisesRegex(ValueError, "Unsupported"):
            load_image_bytes(unsupported.read_bytes())
        with self.assertRaises(TypeError):
            load_image_bytes("not bytes")

    def test_transparency_composites_on_white_and_file_can_close(self):
        transparent = Image.new("RGBA", (100, 120), (0, 0, 0, 0))
        ImageDraw.Draw(transparent).line([(35, 25), (65, 25), (65, 57),
                                         (35, 57), (35, 90), (65, 90)],
                                        fill=(0, 0, 0, 255), width=8)
        path = self.directory / "digit.png"
        transparent.save(path)
        loaded = load_image(path)
        path.unlink()
        self.assertEqual(loaded.mode, "RGB")
        self.assertEqual(loaded.getpixel((0, 0)), (255, 255, 255))
        np.testing.assert_array_equal(prepare_image(loaded), prepare_image(digit_image()))

    def test_palette_transparency_composites_on_white(self):
        image = Image.new("P", (10, 10), 0)
        image.putpalette([0, 0, 0, 255, 0, 0] + [0] * 762)
        image.putpixel((5, 5), 1)
        path = self.directory / "palette.png"
        image.save(path, transparency=0)
        loaded = load_image(path)
        self.assertEqual(loaded.getpixel((0, 0)), (255, 255, 255))
        self.assertEqual(loaded.getpixel((5, 5)), (255, 0, 0))

    def test_exif_orientation_is_applied_and_removed(self):
        source = digit_image()
        exif = source.getexif()
        exif[274] = 6  # Stored pixels need a 90-degree clockwise rotation.
        path = self.directory / "oriented.jpg"
        source.save(path, exif=exif)
        with Image.open(path) as encoded:
            expected = ImageOps.exif_transpose(encoded).convert("RGB")
        actual = load_image(path)
        self.assertEqual(actual.size, (120, 100))
        self.assertNotIn(274, actual.getexif())
        np.testing.assert_array_equal(np.asarray(actual), np.asarray(expected))

    def test_decoded_format_not_extension_controls_loading(self):
        path = self.directory / "export.data"
        digit_image().save(path, format="PNG")
        self.assertEqual(load_image(path).size, (100, 120))
        unsupported = self.directory / "actually-gif.png"
        digit_image().save(unsupported, format="GIF")
        with self.assertRaisesRegex(ValueError, "Unsupported"):
            load_image(unsupported)

    def test_corrupt_missing_oversized_and_multiframe_inputs(self):
        corrupt = self.directory / "bad.png"
        corrupt.write_bytes(b"not an image")
        with self.assertRaisesRegex(ValueError, "readable"):
            load_image(corrupt)
        with self.assertRaises(FileNotFoundError):
            load_image(self.directory / "missing.png")
        oversized = self.directory / "too-wide.png"
        Image.new("L", (16_385, 2)).save(oversized)
        with self.assertRaisesRegex(ValueError, "too large"):
            load_image(oversized)
        multipage = self.directory / "pages.tiff"
        digit_image().save(multipage, save_all=True, append_images=[digit_image()])
        with self.assertRaisesRegex(ValueError, "single image"):
            load_image(multipage)


if __name__ == "__main__":
    unittest.main()
