`timescale 1ns/1ps
// Freeze the 160x120 frame RAM from start until done. frame_data must be a
// synchronous one-clock read of frame_addr. start is accepted only when idle.
// The central 112x112 ROI excludes page edges. Pixels whose selected-polarity
// intensity is >= threshold define the ink bounding box. The box is fitted,
// preserving aspect ratio, inside 20x20 and centered geometrically in 28x28.
// Area averaging retains gray edge coverage when reducing a large digit.
// For enlargement, an output cell repeats its corresponding source pixel.
// All division uses sequential subtraction; there are no combinational
// variable dividers. Every transaction writes all 784 pixels, including a
// blank transaction. done is one cycle; blank remains valid until next start.
// Small marks (< MIN_INK_PIXELS) are blank. This is not perspective correction,
// connected-component segmentation, or the PC uploader's mass centering.
module camera_preprocess #(
    parameter integer MIN_INK_PIXELS = 8
)(
    input wire clk,
    input wire reset,
    input wire start,
    input wire [7:0] threshold,
    input wire invert,
    output reg [14:0] frame_addr,
    input wire [7:0] frame_data,
    output reg pix_wr_en,
    output reg [9:0] pix_wr_addr,
    output reg [7:0] pix_wr_data,
    output reg done,
    output reg busy,
    output reg blank
);
    localparam [4:0] IDLE=0, SCAN_WAIT=1, SCAN_SAMPLE=2, BOUNDS=3,
        DIM_PREP=4, DIM_DIV=5, DIM_DONE=6, MAP_BEGIN=7, MAP_DIV=8,
        MAP_SAVE=9, OUTPUT_PIXEL=10, PIX_WAIT=11, PIX_SAMPLE=12,
        AVG_BEGIN=13, AVG_DIV=14, ADVANCE=15, FINISH=16;
    reg [4:0] state;
    reg [7:0] threshold_latched;
    reg invert_latched;
    wire [7:0] intensity = invert_latched ? (8'd255-frame_data) : frame_data;
    wire is_ink = (intensity != 0) && (intensity >= threshold_latched);
    wire [7:0] clean_intensity = is_ink ? intensity : 8'd0;

    reg [7:0] scan_x, min_x, max_x;
    reg [6:0] scan_y, min_y, max_y;
    reg [13:0] ink_count;
    reg [7:0] box_w, box_h;
    reg [4:0] scaled_w, scaled_h, offset_x, offset_y;
    reg width_is_long;
    reg [11:0] dimension_rem;
    reg [7:0] dimension_divisor;
    reg [4:0] dimension_quotient;

    // Source-cell boundaries, relative to the ink bounding box. The exclusive
    // high boundary is clamped to low+1 when enlarging a tiny source box.
    reg [7:0] x_low [0:19];
    reg [7:0] x_high [0:19];
    reg [7:0] y_low [0:19];
    reg [7:0] y_high [0:19];
    reg map_y;
    reg [4:0] map_i;
    reg [7:0] map_extent, map_boundary, map_next;
    reg [4:0] map_size;
    reg [8:0] map_rem;

    reg [4:0] out_x, out_y;
    reg [9:0] out_index;
    wire in_digit = !blank && out_x >= offset_x && out_x < offset_x+scaled_w
                         && out_y >= offset_y && out_y < offset_y+scaled_h;
    wire [4:0] map_x_index = out_x-offset_x;
    wire [4:0] map_y_index = out_y-offset_y;
    reg [7:0] sample_x, sample_x_begin, sample_x_end;
    reg [6:0] sample_y;
    reg [7:0] sample_y_end;
    reg [15:0] sample_sum;
    reg [7:0] sample_count;
    reg [15:0] average_rem;
    reg [7:0] average;

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            frame_addr <= 0;
            pix_wr_en <= 0;
            pix_wr_addr <= 0;
            pix_wr_data <= 0;
            done <= 0;
            busy <= 0;
            blank <= 1;
            threshold_latched <= 0;
            invert_latched <= 0;
            scan_x <= 0; scan_y <= 0;
            min_x <= 0; max_x <= 0; min_y <= 0; max_y <= 0;
            ink_count <= 0;
            box_w <= 0; box_h <= 0;
            scaled_w <= 0; scaled_h <= 0;
            offset_x <= 0; offset_y <= 0;
            width_is_long <= 0;
            dimension_rem <= 0; dimension_divisor <= 1;
            dimension_quotient <= 0;
            map_y <= 0; map_i <= 0; map_extent <= 0;
            map_boundary <= 0; map_next <= 0; map_size <= 1; map_rem <= 0;
            out_x <= 0; out_y <= 0; out_index <= 0;
            sample_x <= 0; sample_y <= 0;
            sample_x_begin <= 0; sample_x_end <= 0; sample_y_end <= 0;
            sample_sum <= 0; sample_count <= 0; average_rem <= 0; average <= 0;
        end else begin
            pix_wr_en <= 0;
            done <= 0;
            case (state)
                IDLE: if (start) begin
                    busy <= 1;
                    blank <= 0;
                    threshold_latched <= threshold;
                    invert_latched <= invert;
                    min_x <= 8'd135; max_x <= 8'd24;
                    min_y <= 7'd115; max_y <= 7'd4;
                    ink_count <= 0;
                    scan_x <= 8'd24; scan_y <= 7'd4;
                    frame_addr <= 15'd664; // 4*160+24
                    out_x <= 0; out_y <= 0; out_index <= 0;
                    state <= SCAN_WAIT;
                end
                SCAN_WAIT: state <= SCAN_SAMPLE;
                SCAN_SAMPLE: begin
                    if (is_ink) begin
                        ink_count <= ink_count+1'b1;
                        if (scan_x < min_x) min_x <= scan_x;
                        if (scan_x > max_x) max_x <= scan_x;
                        if (scan_y < min_y) min_y <= scan_y;
                        if (scan_y > max_y) max_y <= scan_y;
                    end
                    if (scan_x == 135) begin
                        if (scan_y == 115) state <= BOUNDS;
                        else begin
                            scan_x <= 24;
                            scan_y <= scan_y+1'b1;
                            frame_addr <= frame_addr+15'd49;
                            state <= SCAN_WAIT;
                        end
                    end else begin
                        scan_x <= scan_x+1'b1;
                        frame_addr <= frame_addr+1'b1;
                        state <= SCAN_WAIT;
                    end
                end
                BOUNDS: begin
                    if (ink_count < MIN_INK_PIXELS || ink_count == 0) begin
                        blank <= 1;
                        state <= OUTPUT_PIXEL;
                    end else begin
                        box_w <= max_x-min_x+1'b1;
                        box_h <= max_y-min_y+1'b1;
                        state <= DIM_PREP;
                    end
                end
                DIM_PREP: begin
                    width_is_long <= box_w >= box_h;
                    dimension_quotient <= 0;
                    if (box_w >= box_h) begin
                        scaled_w <= 20;
                        dimension_rem <= box_h*12'd20+(box_w>>1);
                        dimension_divisor <= box_w;
                    end else begin
                        scaled_h <= 20;
                        dimension_rem <= box_w*12'd20+(box_h>>1);
                        dimension_divisor <= box_h;
                    end
                    state <= DIM_DIV;
                end
                DIM_DIV: begin
                    if (dimension_rem >= dimension_divisor) begin
                        dimension_rem <= dimension_rem-dimension_divisor;
                        dimension_quotient <= dimension_quotient+1'b1;
                    end else begin
                        if (width_is_long)
                            scaled_h <= dimension_quotient == 0 ? 5'd1 : dimension_quotient;
                        else
                            scaled_w <= dimension_quotient == 0 ? 5'd1 : dimension_quotient;
                        state <= DIM_DONE;
                    end
                end
                DIM_DONE: begin
                    offset_x <= (6'd28-scaled_w)>>1;
                    offset_y <= (6'd28-scaled_h)>>1;
                    map_y <= 0; map_i <= 0; map_boundary <= 0; map_rem <= 0;
                    map_extent <= box_w; map_size <= scaled_w;
                    state <= MAP_BEGIN;
                end
                MAP_BEGIN: begin
                    map_next <= map_boundary;
                    map_rem <= map_rem+map_extent;
                    state <= MAP_DIV;
                end
                MAP_DIV: begin
                    if (map_rem >= map_size) begin
                        map_rem <= map_rem-map_size;
                        map_next <= map_next+1'b1;
                    end else state <= MAP_SAVE;
                end
                MAP_SAVE: begin
                    if (map_y) begin
                        y_low[map_i] <= map_boundary;
                        y_high[map_i] <= map_next > map_boundary ? map_next : map_boundary+1'b1;
                    end else begin
                        x_low[map_i] <= map_boundary;
                        x_high[map_i] <= map_next > map_boundary ? map_next : map_boundary+1'b1;
                    end
                    if (map_i+1'b1 == map_size) begin
                        if (map_y) state <= OUTPUT_PIXEL;
                        else begin
                            map_y <= 1; map_i <= 0; map_boundary <= 0; map_rem <= 0;
                            map_extent <= box_h; map_size <= scaled_h;
                            state <= MAP_BEGIN;
                        end
                    end else begin
                        map_i <= map_i+1'b1;
                        map_boundary <= map_next;
                        state <= MAP_BEGIN;
                    end
                end
                OUTPUT_PIXEL: begin
                    if (!in_digit) begin
                        pix_wr_en <= 1;
                        pix_wr_addr <= out_index;
                        pix_wr_data <= 0;
                        state <= ADVANCE;
                    end else begin
                        sample_x <= min_x+x_low[map_x_index];
                        sample_y <= min_y+y_low[map_y_index];
                        sample_x_begin <= min_x+x_low[map_x_index];
                        sample_x_end <= min_x+x_high[map_x_index];
                        sample_y_end <= min_y+y_high[map_y_index];
                        frame_addr <= (min_y+y_low[map_y_index])*15'd160
                                      + min_x+x_low[map_x_index];
                        sample_sum <= 0; sample_count <= 0;
                        state <= PIX_WAIT;
                    end
                end
                PIX_WAIT: state <= PIX_SAMPLE;
                PIX_SAMPLE: begin
                    sample_sum <= sample_sum+clean_intensity;
                    sample_count <= sample_count+1'b1;
                    if (sample_x+1'b1 < sample_x_end) begin
                        sample_x <= sample_x+1'b1;
                        frame_addr <= frame_addr+1'b1;
                        state <= PIX_WAIT;
                    end else if (sample_y+1'b1 < sample_y_end) begin
                        sample_x <= sample_x_begin;
                        sample_y <= sample_y+1'b1;
                        frame_addr <= (sample_y+15'd1)*15'd160+sample_x_begin;
                        state <= PIX_WAIT;
                    end else state <= AVG_BEGIN;
                end
                AVG_BEGIN: begin
                    average_rem <= sample_sum+(sample_count>>1);
                    average <= 0;
                    state <= AVG_DIV;
                end
                AVG_DIV: begin
                    if (average_rem >= sample_count) begin
                        average_rem <= average_rem-sample_count;
                        average <= average+1'b1;
                    end else begin
                        pix_wr_en <= 1;
                        pix_wr_addr <= out_index;
                        pix_wr_data <= average;
                        state <= ADVANCE;
                    end
                end
                ADVANCE: begin
                    if (out_index == 783) state <= FINISH;
                    else begin
                        out_index <= out_index+1'b1;
                        if (out_x == 27) begin
                            out_x <= 0;
                            out_y <= out_y+1'b1;
                        end else out_x <= out_x+1'b1;
                        state <= OUTPUT_PIXEL;
                    end
                end
                FINISH: begin
                    done <= 1;
                    busy <= 0;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
