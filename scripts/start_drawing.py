"""Choose a serial port and run the downloaded SNN-FPGA drawing application."""
from pathlib import Path
import argparse
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "repos" / "SNN-FPGA" / "Python scripts" / "input_interface.py"


def configured_source(port):
    source = SOURCE.read_text(encoding="utf-8-sig")
    source, count = re.subn(
        r'^SERIAL_PORT\s*=\s*"COM3"[^\r\n]*',
        lambda _: f"SERIAL_PORT = {port!r}", source, flags=re.MULTILINE,
    )
    if count != 1:
        raise RuntimeError("Upstream serial configuration changed; review input_interface.py.")
    compile(source, str(SOURCE), "exec")
    return source


def choose_port():
    import tkinter as tk
    from tkinter import ttk, messagebox
    from serial.tools.list_ports import comports

    root = tk.Tk()
    root.title("Basys 3 - select USB serial port")
    root.resizable(False, False)
    chosen = []
    ports = []
    ttk.Label(root, text="Connect the powered Basys 3 using its micro-USB port.\n"
              "Program the SNN bitstream before starting the drawing app.",
              padding=12).pack()
    selector = ttk.Combobox(root, state="readonly", width=65)
    selector.pack(padx=12, pady=5)

    def refresh():
        ports[:] = sorted(comports(), key=lambda item: item.device)
        selector["values"] = [f"{p.device} - {p.description}" for p in ports]
        selector.set("")
        if ports:
            selector.current(0)

    def start():
        index = selector.current()
        if index < 0:
            messagebox.showinfo("No port selected", "Select the Basys 3 UART port. If the list is empty, "
                                "check its power, USB data cable and installed cable drivers.")
            return
        chosen.append(ports[index].device)
        root.destroy()

    buttons = ttk.Frame(root, padding=12)
    buttons.pack()
    ttk.Button(buttons, text="Refresh ports", command=refresh).pack(side="left", padx=5)
    ttk.Button(buttons, text="Open drawing app", command=start).pack(side="left", padx=5)
    refresh()
    root.mainloop()
    return chosen[0] if chosen else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", help="Explicit Basys 3 port, e.g. COM4")
    parser.add_argument("--list", action="store_true", help="List serial ports without opening them")
    parser.add_argument("--check", action="store_true", help="Check dependencies and source without opening hardware")
    args = parser.parse_args()
    import tkinter
    import serial
    import numpy
    from PIL import Image
    from scipy.ndimage import center_of_mass, shift
    from serial.tools.list_ports import comports

    if args.check:
        configured_source("COM_TEST")
        print("Dependencies and upstream Python syntax OK. Hardware has not been tested.")
        return 0
    if args.list:
        ports = list(comports())
        for port in ports:
            print(f"{port.device}: {port.description}")
        if not ports:
            print("No serial ports detected.")
        return 0
    port = args.port or choose_port()
    if not port:
        return 0
    if port not in [item.device for item in comports()]:
        raise RuntimeError(f"Serial port {port!r} is no longer available. Reconnect the board and retry.")
    output = ROOT / "build" / "host" / "input_interface.py"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(configured_source(port), encoding="utf-8")
    return subprocess.call([sys.executable, str(output)], cwd=str(SOURCE.parent))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ImportError) as error:
        print(f"Unable to start: {error}", file=sys.stderr)
        raise SystemExit(1)
