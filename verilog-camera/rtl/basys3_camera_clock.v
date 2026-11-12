`timescale 1ns/1ps
// 100 MHz board oscillator -> 50 MHz processing and 25 MHz camera XCLK.
module basys3_camera_clock #(parameter SIM_BYPASS_MMCM = 0)(
    input wire clk100, output wire clk50, output wire cam_xclk,
    output wire locked
);
    generate if (SIM_BYPASS_MMCM) begin : g_sim
        assign clk50 = clk100;
        assign cam_xclk = clk100;
        assign locked = 1'b1;
    end else begin : g_hw
        wire feedback_raw, feedback, logic_raw, camera_raw, camera_clk;
        MMCME2_BASE #(
            .CLKIN1_PERIOD(10.0), .DIVCLK_DIVIDE(1),
            .CLKFBOUT_MULT_F(10.0), .CLKOUT0_DIVIDE_F(20.0),
            .CLKOUT1_DIVIDE(40), .STARTUP_WAIT("FALSE")
        ) u_mmcm (
            .CLKIN1(clk100), .CLKFBIN(feedback), .RST(1'b0),
            .PWRDWN(1'b0), .LOCKED(locked),
            .CLKFBOUT(feedback_raw), .CLKFBOUTB(),
            .CLKOUT0(logic_raw), .CLKOUT0B(),
            .CLKOUT1(camera_raw), .CLKOUT1B(),
            .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
            .CLKOUT4(), .CLKOUT5(), .CLKOUT6()
        );
        BUFG u_feedback (.I(feedback_raw), .O(feedback));
        BUFG u_logic (.I(logic_raw), .O(clk50));
        BUFG u_camera (.I(camera_raw), .O(camera_clk));
        // Forward the clock through an output DDR register, not fabric logic.
        ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
        u_xclk (.C(camera_clk), .CE(1'b1), .D1(1'b1), .D2(1'b0),
                .Q(cam_xclk), .R(1'b0), .S(1'b0));
    end endgenerate
endmodule
