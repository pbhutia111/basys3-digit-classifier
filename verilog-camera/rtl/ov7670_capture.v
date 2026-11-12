`timescale 1ns/1ps
// Captures one complete QQVGA YUYV frame after request, with no partial-frame
// success. Oversampling contract: clk=50MHz, camera PCLK <=6.25MHz, data/HREF
// change on falling PCLK and are stable around rising PCLK; use short wires.
// Synchronize the entire {PCLK,VSYNC,HREF,D} bundle through identical stages.
// At a synchronized PCLK rise the matching bus sample is taken. The camera
// clock must remain divided as configured in ov7670_config. This is NOT a
// generic asynchronous byte bus or an unrestricted-rate camera interface.
module ov7670_capture #(
    parameter integer FRAME_WIDTH = 160,
    parameter integer FRAME_HEIGHT = 120,
    parameter integer TIMEOUT_CLKS = 100000000 // 2 seconds @50MHz
)(
    input wire clk, reset, enable, request,
    input wire cam_pclk, cam_vsync, cam_href,
    input wire [7:0] cam_data,
    output reg wr_en,
    output reg [14:0] wr_addr,
    output reg [7:0] wr_data,
    output reg frame_done, busy, error
);
    (* ASYNC_REG = "TRUE" *) reg pclk_meta, vsync_meta, href_meta;
    (* ASYNC_REG = "TRUE" *) reg [7:0] data_meta;
    (* ASYNC_REG = "TRUE" *) reg [10:0] cam_sync;
    reg pclk_last, vsync_last, href_last;
    wire pclk = cam_sync[10], vsync = cam_sync[9], href = cam_sync[8];
    wire pclk_rise = pclk && !pclk_last;
    wire vsync_rise = vsync && !vsync_last;
    wire vsync_fall = !vsync && vsync_last;
    wire href_rise = href && !href_last;
    wire href_fall = !href && href_last;
    always @(posedge clk) begin
        if (reset) begin
            {pclk_meta, vsync_meta, href_meta, data_meta} <= 0; cam_sync <= 0;
            pclk_last <= 0; vsync_last <= 0; href_last <= 0;
        end else begin
            {pclk_meta, vsync_meta, href_meta, data_meta} <= {cam_pclk, cam_vsync, cam_href, cam_data};
            cam_sync <= {pclk_meta, vsync_meta, href_meta, data_meta};
            pclk_last <= pclk; vsync_last <= vsync; href_last <= href;
        end
    end
    localparam IDLE=0, WAIT_VSYNC=1, WAIT_ACTIVE=2, CAPTURE=3;
    reg [1:0] state;
    reg [31:0] timeout_count;
    reg [9:0] line_bytes;
    reg [7:0] rows;
    reg [14:0] pixels;
    reg row_active;
    always @(posedge clk) begin
        if (reset || !enable) begin
            state <= IDLE; busy <= 0; error <= 0; frame_done <= 0;
            wr_en <= 0; wr_addr <= 0; wr_data <= 0;
            timeout_count <= 0; line_bytes <= 0; rows <= 0;
            pixels <= 0; row_active <= 0;
        end else begin
            wr_en <= 0; frame_done <= 0;
            if (state == IDLE) begin
                busy <= 0;
                if (request) begin
                    busy <= 1; error <= 0; timeout_count <= 0;
                    line_bytes <= 0; rows <= 0; pixels <= 0; row_active <= 0;
                    state <= WAIT_VSYNC;
                end
            end else if (timeout_count >= TIMEOUT_CLKS-1) begin
                error <= 1; busy <= 0; state <= IDLE;
            end else begin
                timeout_count <= timeout_count + 1;
                case (state)
                    // Require a *new* frame boundary after the request.
                    WAIT_VSYNC: if (vsync_rise) state <= WAIT_ACTIVE;
                    WAIT_ACTIVE: if (vsync_fall) state <= CAPTURE;
                    CAPTURE: begin
                        if (vsync_rise) begin
                            busy <= 0; state <= IDLE;
                            if (!row_active && rows == FRAME_HEIGHT &&
                                pixels == FRAME_WIDTH*FRAME_HEIGHT) frame_done <= 1;
                            else error <= 1;
                        end else if (href_rise && rows >= FRAME_HEIGHT) begin
                            error <= 1; busy <= 0; state <= IDLE;
                        end else if (href_fall) begin
                            row_active <= 0;
                            if (!row_active || line_bytes != FRAME_WIDTH*2) begin
                                error <= 1; busy <= 0; state <= IDLE;
                            end else begin rows <= rows + 1; line_bytes <= 0; end
                        end else if (href && pclk_rise) begin
                            row_active <= 1;
                            if (line_bytes >= FRAME_WIDTH*2 || rows >= FRAME_HEIGHT) begin
                                error <= 1; busy <= 0; state <= IDLE;
                            end else begin
                                if (!line_bytes[0]) begin
                                    wr_en <= 1; wr_addr <= pixels; wr_data <= cam_sync[7:0];
                                    pixels <= pixels + 1;
                                end
                                line_bytes <= line_bytes + 1;
                            end
                        end else if (href_rise) row_active <= 1;
                    end
                    default: begin state <= IDLE; busy <= 0; error <= 1; end
                endcase
            end
        end
    end
endmodule
