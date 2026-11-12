"""Offline UART transport only. This module never runs a classifier."""
import struct
import time

PIXEL_COUNT = 784
BAUD = 115200
FPGA_CLOCK_HZ = 50_000_000
ERRORS = {1: "FPGA rejected the image checksum", 2: "FPGA timed out receiving the image",
          3: "FPGA detected a UART framing error"}


def make_request(pixels: bytes, sequence: int) -> bytes:
    if len(pixels) != PIXEL_COUNT:
        raise ValueError("The FPGA requires exactly 784 grayscale bytes (28 x 28).")
    if not 0 <= sequence <= 255:
        raise ValueError("Sequence must fit in one byte.")
    return b"\xaa\x55" + bytes([sequence]) + pixels + bytes([(sequence + sum(pixels)) & 255])


def parse_response(frame: bytes, sequence: int) -> dict:
    if len(frame) != 10 or frame[:2] != b"\xaa\x56":
        raise ValueError("Invalid FPGA reply. Check that the UART MNIST bitstream is programmed.")
    if frame[2] != sequence:
        raise ValueError("Stale FPGA reply: sequence number does not match this image.")
    if (sum(frame[2:9]) & 255) != frame[9]:
        raise ValueError("Corrupted FPGA reply: checksum mismatch.")
    if frame[3]:
        raise ValueError(ERRORS.get(frame[3], f"Unknown FPGA error {frame[3]}"))
    if frame[4] > 9:
        raise ValueError("FPGA returned an invalid digit.")
    cycles = struct.unpack("<I", frame[5:9])[0]
    return {"digit": frame[4], "sequence": sequence, "cycles": cycles,
            "inference_ms": cycles * 1000 / FPGA_CLOCK_HZ,
            "fpga_clock_hz": FPGA_CLOCK_HZ, "response_hex": frame.hex()}


def classify_on_fpga(port: str, pixels: bytes, sequence: int) -> dict:
    import serial
    packet = make_request(pixels, sequence)
    with serial.Serial(port, BAUD, timeout=0.1, write_timeout=2) as device:
        time.sleep(0.1)
        device.reset_input_buffer()
        if device.write(packet) != len(packet):
            raise IOError("Could not transmit the complete image.")
        device.flush()
        frame = bytearray()
        deadline = time.monotonic() + 3
        while len(frame) < 10 and time.monotonic() < deadline:
            frame.extend(device.read(10 - len(frame)))
    if len(frame) != 10:
        raise TimeoutError("No complete FPGA reply. Check board power, COM port, and bitstream.")
    return parse_response(bytes(frame), sequence)
