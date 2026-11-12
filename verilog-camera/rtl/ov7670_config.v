`timescale 1ns/1ps
// OV7670 non-FIFO module, 25 MHz external XCLK, 50 MHz system clock.
// Register meanings: OmniVision OV7670 datasheet v1.4, especially COM3,
// COM14, CLKRC, DBLV, TSLB and SCALING_*; SCCB uses 0x42/0x43 wire IDs.
// Primary datasheet mirror: https://people.ece.cornell.edu/land/courses/
// ece4760/FinalProjects/f2021/jfw225_aei23_dsb298/jfw225_aei23_dsb298/OV7670_2006.pdf
// QQVGA window values also cross-checked against Arduino_OV767X's sensor
// register settings (src/utility/ov7670.c); this SCCB engine is original RTL.
// The device's active-low RESET pin is not the reset polarity printed in
// some early preliminary datasheets. SIOD is open-drain; fit an external
// pull-up to the camera I/O supply on each SCCB line. The ninth TX bit is
// a SCCB don't-care. SIOC is open-drain too; no clock stretching is supported.
// Presence and configuration are established by reads, NOT by assuming ACK.
module ov7670_config #(
    parameter integer CLK_HZ = 50000000,
    parameter integer SCCB_QUARTER_CYCLES = CLK_HZ/200000, // 50 kHz @ 50 MHz
    parameter integer RESET_CYCLES = CLK_HZ/100,     // 10 ms
    parameter integer SETTLE_CYCLES = 3*CLK_HZ/100,  // 30 ms
    parameter integer SOFT_RESET_CYCLES = CLK_HZ/100,
    parameter integer FRAME_SETTLE_CYCLES = CLK_HZ+CLK_HZ/2 // 1.5 s
)(
    input wire clk,
    input wire reset,
    inout wire siod,
    output wire sioc,
    output reg cam_reset_n,
    output wire cam_pwdn,
    output reg ready,
    output reg error,
    output wire [7:0] debug_index,
    output wire [7:0] debug_register,
    output wire [7:0] debug_readback,
    output wire [7:0] debug_expected
);
    assign cam_pwdn = 1'b0;
    reg [7:0] index;
    assign debug_index = index;
    reg [31:0] delay_count;
    reg [3:0] state;
    reg bus_start, bus_read;
    reg [7:0] bus_addr, bus_data;
    wire bus_done, bus_busy;
    wire [7:0] bus_result;
    ov7670_sccb #(.QUARTER_CYCLES(SCCB_QUARTER_CYCLES)) u_sccb (
        .clk(clk), .reset(reset), .start(bus_start), .read_op(bus_read),
        .reg_addr(bus_addr), .write_data(bus_data), .read_data(bus_result),
        .busy(bus_busy), .done(bus_done), .sioc(sioc), .siod(siod)
    );
    // QQVGA from the VGA sensor window: 4:1 horizontal/vertical DCW.
    // CLKRC /4, PLL bypass and COM14 PCLK /4 keep the bus slower than
    // 6.25 MHz, including blanking. Do not speed this up without revisiting
    // the capture sampler and its external timing assumptions.
    function [15:0] configuration;
        input [7:0] n;
        begin
            case (n)
                0: configuration = 16'h1103; // internal clock /4
                1: configuration = 16'h6b0a; // DBLV: PLL bypass
                2: configuration = 16'h3a04; // Y first; disable auto-window BEFORE mode/window
                3: configuration = 16'h1200; // VGA base, YUV output
                4: configuration = 16'h0c04; // COM3: DCW enabled
                5: configuration = 16'h3e1a; // DCW PCLK /4, manual scaling
                6: configuration = 16'h703a; // horizontal scale, no pattern
                7: configuration = 16'h7135; // vertical scale, no pattern
                8: configuration = 16'h7222; // horizontal/vertical /4
                9: configuration = 16'h73f2; // scaling PCLK /4
                10: configuration = 16'ha202; // PCLK delay
                11: configuration = 16'h1716; // horizontal window aligned to /4 DCW
                12: configuration = 16'h1804;
                13: configuration = 16'h32a4;
                14: configuration = 16'h1902; // vertical window
                15: configuration = 16'h1a7a;
                16: configuration = 16'h030a;
                17: configuration = 16'h1500; // normal PCLK/VSYNC polarity
                18: configuration = 16'h3d88; // COM13[0]=0: Y U Y V
                19: configuration = 16'h40c0; // full 0..255 output range
                20: configuration = 16'h8c00; // RGB444 disabled
                21: configuration = 16'h0400; // CCIR656 disabled
                22: configuration = 16'h13e7; // automatic exposure/gain/WB
                default: configuration = 16'hffff;
            endcase
        end
    endfunction
    // Do not compare undocumented reserved bits, or the gain/exposure bits
    // which the sensor's enabled AGC/AEC legitimately change after writes.
    function [7:0] readback_mask;
        input [7:0] address;
        begin
            case (address)
                8'h03: readback_mask = 8'h0f; // upper bits include live gain
                8'h04: readback_mask = 8'h40; // low bits include live exposure
                8'h0c: readback_mask = 8'h7c;
                8'h11: readback_mask = 8'h7f;
                8'h12: readback_mask = 8'hbf;
                8'h13: readback_mask = 8'he7;
                8'h15: readback_mask = 8'h7f;
                8'h3a: readback_mask = 8'h59;
                8'h3d: readback_mask = 8'hc1;
                8'h3e: readback_mask = 8'h1f;
                8'h40: readback_mask = 8'hf0;
                8'h6b: readback_mask = 8'hd0;
                8'h73: readback_mask = 8'h0f;
                8'h8c: readback_mask = 8'h03;
                default: readback_mask = 8'hff;
            endcase
        end
    endfunction
    wire [15:0] entry = configuration(index);
    wire [7:0] verify_mask = readback_mask(entry[15:8]);
    // The transaction address/result remain stable after FAILED. Report the
    // exact read, since index zero can mean either PID or CLKRC verification.
    assign debug_register = bus_addr;
    assign debug_readback = bus_result;
    assign debug_expected = (bus_addr == 8'h0a) ? 8'h76 :
                            (bus_addr == 8'h0b) ? 8'h73 : entry[7:0];
    localparam HW_RESET=0, HW_SETTLE=1, SOFT_START=2, SOFT_WAIT=3,
        SOFT_SETTLE=4, ID_START=5, ID_WAIT=6, WRITE_START=7, WRITE_WAIT=8,
        READ_START=9, READ_WAIT=10, FRAME_SETTLE=11, FINISHED=12, FAILED=13;
    always @(posedge clk) begin
        if (reset) begin
            state <= HW_RESET; delay_count <= 0; cam_reset_n <= 0;
            ready <= 0; error <= 0; index <= 0;
            bus_start <= 0; bus_read <= 0; bus_addr <= 0; bus_data <= 0;
        end else begin
            bus_start <= 0;
            case (state)
                HW_RESET: if (delay_count >= RESET_CYCLES-1) begin
                    delay_count <= 0; cam_reset_n <= 1; state <= HW_SETTLE;
                end else delay_count <= delay_count + 1;
                HW_SETTLE: if (delay_count >= SETTLE_CYCLES-1) begin
                    delay_count <= 0; state <= SOFT_START;
                end else delay_count <= delay_count + 1;
                SOFT_START: begin
                    bus_read <= 0; bus_addr <= 8'h12; bus_data <= 8'h80;
                    bus_start <= 1; state <= SOFT_WAIT;
                end
                SOFT_WAIT: if (bus_done) begin
                    delay_count <= 0; state <= SOFT_SETTLE;
                end
                SOFT_SETTLE: if (delay_count >= SOFT_RESET_CYCLES-1) begin
                    delay_count <= 0; index <= 0; state <= ID_START;
                end else delay_count <= delay_count + 1;
                ID_START: begin
                    bus_read <= 1; bus_addr <= (index == 0) ? 8'h0a : 8'h0b;
                    bus_start <= 1; state <= ID_WAIT;
                end
                ID_WAIT: if (bus_done) begin
                    if (bus_result != ((index == 0) ? 8'h76 : 8'h73))
                        state <= FAILED;
                    else if (index == 0) begin index <= 1; state <= ID_START; end
                    else begin index <= 0; state <= WRITE_START; end
                end
                WRITE_START: if (entry == 16'hffff) begin
                    delay_count <= 0; state <= FRAME_SETTLE;
                end else begin
                    bus_read <= 0; bus_addr <= entry[15:8]; bus_data <= entry[7:0];
                    bus_start <= 1; state <= WRITE_WAIT;
                end
                WRITE_WAIT: if (bus_done) state <= READ_START;
                READ_START: begin
                    bus_read <= 1; bus_addr <= entry[15:8];
                    bus_start <= 1; state <= READ_WAIT;
                end
                READ_WAIT: if (bus_done) begin
                    if ((bus_result & verify_mask) != (entry[7:0] & verify_mask)) state <= FAILED;
                    else begin index <= index + 1; state <= WRITE_START; end
                end
                FRAME_SETTLE: if (delay_count >= FRAME_SETTLE_CYCLES-1) begin
                    state <= FINISHED; ready <= 1;
                end else delay_count <= delay_count + 1;
                FINISHED: ready <= 1;
                FAILED: begin ready <= 0; error <= 1; end
                default: state <= FAILED;
            endcase
        end
    end
endmodule

// One SCCB register operation. Register read is a complete two-byte write
// (with STOP), followed by a two-byte read (with STOP). Last read ninth bit
// is released high. Data never changes while SIOC is high, except START/STOP.
module ov7670_sccb #(
    parameter integer QUARTER_CYCLES = 250
)(
    input wire clk, reset, start, read_op,
    input wire [7:0] reg_addr, write_data,
    output reg [7:0] read_data,
    output reg busy, done,
    output wire sioc,
    inout wire siod
);
    reg drive_low;
    reg sioc_level;
    assign sioc = sioc_level ? 1'bz : 1'b0;
    assign siod = drive_low ? 1'b0 : 1'bz;
    (* ASYNC_REG = "TRUE" *) reg siod_meta, siod_sync;
    always @(posedge clk) begin
        if (reset) begin siod_meta <= 1; siod_sync <= 1; end
        else begin siod_meta <= siod; siod_sync <= siod_meta; end
    end
    reg [31:0] divider;
    wire tick = divider == QUARTER_CYCLES-1;
    reg [4:0] state;
    reg op_read, read_phase, restart_after_stop;
    reg [7:0] addr_latch, data_latch, tx_byte;
    reg [1:0] byte_index;
    reg [3:0] bit_index;
    localparam IDLE=0, START_A=1, START_B=2, START_C=3,
        TX_SETUP=4, TX_HIGH=5, TX_HOLD=6, TX_LOW=7,
        RX_SETUP=8, RX_HIGH=9, RX_SAMPLE=10, RX_LOW=11,
        STOP_LOW=12, STOP_HIGH=13, STOP_RELEASE=14, STOP_GAP=15;
    always @(posedge clk) begin
        if (reset) begin
            divider <= 0; state <= IDLE; drive_low <= 0; sioc_level <= 1;
            busy <= 0; done <= 0; read_data <= 0; op_read <= 0;
            read_phase <= 0; restart_after_stop <= 0; addr_latch <= 0;
            data_latch <= 0; tx_byte <= 0; byte_index <= 0; bit_index <= 0;
        end else begin
            done <= 0;
            if (tick) divider <= 0; else divider <= divider + 1;
            if (state == IDLE) begin
                sioc_level <= 1; drive_low <= 0;
                if (start) begin
                    busy <= 1; op_read <= read_op; addr_latch <= reg_addr;
                    data_latch <= write_data; tx_byte <= 8'h42;
                    byte_index <= 0; bit_index <= 0; read_phase <= 0;
                    restart_after_stop <= 0; read_data <= 0; state <= START_A;
                end
            end else if (tick) begin
                case (state)
                    START_A: begin sioc_level <= 1; drive_low <= 0; state <= START_B; end
                    START_B: begin drive_low <= 1; state <= START_C; end
                    START_C: begin sioc_level <= 0; state <= TX_SETUP; end
                    TX_SETUP: begin
                        drive_low <= (bit_index < 8) ? !tx_byte[7-bit_index] : 0;
                        state <= TX_HIGH;
                    end
                    TX_HIGH: begin sioc_level <= 1; state <= TX_HOLD; end
                    TX_HOLD: state <= TX_LOW;
                    TX_LOW: begin
                        sioc_level <= 0;
                        if (bit_index < 8) begin
                            bit_index <= bit_index + 1; state <= TX_SETUP;
                        end else begin
                            bit_index <= 0;
                            if (read_phase) state <= RX_SETUP;
                            else if (byte_index == 0) begin
                                byte_index <= 1; tx_byte <= addr_latch; state <= TX_SETUP;
                            end else if (byte_index == 1 && !op_read) begin
                                byte_index <= 2; tx_byte <= data_latch; state <= TX_SETUP;
                            end else begin
                                restart_after_stop <= op_read; state <= STOP_LOW;
                            end
                        end
                    end
                    RX_SETUP: begin drive_low <= 0; state <= RX_HIGH; end
                    RX_HIGH: begin sioc_level <= 1; state <= RX_SAMPLE; end
                    RX_SAMPLE: begin
                        if (bit_index < 8) read_data <= {read_data[6:0], siod_sync};
                        state <= RX_LOW;
                    end
                    RX_LOW: begin
                        sioc_level <= 0;
                        if (bit_index < 8) begin
                            bit_index <= bit_index + 1; state <= RX_SETUP;
                        end else begin restart_after_stop <= 0; state <= STOP_LOW; end
                    end
                    STOP_LOW: begin drive_low <= 1; sioc_level <= 0; state <= STOP_HIGH; end
                    STOP_HIGH: begin sioc_level <= 1; state <= STOP_RELEASE; end
                    STOP_RELEASE: begin drive_low <= 0; state <= STOP_GAP; end
                    STOP_GAP: begin
                        if (restart_after_stop) begin
                            read_phase <= 1; tx_byte <= 8'h43;
                            byte_index <= 0; bit_index <= 0; state <= START_A;
                        end else begin busy <= 0; done <= 1; state <= IDLE; end
                    end
                    default: begin state <= IDLE; busy <= 0; end
                endcase
            end
        end
    end
endmodule
