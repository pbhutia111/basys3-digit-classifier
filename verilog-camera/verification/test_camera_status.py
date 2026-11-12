"""Pure unit tests: no serial port is opened and no hardware is modified."""

import importlib.util
from pathlib import Path
import sys
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "host" / "camera_status.py"
SPEC = importlib.util.spec_from_file_location("camera_status", MODULE_PATH)
status = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = status
SPEC.loader.exec_module(status)


def wire_packet(sequence=1, flags=0x25, frames=5, config_index=23, min_y=12, max_y=240,
                protocol_version=0xC0):
    data = bytes([0xAA, protocol_version, sequence, flags, config_index,
                  frames & 255, frames >> 8, min_y, max_y])
    return data + bytes([sum(data[2:9]) & 255])


def packet(sequence, frames, flags=0x25):
    return status.PacketParser().feed(wire_packet(sequence, flags, frames))[0]


class ParserTests(unittest.TestCase):
    def test_partial_header_and_packet(self):
        parser = status.PacketParser()
        raw = wire_packet(frames=0x1234)
        self.assertEqual(parser.feed(b"noise" + raw[:1]), [])
        self.assertEqual(parser.feed(raw[1:8]), [])
        received = parser.feed(raw[8:])
        self.assertEqual(received[0].frames, 0x1234)
        self.assertEqual(received[0].min_y, 12)
        self.assertEqual(parser.noise_bytes, 5)

    def test_bad_checksum_resynchronizes(self):
        parser = status.PacketParser()
        corrupt = bytearray(wire_packet())
        corrupt[-1] ^= 1
        received = parser.feed(bytes(corrupt) + b"\x00\xaa" + wire_packet(sequence=2))
        self.assertEqual([item.sequence for item in received], [2])
        self.assertEqual(parser.checksum_errors, 1)

    def test_multiple_packets_and_header_inside_payload(self):
        parser = status.PacketParser()
        received = parser.feed(wire_packet(sequence=0xAA, flags=0x80, min_y=0xAA, max_y=0xC0)
                               + wire_packet(sequence=3))
        self.assertEqual(len(received), 2)
        self.assertEqual(received[0].min_y, 0xAA)
        self.assertEqual(received[0].max_y, 0xC0)

    def test_reserved_flag_rejected(self):
        parser = status.PacketParser()
        received = parser.feed(wire_packet(flags=0x65) + wire_packet(sequence=4))
        self.assertEqual([item.sequence for item in received], [4])
        self.assertEqual(parser.protocol_errors, 1)

    def test_c1_identity_error_has_readback_diagnostics(self):
        received = status.PacketParser().feed(wire_packet(
            flags=0x02, frames=0, config_index=0x0A, min_y=0xFF, max_y=0x76,
            protocol_version=0xC1))[0]
        self.assertEqual(received.protocol_version, 0xC1)
        self.assertTrue(received.has_config_diagnostic)
        diagnostic = received.diagnostic_dict()
        self.assertEqual(diagnostic["config_failure_register"], 0x0A)
        self.assertEqual(diagnostic["config_failure_readback"], 0xFF)
        self.assertEqual(diagnostic["config_failure_expected"], 0x76)
        self.assertIn("PID register 0x0A read 0xFF, expected 0x76", received.config_failure_message())

    def test_legacy_error_never_interprets_luma_as_readback(self):
        received = status.PacketParser().feed(wire_packet(
            flags=0x02, config_index=0x0A, min_y=0xFF, max_y=0x76))[0]
        self.assertEqual(received.protocol_version, 0xC0)
        self.assertFalse(received.has_config_diagnostic)
        self.assertNotIn("config_failure_readback", received.diagnostic_dict())
        self.assertEqual(received.config_failure_message(), "Camera identification/configuration failed.")
        self.assertEqual(status.Packet(1, 2, 0, 0, 0, 0).protocol_version, 0xC0)

    def test_mixed_versions_preserve_order_and_split_headers(self):
        parser = status.PacketParser()
        first = wire_packet(sequence=1, protocol_version=0xC1)
        second = wire_packet(sequence=2)
        third = wire_packet(sequence=3, protocol_version=0xC1, min_y=0xAA, max_y=0xC1)
        self.assertEqual(parser.feed(b"noise\xaa\xc2" + first[:1]), [])
        received = parser.feed(first[1:] + second + third[:1])
        self.assertEqual([(item.sequence, item.protocol_version) for item in received],
                         [(1, 0xC1), (2, 0xC0)])
        received = parser.feed(third[1:])
        self.assertEqual(len(received), 1)
        self.assertEqual((received[0].min_y, received[0].max_y), (0xAA, 0xC1))
        self.assertNotIn("config_failure_register", received[0].diagnostic_dict())
        self.assertEqual(parser.noise_bytes, 7)

    def test_c1_corruption_resynchronizes_to_either_version(self):
        parser = status.PacketParser()
        corrupt = bytearray(wire_packet(protocol_version=0xC1))
        corrupt[-1] ^= 1
        received = parser.feed(bytes(corrupt) + wire_packet(sequence=2)
                               + wire_packet(sequence=3, flags=0x65, protocol_version=0xC1)
                               + wire_packet(sequence=4, protocol_version=0xC1))
        self.assertEqual([item.sequence for item in received], [2, 4])
        self.assertEqual(parser.checksum_errors, 1)
        self.assertEqual(parser.protocol_errors, 1)


