`timescale 1ns/1ps
// Camera bring-up ONLY: verify SCCB identity/configuration, capture complete
// frames, show raw VGA and report diagnostics over the Basys3 USB UART.
module basys3_camera_test_top #(
    parameter integer RESET_CYCLES=65536,
    parameter integer CAPTURE_TIMEOUT_CLKS=100000000,
    parameter integer FRAME_PAUSE_CLKS=2500000,
    parameter integer REPORT_CLKS=25000000,
    parameter integer UART_BAUD=115200,
    parameter integer SIM_BYPASS_MMCM=0
)(
    input wire clk, btnC,
    input wire [15:0] sw,
    input wire [7:0] cam_data,
    input wire cam_pclk,cam_href,cam_vsync,
    output wire cam_xclk,cam_sioc,
    inout wire cam_siod,
    output wire cam_reset_n,cam_pwdn,
    output reg [6:0] seg,
    output wire [3:0] an,
    output wire dp,
    output wire [15:0] led,
    output wire [3:0] vgaRed,vgaGreen,vgaBlue,
    output wire Hsync,Vsync,
    output wire uart_tx
);
    wire logic_clk,clock_locked;
    basys3_camera_clock #(.SIM_BYPASS_MMCM(SIM_BYPASS_MMCM)) u_clock (
        .clk100(clk),.clk50(logic_clk),.cam_xclk(cam_xclk),.locked(clock_locked)
    );
    (* ASYNC_REG="TRUE" *) reg lock_meta=0,lock_sync=0;
    (* ASYNC_REG="TRUE" *) reg btn_meta=0,btn_sync=0;
    (* ASYNC_REG="TRUE" *) reg [15:0] sw_meta=0,sw_sync=0;
    reg [31:0] startup_count=0;
    always @(posedge logic_clk or negedge clock_locked) begin
        if (!clock_locked) begin lock_meta<=0; lock_sync<=0; end
        else begin lock_meta<=1; lock_sync<=lock_meta; end
    end
    always @(posedge logic_clk) begin
        btn_meta<=btnC; btn_sync<=btn_meta;
        sw_meta<=sw; sw_sync<=sw_meta;
        if (!lock_sync) startup_count<=0;
        else if (startup_count<RESET_CYCLES) startup_count<=startup_count+1;
    end
    wire reset=!lock_sync || (startup_count<RESET_CYCLES) || btn_sync;
    wire config_ready,config_error;
    wire [7:0] config_index;
    wire [7:0] config_register,config_readback,config_expected;
    ov7670_config u_config (
        .clk(logic_clk),.reset(reset),.siod(cam_siod),.sioc(cam_sioc),
        .cam_reset_n(cam_reset_n),.cam_pwdn(cam_pwdn),
        .ready(config_ready),.error(config_error),.debug_index(config_index),
        .debug_register(config_register),.debug_readback(config_readback),
        .debug_expected(config_expected)
    );
    reg capture_request;
    wire capture_busy,capture_done,capture_error,frame_wr_en;
    wire [14:0] frame_wr_addr;
    wire [7:0] frame_wr_data;
    ov7670_capture #(.TIMEOUT_CLKS(CAPTURE_TIMEOUT_CLKS)) u_capture (
        .clk(logic_clk),.reset(reset),.enable(config_ready),
        .request(capture_request),.cam_pclk(cam_pclk),
        .cam_href(cam_href),.cam_vsync(cam_vsync),.cam_data(cam_data),
        .wr_en(frame_wr_en),.wr_addr(frame_wr_addr),.wr_data(frame_wr_data),
        .frame_done(capture_done),.busy(capture_busy),.error(capture_error)
    );
    (* ram_style="block" *) reg [7:0] frame_mem[0:19199];
    wire [14:0] video_frame_addr;
    reg [7:0] video_frame_data;
    always @(posedge logic_clk) if(frame_wr_en) frame_mem[frame_wr_addr]<=frame_wr_data;
    always @(posedge logic_clk) video_frame_data<=frame_mem[video_frame_addr];

    localparam WAIT_CONFIG=0,REQUEST_FRAME=1,CAPTURE=2,PAUSE=3;
    reg [1:0] state;
    reg [31:0] pause_count;
    reg frame_valid,frame_fault,pixels_seen;
    reg [15:0] frame_count;
    reg [7:0] sample_min,sample_max,last_min,last_max;
    always @(posedge logic_clk) begin
        if(reset) begin
            state<=WAIT_CONFIG;capture_request<=0;pause_count<=0;
            frame_valid<=0;frame_fault<=0;pixels_seen<=0;frame_count<=0;
            sample_min<=255;sample_max<=0;last_min<=0;last_max<=0;
        end else begin
            capture_request<=0;
            if(frame_wr_en) begin
                pixels_seen<=1;
                if(frame_wr_data<sample_min) sample_min<=frame_wr_data;
                if(frame_wr_data>sample_max) sample_max<=frame_wr_data;
            end
            if(config_error || !config_ready) begin
                state<=WAIT_CONFIG;frame_valid<=0;frame_fault<=0;pixels_seen<=0;
            end else case(state)
                WAIT_CONFIG:state<=REQUEST_FRAME;
                REQUEST_FRAME:if(!sw_sync[15]) begin
                    capture_request<=1;pixels_seen<=0;
                    sample_min<=255;sample_max<=0;state<=CAPTURE;
                end
                CAPTURE:begin
                    if(capture_error && !capture_request) begin
                        frame_valid<=0;frame_fault<=1;pause_count<=0;state<=PAUSE;
                    end else if(capture_done) begin
                        frame_valid<=1;frame_fault<=0;frame_count<=frame_count+1;
                        last_min<=sample_min;last_max<=sample_max;
                        pause_count<=0;state<=PAUSE;
                    end
                end
                PAUSE:if(!sw_sync[15]) begin
                    if(pause_count>=FRAME_PAUSE_CLKS) state<=REQUEST_FRAME;
                    else pause_count<=pause_count+1;
                end
                default:state<=WAIT_CONFIG;
            endcase
        end
    end
    camera_vga u_video (
        .clk(logic_clk),.reset(reset),.frame_valid(frame_valid),
        .pixels_valid(1'b0),.frame_addr(video_frame_addr),
        .frame_data(video_frame_data),.pix_addr(),.pix_data(8'd0),
        .vgaRed(vgaRed),.vgaGreen(vgaGreen),.vgaBlue(vgaBlue),
        .Hsync(Hsync),.Vsync(Vsync)
    );
    // Snapshot all fields before transmitting. Packet: AA C1 seq flags
    // config_index framesLE16 minY maxY checksum(sum bytes2..8 modulo256).
    // On configuration error: index/min/max become register/actual/expected.
    reg [31:0] report_timer;
    reg [7:0] report_sequence,packet_seq,packet_flags,packet_index;
    reg [15:0] packet_frames;
    reg [7:0] packet_min,packet_max;
    reg [3:0] tx_index;
    reg [1:0] tx_state;
    reg tx_start,heartbeat;
    reg [7:0] tx_data;
    wire tx_busy;
    wire [7:0] packet_sum=packet_seq+packet_flags+packet_index+
        packet_frames[7:0]+packet_frames[15:8]+packet_min+packet_max;
    uart_tx #(.CLK_HZ(50000000),.BAUD(UART_BAUD)) u_uart_tx (
        .clk(logic_clk),.reset(reset),.start(tx_start),.data(tx_data),
        .tx(uart_tx),.busy(tx_busy)
    );
    always @(*) case(tx_index)
        0:tx_data=8'haa;1:tx_data=8'hc1;2:tx_data=packet_seq;
        3:tx_data=packet_flags;4:tx_data=packet_index;
        5:tx_data=packet_frames[7:0];6:tx_data=packet_frames[15:8];
        7:tx_data=packet_min;8:tx_data=packet_max;9:tx_data=packet_sum;
        default:tx_data=0;
    endcase
    always @(posedge logic_clk) begin
        if(reset) begin
            report_timer<=0;report_sequence<=0;packet_seq<=0;packet_flags<=0;
            packet_index<=0;packet_frames<=0;packet_min<=0;packet_max<=0;
            tx_index<=0;tx_state<=0;tx_start<=0;heartbeat<=0;
        end else begin
            tx_start<=0;
            case(tx_state)
                0:if(report_timer>=REPORT_CLKS-1) begin
                    report_timer<=0;heartbeat<=!heartbeat;
                    packet_seq<=report_sequence;report_sequence<=report_sequence+1;
                    packet_flags<={sw_sync[15],1'b0,pixels_seen,frame_fault,
                        capture_busy,frame_valid,config_error,config_ready};
                    packet_index<=config_error ? config_register : config_index;
                    packet_frames<=frame_count;
                    packet_min<=config_error ? config_readback : last_min;
                    packet_max<=config_error ? config_expected : last_max;
                    tx_index<=0;tx_state<=1;
                end else report_timer<=report_timer+1;
                1:if(!tx_busy) begin tx_start<=1;tx_state<=2;end
                2:if(tx_busy) tx_state<=3;
                3:if(!tx_busy) begin
                    if(tx_index==9) tx_state<=0;
                    else begin tx_index<=tx_index+1;tx_state<=1;end
                end
            endcase
        end
    end
    assign an=4'b1110;
    assign dp=1'b1;
    always @(*) begin
        if(config_error) seg=7'b0000110; // E: identity/configuration error
        else if(frame_fault) seg=7'b0100001; // d: stream/geometry error
        else if(frame_valid) seg=7'b0001110; // F: complete frame received
        else if(config_ready) seg=7'b1000110; // C: camera identified
        else seg=7'b0001100; // P: powering/configuring
    end
    assign led={frame_count[7:0],heartbeat,sw_sync[15],frame_fault,
                config_error,pixels_seen,capture_busy,frame_valid,config_ready};
endmodule
