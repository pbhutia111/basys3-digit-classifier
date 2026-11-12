`timescale 1ns/1ps
// Board oscillator is always 100MHz. The inference logic runs at 50MHz.
// Bypass exists only for explicit accelerated RTL simulations.
module basys3_clock50 #(
    parameter integer SIM_BYPASS_MMCM = 0
)(
    input wire clk100,
    output wire clk50,
    output wire locked
);
    generate if (SIM_BYPASS_MMCM != 0) begin : g_sim
        assign clk50 = clk100;
        assign locked = 1'b1;
    end else begin : g_hw
        wire clk_feedback_raw, clk_feedback, clk50_raw;
        MMCME2_BASE #(
            .BANDWIDTH("OPTIMIZED"),
            .CLKIN1_PERIOD(10.0),
            .DIVCLK_DIVIDE(1),
            .CLKFBOUT_MULT_F(10.0),
            .CLKOUT0_DIVIDE_F(20.0),
            .CLKOUT0_DUTY_CYCLE(0.5),
            .CLKOUT0_PHASE(0.0),
            .STARTUP_WAIT("FALSE")
        ) u_mmcm (
            .CLKIN1(clk100), .CLKFBIN(clk_feedback),
            .RST(1'b0), .PWRDWN(1'b0), .LOCKED(locked),
            .CLKFBOUT(clk_feedback_raw), .CLKFBOUTB(),
            .CLKOUT0(clk50_raw), .CLKOUT0B(),
            .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
            .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6()
        );
        BUFG u_feedback_buf (.I(clk_feedback_raw), .O(clk_feedback));
        BUFG u_logic_buf (.I(clk50_raw), .O(clk50));
    end endgenerate
endmodule
