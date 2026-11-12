`timescale 1ns/1ps
module tb_camera_wiring_test;
    reg clk = 0;
    always #10 clk = ~clk;
    reg [1:0] sw = 0;
    wire cam_xclk, cam_reset_n, uart_tx;
    tri cam_sioc, cam_siod;
    wire [15:0] led;
    reg external_pullups = 0;
    reg monitor_outputs = 0;
    integer clock_edges = 0;
    integer selection;

    // First test the undriven bus directly: a released output must be Z,
    // not an actively driven 1. Then add realistic external weak pull-ups.
    assign (pull1, highz0) cam_sioc = external_pullups ? 1'b1 : 1'bz;
    assign (pull1, highz0) cam_siod = external_pullups ? 1'b1 : 1'bz;

    basys3_camera_wiring_test_top #(.SIM_BYPASS_MMCM(1)) dut (
        .clk(clk), .sw(sw), .cam_xclk(cam_xclk),
        .cam_sioc(cam_sioc), .cam_siod(cam_siod),
        .cam_reset_n(cam_reset_n), .led(led), .uart_tx(uart_tx)
    );

    always @(posedge cam_xclk) clock_edges = clock_edges + 1;
    always @(cam_sioc or cam_siod) begin
        if (monitor_outputs && !external_pullups) begin
            if (cam_sioc === 1'b1 || cam_siod === 1'b1)
                $fatal(1, "SCCB output actively driven HIGH without pull-ups");
        end
    end
    always @(negedge clk) begin
        if (cam_reset_n !== 1'b0)
            $fatal(1, "Camera must remain held in reset throughout wiring test");
        if (uart_tx !== 1'b1)
            $fatal(1, "UART must remain idle throughout wiring test");
        if (led[14:2] !== 13'b0)
            $fatal(1, "Unused LEDs must remain off");
    end

    task check_switches;
        input [1:0] requested;
        reg expected_scl, expected_sda;
        begin
            sw = requested;
            // Allow both synchronization stages to settle, away from edges.
            repeat (4) @(negedge clk);
            expected_scl = requested[0] ? 1'b0 : (external_pullups ? 1'b1 : 1'bz);
            expected_sda = requested[1] ? 1'b0 : (external_pullups ? 1'b1 : 1'bz);
            if (cam_sioc !== expected_scl || cam_siod !== expected_sda)
                $fatal(1, "Wrong switch/bus mapping sw=%b pullups=%b SCL=%b SDA=%b",
                       requested, external_pullups, cam_sioc, cam_siod);
            if (led[1:0] !== requested)
                $fatal(1, "LED0/1 do not match synchronized switches: sw=%b led=%b",
                       requested, led[1:0]);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        monitor_outputs = 1;
        check_switches(2'b00);
        check_switches(2'b01);
        check_switches(2'b00);
        check_switches(2'b10);
        check_switches(2'b11);
        check_switches(2'b01);
        check_switches(2'b10);
        check_switches(2'b00);
        $display("PASS: independent low/release control with no active HIGH drive");

        external_pullups = 1;
        for (selection = 0; selection < 4; selection = selection + 1)
            check_switches(selection[1:0]);
        check_switches(2'b00);
        external_pullups = 0;
        check_switches(2'b00);
        if (clock_edges < 8)
            $fatal(1, "Forwarded camera clock did not run during wiring test");
        $display("PASS: external pull-ups, switch LEDs, reset hold and idle UART");
        $display("CAMERA_WIRING_TEST_PASS");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "Wiring test simulation timed out");
    end
endmodule
