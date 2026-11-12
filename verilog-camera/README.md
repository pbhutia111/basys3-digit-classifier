# Basys 3 + OV7670 camera test

This first-stage build checks the camera connection. It reads the OV7670's identity over SCCB, writes and reads back its configuration, then receives complete 160 x 120 grayscale frames. It reports status on the Basys 3 and through USB. It does not run digit classification.

## Start here

1. Wire the camera with **Basys 3 power off**, using the signal-name table below. Verify your physical module's pin labels and I/O voltage first. The Amazon listing image does not establish the physical header order or voltage translation circuitry.
2. Leave all Basys 3 switches down. Connect the Basys 3's micro-USB programming connector to the laptop with a data cable, and turn it on.
3. Run [Program-Camera-Test.cmd](../Program-Camera-Test.cmd). This loads the separately built camera test into volatile FPGA memory; power loss removes it.
4. Wait about three seconds. The rightmost seven-segment digit should change from **P** to **C**, then **F**. C may pass too quickly to notice.
5. Run [Check-Camera-Test.cmd](../Check-Camera-Test.cmd) to see the camera status and count of incoming frames on the laptop. No image upload is needed.
6. Optionally connect a VGA monitor. A grayscale camera preview appears on the left after a complete frame arrives. The green box marks the region intended for later digit classification. The right side stays black in this camera-only build.

If the camera was connected after startup, press the **center button** to restart detection. Connect or rearrange wires only with power off. The camera does not plug directly into one Pmod connector: use individual jumper wires and any required voltage interface.

## Wiring by signal name

This is the current recommended wiring. FPGA signal assignments are programmed into `constraints/basys3_camera_test.xdc`; PWDN is now connected directly to ground as described below. Pmod numbers are connector pin numbers, not FPGA package pin numbers. Match the camera's printed signal names; do not assume the order of its 18-pin header.

| Camera signal | Basys 3 connector pin | FPGA package pin | Direction |
|---|---|---|---|
| D0 | JB1 | A14 | Camera to FPGA |
| D1 | JB2 | A16 | Camera to FPGA |
| D2 | JB3 | B15 | Camera to FPGA |
| D3 | JB4 | B16 | Camera to FPGA |
| D4 | JB7 | A15 | Camera to FPGA |
| D5 | JB8 | A17 | Camera to FPGA |
| D6 | JB9 | C15 | Camera to FPGA |
| D7 | JB10 | C16 | Camera to FPGA |
| PCLK / PLK | JA3 | J2 | Camera to FPGA |
| HREF / HS | JA2 | L2 | Camera to FPGA |
| VSYNC / VS | JA1 | J1 | Camera to FPGA |
| XCLK / XLK | JA4 | G2 | FPGA to camera, 25 MHz |
| SIOC / SCL | JA7 | H1 | Open-drain control clock |
| SIOD / SDA | JA8 | K2 | Open-drain bidirectional data |
| RESET / RESET_N | JA9 | H2 | FPGA to camera, active low |
| PWDN | JA11 (GND) | Ground | Camera input held low directly |
| 3V3 power input | JA6 | Power | Only for a module rated for 3.3 V input |
| GND | JA5 | Ground | Shared ground |

The mapping was corrected on November 2, 2026 to match the user's existing wiring. The previous build assigned data to JA and controls to JB; it sent XCLK to the user's D3 wire and could not identify the camera. Both camera constraint files now use the signal assignments above, except that `cam_pwdn` remains assigned to JA10/G3 and driven low but is **unused in the current wiring**. Connect camera PWDN only to verified ground at JA11, leaving it disconnected from JA10.

RESET/RET and PWDN were initially unconnected. The user subsequently connected them to the assigned FPGA pins, but the retest still failed. A later meter reading on the PWDN connection intended for JA10 was 2.5 V, contrary to the programmed constant-low output; this did not establish whether the cause was pin identification, the jumper, the ground reference, or another electrical fault. With power off, the user disconnected PWDN from JA10 and moved it to verified Basys ground, then confirmed 0 V after restoring power. Camera operation after this change still requires a fresh programmed-board test. The user also confirmed jumper wires only, without external SCCB pull-ups. RESET must be high and PWDN low for normal operation. Do not connect a pin simultaneously to an FPGA output and a fixed supply.

