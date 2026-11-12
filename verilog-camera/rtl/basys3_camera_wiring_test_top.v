`timescale 1ns/1ps
// Temporary DC-meter test. Keep the sensor in reset; independently pull
// SCL/SDA low with SW0/SW1. A down switch releases its line, never drives high.
// Restore the normal camera-test bitstream when measurements are complete.
module basys3_camera_wiring_test_top #(
    parameter integer SIM_BYPASS_MMCM=0
)(
    input wire clk,
    input wire [1:0] sw,
    output wire cam_xclk,cam_sioc,cam_siod,cam_reset_n,
    output wire [15:0] led,
    output wire uart_tx
);
    wire logic_clk,clock_locked;
    basys3_camera_clock #(.SIM_BYPASS_MMCM(SIM_BYPASS_MMCM)) u_clock (
        .clk100(clk),.clk50(logic_clk),.cam_xclk(cam_xclk),.locked(clock_locked)
    );
    (* ASYNC_REG="TRUE" *) reg [1:0] sw_meta=0,sw_sync=0;
    reg [25:0] heartbeat=0;
    always @(posedge logic_clk) begin
        sw_meta<=sw;
        sw_sync<=sw_meta;
        heartbeat<=heartbeat+1'b1;
    end
    assign cam_sioc=sw_sync[0] ? 1'b0 : 1'bz;
    assign cam_siod=sw_sync[1] ? 1'b0 : 1'bz;
    assign cam_reset_n=1'b0;
    assign uart_tx=1'b1;
    assign led={heartbeat[25],13'b0,sw_sync};
endmodule
