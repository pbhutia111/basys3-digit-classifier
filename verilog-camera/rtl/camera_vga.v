`timescale 1ns / 1ps

// VGA aiming preview. All state uses clk=50MHz; a clock enable produces
// 25MHz pixels (800x525 total, 640x480 visible, approximately 59.52Hz).
// Both memory ports must return data one clk after sampling their address.
// The metadata pipeline matches this latency and registers RGB and sync
// together. Addresses outside their respective image rectangles are zero.
// The raw frame buffer may be written during display; preview tearing is
// accepted so that the classifier does not need a second full-frame buffer.
module camera_vga (
    input  wire        clk,
    input  wire        reset,
    input  wire        frame_valid,
    input  wire        pixels_valid,
    output wire [14:0] frame_addr,
    input  wire [7:0]  frame_data,
    output wire [9:0]  pix_addr,
    input  wire [7:0]  pix_data,
    output reg  [3:0]  vgaRed,
    output reg  [3:0]  vgaGreen,
    output reg  [3:0]  vgaBlue,
    output reg         Hsync,
    output reg         Vsync
);
    reg pixel_phase;
    reg [9:0] h_count;
    reg [9:0] v_count;

    wire raw_area = h_count >= 10'd16 && h_count < 10'd336 &&
                    v_count >= 10'd120 && v_count < 10'd360;
    wire pix_area = h_count >= 10'd368 && h_count < 10'd592 &&
                    v_count >= 10'd128 && v_count < 10'd352;
    wire roi_border =
        ((h_count == 10'd64 || h_count == 10'd287) &&
         v_count >= 10'd128 && v_count <= 10'd351) ||
        ((v_count == 10'd128 || v_count == 10'd351) &&
         h_count >= 10'd64 && h_count <= 10'd287);

    wire [9:0] raw_dx = h_count - 10'd16;
    wire [9:0] raw_dy = v_count - 10'd120;
    wire [9:0] pix_dx = h_count - 10'd368;
    wire [9:0] pix_dy = v_count - 10'd128;
    wire [7:0] raw_x = raw_dx[8:1];
    wire [6:0] raw_y = raw_dy[7:1];
    wire [4:0] pix_x = pix_dx[7:3];
    wire [4:0] pix_y = pix_dy[7:3];

    assign frame_addr = raw_area ? raw_y * 15'd160 + raw_x : 15'd0;
    assign pix_addr = pix_area ? pix_y * 10'd28 + pix_x : 10'd0;

    reg raw_q;
    reg pix_q;
    reg border_q;
    reg hsync_q;
    reg vsync_q;

    always @(posedge clk) begin
        if (reset) begin
            pixel_phase <= 1'b0;
            h_count <= 10'd0;
            v_count <= 10'd0;
            raw_q <= 1'b0;
            pix_q <= 1'b0;
            border_q <= 1'b0;
            hsync_q <= 1'b1;
            vsync_q <= 1'b1;
            vgaRed <= 4'd0;
            vgaGreen <= 4'd0;
            vgaBlue <= 4'd0;
            Hsync <= 1'b1;
            Vsync <= 1'b1;
        end else begin
            pixel_phase <= ~pixel_phase;
            if (pixel_phase) begin
                if (h_count == 10'd799) begin
                    h_count <= 10'd0;
                    if (v_count == 10'd524)
                        v_count <= 10'd0;
                    else
                        v_count <= v_count + 1'b1;
                end else begin
                    h_count <= h_count + 1'b1;
                end
            end

            // The external synchronous RAM reads these same coordinates now.
            raw_q <= raw_area && frame_valid;
            pix_q <= pix_area && pixels_valid;
            border_q <= roi_border && frame_valid;
            hsync_q <= !(h_count >= 10'd656 && h_count < 10'd752);
            vsync_q <= !(v_count >= 10'd490 && v_count < 10'd492);

            Hsync <= hsync_q;
            Vsync <= vsync_q;
            if (border_q) begin
                vgaRed <= 4'd0;
                vgaGreen <= 4'hf;
                vgaBlue <= 4'd0;
            end else if (raw_q) begin
                vgaRed <= frame_data[7:4];
                vgaGreen <= frame_data[7:4];
                vgaBlue <= frame_data[7:4];
            end else if (pix_q) begin
                vgaRed <= pix_data[7:4];
                vgaGreen <= pix_data[7:4];
                vgaBlue <= pix_data[7:4];
            end else begin
                vgaRed <= 4'd0;
                vgaGreen <= 4'd0;
                vgaBlue <= 4'd0;
            end
        end
    end
endmodule