Keep signal wires short. Pmod pins 5/11 are ground and 6/12 are 3.3 V. Never apply 5 V to a Pmod signal or a camera pin marked 3V3. These connector assignments match [Digilent's master constraints](https://github.com/Digilent/digilent-xdc/blob/master/Basys-3-Master.xdc) and [Basys 3 manual](https://digilent.com/reference/_media/basys3:basys3_rm.pdf).

### Module supply and signal voltage are different

A camera module with a 3.3 V supply input can still run its sensor I/O at 2.8 V. The [OmniVision v1.4 datasheet](https://web.mit.edu/6.111/www/f2015/tools/OV7670_2006.pdf) specifies sensor I/O supply up to 3.0 V and an absolute input limit of I/O supply + 0.5 V. The exact HiLetgo module schematic has not been verified here.

For a module with unshifted 2.8 V sensor I/O, translate FPGA-driven XCLK and RESET from 3.3 V to the sensor level using an interface rated for the 25 MHz clock. PWDN is held at ground. Camera outputs at 2.8 V meet the FPGA's LVCMOS33 input-high threshold. If the module already includes suitable signal translation, follow its documented interface instead.

SIOC and SIOD are driven **low or high-impedance**, never actively high. They need pull-ups to the camera's actual I/O supply, not automatically the 3.3 V Pmod supply. Check for existing pull-ups; 4.7 kOhm is a starting value for external ones at this build's 50 kHz SCCB rate, subject to bus capacitance. FPGA internal pull-ups are intentionally disabled. Confirm the actual module before powering the wiring.

## What the board shows

| Rightmost display | Meaning | Next check |
|---|---|---|
| P | Reset/configuration in progress | Wait about three seconds |
| C | Camera identity and configuration verified; waiting for a complete frame | Check PCLK/HREF/VSYNC/data wiring if it persists |
| F | A complete 160 x 120 frame was received | Confirm the USB frame count keeps increasing and the preview responds to movement |
| E | Camera identity or configuration readback failed | Check power, ground, XCLK, RESET and SCCB wiring/pull-ups; then press center |
| d | Invalid frame geometry or capture timeout | Check PCLK/HREF/VSYNC/data wiring and the camera configuration |

LED0: camera configured. LED1: valid frame available. LED2: capture busy. LED3: pixel bytes seen during the latest capture. LED4: configuration error. LED5: frame error. LED6: hold enabled. LED7: status heartbeat. LED15..8: low eight bits of the complete-frame counter.

**SW15 up** holds capture after the current request finishes, retaining the last preview. Leave it down to test live reception. Other switches are unused in this build. A previously received frame alone does not prove a currently live camera; the laptop checker distinguishes a progressing frame counter from a held or stale frame.

The normal capture timeout is two seconds. If video stops, the valid-frame flag and preview clear after the timeout. Capture retries automatically. SCCB initialization errors require the center-button reset.

## Build and verification

### Temporary meter wiring test

`scripts/build_camera_wiring_test.tcl` builds a separate bitstream and `scripts/program_camera_wiring_test.tcl` loads it. This test holds camera RESET low, keeps XCLK running, and lets SW0 pull SCL/JA7 low and SW1 pull SDA/JA8 low independently. A down switch releases its line; neither line is ever driven high by the FPGA. LED0/LED1 indicate the respective low-drive commands, and LED15 blinks. UART is idle and camera capture is deliberately stopped during this test.

With the board still powered, use DC volts, black probe on camera GND, red probe on the camera's labeled SCL/SDA pins. Compare both-switches-down readings against SW0-up-only (SCL should become approximately 0 V) and SW1-up-only (SDA should become approximately 0 V). Record both pins in all three states; high idle readings alone do not prove adequate pull-ups. Return switches down afterward. Reload the normal camera program with `Program-Camera-Test.cmd` before testing identification again.

The wiring-test bench passed independent drive/release checks with and without modeled external pull-ups. Its routed build passed setup (+4.464 ns), hold (+0.131 ns) and DRC checks. Reports are in `reports/camera_wiring_test/`, with simulation evidence in `verification/wiring_test/`.

### Normal camera build and latest result

The user clarified that RET/PWDN had been swapped, then confirmed the full corrected table (RET to JA9, PWDN to JA11/GND). The C1 build was reloaded successfully. COM8 still reported PID `0x0A = 0xFF` (expected `0x76`) and zero frames over ten seconds. See `reports/camera_test/full_wiring_confirmed_status.json`. The temporary meter test described above is now loaded to verify which camera pins respond to the FPGA outputs.

- Open the diagnostic project: [Open-Camera-Test-Project.cmd](../Open-Camera-Test-Project.cmd).
- Rebuild and check routed timing: [Build-Camera-Test.cmd](../Build-Camera-Test.cmd).
- Project: `build/camera_test_basys3/camera_test_basys3.xpr`.
- Top: `basys3_camera_test_top`.
- Bitstream: `build/camera_test_basys3/camera_test_basys3.runs/impl_1/basys3_camera_test_top.bit`.
- Reports: `reports/camera_test/`.
- Simulation runner: `scripts/test.ps1`.

The current C1 diagnostic build was rebuilt and programmed into the connected Basys 3. Routed setup slack is +5.008 ns and hold slack +0.081 ns, with zero unconstrained internal endpoints and zero DRC violations. All five RTL benches and 19 host-checker tests passed.

Before the PWDN ground correction, camera identification still failed after the user connected RESET/PWDN. Enhanced C1 telemetry identified the exact failure: PID register `0x0A` returned `0xFF`, expected `0x76`, and zero frames were received. PWDN has since been moved to verified ground and measured at 0 V; that voltage measurement alone does not establish camera detection or frame reception. No external SCCB pull-ups are fitted according to the user; on-module pull-ups and sensor I/O voltage remain unverified. The earlier readback was consistent with a missing sensor response but did not establish a unique electrical cause.

See `reports/camera_test/build_status.json` for current evidence and `reports/camera_test/readback_status.json` for the C1 COM8 check before the PWDN ground correction. Earlier checks are retained as `wiring_before_status.json`, `wiring_after_status.json`, and `controls_connected_status.json`. Original artifacts are retained in `before_wiring_fix/` and `before_readback_diagnostics/` under the same report directory. After a power cycle, reload the camera-test bitstream before collecting a new status check.

The programming script requires a bitstream that passed the build's timing checks and exactly one connected XC7A35T programming target. Simulation and routed timing cannot establish physical camera operation; actual detection, frame geometry, focus and image quality must be checked with your connected module.

The camera runs from a 25 MHz MMCM-generated XCLK. CLKRC/PLL/scaling settings keep PCLK no faster than 6.25 MHz, and the complete data/control bundle is oversampled through matched registers at 50 MHz. No Pmod signal is used as an FPGA fabric clock. Do not increase PCLK without redesigning and revalidating capture timing. Digital simulations do not model metastability or cable signal quality.

Frames are accepted only after a new VSYNC, exactly 120 rows of 320 YUYV bytes, and a closing VSYNC. Luma is the first byte of each pair. Partial frames and timeouts cannot count as success. VGA uses 25 MHz pixels (approximately 59.52 Hz); raw preview can tear while a new frame is being written.

USB telemetry is 115200 baud, 8N1, approximately every half-second. Packet: `AA C1 sequence flags config_index frames_lo frames_hi min_Y max_Y checksum`. Checksum is the sum of bytes 2 through 8 modulo 256. Flags: bit0 configured, bit1 configuration error, bit2 valid frame, bit3 capture busy, bit4 frame fault, bit5 pixels seen, bit6 reserved, bit7 hold. Normally the intensity range belongs to the last complete frame. On a configuration error, the index/min/max bytes instead report the failed SCCB register, actual readback, and expected byte. Configuration comparisons apply the register-specific masks in `ov7670_config.v`; identity reads compare all bits. The host also accepts old `AA C0` packets but does not interpret their error bytes as register diagnostics. These are diagnostic values, not image classification.

The existing [USB digit classifier](../verilog-uart/README.md) remains available. Camera classification RTL is retained here as work in progress for the next stage; use the **Camera-Test** launchers for this first test.
