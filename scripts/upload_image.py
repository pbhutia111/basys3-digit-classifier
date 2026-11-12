"""Local image preprocessing and USB UART client. All classification runs on FPGA."""
from datetime import datetime, timezone
from pathlib import Path
import argparse
import hashlib
import json
import queue
import threading
import uuid
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from PIL import Image, ImageTk
from serial.tools.list_ports import comports

from image_pipeline import load_image_bytes, prepare_image
from fpga_protocol import classify

ROOT = Path(__file__).resolve().parents[1]


def save_run(metadata, payload, result=None, error=None):
    folder = ROOT / "runs" / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
                             + "-" + uuid.uuid4().hex[:8])
    folder.mkdir(parents=True, exist_ok=False)
    (folder / "payload.bin").write_bytes(payload)
    Image.frombytes("L", (16, 16), payload).save(folder / "fpga_input.png")
    record = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "source": metadata,
        "payload_sha256": hashlib.sha256(payload).hexdigest(),
        "payload_bytes": len(payload),
        "inference_location": "external FPGA over USB UART; no host classifier",
        "network_status": "not measured; this application makes no network requests",
        "status": "response_received" if result is not None else "failed",
        "result": result,
        "error": error,
    }
    (folder / "result.json").write_text(json.dumps(record, indent=2), encoding="utf-8")
    return folder


