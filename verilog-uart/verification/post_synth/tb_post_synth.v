`timescale 1ns/1ps
// Actual 100MHz input / MMCM 50MHz logic / 115200-baud synthesized netlist.
// No force statements or RTL parameter overrides; actual initialized BRAMs.
module tb_post_synth;
    localparam BIT_CLKS=868, BIT_NS=8680;
    reg clk=0;
    always #5 clk=~clk;
    reg btnC=0;
    reg rx=1;
    wire tx;
    wire [6:0] seg;
    wire [3:0] an;
    wire dp;
    wire [15:0] led;
    basys3_mnist_top dut(.clk(clk), .btnC(btnC), .uart_rx(rx),
        .uart_tx(tx), .seg(seg), .an(an), .dp(dp), .led(led));
    reg [7:0] pixels [0:783];
    reg [7:0] expected [0:0];
    reg [7:0] received [0:31];
    reg [7:0] sampled;
    integer rx_count=0;
    integer monitor_bit;
    integer inference_count=0;
    reg monitor_enable=0;
    always @(posedge led[5]) if (monitor_enable)
        inference_count=inference_count+1;

    initial forever begin
        @(negedge tx);
        #(BIT_NS/2);
        if (tx !== 0) begin $display("FAIL start bit"); $finish; end
        for (monitor_bit=0; monitor_bit<8; monitor_bit=monitor_bit+1) begin
            #(BIT_NS);
            sampled[monitor_bit]=tx;
        end
        #(BIT_NS);
        if (tx !== 1) begin $display("FAIL stop bit"); $finish; end
        received[rx_count]=sampled;
        rx_count=rx_count+1;
    end

    task send_byte;
        input [7:0] value;
        integer b;
        begin
            @(negedge clk); rx=0;
            #(BIT_NS);
            for (b=0; b<8; b=b+1) begin
                rx=value[b];
                #(BIT_NS);
            end
            rx=1;
            #(BIT_NS);
        end
    endtask
    task send_image;
        input [7:0] seq;
        integer p;
        reg [7:0] checksum;
        begin
            send_byte(8'haa); send_byte(8'h55); send_byte(seq);
            checksum=seq;
            for (p=0; p<784; p=p+1) begin
                send_byte(pixels[p]);
                checksum=checksum+pixels[p];
                if (p % 196 == 195)
                    $display("POST_SYNTH_TX seq=%02x pixels=%0d time=%0t",seq,p+1,$time);
            end
            send_byte(checksum);
        end
    endtask
    task check_reply;
        input integer offset;
        input [7:0] seq;
        integer j;
        reg [7:0] checksum;
        reg [31:0] cycles;
        begin
            wait(rx_count >= offset+10);
            repeat(BIT_CLKS) @(negedge clk);
            if (received[offset] !== 8'haa || received[offset+1] !== 8'h56 ||
                received[offset+2] !== seq || received[offset+3] !== 0 ||
                received[offset+4] !== expected[0]) begin
                $display("FAIL reply hdr=%02x,%02x seq=%02x status=%02x digit=%02x expected=%02x",
                    received[offset],received[offset+1],received[offset+2],
                    received[offset+3],received[offset+4],expected[0]);
                $finish;
            end
            checksum=0;
            for (j=2; j<9; j=j+1) checksum=checksum+received[offset+j];
            cycles={received[offset+8],received[offset+7],received[offset+6],received[offset+5]};
            if (received[offset+9] !== checksum || cycles < 50000 ||
                an !== 4'he || !led[4] || led[3:0] !== expected[0][3:0] ||
                seg !== 7'b1111000 || dp !== 1) begin
                $display("FAIL checksum/cycles/display cycles=%0d seg=%07b led=%04x",cycles,seg,led);
                $finish;
            end
            $display("POST_SYNTH_REPLY seq=%02x digit=%0d cycles=%0d time=%0t",seq,received[offset+4],cycles,$time);
        end
    endtask
    initial begin
        $readmemh("sample_pixels.mem",pixels);
        $readmemh("sample_expected.mem",expected);
        // Allow MMCM lock plus 65536 internal 50MHz startup clocks.
        repeat(160000) @(negedge clk);
        if (an !== 4'hf || seg !== 7'h7f || tx !== 1) begin
            $display("FAIL startup blank/idle"); $finish;
        end
        monitor_enable=1;
        $display("POST_SYNTH_START first packet time=%0t",$time);
        send_image(8'h41);
        check_reply(0,8'h41);
        btnC=1;
        repeat(20) @(negedge clk);
        btnC=0;
        repeat(20) @(negedge clk);
        if (an !== 4'hf || seg !== 7'h7f || tx !== 1) begin
            $display("FAIL button reset"); $finish;
        end
        $display("POST_SYNTH_START recovery packet time=%0t",$time);
        send_image(8'h42);
        check_reply(10,8'h42);
        if (inference_count != 2) begin
            $display("FAIL inference count %0d",inference_count); $finish;
        end
        $display("POST_SYNTH_PASS: two real UART inferences, initialized weights/image RAM, display and reset recovery");
        $finish;
    end
    initial begin
        #200000000;
        $display("FAIL post-synthesis watchdog");
        $finish;
    end
endmodule
