`timescale 1ns/1ps
// start is accepted for one cycle only while busy is low.
module uart_tx #(
    parameter integer CLK_HZ = 100000000,
    parameter integer BAUD = 115200
)(
    input wire clk,
    input wire reset,
    input wire start,
    input wire [7:0] data,
    output reg tx,
    output reg busy
);
    localparam integer BIT_CLKS = (CLK_HZ + BAUD/2) / BAUD;
    reg [9:0] shift;
    reg [3:0] bit_index;
    reg [31:0] count;
    always @(posedge clk) begin
        if (reset) begin
            tx <= 1;
            busy <= 0;
            shift <= 10'h3ff;
            bit_index <= 0;
            count <= 0;
        end else if (!busy) begin
            tx <= 1;
            if (start) begin
                shift <= {1'b1, data, 1'b0};
                tx <= 0;
                busy <= 1;
                bit_index <= 0;
                count <= BIT_CLKS-1;
            end
        end else if (count != 0) count <= count-1;
        else if (bit_index == 9) begin
            tx <= 1;
            busy <= 0;
        end else begin
            shift <= {1'b1, shift[9:1]};
            tx <= shift[1];
            bit_index <= bit_index+1'b1;
            count <= BIT_CLKS-1;
        end
    end
endmodule
