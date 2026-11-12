# Laptop image to Basys 3 seven-segment digit

Choose a handwritten-digit image on the laptop, click **Send to FPGA**, and the Basys 3 computes the prediction and displays 0–9 on its rightmost seven-segment digit. The Python uploader only prepares pixels, transfers bytes, and displays the board's reply. It contains no neural-network model or prediction fallback.

This is a Verilog, 28×28 grayscale, USB/UART adaptation of the MIT-licensed [ZakriyaParacha46/neural-net-on-fpga](https://github.com/ZakriyaParacha46/neural-net-on-fpga), pinned at `ff9af3f63a329d7ad5e6b93a1d7d21ff8d84686e`. Its original design uses a camera. This project uses its **unmodified inference engine, ROM modules, and pretrained weights** with a new UART image receiver and Basys 3 display wrapper. The upstream checkout and MIT license are preserved in `../repos/neural-net-on-fpga`.

## Open and use

1. Connect and power a Basys 3 using its micro-USB programming/UART connector and a USB **data** cable.
2. Open `../Open-Verilog-MNIST-Project.cmd`. The project is `build/mnist_basys3/mnist_basys3.xpr`, device `xc7a35tcpg236-1`, top `basys3_mnist_top`.
3. Run `../Program-Verilog-MNIST.cmd`, or program `build/mnist_basys3/mnist_basys3.runs/impl_1/basys3_mnist_top.bit` through Vivado Hardware Manager. The launcher requires exactly one connected programming target and one XC7A35T device. This uses FPGA SRAM; reprogram after removing power.
4. Open `../Open-Verilog-MNIST-Uploader.cmd`. This is the **28×28 Verilog uploader**; the earlier 16×16 SNN uploader uses a different protocol.
5. Click **Bundled MNIST examples**, select a PNG under `data/samples`, choose the board's COM port, and click **Send to FPGA**. The board's rightmost digit and the laptop's **Digit from FPGA** should agree.
6. For your own image, select one handwritten digit on a plain background. Exact-pixel mode preserves an existing 28×28 MNIST image. Turn it off for a larger image; the uploader crops, inverts bright backgrounds, fits the ink within 20×20, and centers it in 28×28. Check the bright-on-black preview before sending.

No network connection is used by the running design or uploader. Example images, the MNIST test split, trained weights, and Python dependencies are stored locally. Setup/source retrieval used the internet; inference does not.

Press the board's center button to reset. The seven-segment display stays blank until a valid completed inference, and clears on the next accepted image header. An invalid or incomplete image does not trigger inference. LED4 means a valid displayed prediction, LED5 means inference busy, LED6 means receiving, LED7 means a protocol error, LED[3:0] is the digit in binary, and LED[15:8] is the packet sequence number.

## Model and evidence

- Architecture: 784 → 32 → 10 MLP, signed INT8 weights, unsigned 8-bit pixels/hidden activations, signed 32-bit accumulators, ReLU and right shift of 10 after layer 1.
- Supplied parameters achieved **9,457/10,000 correct (94.57%)** on the original MNIST test split in the integer reference evaluation. These figures measure model accuracy, not physical-board performance or accuracy on new handwriting.
- Direct XSim verification of the unchanged core matched **20 predictions, 640 hidden activations, and 200 logits** against the integer reference, including repeated inputs without resets. Two of those first 20 MNIST cases are model misclassifications; a passing RTL comparison does not mean every image is recognized correctly.
- The UART/display testbench checks a real inference, corrupt checksum, incomplete frame timeout, malformed UART framing, trailing-byte drain, recovery, and button reset. Logs are in `reports/uart_simulation.log`.
- Core latency is 50,985 clocks; the UART wrapper reports 50,986 clocks including its observation cycle (about 1.020 ms at 50 MHz). The board's 100 MHz oscillator feeds an MMCM that generates the 50 MHz internal clock. Uploading 788 UART bytes takes about 68.4 ms at 115200 baud, in addition to host overhead.
- Host checks reject stale sequence numbers, corrupted replies, hardware error status, and invalid digits. No valid hardware response means no prediction on the laptop.
- Full model results: `verification/accuracy_report.json`; RTL results: `verification/rtl_reference_report.json`. The demo sample manifest records original dataset indices and labels; the filename/label is never sent to the board.

The final 50 MHz design was built, programmed onto the Basys 3, and passed a real USB/UART check of all ten bundled demonstration images (0–9) on COM8. Each FPGA reply reported 50,986 inference clocks. This small selected set is a hardware functional check, not a model accuracy estimate. The GUI also sent the sample seven and displayed the FPGA's returned digit 7. Visual confirmation of the physical display is recorded separately in `reports/build_status.json`.

Final routed timing passed: setup slack +7.550 ns, hold slack +0.110 ns, with zero failing timing endpoints or unconstrained internal endpoints. Utilization is 4,605 LUTs (22.14%), 858 flip-flops, one block-RAM tile, two DSP slices, and one MMCM. See `reports/timing.rpt`, `reports/utilization.rpt`, and `reports/drc.rpt` for the full reports, including advisory warnings.

The final post-synthesis native-MMCM simulation was stopped after the physical hardware test passed; it is accurately recorded as incomplete/superseded in `verification/post_synth/final_report.json`. The completed behavioral tests and independent integer-reference comparisons remain separate evidence.

## Rebuild and verify

Run from this directory in PowerShell:

```powershell
& 'C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat' -mode batch -source scripts/simulate.tcl
& 'C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat' -mode batch -source scripts/build.tcl
& '..\.venv\Scripts\python.exe' -m unittest discover -s verification -p test_host.py -v
& '.\verification\run_reference_sim.ps1'
```

With the board programmed, repeat the real hardware check using its current COM port:

```powershell
& '..\.venv\Scripts\python.exe' verification/hardware_smoke.py --port COM8
```

The build script validates setup and hold timing before enabling the programming launcher. The launcher checks that the generated bitstream still matches that validation.

`verification/integer_reference.py` is explicitly a verification utility. It evaluates the supplied model on the laptop for comparison; the normal `host/uploader.py` runtime neither imports nor executes it.

## UART packet format

115200 baud, 8 data bits, no parity, one stop bit. Send one image and wait for its reply before sending the next.

- Request: `AA 55 sequence`, **784 row-major grayscale bytes**, then `sum(sequence + pixels) mod 256`.
- Reply: `AA 56 sequence status digit cycles[0..3] checksum` (10 bytes). Cycle count is uint32 little-endian. Checksum sums bytes 2–8 modulo 256.
- Status: 0 success, 1 bad image checksum, 2 receive timeout, 3 UART framing error. Errors return digit `FF` and zero cycles.

Checksums detect ordinary transmission corruption, and sequence matching rejects stale replies. They are not authentication. Per-transfer logs under `runs/` save the actual input bytes, preview, reply and outcome.

## Repository review

No examined repository provided a verified immediate match for Basys 3 + Verilog + raw 28×28 UART + committed trained weights + seven-segment output. The selected source provides the trained Basys 3 inference core; this project supplies the UART adaptation and reproducible Vivado build.

- [AdityaDas10/Fpga-SNN-Inference](https://github.com/AdityaDas10/Fpga-SNN-Inference) has a matching UART/display architecture, but its four required pretrained weight/bias files are absent from the checked repository.
- [mqqz/mnist-fpga-nn](https://github.com/mqqz/mnist-fpga-nn) supplies a trained Verilog UART core and tests, but targets Tang Nano 9K; it was downloaded only for comparison and is not part of this design.
- [haydenthai/FPGA-Neural-Network-Inferencer](https://github.com/haydenthai/FPGA-Neural-Network-Inferencer) has an XPR, but the inspected synthesis branches tie memory reads to zero and leave UART TX idle, so it was not selected.
- The older local [SNN-FPGA](https://github.com/InduwaraGunasena/SNN-FPGA) project remains available separately. It uses VHDL and 16×16 inputs.

Pin assignments follow [Digilent's Basys 3 master XDC](https://github.com/Digilent/digilent-xdc/blob/master/Basys-3-Master.xdc).