class Uploader:
    def __init__(self, root):
        self.root = root
        self.image = None
        self.source_path = None
        self.source_hash = None
        self.crop = None
        self.prepared = None
        self.busy = False
        self.ports = []
        self.events = queue.Queue()
        self.drag_start = None
        self.selection = None
        self.display_box = None
        self.image_photo = None
        self.preview_photo = None
        root.title("Basys 3 - Offline Image Uploader")
        root.minsize(920, 720)
        root.protocol("WM_DELETE_WINDOW", self.close)
        style = ttk.Style(root)
        style.configure("TLabel", font=("Segoe UI", 10))
        style.configure("TButton", font=("Segoe UI", 10), padding=5)
        frame = ttk.Frame(root, padding=20)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="Goodnotes → Basys 3", font=("Segoe UI", 23, "bold")).pack(anchor="w")
        ttk.Label(frame, text="Open a saved digit image. Send pixels over USB. Read the FPGA prediction.").pack(anchor="w", pady=(2, 12))
        file_row = ttk.Frame(frame)
        file_row.pack(fill="x", pady=(0, 12))
        self.open_button = ttk.Button(file_row, text="Choose image…", command=self.choose_file)
        self.open_button.pack(side="left")
        self.filename = tk.StringVar(value="PNG, JPG, BMP, TIFF or WebP · one digit on plain paper")
        ttk.Label(file_row, textvariable=self.filename, wraplength=650).pack(side="left", padx=12)

        panels = ttk.Frame(frame)
        panels.pack(fill="x")
        left = ttk.LabelFrame(panels, text="1. Crop your digit", padding=10)
        left.pack(side="left", fill="both", expand=True, padx=(0, 12))
        self.canvas = tk.Canvas(left, width=480, height=340, bg="#e9eef5", highlightthickness=0)
        self.canvas.pack()
        self.canvas.create_text(240, 170, text="Choose an image to begin", fill="#526173", font=("Segoe UI", 14))
        self.canvas.bind("<ButtonPress-1>", self.start_crop)
        self.canvas.bind("<B1-Motion>", self.drag_crop)
        self.canvas.bind("<ButtonRelease-1>", self.finish_crop)
        ttk.Label(left, text="Drag around ONE digit, leaving a small blank border.").pack(anchor="w", pady=(8, 3))
        self.reset_button = ttk.Button(left, text="Use whole image", command=self.reset_crop)
        self.reset_button.pack(anchor="w")
        right = ttk.LabelFrame(panels, text="2. Pixels sent to FPGA", padding=10)
        right.pack(side="left", fill="both", expand=True)
        self.preview = tk.Canvas(right, width=240, height=240, bg="#101826", highlightthickness=0)
        self.preview.pack(pady=(8, 5))
        ttk.Label(right, text="16 × 16 grayscale · 256 bytes").pack()
        ttk.Label(right, text="Ink / background").pack(anchor="w", pady=(15, 2))
        self.polarity = ttk.Combobox(right, values=("Auto", "Dark ink on light paper", "Light ink on dark paper"), state="readonly", width=29)
        self.polarity.current(0)
        self.polarity.pack(fill="x")
        self.polarity.bind("<<ComboboxSelected>>", lambda _: self.reprocess())

        controls = ttk.Frame(frame)
        controls.pack(fill="x", pady=(16, 12))
        ttk.Label(controls, text="Basys 3 USB port").pack(side="left")
        self.port = ttk.Combobox(controls, state="readonly", width=35)
        self.port.pack(side="left", padx=8)
        self.port.bind("<<ComboboxSelected>>", self.port_changed)
        self.refresh_button = ttk.Button(controls, text="Refresh", command=self.refresh_ports)
        self.refresh_button.pack(side="left")
        self.send_button = ttk.Button(controls, text="Send to FPGA", command=self.send, state="disabled")
        self.send_button.pack(side="right")
        self.result = tk.StringVar(value="FPGA prediction: —")
        ttk.Label(frame, textvariable=self.result, font=("Segoe UI", 25, "bold")).pack(anchor="w")
        self.status = tk.StringVar(value="Choose an image. Program the SNN design before sending.")
        ttk.Label(frame, textvariable=self.status, wraplength=860).pack(anchor="w", pady=(4, 4))
        self.log_status = tk.StringVar(value="")
        ttk.Label(frame, textvariable=self.log_status, wraplength=860, foreground="#526173").pack(anchor="w")
        ttk.Label(frame, text="Laptop: crop, resize and transfer only. FPGA: neural-network inference.\n"
                  "No internet is needed to use this app after setup.", foreground="#526173").pack(anchor="w", pady=(12, 0))
        self.refresh_ports()
        self.poll_id = root.after(60, self.poll)

    def choose_file(self):
        path = filedialog.askopenfilename(title="Choose a saved Goodnotes digit", filetypes=[
            ("Image files", "*.png *.jpg *.jpeg *.bmp *.tif *.tiff *.webp"), ("All files", "*.*")])
        if path:
            self.load_path(path)

    def load_path(self, path):
        self.clear_result()
        self.prepared = None
        self.update_controls()
        try:
            # One snapshot feeds both decoding and the evidence hash.
            with Path(path).open("rb") as source:
                captured = source.read(64 * 1024 * 1024 + 1)
            if len(captured) > 64 * 1024 * 1024:
                raise ValueError("This file exceeds 64 MB. Export a smaller PNG or JPEG.")
            loaded = load_image_bytes(captured)
            source_hash = hashlib.sha256(captured).hexdigest()
        except (OSError, ValueError) as error:
            self.image = None
            self.source_path = None
            self.source_hash = None
            self.crop = None
            self.drag_start = None
            self.selection = None
            self.canvas.delete("all")
            self.preview.delete("all")
            self.filename.set("No image loaded")
            self.status.set(f"Cannot prepare the selected image: {error}")
            messagebox.showerror("Cannot open image", str(error))
            return
        self.image = loaded
        self.source_path = Path(path).resolve()
        self.source_hash = source_hash
        self.filename.set(self.source_path.name)
        self.crop = None
        self.drag_start = None
        self.draw_image()
        self.reprocess()

    def draw_image(self):
        self.canvas.delete("all")
        scale = min(480 / self.image.width, 340 / self.image.height)
        size = (max(1, round(self.image.width * scale)), max(1, round(self.image.height * scale)))
        scaled = self.image.resize(size, Image.Resampling.NEAREST if scale > 1 else Image.Resampling.LANCZOS)
        x = (480 - scaled.width) // 2
        y = (340 - scaled.height) // 2
        self.display_box = (x, y, x + scaled.width, y + scaled.height)
        self.image_photo = ImageTk.PhotoImage(scaled)
        self.canvas.create_image(x, y, image=self.image_photo, anchor="nw")
        self.selection = None

    def clipped_point(self, event):
        x0, y0, x1, y1 = self.display_box
        return max(x0, min(x1, event.x)), max(y0, min(y1, event.y))

    def start_crop(self, event):
        if self.image is None or self.busy:
            return
        self.drag_start = self.clipped_point(event)
        self.clear_result()
        self.status.set("Release the crop selection to prepare the new input.")
        self.update_controls()
        if self.selection:
            self.canvas.delete(self.selection)
        x, y = self.drag_start
        self.selection = self.canvas.create_rectangle(x, y, x, y, outline="#0875e1", width=3)

    def drag_crop(self, event):
        if self.drag_start is not None and not self.busy:
            self.canvas.coords(self.selection, *self.drag_start, *self.clipped_point(event))

    def finish_crop(self, event):
        if self.drag_start is None or self.busy:
            return
        x, y = self.clipped_point(event)
        sx, sy = self.drag_start
        self.drag_start = None
        if abs(x - sx) < 4 or abs(y - sy) < 4:
            self.reset_crop()
            return
        self.canvas.coords(self.selection, min(x, sx), min(y, sy), max(x, sx), max(y, sy))
        dx0, dy0, dx1, dy1 = self.display_box
        self.crop = (
            round((min(x, sx) - dx0) * self.image.width / (dx1 - dx0)),
            round((min(y, sy) - dy0) * self.image.height / (dy1 - dy0)),
            round((max(x, sx) - dx0) * self.image.width / (dx1 - dx0)),
            round((max(y, sy) - dy0) * self.image.height / (dy1 - dy0)),
        )
        self.reprocess()

    def reset_crop(self):
        if self.image is None or self.busy:
            return
        self.crop = None
        if self.selection:
            self.canvas.delete(self.selection)
            self.selection = None
        self.reprocess()

    def clear_result(self):
        self.result.set("FPGA prediction: —")
        self.log_status.set("")

    def reprocess(self):
        self.clear_result()
        self.prepared = None
        self.preview.delete("all")
        if self.image is not None:
            try:
                self.prepared = prepare_image(self.image, self.crop, ("auto", "dark", "light")[self.polarity.current()])
                pixels = Image.fromarray(self.prepared).resize((240, 240), Image.Resampling.NEAREST)
                self.preview_photo = ImageTk.PhotoImage(pixels)
                self.preview.create_image(0, 0, image=self.preview_photo, anchor="nw")
                self.status.set("Image prepared. Check the preview, select the board's USB port, then send.")
            except ValueError as error:
                self.status.set(str(error))
        self.update_controls()

    def refresh_ports(self):
        old = self.port.get()
        self.ports = sorted(comports(), key=lambda p: p.device)
        names = [f"{p.device} — {p.description}" for p in self.ports]
        self.port["values"] = names
        self.port.set(old if old in names else "")
        if not self.port.get() and len(names) == 1:
            self.port.current(0)
        if not names:
            self.port.set("No serial ports detected")
        self.clear_result()
        self.update_controls()

    def port_changed(self, _):
        self.clear_result()
        self.update_controls()

    def update_controls(self):
        allowed = self.prepared is not None and self.port.current() >= 0 and not self.busy and self.drag_start is None
        self.send_button.configure(state="normal" if allowed else "disabled")

    def set_busy(self, value):
        self.busy = value
        for widget in (self.open_button, self.reset_button, self.refresh_button):
            widget.configure(state="disabled" if value else "normal")
        for widget in (self.port, self.polarity):
            widget.configure(state="disabled" if value else "readonly")
        self.update_controls()

    def send(self):
        index = self.port.current()
        if self.busy or self.prepared is None or index < 0 or self.drag_start is not None:
            return
        payload = self.prepared.tobytes(order="C")
        selected_port = self.ports[index].device
        metadata = {"image_path": str(self.source_path), "image_sha256": self.source_hash,
                    "crop_box": self.crop, "polarity": ("auto", "dark", "light")[self.polarity.current()],
                    "port": selected_port, "baud_rate": 115200}
        self.clear_result()
        self.set_busy(True)
        self.status.set("Sending pixels over USB and waiting for the FPGA…")

        def work():
            response, error, saved, log_error = None, None, None, None
            try:
                response = classify(selected_port, payload)
            except Exception as exc:
                error = str(exc)
            try:
                saved = save_run(metadata, payload, response, error)
            except OSError as exc:
                log_error = str(exc)
            self.events.put((response, error, saved, log_error))

        threading.Thread(target=work, daemon=True).start()

    def poll(self):
        try:
            response, error, saved, log_error = self.events.get_nowait()
        except queue.Empty:
            pass
        else:
            self.set_busy(False)
            if error:
                self.result.set("FPGA prediction: —")
                self.status.set(f"No valid FPGA result. {error}")
            else:
                self.result.set(f"FPGA prediction: {response['prediction']}")
                self.status.set(f"USB response received. FPGA reported {response['cycles']:,} cycles "
                                f"({response['hardware_ms']:.3f} ms at 25 MHz). "
                                f"USB round trip: {response['round_trip_ms']:.1f} ms.")
            self.log_status.set(f"Saved locally: {saved}" if saved else f"Could not save transfer log: {log_error}")
        self.poll_id = self.root.after(60, self.poll)

    def close(self):
        if self.busy:
            messagebox.showinfo("Transfer in progress", "Wait for the USB transfer to finish before closing.")
            return
        self.root.after_cancel(self.poll_id)
        self.root.destroy()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, help="Open a local image at startup")
    parser.add_argument("--smoke-test", action="store_true", help="Initialize GUI, validate optional image, then exit without hardware")
    args = parser.parse_args()
    root = tk.Tk()
    if args.smoke_test:
        root.withdraw()
    app = Uploader(root)
    if args.image:
        app.load_path(args.image)
    if args.smoke_test:
        root.update_idletasks()
        if args.image and app.prepared is None:
            raise SystemExit("Image preprocessing failed")
        assert app.result.get() == "FPGA prediction: —"
        app.close()
        print("GUI initialized; no serial port opened and no prediction generated.")
    else:
        root.mainloop()


if __name__ == "__main__":
    main()
