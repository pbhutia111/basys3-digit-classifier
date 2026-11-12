`timescale 1ns/1ps
// 8-N-1 receiver. The external pin enters only this two-flop synchronizer.
module uart_rx #(
    parameter integer CLK_HZ = 100000000,
    parameter integer BAUD = 115200
)(
    input wire clk,
    input wire reset,
    input wire rx,
    output reg [7:0] data,
    output reg valid,
    output reg framing_error
);
    localparam integer BIT_CLKS = (CLK_HZ + BAUD/2) / BAUD;
    localparam IDLE=0, START=1, DATA=2, STOP=3, BREAK_WAIT=4;
    (* ASYNC_REG = "TRUE" *) reg rx_meta = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg rx_sync = 1'b1;
    reg [2:0] state;
    reg [31:0] count;
    reg [2:0] bit_index;
    reg [7:0] shift;
    always @(posedge clk) begin
        rx_meta <= rx;
        rx_sync <= rx_meta;
    end
    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            count <= 0;
            bit_index <= 0;
            shift <= 0;
            data <= 0;
            valid <= 0;
            framing_error <= 0;
        end else begin
            valid <= 0;
            framing_error <= 0;
            case (state)
                IDLE: if (!rx_sync) begin
                    count <= BIT_CLKS/2-1;
                    state <= START;
                end
                START: if (count != 0) count <= count-1;
                    else if (rx_sync) state <= IDLE;
                    else begin
                        count <= BIT_CLKS-1;
                        bit_index <= 0;
                        state <= DATA;
                    end
                DATA: if (count != 0) count <= count-1;
                    else begin
                        shift[bit_index] <= rx_sync;
                        count <= BIT_CLKS-1;
                        if (bit_index == 7) state <= STOP;
                        else bit_index <= bit_index+1'b1;
                    end
                STOP: if (count != 0) count <= count-1;
                    else if (rx_sync) begin
                        data <= shift;
                        valid <= 1;
                        state <= IDLE;
                    end else begin
                        framing_error <= 1;
                        state <= BREAK_WAIT;
                    end
                // One error per break; resume only after the line is idle.
                BREAK_WAIT: if (rx_sync) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
