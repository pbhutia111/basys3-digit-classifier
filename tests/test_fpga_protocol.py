"""Protocol checks using a fake serial transport; never accesses live hardware."""

import importlib.util
from pathlib import Path
import sys
import types
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "fpga_protocol.py"
SPEC = importlib.util.spec_from_file_location("fpga_protocol_test_target", MODULE_PATH)
protocol = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(protocol)


class FakeClock:
    def __init__(self):
        self.now = 100.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class FakeSerial:
    def __init__(self, clock, replies, write_chunks=None, read_error=None, write_error=None):
        self.clock = clock
        self.replies = list(replies)
        self.write_chunks = list(write_chunks or [])
        self.read_error = read_error
        self.write_error = write_error
        self.written = bytearray()
        self.pending = [b"stale bytes"]
        self.events = []
        self.closed = False
        self.timeout = 0.1
        self.write_timeout = 0.1
        self.settings = None

    def open_factory(self, **kwargs):
        self.settings = kwargs
        return self

    def reset_input_buffer(self):
        self.events.append("clear")
        self.pending.clear()

    def write(self, data):
        self.events.append("write")
        if self.write_error:
            raise self.write_error
        count = self.write_chunks.pop(0) if self.write_chunks else len(data)
        count = min(count, len(data))
        self.written.extend(data[:count])
        self.clock.sleep(0.001)
        if len(self.written) == 259:
            # ACK can arrive immediately during the final write.
            self.pending.extend(self.replies)
        return count

    def read(self, size):
        self.events.append("read")
        if self.read_error:
            raise self.read_error
        if not self.pending:
            self.clock.sleep(self.timeout)
            return b""
        chunk = self.pending.pop(0)
        if not chunk:
            self.clock.sleep(self.timeout)
            return b""
        self.clock.sleep(0.001)
        if len(chunk) > size:
            self.pending.insert(0, chunk[size:])
        return chunk[:size]

    def close(self):
        self.events.append("close")
        self.closed = True


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.payload = bytes(range(256))

    def call(self, transport, **kwargs):
        fake_module = types.SimpleNamespace(
            Serial=transport.open_factory,
            EIGHTBITS=8,
            PARITY_NONE="N",
            STOPBITS_ONE=1,
        )
        with mock.patch.dict(sys.modules, {"serial": fake_module}), mock.patch.object(
            protocol, "time", self.clock
        ):
            return protocol.classify("COM7", self.payload, **kwargs)

    def test_fragmented_writes_reads_checksum_and_exact_result(self):
        transport = FakeSerial(
            self.clock, [b"\x06", b"\x07", b"\x01", b"\x02\x03"], [0, 1, 17, 63]
        )
        result = self.call(transport)
        expected_request = b"\xaa\x55" + self.payload + b"\x80"
        self.assertEqual(bytes(transport.written), expected_request)
        self.assertEqual(result["prediction"], 7)
        self.assertEqual(result["cycles"], 0x010203)
        self.assertAlmostEqual(result["hardware_ms"], 0x010203 / 25_000)
        self.assertGreater(result["round_trip_ms"], 0)
        self.assertEqual(result["request_hex"], expected_request.hex())
        self.assertEqual(result["response_hex"], "0607010203")
        self.assertTrue(transport.closed)

    def test_explicit_uart_settings_and_preserves_immediate_ack(self):
        transport = FakeSerial(self.clock, [b"\x06\x00\x00\x00\x01"])
        result = self.call(transport)
        self.assertEqual(result["prediction"], 0)
        self.assertEqual(transport.events[0], "clear")
        self.assertEqual(transport.events.count("clear"), 1)
        self.assertEqual(transport.events[-1], "close")
        for name, expected in {
            "port": "COM7", "baudrate": 115200, "bytesize": 8,
            "parity": "N", "stopbits": 1, "xonxoff": False,
            "rtscts": False, "dsrdtr": False, "inter_byte_timeout": None,
        }.items():
            self.assertEqual(transport.settings[name], expected)
        self.assertGreater(transport.settings["timeout"], 0)
        self.assertGreater(transport.settings["write_timeout"], 0)

    def test_nak_and_unexpected_ack_are_errors(self):
        for reply, message in [(b"\x15", "checksum"), (b"\x41", "Unexpected FPGA ACK")]:
            with self.subTest(reply=reply):
                transport = FakeSerial(self.clock, [reply])
                with self.assertRaisesRegex(RuntimeError, message):
                    self.call(transport)
                self.assertTrue(transport.closed)

    def test_missing_ack_times_out_and_closes(self):
        transport = FakeSerial(self.clock, [])
        with self.assertRaisesRegex(RuntimeError, r"FPGA ACK \(0/1 bytes\)"):
            self.call(transport, timeout=0.2)
        self.assertTrue(transport.closed)
        self.assertLessEqual(self.clock.now, 100.20001)

    def test_partial_response_uses_same_deadline(self):
        transport = FakeSerial(self.clock, [b"", b"\x06", b"\x08\x01"])
        with self.assertRaisesRegex(RuntimeError, r"cycle count \(2/4 bytes\)"):
            self.call(transport, timeout=0.2)
        self.assertTrue(transport.closed)
        self.assertLessEqual(self.clock.now, 100.20001)

    def test_invalid_prediction_and_zero_cycles(self):
        for reply, message in [
            (b"\x06\x0a\x00\x00\x01", "Invalid FPGA prediction"),
            (b"\x06\x09\x00\x00\x00", "cycle count 0"),
        ]:
            with self.subTest(reply=reply):
                transport = FakeSerial(self.clock, [reply])
                with self.assertRaisesRegex(RuntimeError, message):
                    self.call(transport)
                self.assertTrue(transport.closed)

    def test_serial_failures_close_transport(self):
        for failure in ["read_error", "write_error"]:
            with self.subTest(failure=failure):
                transport = FakeSerial(self.clock, [], **{failure: OSError("disconnected")})
                with self.assertRaisesRegex(OSError, "COM7.*disconnected"):
                    self.call(transport)
                self.assertTrue(transport.closed)

    def test_open_failure_is_actionable(self):
        transport = FakeSerial(self.clock, [])
        transport.open_factory = mock.Mock(side_effect=OSError("access denied"))
        with self.assertRaisesRegex(OSError, "COM7.*access denied"):
            self.call(transport)
        self.assertFalse(transport.closed)

    def test_validation_never_opens_a_serial_port(self):
        with mock.patch.dict(sys.modules, {"serial": None}):
            for bad_payload in [b"", b"x" * 255, b"x" * 257, [0] * 256]:
                with self.subTest(payload_type=type(bad_payload)):
                    with self.assertRaisesRegex(RuntimeError, "256 bytes"):
                        protocol.classify("COM7", bad_payload)
            with self.assertRaisesRegex(RuntimeError, "Select the Basys 3 COM port"):
                protocol.classify("  ", self.payload)
            for bad_timeout in [0, -1, float("inf"), float("nan"), True, "bad", None]:
                with self.subTest(timeout=bad_timeout):
                    with self.assertRaisesRegex(RuntimeError, "positive finite"):
                        protocol.classify("COM7", self.payload, bad_timeout)

    def test_pyserial_is_loaded_lazily_and_missing_dependency_is_clear(self):
        with mock.patch.dict(sys.modules, {"serial": None}):
            with self.assertRaisesRegex(RuntimeError, "pyserial is missing"):
                protocol.classify("COM7", self.payload)

    def test_write_stall_respects_deadline(self):
        transport = FakeSerial(self.clock, [], write_chunks=[0] * 1000)
        with self.assertRaisesRegex(RuntimeError, "sending the FPGA request"):
            self.call(transport, timeout=0.1)
        self.assertTrue(transport.closed)
        self.assertLess(self.clock.now, 100.102)
        self.assertEqual(bytes(transport.written), b"")


if __name__ == "__main__":
    unittest.main()
