`timescale 1ns/1ps
// Basys 3 UART -> image BRAM -> pretrained INT8 inference -> display/UART.
// Request: AA 55 sequence 784 pixels checksum(sum(sequence,pixels) mod 256).
// Reply: AA 56 sequence status digit cycles[7:0] ... cycles[31:24] checksum.
// Reply checksum sums bytes 2..8. Status: 0 OK, 1 checksum, 2 timeout,
// 3 framing. Errors return digit FF and cycles 0. One request at a time.
module basys3_mnist_top #(
    // Internal logic clock. Physical board input remains 100MHz.
    parameter integer CLK_HZ = 50000000,
    parameter integer BAUD = 115200,
    parameter integer INTERBYTE_TIMEOUT_CLKS = CLK_HZ/10,
    parameter integer RESET_CYCLES = 65536,
    parameter integer SIM_BYPASS_MMCM = 0
)(
    input wire clk,
    input wire btnC,
    input wire uart_rx,
    output wire uart_tx,
    output reg [6:0] seg,
    output wire [3:0] an,
    output wire dp,
    output wire [15:0] led
);
    wire logic_clk, clock_locked;
    basys3_clock50 #(.SIM_BYPASS_MMCM(SIM_BYPASS_MMCM)) u_clock (
        .clk100(clk), .clk50(logic_clk), .locked(clock_locked)
    );
    // Assert reset immediately on loss of lock; release only on two valid
    // 50MHz edges, followed by the startup counter. No derived fabric clock.
    (* ASYNC_REG = "TRUE" *) reg lock_meta = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg lock_sync = 1'b0;
    always @(posedge logic_clk or negedge clock_locked) begin
        if (!clock_locked) begin
            lock_meta <= 0;
            lock_sync <= 0;
        end else begin
            lock_meta <= 1;
            lock_sync <= lock_meta;
        end
    end
    (* ASYNC_REG = "TRUE" *) reg btn_meta = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg btn_sync = 1'b0;
    reg [31:0] startup_count = 0;
    wire reset = !lock_sync || (startup_count < RESET_CYCLES) || btn_sync;
    always @(posedge logic_clk) begin
        btn_meta <= btnC;
        btn_sync <= btn_meta;
        if (!lock_sync) startup_count <= 0;
        else if (startup_count < RESET_CYCLES) startup_count <= startup_count+1'b1;
    end

    wire [7:0] rx_data;
    wire rx_valid, rx_error;
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_uart_rx (
        .clk(logic_clk), .reset(reset), .rx(uart_rx), .data(rx_data),
        .valid(rx_valid), .framing_error(rx_error)
    );
    reg tx_start;
    reg [7:0] tx_data;
    wire tx_busy;
    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_uart_tx (
        .clk(logic_clk), .reset(reset), .start(tx_start), .data(tx_data),
        .tx(uart_tx), .busy(tx_busy)
    );

    localparam S_AA=0, S_55=1, S_SEQ=2, S_PIXELS=3, S_CHECK=4,
               S_INFER=5, S_SEND=6, S_TX_BUSY=7, S_TX_DONE=8, S_DRAIN=9;
    reg [3:0] state;
    reg [9:0] pixel_index;
    reg [7:0] sequence, sum;
    reg [31:0] timeout_count;
    wire receiving = state == S_SEQ || state == S_PIXELS || state == S_CHECK;
    reg [7:0] reply_status, reply_digit;
    reg [31:0] reply_cycles, cycle_count;
    reg [3:0] reply_index;
    wire [7:0] reply_sum = sequence + reply_status + reply_digit +
        reply_cycles[7:0] + reply_cycles[15:8] +
        reply_cycles[23:16] + reply_cycles[31:24];

    (* ram_style = "block" *) reg [7:0] image_mem [0:783];
    wire [9:0] pix_addr;
    reg [7:0] pix_data;
    reg infer_start;
    wire infer_done, infer_busy;
    wire [3:0] infer_digit;
    wire [6:0] infer_confidence;
    // Separate synchronous read and write ports allow block RAM inference.
    // Never clear the RAM on reset; the core only starts after 784 good bytes.
    always @(posedge logic_clk) begin
        if (!reset && state == S_PIXELS && rx_valid && !rx_error)
            image_mem[pixel_index] <= rx_data;
        pix_data <= image_mem[pix_addr];
    end
    inference_engine #(.N_IN(784), .N_HID(32), .N_OUT(10), .SHIFT1(10)) u_infer (
        .clk(logic_clk), .reset(reset), .start(infer_start),
        .pix_addr(pix_addr), .pix_data(pix_data), .digit(infer_digit),
        .confidence(infer_confidence), .done(infer_done), .busy(infer_busy)
    );

    reg display_valid;
    reg [3:0] display_digit;
    always @(posedge logic_clk) begin
        if (reset) begin
            state <= S_AA;
            pixel_index <= 0;
            sequence <= 0;
            sum <= 0;
            timeout_count <= 0;
            reply_status <= 0;
            reply_digit <= 8'hff;
            reply_cycles <= 0;
            cycle_count <= 0;
            reply_index <= 0;
            infer_start <= 0;
            tx_start <= 0;
            display_valid <= 0;
            display_digit <= 0;
        end else begin
            infer_start <= 0;
            tx_start <= 0;
            if ((!receiving && state != S_DRAIN) || rx_valid || rx_error)
                timeout_count <= 0;
            else if (timeout_count < INTERBYTE_TIMEOUT_CLKS)
                timeout_count <= timeout_count+1'b1;

            if (receiving && (rx_error || (!rx_valid &&
                    timeout_count >= INTERBYTE_TIMEOUT_CLKS-1))) begin
                reply_status <= rx_error ? 8'd3 : 8'd2;
                reply_digit <= 8'hff;
                reply_cycles <= 0;
                reply_index <= 0;
                // A bad stop bit may occur near the start of a long frame.
                // Drain the remaining bytes before replying, so their pixel
                // values cannot be mistaken for the next frame's header.
                state <= rx_error ? S_DRAIN : S_SEND;
            end else case (state)
                S_AA: if (rx_valid && rx_data == 8'haa) state <= S_55;
                S_55: if (rx_error) state <= S_AA;
                    else if (rx_valid) begin
                        if (rx_data == 8'h55) begin
                            state <= S_SEQ;
                            sequence <= 0; // Used if sequence byte never arrives.
                            sum <= 0;
                            pixel_index <= 0;
                            reply_status <= 0;
                            display_valid <= 0;
                        end else if (rx_data != 8'haa) state <= S_AA;
                    end
                S_SEQ: if (rx_valid) begin
                    sequence <= rx_data;
                    sum <= rx_data;
                    state <= S_PIXELS;
                end
                S_PIXELS: if (rx_valid) begin
                    sum <= sum+rx_data;
                    if (pixel_index == 783) state <= S_CHECK;
                    else pixel_index <= pixel_index+1'b1;
                end
                S_CHECK: if (rx_valid) begin
                    reply_index <= 0;
                    if (rx_data == sum) begin
                        infer_start <= 1;
                        cycle_count <= 0;
                        state <= S_INFER;
                    end else begin
                        reply_status <= 1;
                        reply_digit <= 8'hff;
                        reply_cycles <= 0;
                        state <= S_SEND;
                    end
                end
                S_INFER: begin
                    cycle_count <= cycle_count+1'b1;
                    if (infer_done) begin
                        reply_status <= 0;
                        reply_digit <= {4'd0, infer_digit};
                        // Cycles from the edge accepting start to observed done.
                        reply_cycles <= cycle_count;
                        display_digit <= infer_digit;
                        display_valid <= 1;
                        state <= S_SEND;
                    end
                end
                S_SEND: if (!tx_busy) begin
                    tx_start <= 1;
                    state <= S_TX_BUSY;
                end
                S_TX_BUSY: if (tx_busy) state <= S_TX_DONE;
                S_TX_DONE: if (!tx_busy) begin
                    if (reply_index == 9) state <= S_AA;
                    else begin
                        reply_index <= reply_index+1'b1;
                        state <= S_SEND;
                    end
                end
                S_DRAIN: if (!rx_valid && !rx_error &&
                    timeout_count >= INTERBYTE_TIMEOUT_CLKS-1)
                    state <= S_SEND;
                default: state <= S_AA;
            endcase
        end
    end

    always @(*) begin
        case (reply_index)
            0: tx_data = 8'haa;
            1: tx_data = 8'h56;
            2: tx_data = sequence;
            3: tx_data = reply_status;
            4: tx_data = reply_digit;
            5: tx_data = reply_cycles[7:0];
            6: tx_data = reply_cycles[15:8];
            7: tx_data = reply_cycles[23:16];
            8: tx_data = reply_cycles[31:24];
            9: tx_data = reply_sum;
            default: tx_data = 8'hff;
        endcase
    end
    // Active-low {g,f,e,d,c,b,a}; only AN0 (rightmost digit) is enabled.
    assign an = display_valid ? 4'b1110 : 4'b1111;
    assign dp = 1'b1;
    always @(*) begin
        if (!display_valid) seg = 7'b1111111;
        else case (display_digit)
            0: seg = 7'b1000000;
            1: seg = 7'b1111001;
            2: seg = 7'b0100100;
            3: seg = 7'b0110000;
            4: seg = 7'b0011001;
            5: seg = 7'b0010010;
            6: seg = 7'b0000010;
            7: seg = 7'b1111000;
            8: seg = 7'b0000000;
            9: seg = 7'b0010000;
            default: seg = 7'b1111111;
        endcase
    end
    assign led = {sequence, (reply_status != 0), receiving, infer_busy,
                  display_valid, (display_valid ? display_digit : 4'd0)};
endmodule
