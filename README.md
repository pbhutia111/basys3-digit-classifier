# Basys 3 handwritten digit classifier

Classify a handwritten digit on a Digilent Basys 3 FPGA and show the prediction
on its seven-segment display. The laptop prepares a 28 x 28 grayscale image and
sends its pixels over USB UART; the neural network runs in FPGA logic.

The current Verilog design uses a 784 -> 32 -> 10 integer MLP. It adapts the
inference engine and pretrained weights from
[Zakriya Paracha's neural-net-on-fpga](https://github.com/ZakriyaParacha46/neural-net-on-fpga)
with a UART receiver, display wrapper, Python uploader, and verification tools.
See [third-party credits](THIRD_PARTY.md) for source and dataset attribution.

## Get started on Windows

Install Git, Python 3.11, and Vivado with Artix-7 device support and cable drivers.
The recorded build used Vivado 2026.1. Clone with submodules to obtain the exact
inference source and trained weights:

```powershell
git clone --recurse-submodules https://github.com/pbhutia111/basys3-digit-classifier.git
cd basys3-digit-classifier
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-runtime.txt -r verilog-uart/requirements-runtime.txt
```

If you cloned without submodules, run `git submodule update --init --recursive`.

1. Open `Open-Verilog-MNIST-Project.cmd` to create the Vivado project.
2. Build from PowerShell (adjust the Vivado installation path if needed):

   ```powershell
   & 'C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat' -mode batch -source verilog-uart/scripts/build.tcl
   ```

3. Connect and power a Basys 3 with a USB data cable, then run `Program-Verilog-MNIST.cmd`.
4. Run `Open-Verilog-MNIST-Uploader.cmd`, select a bundled sample or your own image,
   choose the board's serial port, and click **Send to FPGA**.

The `.cmd` Vivado launchers use `C:\AMDDesignTools\2026.1\Vivado`; adjust that
path for a different installation. Project files, bitstreams, run logs, and
reports are generated locally. Build before programming a fresh clone.

## Project contents

| Directory | Purpose |
| --- | --- |
| [verilog-uart](verilog-uart/README.md) | Current 28 x 28 classifier, uploader, RTL, and tests |
| [verilog-camera](verilog-camera/README.md) | Experimental OV7670 connection diagnostics; camera classification is not established |
| `scripts/` and `tests/` | Earlier 16 x 16 VHDL uploader and host tests |
| `repos/neural-net-on-fpga` | Pinned upstream Verilog inference core and pretrained weights |
| `repos/SNN-FPGA` | Pinned upstream source for the earlier VHDL workflow |

The recorded integer-reference result is **94.57% on 10,000 MNIST test images**.
This is model evaluation, not a physical-board accuracy estimate. The recorded
hardware smoke test passed ten selected demonstration digits. See the
[current design documentation](verilog-uart/README.md) for validation details
and the limits of those checks. Historical machine-specific build reports and
personal uploads are kept out of this repository.

Run the host checks without programming hardware:

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s verilog-uart/verification -p test_host.py -v
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
.\.venv\Scripts\python.exe -m unittest discover -s verilog-camera/verification -p test_camera_status.py -v
```

The earlier VHDL notes below describe a separate 16 x 16 design and protocol.
Use the Verilog launchers above for the current classifier.

## Earlier setup notes

**Camera connection test:** see [verilog-camera/README.md](verilog-camera/README.md). Use `Program-Camera-Test.cmd` and `Check-Camera-Test.cmd` to verify the OV7670 before moving on to camera classification.

**Current 28 × 28 Verilog project:** see [verilog-uart/README.md](verilog-uart/README.md). Open `Open-Verilog-MNIST-Project.cmd` for Vivado and `Open-Verilog-MNIST-Uploader.cmd` to select a laptop image and send its pixels to the FPGA. `Program-Verilog-MNIST.cmd` programs a connected Basys 3 after a successful build. The FPGA performs classification and drives the rightmost seven-segment digit.

The earlier 16 × 16 VHDL project is preserved below and uses a different uploader/protocol.

# Earlier Goodnotes image → USB → Basys 3 inference

Save a picture of one handwritten digit from Goodnotes on this laptop, select it in the uploader, and send its pixels over the Basys 3 micro-USB connection. The laptop crops, resizes and transfers the image. The trained neural network runs in FPGA logic, returns its prediction over USB UART, and drives the board's seven-segment display.

The uploader uses local files and USB only. It has no network requests, CPU classifier or fallback prediction. Internet is unnecessary during the demo once setup is complete. No mouse or camera connects to the FPGA.

## Ready and remaining

- [SNN-FPGA](https://github.com/InduwaraGunasena/SNN-FPGA), including VHDL, trained weights and Basys 3 constraints, is downloaded under `repos/SNN-FPGA`.
- **Open-Image-Uploader.cmd** launches the saved-image app with cropping, ink/background selection, a 16 × 16 preview, COM-port selection and local transfer logs.
- Runtime dependencies are installed; versions are in `requirements-runtime.txt`. The local Python environment also uses scientific packages already installed on this computer.
- **Open-SNN-Project.cmd** creates/opens the Vivado project for `xc7a35tcpg236-1` once installation finishes.

Still required: synthesize and implement the FPGA design, validate timing, generate its bitstream, program the connected board, and test real Goodnotes digits. Host-software checks do not establish FPGA accuracy or hardware operation. During preparation Vivado was still installing and no serial ports were detected.

## First hardware setup

1. Finish Vivado installation with Artix-7 support and cable drivers. Connect and power Basys 3 with a micro-USB **data** cable.
2. Open `Open-SNN-Project.cmd`. It creates `build/snn_basys3/snn_basys3.xpr`, design top `top_fpga`, without automatically synthesizing or programming.
3. Run synthesis and inspect utilization/clocks, then implementation. The upstream 25 MHz counter-derived clock has no explicit generated-clock constraint in its XDC. Review synthesized clock routing/buffering and validate timing constraints before accepting timing or generating a bitstream. The original RTL/XDC are preserved for review.
4. In Hardware Manager, connect to the board and program the generated `top_fpga.bit` from the implementation run. SRAM programming is lost at power-off; reprogram after a power cycle.

## Your saved-image workflow

1. Write **one digit** on plain paper in Goodnotes. Save a screenshot, exported image or photograph to the laptop as PNG/JPG. A clean screenshot/export usually gives cleaner pixels than a photograph. Convert HEIC/PDF to PNG/JPG first.
2. Launch **Open-Image-Uploader.cmd**, click **Choose image**, and select the file.
3. Drag around the digit, leaving a small blank border. Exclude app controls, other handwriting, grid lines and page edges. This is a single-digit classifier, not whole-page OCR; it does not remove page grids or correct perspective.
4. Check the pixel preview: your stroke should appear bright on black. Choose the ink/background option manually if Auto gets it wrong.
5. Select the board's COM port and click **Send to FPGA**. The app shows a prediction only after a valid USB reply. Check the board's seven-segment digit too. Accuracy on your Goodnotes handwriting remains to be measured.

Preprocessing crops the ink, fits it proportionally within 12 × 12 pixels, centers it within 16 × 16, and quantizes it to 256 bytes. It does not classify the digit. The source filename is not transmitted to the FPGA.

## Offline demonstration

Finish all downloads first. Then disconnect Wi-Fi and Ethernet on the laptop, show that network state in your recording, and run the workflow. Show the input, preview, board display and returned result. As an additional check, unplug the board and attempt a fresh transfer: the app should report a connection/response error with no new prediction. Reconnect and reprogram if unplugging also removed power.

Each attempted transfer saves `runs/<timestamp-id>/payload.bin`, `fpga_input.png`, and `result.json`. The JSON records source/payload hashes, crop settings, port, success/error, and the successful raw UART response and cycle count. These logs document transfers; they do not independently certify Windows network state or which bitstream is programmed. The network display demonstrates offline use; board behavior, USB dependency and reviewed source demonstrate FPGA inference.

## Source and checks

Upstream snapshot: [`ff4218e089740087a16321b5b74d75354e3f140b`](https://github.com/InduwaraGunasena/SNN-FPGA/tree/ff4218e089740087a16321b5b74d75354e3f140b). The model uses 256 inputs, 64 hidden neurons and 10 outputs. Trained weights are in the HDL `packages/weights_pkg.vhd`; initial use does not require retraining.

Local additions: `scripts/image_pipeline.py` (preprocessing), `scripts/fpga_protocol.py` (USB UART), and `scripts/upload_image.py` (GUI/logging). None imports or runs the training notebook or a host classifier.

UART is 115200 baud, 8N1. Request: `AA 55`, 256 pixels, sum modulo 256. Success reply: `06`, digit, then a three-byte big-endian cycle count, assuming the upstream 25 MHz clock. Missing/partial replies, checksum rejection and invalid results produce errors. The upstream reply has no sequence number or response checksum; logs are debugging records rather than authenticated hardware evidence.

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
.\.venv\Scripts\python.exe .\scripts\upload_image.py --smoke-test --image ".\repos\SNN-FPGA\Python scripts\sample MNIST data\7.png"
```

These check preprocessing, UART with a fake test transport, and GUI initialization; they do not access a live board or measure hardware accuracy. Upstream VHDL benches are included in the project but are not a complete self-checking suite.

Preparation check: all 30 host tests passed, including stale-result prevention and disconnected-board error handling. GUI initialization and the processed sample-digit preview were also checked. No hardware inference has been run here yet.

The previously downloaded mouse/VGA Painter repository and original `Open-Drawing-App.cmd` remain available as research alternatives. They are not needed for your workflow: use **Open-Image-Uploader.cmd**.

Reference: [official Digilent pin constraints](https://github.com/Digilent/digilent-xdc/blob/master/Basys-3-Master.xdc) and [Basys 3 manual](https://www.amd.com/content/dam/amd/en/documents/university/aup-boards/XUPBasys3/documentation/Basys3_rm_8_22_2014.pdf).
