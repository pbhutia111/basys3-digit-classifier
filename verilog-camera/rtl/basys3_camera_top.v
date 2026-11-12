`timescale 1ns/1ps
// OV7670 -> frozen QQVGA frame -> MNIST normalization -> existing MLP.
// Runtime is entirely FPGA hardware. UART version is a separate project.
module basys3_camera_top #(
    parameter integer RESET_CYCLES = 65536,
    parameter integer CAPTURE_TIMEOUT_CLKS = 100000000,
    parameter integer FRAME_PAUSE_CLKS = 12500000,
    parameter integer SIM_BYPASS_MMCM = 0
)(
    input wire clk, btnC,
    input wire [15:0] sw,
    input wire [7:0] cam_data,
    input wire cam_pclk, cam_href, cam_vsync,
    output wire cam_xclk, cam_sioc,
    inout wire cam_siod,
    output wire cam_reset_n, cam_pwdn,
    output reg [6:0] seg,
    output wire [3:0] an,
    output wire dp,
    output wire [15:0] led,
    output wire [3:0] vgaRed, vgaGreen, vgaBlue,
    output wire Hsync, Vsync
);
    wire logic_clk, clock_locked;
    basys3_camera_clock #(.SIM_BYPASS_MMCM(SIM_BYPASS_MMCM)) u_clock (
        .clk100(clk), .clk50(logic_clk), .cam_xclk(cam_xclk), .locked(clock_locked)
    );
    (* ASYNC_REG = "TRUE" *) reg lock_meta = 0, lock_sync = 0;
    (* ASYNC_REG = "TRUE" *) reg btn_meta = 0, btn_sync = 0;
    (* ASYNC_REG = "TRUE" *) reg [15:0] sw_meta = 0, sw_sync = 0;
    reg [31:0] startup_count = 0;
    always @(posedge logic_clk or negedge clock_locked) begin
        if (!clock_locked) begin lock_meta <= 0; lock_sync <= 0; end
        else begin lock_meta <= 1; lock_sync <= lock_meta; end
    end
    always @(posedge logic_clk) begin
        btn_meta <= btnC; btn_sync <= btn_meta;
        sw_meta <= sw; sw_sync <= sw_meta;
        if (!lock_sync) startup_count <= 0;
        else if (startup_count < RESET_CYCLES) startup_count <= startup_count + 1;
    end
    wire reset = !lock_sync || (startup_count < RESET_CYCLES) || btn_sync;
    wire config_ready, config_error;
    wire [7:0] config_index;
    ov7670_config u_config (
        .clk(logic_clk), .reset(reset), .siod(cam_siod), .sioc(cam_sioc),
        .cam_reset_n(cam_reset_n), .cam_pwdn(cam_pwdn),
        .ready(config_ready), .error(config_error), .debug_index(config_index)
    );

    reg capture_request;
    wire capture_busy, capture_done, capture_error, frame_wr_en;
    wire [14:0] frame_wr_addr;
    wire [7:0] frame_wr_data;
    ov7670_capture #(.TIMEOUT_CLKS(CAPTURE_TIMEOUT_CLKS)) u_capture (
        .clk(logic_clk), .reset(reset), .enable(config_ready),
        .request(capture_request), .cam_pclk(cam_pclk),
        .cam_href(cam_href), .cam_vsync(cam_vsync), .cam_data(cam_data),
        .wr_en(frame_wr_en), .wr_addr(frame_wr_addr), .wr_data(frame_wr_data),
        .frame_done(capture_done), .busy(capture_busy), .error(capture_error)
    );

    reg prep_start;
    wire prep_busy, prep_done, prep_blank;
    wire [14:0] prep_addr, video_frame_addr;
    reg [7:0] prep_data, video_frame_data;
    wire image_wr_en;
    wire [9:0] image_wr_addr;
    wire [7:0] image_wr_data;
    // All switches off: dark ink on white, intensity threshold 96.
    // SW7:0 nonzero overrides threshold; SW14 reverses foreground polarity.
    wire [7:0] threshold = (sw_sync[7:0] == 0) ? 8'd96 : sw_sync[7:0];
    camera_preprocess u_preprocess (
        .clk(logic_clk), .reset(reset), .start(prep_start),
        .threshold(threshold), .invert(!sw_sync[14]),
        .frame_addr(prep_addr), .frame_data(prep_data),
        .pix_wr_en(image_wr_en), .pix_wr_addr(image_wr_addr),
        .pix_wr_data(image_wr_data), .done(prep_done), .busy(prep_busy),
        .blank(prep_blank)
    );
    // Capture and preprocessing are mutually exclusive. Port B serves VGA.
    (* ram_style = "block" *) reg [7:0] frame_mem [0:19199];
    always @(posedge logic_clk) begin
        if (frame_wr_en) frame_mem[frame_wr_addr] <= frame_wr_data;
        else prep_data <= frame_mem[prep_addr];
    end
    always @(posedge logic_clk) video_frame_data <= frame_mem[video_frame_addr];

    wire [9:0] infer_addr, video_image_addr;
    reg [7:0] infer_data, video_image_data;
    (* ram_style = "block" *) reg [7:0] image_mem [0:783];
    always @(posedge logic_clk) begin
        if (image_wr_en) image_mem[image_wr_addr] <= image_wr_data;
        else infer_data <= image_mem[infer_addr];
    end
    always @(posedge logic_clk) video_image_data <= image_mem[video_image_addr];
    reg infer_start;
    wire infer_done, infer_busy;
    wire [3:0] infer_digit;
    wire [6:0] infer_confidence;
    inference_engine u_infer (
        .clk(logic_clk), .reset(reset), .start(infer_start),
        .pix_addr(infer_addr), .pix_data(infer_data), .digit(infer_digit),
        .confidence(infer_confidence), .done(infer_done), .busy(infer_busy)
    );

    localparam WAIT_CONFIG=0, REQUEST_FRAME=1, CAPTURE=2,
               PREPROCESS=3, INFER=4, PAUSE=5;
    reg [2:0] state;
    reg [31:0] pause_count;
    reg display_valid, frame_valid, pixels_valid, blank_frame, frame_fault;
    reg [3:0] display_digit;
    reg [7:0] frame_count;
    always @(posedge logic_clk) begin
        if (reset) begin
            state <= WAIT_CONFIG; capture_request <= 0;
            prep_start <= 0; infer_start <= 0; pause_count <= 0;
            display_valid <= 0; display_digit <= 0;
            frame_valid <= 0; pixels_valid <= 0; blank_frame <= 0;
            frame_fault <= 0; frame_count <= 0;
        end else begin
            capture_request <= 0; prep_start <= 0; infer_start <= 0;
            if (config_error || !config_ready) begin
                state <= WAIT_CONFIG; display_valid <= 0;
                frame_valid <= 0; pixels_valid <= 0;
            end else case (state)
                WAIT_CONFIG: state <= REQUEST_FRAME;
                REQUEST_FRAME: if (!sw_sync[15]) begin
                    capture_request <= 1;
                    state <= CAPTURE;
                end
                CAPTURE: begin
                    if (capture_error && !capture_request) begin
                        display_valid <= 0; frame_valid <= 0;
                        pixels_valid <= 0; frame_fault <= 1;
                        pause_count <= 0; state <= PAUSE;
                    end else if (capture_done) begin
                        frame_valid <= 1; frame_fault <= 0;
                        pixels_valid <= 0; prep_start <= 1;
                        frame_count <= frame_count + 1;
                        state <= PREPROCESS;
                    end
                end
                PREPROCESS: if (prep_done) begin
                    pixels_valid <= 1; blank_frame <= prep_blank;
                    if (prep_blank) begin
                        display_valid <= 0; pause_count <= 0;
                        state <= PAUSE;
                    end else begin infer_start <= 1; state <= INFER; end
                end
                INFER: if (infer_done) begin
                    display_digit <= infer_digit;
                    display_valid <= (infer_digit <= 9);
                    pause_count <= 0; state <= PAUSE;
                end
                PAUSE: if (!sw_sync[15]) begin
                    if (pause_count >= FRAME_PAUSE_CLKS) state <= REQUEST_FRAME;
                    else pause_count <= pause_count + 1;
                end
                default: state <= WAIT_CONFIG;
            endcase
        end
    end

    camera_vga u_video (
        .clk(logic_clk), .reset(reset), .frame_valid(frame_valid),
        .pixels_valid(pixels_valid), .frame_addr(video_frame_addr),
        .frame_data(video_frame_data), .pix_addr(video_image_addr),
        .pix_data(video_image_data), .vgaRed(vgaRed), .vgaGreen(vgaGreen),
        .vgaBlue(vgaBlue), .Hsync(Hsync), .Vsync(Vsync)
    );
    assign an = display_valid ? 4'b1110 : 4'b1111;
    assign dp = 1'b1;
    always @(*) begin
        if (!display_valid) seg = 7'b1111111;
        else case (display_digit)
            0: seg=7'b1000000; 1: seg=7'b1111001;
            2: seg=7'b0100100; 3: seg=7'b0110000;
            4: seg=7'b0011001; 5: seg=7'b0010010;
            6: seg=7'b0000010; 7: seg=7'b1111000;
            8: seg=7'b0000000; 9: seg=7'b0010000;
            default: seg=7'b1111111;
        endcase
    end
    assign led[3:0] = display_valid ? display_digit : 4'd0;
    assign led[4] = display_valid;
    assign led[5] = infer_busy || prep_busy;
    assign led[6] = capture_busy;
    assign led[7] = config_error || frame_fault;
    assign led[8] = config_ready;
    assign led[9] = blank_frame;
    assign led[10] = sw_sync[15];
    assign led[15:11] = frame_count[4:0];
endmodule
