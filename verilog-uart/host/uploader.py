"""Select a local digit image and send 784 pixels to the FPGA. No CPU inference."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import threading
import time
import tkinter as tk
from tkinter import filedialog, ttk

from PIL import Image, ImageOps, ImageTk
from serial.tools import list_ports
from protocol import classify_on_fpga

ROOT = Path(__file__).resolve().parents[1]


def prepare_image(path, preserve=False):
    path = Path(path)
    if path.suffix.lower() == ".raw":
        pixels = path.read_bytes()
        if len(pixels) != 784:
            raise ValueError("Raw input must contain 784 bytes.")
        return Image.frombytes("L", (28, 28), pixels)
    with Image.open(path) as source:
        rgba = ImageOps.exif_transpose(source).convert("RGBA")
        background = Image.new("RGBA", rgba.size, "white")
        background.alpha_composite(rgba)
        image = background.convert("L")
    if preserve:
        if image.size != (28, 28):
            raise ValueError("Exact-pixel mode requires a 28 x 28 image. Uncheck it for a photo or drawing.")
        return image
    border = [image.getpixel(p) for p in [(0, 0), (image.width-1, 0),
               (0, image.height-1), (image.width-1, image.height-1)]]
    if sorted(border)[2] > 127:
        image = ImageOps.invert(image)
    image = ImageOps.autocontrast(image)
    bbox = image.point(lambda p: 255 if p > 25 else 0).getbbox()
    if bbox is None:
        raise ValueError("This image looks blank. Select a single handwritten digit.")
    ink = image.crop(bbox)
    ink.thumbnail((20, 20), Image.Resampling.LANCZOS)
    canvas = Image.new("L", (28, 28), 0)
    canvas.paste(ink, ((28-ink.width)//2, (28-ink.height)//2))
    return canvas


def send_and_record(port, path, image):
    pixels = image.tobytes()
    sequence = time.time_ns() & 255
    run = ROOT / "runs" / datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    run.mkdir(parents=True)
    (run / "payload.raw").write_bytes(pixels)
    image.save(run / "preview.png")
    record = {"source": str(Path(path).resolve()), "port": port, "sequence": sequence,
              "payload_sha256": hashlib.sha256(pixels).hexdigest(), "pixels": 784}
    try:
        result = classify_on_fpga(port, pixels, sequence)
        record.update(result, success=True)
        return record
    except Exception as error:
        record.update(success=False, error=str(error))
        raise
    finally:
        (run / "result.json").write_text(json.dumps(record, indent=2), encoding="utf-8")


class Uploader:
    def __init__(self, root):
        self.root = root
        root.title("Basys 3 - Offline MNIST (28 x 28 Verilog)")
        root.geometry("650x650")
        root.minsize(650, 650)
        self.path = None
        self.image = None
        self.sending = False
        self.exact = tk.BooleanVar(value=True)
        self.status = tk.StringVar(value="Choose a local image or a bundled MNIST example.")
        self.result = tk.StringVar(value="Digit from FPGA: —")
        box = ttk.Frame(root, padding=18)
        box.pack(fill="both", expand=True)
        ttk.Label(box, text="Offline handwritten digit classifier", font=("Segoe UI", 18, "bold")).pack(anchor="w")
        ttk.Label(box, text="Python prepares and sends pixels. The Basys 3 computes the digit.").pack(anchor="w", pady=(4, 12))
        files = ttk.Frame(box)
        files.pack(fill="x")
        self.choose_button = ttk.Button(files, text="Choose image…", command=self.choose)
        self.choose_button.pack(side="left")
        self.samples_button = ttk.Button(files, text="Bundled MNIST examples…", command=self.choose_sample)
        self.samples_button.pack(side="left", padx=8)
        self.exact_button = ttk.Checkbutton(box, text="Preserve exact 28 × 28 pixels (MNIST images)", variable=self.exact, command=self.reprocess)
        self.exact_button.pack(anchor="w", pady=8)
        self.preview = ttk.Label(box)
        self.preview.pack(pady=4)
        self.filename = ttk.Label(box, text="No image selected")
        self.filename.pack()
        row = ttk.Frame(box)
        row.pack(fill="x", pady=14)
        ttk.Label(row, text="USB / COM port:").pack(side="left")
        self.port = ttk.Combobox(row, width=26, state="readonly")
        self.port.pack(side="left", padx=8)
        ttk.Button(row, text="Refresh", command=self.refresh_ports).pack(side="left")
        self.send_button = ttk.Button(box, text="Send to FPGA", command=self.send)
        self.send_button.pack(fill="x")
        ttk.Label(box, textvariable=self.result, font=("Segoe UI", 22, "bold")).pack(pady=15)
        ttk.Label(box, textvariable=self.status, wraplength=600).pack(anchor="w")
        self.refresh_ports()
        root.protocol("WM_DELETE_WINDOW", self.close)

    def refresh_ports(self):
        ports = [p.device for p in list_ports.comports()]
        self.port["values"] = ports
        if ports and self.port.get() not in ports:
            self.port.set(ports[0])
        elif not ports:
            self.port.set("")
            self.status.set("No COM port found. Connect and power the Basys 3 using a USB data cable.")

    def choose(self):
        path = filedialog.askopenfilename(filetypes=[("Digit image", "*.png *.jpg *.jpeg *.bmp *.raw"), ("All files", "*.*")])
        if path:
            self.path = Path(path)
            self.exact.set(self.path.suffix.lower() == ".raw")
            if not self.exact.get():
                try:
                    with Image.open(self.path) as image:
                        self.exact.set(image.size == (28, 28))
                except Exception as error:
                    self.image = None
                    self.result.set("Digit from FPGA: —")
                    self.status.set(str(error))
                    return
            self.reprocess()

    def choose_sample(self):
        path = filedialog.askopenfilename(initialdir=ROOT / "data" / "samples", filetypes=[("MNIST images", "*.png *.raw"), ("All files", "*.*")])
        if path:
            self.path = Path(path)
            self.exact.set(True)
            self.reprocess()

    def reprocess(self):
        self.result.set("Digit from FPGA: —")
        if not self.path:
            return
        try:
            self.image = prepare_image(self.path, self.exact.get())
            self.photo = ImageTk.PhotoImage(self.image.resize((196, 196), Image.Resampling.NEAREST))
            self.preview.configure(image=self.photo)
            self.filename.configure(text=self.path.name)
            self.status.set("Ready: 784 pixel bytes. No prediction has been computed on the laptop.")
        except Exception as error:
            self.image = None
            self.status.set(str(error))

    def send(self):
        if self.sending:
            return
        self.result.set("Digit from FPGA: —")
        if self.image is None or not self.port.get():
            self.status.set("Choose an image and a COM port first.")
            return
        path, image, port = self.path, self.image.copy(), self.port.get()
        self.sending = True
        for control in (self.send_button, self.choose_button, self.samples_button, self.exact_button):
            control.state(["disabled"])
        self.status.set("Sending pixels and waiting for the FPGA…")
        def worker():
            try:
                result = send_and_record(port, path, image)
                self.root.after(0, lambda: self.finish(result, None))
            except Exception as error:
                message = str(error)
                self.root.after(0, lambda: self.finish(None, message))
        threading.Thread(target=worker, daemon=True).start()

    def finish(self, result, error):
        self.sending = False
        for control in (self.send_button, self.choose_button, self.samples_button, self.exact_button):
            control.state(["!disabled"])
        if error:
            self.status.set(error)
        else:
            self.result.set(f"Digit from FPGA: {result['digit']}")
            self.status.set(f"FPGA reply verified. Inference: {result['cycles']:,} cycles / {result['inference_ms']:.3f} ms. Log saved locally.")

    def close(self):
        if self.sending:
            self.status.set("Wait for the current transfer to finish before closing.")
        else:
            self.root.destroy()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", type=Path)
    parser.add_argument("--port")
    parser.add_argument("--exact", action="store_true")
    parser.add_argument("--prepare-only", type=Path, help="Write 784 input bytes without connecting to a board")
    args = parser.parse_args()
    if args.image:
        image = prepare_image(args.image, args.exact)
        if args.prepare_only:
            args.prepare_only.write_bytes(image.tobytes())
        elif args.port:
            print(json.dumps(send_and_record(args.port, args.image, image), indent=2))
        else:
            parser.error("Use --port or --prepare-only with --image.")
    else:
        root = tk.Tk()
        Uploader(root)
        root.mainloop()


if __name__ == "__main__":
    main()
