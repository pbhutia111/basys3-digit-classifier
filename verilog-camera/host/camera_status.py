"""Read-only OV7670 bring-up status monitor; no image processing or uploads.

Firmware packets: AA C0/C1 sequence flags config_index frames_lo frames_hi
min_Y max_Y checksum. The checksum is sum(bytes[2:9]) modulo 256.
For C1 configuration errors only, config_index/min_Y/max_Y instead contain
the failing SCCB register, actual readback and expected byte respectively.
Exit status: 0 = recent live-frame evidence, 1 = no such evidence, 2 = setup/I/O
error. A held camera can be identified and have a valid frame without being live.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import time


HEADER = b"\xaa\xc0"
HEADERS = (HEADER, b"\xaa\xc1")
PACKET_SIZE = 10
STALE_SECONDS = 2.0


@dataclass(frozen=True)
class Packet:
    sequence: int
    flags: int
    config_index: int
    frames: int
    min_y: int
    max_y: int
    protocol_version: int = 0xC0

    @property
    def ready(self) -> bool:
        return bool(self.flags & 0x01)

    @property
    def config_error(self) -> bool:
        return bool(self.flags & 0x02)

    @property
    def frame_valid(self) -> bool:
        return bool(self.flags & 0x04)

    @property
    def capture_busy(self) -> bool:
        return bool(self.flags & 0x08)

    @property
    def frame_fault(self) -> bool:
        return bool(self.flags & 0x10)

    @property
    def pixels_seen(self) -> bool:
        return bool(self.flags & 0x20)

    @property
    def hold(self) -> bool:
        return bool(self.flags & 0x80)

    @property
    def has_config_diagnostic(self) -> bool:
        return self.protocol_version == 0xC1 and self.config_error

    def config_failure_message(self) -> str:
        if not self.has_config_diagnostic:
            return "Camera identification/configuration failed."
        details = (f"register 0x{self.config_index:02X} read 0x{self.min_y:02X}, "
                   f"expected 0x{self.max_y:02X}")
        if self.config_index in (0x0A, 0x0B):
            identity = "PID" if self.config_index == 0x0A else "version"
            return f"Camera identity read failed: {identity} {details}."
        return f"Camera configuration readback failed: {details} (comparison uses the register mask)."

    def diagnostic_dict(self) -> dict:
        result = asdict(self)
        result.update({name: getattr(self, name) for name in (
            "ready", "config_error", "frame_valid", "capture_busy",
            "frame_fault", "pixels_seen", "hold",
        )})
        if self.has_config_diagnostic:
            result.update(config_failure_register=self.config_index,
                          config_failure_readback=self.min_y,
                          config_failure_expected=self.max_y)
        return result


class PacketParser:
    """Incremental parser: retain partial headers and resync after bad packets."""

    def __init__(self) -> None:
        self.buffer = bytearray()
        self.checksum_errors = 0
        self.protocol_errors = 0
        self.noise_bytes = 0

    def feed(self, data: bytes) -> list[Packet]:
        self.buffer.extend(data)
        packets = []
        while True:
            matches = [index for header in HEADERS
                       if (index := self.buffer.find(header)) >= 0]
            index = min(matches, default=-1)
            if index < 0:
                keep = 1 if self.buffer.endswith(HEADER[:1]) else 0
                discard = len(self.buffer) - keep
                self.noise_bytes += discard
                del self.buffer[:discard]
                break
            if index:
                self.noise_bytes += index
                del self.buffer[:index]
            if len(self.buffer) < PACKET_SIZE:
                break
            raw = self.buffer[:PACKET_SIZE]
            if (sum(raw[2:9]) & 0xFF) != raw[9]:
                self.checksum_errors += 1
                self.noise_bytes += 1
                del self.buffer[0]
                continue
            if raw[3] & 0x40:  # Reserved flag must be zero in this protocol.
                self.protocol_errors += 1
                self.noise_bytes += 1
                del self.buffer[0]
                continue
            packets.append(Packet(raw[2], raw[3], raw[4], raw[5] | (raw[6] << 8),
                                  raw[7], raw[8], protocol_version=raw[1]))
            del self.buffer[:PACKET_SIZE]
        return packets


class StatusTracker:
    """Require sequence and frame-counter progress, not just a retained frame."""

    def __init__(self) -> None:
        self.latest: Packet | None = None
        self.last_fresh_time: float | None = None
        self.last_progress_time: float | None = None
        self.packets_received = 0
        self.fresh_packets = 0
        self.duplicate_packets = 0
        self.counter_discontinuities = 0
        self.frame_advance_events = 0
        self.frames_advanced = 0
        self.epoch_fresh_packets = 0

    @staticmethod
    def _can_be_live(packet: Packet) -> bool:
        return packet.ready and packet.frame_valid and not (
            packet.config_error or packet.frame_fault or packet.hold
        )

    def observe(self, packet: Packet, now: float) -> bool:
        """Return whether this packet established a new sequence observation."""
        self.packets_received += 1
        previous = self.latest
        if previous is None:
            self.epoch_fresh_packets = 1
        else:
            sequence_delta = (packet.sequence - previous.sequence) & 0xFF
            if sequence_delta == 0:
                self.duplicate_packets += 1
                return False
            frame_delta = (packet.frames - previous.frames) & 0xFFFF
            if sequence_delta >= 128 or frame_delta >= 32768:
                # Likely firmware restart or an out-of-order packet. Establish
                # a new baseline, never count this jump as captured frames.
                self.counter_discontinuities += 1
                self.epoch_fresh_packets = 1
                self.last_progress_time = None
            else:
                self.epoch_fresh_packets += 1
                if frame_delta and self._can_be_live(previous) and self._can_be_live(packet):
                    self.frame_advance_events += 1
                    self.frames_advanced += frame_delta
                    self.last_progress_time = now
            if not self._can_be_live(packet):
                self.last_progress_time = None
        self.latest = packet
        self.last_fresh_time = now
        self.fresh_packets += 1
        return True

    def summary(self, now: float) -> dict:
        packet = self.latest
        packet_age = None if self.last_fresh_time is None else max(0.0, now - self.last_fresh_time)
        progress_age = None if self.last_progress_time is None else max(0.0, now - self.last_progress_time)
        fresh = packet is not None and packet_age <= STALE_SECONDS
        responding = bool(fresh and packet.ready and not packet.config_error)
        valid_frame = bool(responding and packet.frame_valid and not packet.frame_fault)
        live = bool(valid_frame and not packet.hold and self.epoch_fresh_packets >= 2
                    and progress_age is not None and progress_age <= STALE_SECONDS)
        if packet is None:
            message = "No camera diagnostic stream received."
        elif not fresh:
            message = "Diagnostic stream stopped; the last packet is stale."
        elif packet.config_error:
            message = packet.config_failure_message()
        elif not packet.ready:
            message = "Waiting for verified camera identification and configuration."
        elif packet.frame_fault:
            message = "Camera identified; frame capture failed."
        elif packet.hold:
            message = "Camera identified; capture held by SW15."
        elif live:
            message = "Camera identified; valid frames are progressing."
        elif packet.frame_valid:
            message = "Camera identified; valid frame reported, but live frame progress is not yet verified."
        else:
            message = "Camera identified; waiting for a complete valid frame."
        return {
            "message": message,
            "camera_responding": responding,
            "valid_frame": valid_frame,
            "live_frames": live,
            "stream_fresh": bool(fresh),
            "packets_received": self.packets_received,
            "fresh_packets": self.fresh_packets,
            "duplicate_packets": self.duplicate_packets,
            "counter_discontinuities": self.counter_discontinuities,
            "frame_advance_events": self.frame_advance_events,
            "frames_advanced": self.frames_advanced,
            "last_packet_age_seconds": packet_age,
            "last_frame_progress_age_seconds": progress_age,
            "latest": None if packet is None else packet.diagnostic_dict(),
        }


def write_json(path: Path | None, diagnostic: dict) -> None:
    if path is not None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(diagnostic, indent=2) + "\n", encoding="utf-8")
        print(f"Diagnostic JSON: {path.resolve()}")


def positive_seconds(value: str) -> float:
    number = float(value)
    if not 0 < number < float("inf"):
        raise argparse.ArgumentTypeError("seconds must be a finite number greater than zero")
    return number


def main(argv: list[str] | None = None) -> int:
    arguments = argparse.ArgumentParser(description=__doc__)
    arguments.add_argument("--list", action="store_true", help="list serial ports without opening one")
    arguments.add_argument("--port", help="serial port, e.g. COM5; auto-select only when exactly one exists")
    arguments.add_argument("--seconds", type=positive_seconds, default=10.0, help="observation time (default: 10 seconds)")
    arguments.add_argument("--json", type=Path, metavar="PATH", help="write the diagnostic summary to this JSON file")
    args = arguments.parse_args(argv)
    diagnostic = {"schema_version": 1, "timestamp_utc": datetime.now(timezone.utc).isoformat(),
                  "baud": 115200, "requested_seconds": args.seconds}

    try:
        import serial
        from serial.tools import list_ports
    except ImportError:
        diagnostic["error"] = "pyserial is unavailable; run this with the project's .venv Python."
        print(diagnostic["error"], file=sys.stderr)
        write_json(args.json, diagnostic)
        return 2

    ports = sorted(list_ports.comports(), key=lambda item: item.device)
    diagnostic["ports"] = [{"device": port.device, "description": port.description} for port in ports]
    if args.list or (not args.port and len(ports) != 1):
        print("Available serial ports:")
        for port in ports:
            print(f"  {port.device}: {port.description}")
        if not ports:
            print("  None. Connect and power the Basys 3 using its USB programming/UART connector.")
        if args.list:
            write_json(args.json, diagnostic)
            return 0
        diagnostic["error"] = ("No serial port is available." if not ports else
                               "Multiple serial ports are available; choose the Basys 3 port with --port COMx.")
        print(diagnostic["error"], file=sys.stderr)
        write_json(args.json, diagnostic)
        return 2

    port_name = args.port if args.port else ports[0].device
    diagnostic["port"] = port_name
    parser = PacketParser()
    tracker = StatusTracker()
    started = time.monotonic()
    interrupted = False
    io_error = None
    print(f"Reading {port_name} at 115200 8N1 for {args.seconds:g} seconds. No commands or images are sent.")
    try:
        with serial.Serial(port=port_name, baudrate=115200, bytesize=serial.EIGHTBITS,
                           parity=serial.PARITY_NONE, stopbits=serial.STOPBITS_ONE,
                           timeout=0.1, xonxoff=False, rtscts=False, dsrdtr=False) as connection:
            connection.reset_input_buffer()
            started = time.monotonic()
            while time.monotonic() - started < args.seconds:
                data = connection.read(min(connection.in_waiting or 1, 4096))
                now = time.monotonic()
                for packet in parser.feed(data):
                    if tracker.observe(packet, now):
                        status = tracker.summary(now)
                        payload = ("" if packet.has_config_diagnostic else
                                   f"Y={packet.min_y}..{packet.max_y} cfg={packet.config_index} ")
                        print(f"{status['message']}  seq={packet.sequence} frames={packet.frames} "
                              f"{payload}flags=0x{packet.flags:02X}", flush=True)
    except KeyboardInterrupt:
        interrupted = True
        print("\nObservation stopped.")
    except (serial.SerialException, OSError) as exc:
        io_error = f"Cannot read {port_name}: {exc}"
        print(io_error, file=sys.stderr)

    now = time.monotonic()
    status = tracker.summary(now)
    diagnostic.update(status)
    diagnostic.update({"elapsed_seconds": now - started, "interrupted": interrupted,
                       "checksum_errors": parser.checksum_errors,
                       "protocol_errors": parser.protocol_errors,
                       "discarded_noise_bytes": parser.noise_bytes,
                       "partial_packet_bytes": len(parser.buffer)})
    if io_error:
        diagnostic["error"] = io_error
        # A disconnected port cannot provide evidence of a currently live camera.
        diagnostic.update(camera_responding=False, valid_frame=False, live_frames=False, stream_fresh=False)
    print("\nResult: " + (io_error or status["message"]))
    print(f"Camera responding: {'yes' if diagnostic['camera_responding'] else 'no'}; "
          f"valid frame: {'yes' if diagnostic['valid_frame'] else 'no'}; "
          f"live frames verified: {'yes' if diagnostic['live_frames'] else 'no'}.")
    if tracker.latest is None and not io_error:
        print("Check that the camera-test bitstream is programmed and this is the Basys 3 UART port.")
    elif tracker.latest and tracker.latest.hold:
        print("Move SW15 down to resume captures, then run the check again.")
    if parser.checksum_errors or parser.protocol_errors:
        print(f"Rejected packets: {parser.checksum_errors} checksum errors, {parser.protocol_errors} protocol errors.")
    write_json(args.json, diagnostic)
    return 2 if io_error else (0 if diagnostic["live_frames"] else 1)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except OSError as exc:
        print(f"Cannot write diagnostic JSON: {exc}", file=sys.stderr)
        raise SystemExit(2)
