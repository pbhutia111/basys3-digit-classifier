`timescale 1ns/1ps
// End-to-end UART test with the real pretrained inference core and ROMs.
// The simulator working directory needs weights and sample_*.mem fixtures.
module tb_basys3_mnist;
    localparam BIT_CLKS = 10;
    localparam BIT_NS = BIT_CLKS*10;
    reg clk = 0;
    always #5 clk = ~clk;
    reg btnC = 0;
    reg rx = 1;
    wire tx;
    wire [6:0] seg;
    wire [3:0] an;
    wire dp;
    wire [15:0] led;
    basys3_mnist_top #(.CLK_HZ(100000000), .BAUD(10000000),
        .INTERBYTE_TIMEOUT_CLKS(2000), .RESET_CYCLES(16),
        .SIM_BYPASS_MMCM(1)) dut (
        .clk(clk), .btnC(btnC), .uart_rx(rx), .uart_tx(tx),
        .seg(seg), .an(an), .dp(dp), .led(led)
    );
    reg [7:0] pixels [0:783];
    reg [7:0] expected [0:0];
    reg [7:0] received [0:255];
    integer received_count = 0;
    integer inference_starts = 0;
    integer monitor_bit;
    integer i;
    reg [7:0] monitor_data;
    reg [7:0] check_sum;
    reg [31:0] reply_cycles;
    always @(posedge clk) if (!dut.reset && dut.infer_start)
        inference_starts = inference_starts+1;

    // Independent wire-level decoder (does not reuse the DUT UART RTL).
    initial forever begin
        @(negedge tx);
        #(BIT_NS/2);
        if (tx !== 0) begin
            $display("FAIL: TX start bit");
            $finish;
        end
        for (monitor_bit=0; monitor_bit<8; monitor_bit=monitor_bit+1) begin
            #(BIT_NS);
            monitor_data[monitor_bit] = tx;
        end
        #(BIT_NS);
        if (tx !== 1) begin
            $display("FAIL: TX stop bit");
            $finish;
        end
        received[received_count] = monitor_data;
        received_count = received_count+1;
    end

    task send_byte;
        input [7:0] value;
        integer bit_no;
        begin
            @(negedge clk);
            rx = 0;
            repeat(BIT_CLKS) @(negedge clk);
            for (bit_no=0; bit_no<8; bit_no=bit_no+1) begin
                rx = value[bit_no];
                repeat(BIT_CLKS) @(negedge clk);
            end
            rx = 1;
            repeat(BIT_CLKS) @(negedge clk);
        end
    endtask

    task send_image;
        input [7:0] seq;
        input bad_checksum;
        reg [7:0] checksum;
        integer pixel_no;
        begin
            send_byte(8'haa);
            send_byte(8'h55);
            send_byte(seq);
            checksum = seq;
            for (pixel_no=0; pixel_no<784; pixel_no=pixel_no+1) begin
                send_byte(pixels[pixel_no]);
                checksum = checksum+pixels[pixel_no];
            end
            send_byte(checksum ^ (bad_checksum ? 8'h01 : 8'h00));
        end
    endtask

    task check_reply;
        input integer offset;
        input [7:0] seq;
        input [7:0] status;
        input [7:0] digit;
        integer j;
        reg [7:0] checksum;
        begin
            wait(received_count >= offset+10);
            repeat(30) @(negedge clk);
            if (received[offset] !== 8'haa || received[offset+1] !== 8'h56 ||
                received[offset+2] !== seq || received[offset+3] !== status ||
                received[offset+4] !== digit) begin
                $display("FAIL: reply offset=%0d hdr=%02x,%02x seq=%02x status=%02x digit=%02x expected=%02x/%02x/%02x",
                    offset, received[offset], received[offset+1], received[offset+2],
                    received[offset+3], received[offset+4], seq, status, digit);
                $finish;
            end
            checksum = 0;
            for (j=2; j<9; j=j+1) checksum = checksum+received[offset+j];
            if (received[offset+9] !== checksum) begin
                $display("FAIL: reply checksum");
                $finish;
            end
            reply_cycles = {received[offset+8], received[offset+7],
                            received[offset+6], received[offset+5]};
            if ((status == 0 && reply_cycles < 50000) ||
                (status != 0 && reply_cycles !== 0)) begin
                $display("FAIL: cycle count %0d for status %0d", reply_cycles, status);
                $finish;
            end
            $display("Reply seq=%02x status=%0d digit=%02x cycles=%0d",
                     seq, status, digit, reply_cycles);
        end
    endtask

    initial begin
        $readmemh("sample_pixels.mem", pixels);
        $readmemh("sample_expected.mem", expected);
        repeat(40) @(negedge clk);
        if (an !== 4'hf || seg !== 7'h7f || tx !== 1) begin
            $display("FAIL: startup blank/idle");
            $finish;
        end

        send_image(8'h21, 0);
        check_reply(0, 8'h21, 0, expected[0]);
        if (inference_starts != 1 || !led[4] || an !== 4'he ||
            dut.display_digit !== expected[0][3:0]) begin
            $display("FAIL: inference/display after valid packet");
            $finish;
        end

        send_image(8'h22, 1);
        check_reply(10, 8'h22, 1, 8'hff);
        if (inference_starts != 1 || an !== 4'hf) begin
            $display("FAIL: bad checksum triggered inference or stale display");
            $finish;
        end

        send_byte(8'haa);
        send_byte(8'h55);
        send_byte(8'h23);
        send_byte(8'h80);
        check_reply(20, 8'h23, 2, 8'hff);
        if (inference_starts != 1) begin
            $display("FAIL: partial packet triggered inference");
            $finish;
        end

        send_byte(8'haa);
        send_byte(8'h55);
        send_byte(8'h24);
        // Hold low through the stop bit to force framing error / break.
        @(negedge clk);
        rx = 0;
        repeat(12*BIT_CLKS) @(negedge clk);
        rx = 1;
        repeat(2*BIT_CLKS) @(negedge clk);
        // Sender can still be streaming pixels after the corrupt byte.
        // Include a fake header in this tail: it must be drained, not parsed.
        send_byte(8'haa);
        send_byte(8'h55);
        send_byte(8'h99);
        for (i=0; i<20; i=i+1) send_byte(8'h40+i);
        check_reply(30, 8'h24, 3, 8'hff);
        if (inference_starts != 1) begin
            $display("FAIL: framing error triggered inference");
            $finish;
        end

        // Prove recovery after all three rejected frames.
        send_image(8'h25, 0);
        check_reply(40, 8'h25, 0, expected[0]);
        if (inference_starts != 2 || an !== 4'he) begin
            $display("FAIL: recovery");
            $finish;
        end
        btnC = 1;
        repeat(10) @(negedge clk);
        btnC = 0;
        repeat(10) @(negedge clk);
        if (an !== 4'hf || tx !== 1) begin
            $display("FAIL: button reset");
            $finish;
        end
        $display("PASS: UART real inference, checksum rejection, timeout, framing error, recovery, reset");
        $finish;
    end
    initial begin
        #10000000;
        $display("FAIL: watchdog timeout");
        $finish;
    end
endmodule