class TrackerTests(unittest.TestCase):
    def test_missing_stream(self):
        result = status.StatusTracker().summary(0)
        self.assertFalse(result["camera_responding"])
        self.assertFalse(result["valid_frame"])
        self.assertFalse(result["live_frames"])

    def test_one_old_frame_is_not_live(self):
        tracker = status.StatusTracker()
        tracker.observe(packet(1, 45), 0)
        result = tracker.summary(0.5)
        self.assertTrue(result["camera_responding"])
        self.assertTrue(result["valid_frame"])
        self.assertFalse(result["live_frames"])
        tracker.observe(packet(2, 45), 0.5)
        self.assertFalse(tracker.summary(1)["live_frames"])

    def test_fresh_progress_and_both_counter_wraps(self):
        tracker = status.StatusTracker()
        tracker.observe(packet(255, 65535), 0)
        tracker.observe(packet(0, 0), 0.5)
        result = tracker.summary(0.6)
        self.assertTrue(result["live_frames"])
        self.assertEqual(result["frames_advanced"], 1)
        self.assertEqual(result["counter_discontinuities"], 0)

    def test_duplicate_cannot_prove_progress_or_keep_stream_fresh(self):
        tracker = status.StatusTracker()
        tracker.observe(packet(4, 20), 0)
        self.assertFalse(tracker.observe(packet(4, 21), 0.5))
        result = tracker.summary(3)
        self.assertFalse(result["live_frames"])
        self.assertFalse(result["stream_fresh"])
        self.assertEqual(result["duplicate_packets"], 1)

    def test_stalled_counter_loses_live_status_even_with_packets(self):
        tracker = status.StatusTracker()
        tracker.observe(packet(1, 1), 0)
        tracker.observe(packet(2, 2), 0.5)
        self.assertTrue(tracker.summary(0.5)["live_frames"])
        tracker.observe(packet(3, 2), 2)
        tracker.observe(packet(4, 2), 3)
        result = tracker.summary(3)
        self.assertTrue(result["camera_responding"])
        self.assertTrue(result["valid_frame"])
        self.assertFalse(result["live_frames"])

    def test_hold_never_counts_as_live(self):
        tracker = status.StatusTracker()
        tracker.observe(packet(1, 1), 0)
        tracker.observe(packet(2, 2), 0.5)
        tracker.observe(packet(3, 3, flags=0xA5), 1)
        result = tracker.summary(1)
        self.assertTrue(result["camera_responding"])
        self.assertTrue(result["valid_frame"])
        self.assertFalse(result["live_frames"])
        self.assertIn("SW15", result["message"])

    def test_counter_restart_rebaselines_without_fake_progress(self):
        tracker = status.StatusTracker()
        tracker.observe(packet(100, 1000), 0)
        tracker.observe(packet(101, 1001), 0.5)
        tracker.observe(packet(0, 0), 1)
        self.assertFalse(tracker.summary(1)["live_frames"])
        self.assertEqual(tracker.summary(1)["counter_discontinuities"], 1)
        tracker.observe(packet(1, 1), 1.5)
        self.assertTrue(tracker.summary(1.5)["live_frames"])

    def test_frame_counter_backwards_is_not_a_large_advance(self):
        tracker = status.StatusTracker()
        tracker.observe(packet(1, 100), 0)
        tracker.observe(packet(2, 99), 0.5)
        result = tracker.summary(0.5)
        self.assertFalse(result["live_frames"])
        self.assertEqual(result["frames_advanced"], 0)

    def test_errors_override_progress(self):
        for flags in (0x27, 0x35):
            tracker = status.StatusTracker()
            tracker.observe(packet(1, 1), 0)
            tracker.observe(packet(2, 2), 0.5)
            tracker.observe(packet(3, 3, flags=flags), 1)
            self.assertFalse(tracker.summary(1)["live_frames"])
            self.assertFalse(tracker.summary(1)["valid_frame"])

    def test_c1_report_distinguishes_identity_and_configuration_failures(self):
        for address, actual, expected, description in (
            (0x0A, 0x00, 0x76, "Camera identity read failed: PID"),
            (0x0B, 0x70, 0x73, "Camera identity read failed: version"),
            (0x11, 0x01, 0x03, "Camera configuration readback failed"),
        ):
            with self.subTest(address=address):
                tracker = status.StatusTracker()
                tracker.observe(status.Packet(1, 0x02, address, 0, actual, expected, 0xC1), 0)
                result = tracker.summary(0.5)
                self.assertIn(description, result["message"])
                self.assertEqual(result["latest"]["config_failure_readback"], actual)
                self.assertFalse(result["camera_responding"])
                self.assertFalse(result["live_frames"])
                if address == 0x11:
                    self.assertIn("register mask", result["message"])

    def test_c1_normal_frames_still_require_and_report_progress(self):
        tracker = status.StatusTracker()
        tracker.observe(status.Packet(1, 0x25, 23, 8, 12, 240, 0xC1), 0)
        self.assertFalse(tracker.summary(0)["live_frames"])
        tracker.observe(status.Packet(2, 0x25, 23, 9, 13, 239, 0xC1), 0.5)
        result = tracker.summary(0.5)
        self.assertTrue(result["live_frames"])
        self.assertEqual(result["latest"]["min_y"], 13)
        self.assertNotIn("config_failure_register", result["latest"])


if __name__ == "__main__":
    unittest.main()
