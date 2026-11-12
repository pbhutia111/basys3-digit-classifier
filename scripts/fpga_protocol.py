"""Offline serial client for the unmodified InduwaraGunasena/SNN-FPGA design.

uart_frame_receiver256.vhd receives AA55, 256 pixel bytes and an 8-bit sum.
top_fpga.vhd returns ACK 06, digit, then a 24-bit big-endian cycle count.
The FPGA clock used by that counter is 25 MHz. The reply has no checksum or
request identifier, so this module does not claim end-to-end error detection.
It performs one request, never retries automatically and never predicts on CPU.
"""

import math
import sys
import time


PAYLOAD_SIZE = 256
BAUD_RATE = 115200
FPGA_CLOCK_HZ = 25_000_000
_IO_SLICE_SECONDS = 0.1
_SETTLE_SECONDS = 0.05


def _remaining(deadline: float, operation: str) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise RuntimeError(
            f"Timed out {operation}. Check the selected COM port and programmed "
            "SNN bitstream. A partial request may require reprogramming the FPGA "
            "before retrying; this firmware has no receive-frame timeout."
        )
    return remaining


def _write_all(transport, request: bytes, deadline: float) -> None:
    sent = 0
    while sent < len(request):
        operation = f"sending the FPGA request ({sent}/{len(request)} bytes)"
        transport.write_timeout = min(
            _IO_SLICE_SECONDS, _remaining(deadline, operation)
        )
        count = transport.write(request[sent:])
        if not isinstance(count, int) or isinstance(count, bool) or not (
            0 <= count <= len(request) - sent
        ):
            raise RuntimeError("The serial driver returned an invalid write count.")
        sent += count
        _remaining(deadline, f"sending the FPGA request ({sent}/{len(request)} bytes)")
        if count == 0:
            time.sleep(min(0.005, _remaining(deadline, operation)))


def _read_exact(transport, size: int, deadline: float, label: str) -> bytes:
    received = bytearray()
    while len(received) < size:
        operation = f"waiting for {label} ({len(received)}/{size} bytes)"
        transport.timeout = min(_IO_SLICE_SECONDS, _remaining(deadline, operation))
        fragment = transport.read(size - len(received))
        if not isinstance(fragment, bytes) or len(fragment) > size - len(received):
            raise RuntimeError("The serial driver returned an invalid read result.")
        received.extend(fragment)
        _remaining(deadline, f"waiting for {label} ({len(received)}/{size} bytes)")
    return bytes(received)


def classify(port: str, payload: bytes, timeout: float = 3.0) -> dict:
    """Return a digit received from the FPGA for exactly 256 input pixel bytes.

    The timeout is a shared deadline covering settling and all serial transfer
    after the OS opens the port. round_trip_ms measures first write to final
    response byte; it excludes opening and settling. response_hex includes ACK.
    request_hex/response_hex are raw bytes for logs, not confidence estimates.
    RuntimeError describes invalid input/protocol/timeouts; OSError describes
    connection/driver failures. The serial connection is closed on every path.
    """
    if not isinstance(port, str) or not port.strip():
        raise RuntimeError("Select the Basys 3 COM port before classifying.")
    port = port.strip()
    if not isinstance(payload, bytes) or len(payload) != PAYLOAD_SIZE:
        raise RuntimeError("The FPGA input must be exactly 256 bytes (16 by 16 pixels).")
    try:
        timeout_seconds = float(timeout)
    except (TypeError, ValueError, OverflowError) as exc:
        raise RuntimeError("Serial timeout must be a positive finite number of seconds.") from exc
    if isinstance(timeout, bool) or not math.isfinite(timeout_seconds) or timeout_seconds <= 0:
        raise RuntimeError("Serial timeout must be a positive finite number of seconds.")

    # No training libraries, network calls, or pyserial import are needed until
    # a user actually asks to send a prepared image to the board.
    try:
        import serial
    except ImportError as exc:
        raise RuntimeError(
            "pyserial is missing. Start this app with its prepared Python environment."
        ) from exc
    if not hasattr(serial, "Serial"):
        raise RuntimeError("The installed 'serial' module is not pyserial.")

    request = b"\xaa\x55" + payload + bytes([sum(payload) & 0xFF])
    transport = None
    try:
        transport = serial.Serial(
            port=port,
            baudrate=BAUD_RATE,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=min(_IO_SLICE_SECONDS, timeout_seconds),
            write_timeout=min(_IO_SLICE_SECONDS, timeout_seconds),
            xonxoff=False,
            rtscts=False,
            dsrdtr=False,
            inter_byte_timeout=None,
        )
        deadline = time.monotonic() + timeout_seconds
        time.sleep(min(_SETTLE_SECONDS, _remaining(deadline, "settling the serial port")))
        _remaining(deadline, "settling the serial port")
        # Discard stale bytes BEFORE sending. Never reset the receive buffer
        # after writing: the hardware may already have returned its ACK.
        transport.reset_input_buffer()
        _remaining(deadline, "preparing the serial port")
        started = time.monotonic()
        _write_all(transport, request, deadline)
        # Avoid flush(): it may block without a deadline. Reading the hardware
        # reply also establishes that the complete request reached the FPGA.
        ack = _read_exact(transport, 1, deadline, "FPGA ACK")
        if ack == b"\x15":
            raise RuntimeError("The FPGA rejected the request checksum (NAK 0x15).")
        if ack != b"\x06":
            raise RuntimeError(
                f"Unexpected FPGA ACK 0x{ack[0]:02X}; expected 0x06. "
                "Check that the SNN bitstream and correct COM port are selected."
            )
        result = _read_exact(transport, 4, deadline, "FPGA prediction and cycle count")
        finished = time.monotonic()
        prediction = result[0]
        cycles = int.from_bytes(result[1:], "big")
        if prediction > 9:
            raise RuntimeError(f"Invalid FPGA prediction {prediction}; expected a digit from 0 to 9.")
        if cycles == 0:
            raise RuntimeError("Invalid FPGA cycle count 0; inference cannot complete in zero cycles.")
        return {
            "prediction": prediction,
            "cycles": cycles,
            "hardware_ms": cycles * 1000.0 / FPGA_CLOCK_HZ,
            "round_trip_ms": (finished - started) * 1000.0,
            "request_hex": request.hex(),
            "response_hex": (ack + result).hex(),
        }
    except OSError as exc:
        raise OSError(
            f"Serial communication failed on {port}: {exc}. "
            "Check the USB cable and close other programs using this COM port. "
            "If transmission was interrupted, reprogram the FPGA before retrying."
        ) from exc
    finally:
        if transport is not None:
            failed = sys.exc_info()[0] is not None
            try:
                transport.close()
            except OSError as exc:
                if not failed:
                    raise OSError(f"Could not close serial port {port}: {exc}") from exc
