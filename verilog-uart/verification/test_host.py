"""Transport/preparation checks; no real FPGA is claimed by these tests."""
import struct
import sys
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "host"))
from protocol import make_request, parse_response
from uploader import prepare_image


class HostTests(unittest.TestCase):
    def reply(self, sequence=42, status=0, digit=7):
        body = bytes([sequence, status, digit]) + struct.pack("<I", 50986)
        return b"\xaa\x56" + body + bytes([sum(body) & 255])

    def test_packet_contains_all_pixels_and_checksum(self):
        pixels = bytes(i % 256 for i in range(784))
        packet = make_request(pixels, 42)
        self.assertEqual(packet[:3], b"\xaa\x55\x2a")
        self.assertEqual(packet[3:-1], pixels)
        self.assertEqual(packet[-1], (42 + sum(pixels)) & 255)
        self.assertEqual(len(packet), 788)

    def test_short_input_rejected(self):
        with self.assertRaises(ValueError):
            make_request(bytes(783), 0)

    def test_hardware_response_decoded(self):
        result = parse_response(self.reply(), 42)
        self.assertEqual((result["digit"], result["cycles"]), (7, 50986))
        self.assertAlmostEqual(result["inference_ms"], 1.01972)

    def test_stale_sequence_rejected(self):
        with self.assertRaisesRegex(ValueError, "Stale"):
            parse_response(self.reply(), 41)

    def test_corrupted_response_rejected(self):
        reply = bytearray(self.reply())
        reply[4] ^= 1
        with self.assertRaisesRegex(ValueError, "checksum"):
            parse_response(bytes(reply), 42)

    def test_fpga_errors_never_become_predictions(self):
        for status in (1, 2, 3, 99):
            with self.subTest(status=status), self.assertRaises(ValueError):
                parse_response(self.reply(status=status, digit=255), 42)

    def test_invalid_digit_rejected(self):
        with self.assertRaisesRegex(ValueError, "invalid digit"):
            parse_response(self.reply(digit=12), 42)

    def test_mnist_exact_mode_preserves_bytes(self):
        image_paths = list((ROOT / "data" / "samples").glob("*.png"))
        self.assertEqual(len(image_paths), 10)
        for image_path in image_paths:
            raw_path = image_path.with_suffix(".raw")
            self.assertTrue(raw_path.exists())
            self.assertEqual(prepare_image(image_path, True).tobytes(), raw_path.read_bytes())


if __name__ == "__main__":
    unittest.main()
