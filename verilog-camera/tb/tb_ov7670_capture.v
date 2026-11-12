`timescale 1ns/1ps
module tb_ov7670_capture;
    reg clk=0, reset=1, enable=0, request=0;
    always #10 clk=~clk;
    reg cam_pclk=0,cam_vsync=0,cam_href=0;
    reg [7:0] cam_data=0;
    wire wr_en,frame_done,busy,error;
    wire [14:0] wr_addr;
    wire [7:0] wr_data;
    integer writes=0, done_count=0, x,y;
    reg check_values=1;
    ov7670_capture #(.FRAME_WIDTH(4),.FRAME_HEIGHT(3),.TIMEOUT_CLKS(4000)) dut (
        .clk(clk),.reset(reset),.enable(enable),.request(request),
        .cam_pclk(cam_pclk),.cam_vsync(cam_vsync),.cam_href(cam_href),
        .cam_data(cam_data),.wr_en(wr_en),.wr_addr(wr_addr),.wr_data(wr_data),
        .frame_done(frame_done),.busy(busy),.error(error)
    );
    always @(negedge clk) begin
        if(wr_en) begin
            if(wr_addr!=writes) $fatal(1,"Wrong sequential address %0d vs %0d",wr_addr,writes);
            if(check_values && wr_data!=(8'd20+writes))
                $fatal(1,"Wrong Y byte at %0d: got %0d",writes,wr_data);
            writes=writes+1;
        end
        if(frame_done) done_count=done_count+1;
    end
    task byte_out(input [7:0] value);
        begin
            // Deliberately not phase-aligned with 50MHz. 5MHz camera PCLK.
            cam_pclk=0; cam_data=value; #100;
            cam_pclk=1; #100; cam_pclk=0;
        end
    endtask
    task boundary;
        begin cam_href=0; cam_pclk=0; cam_vsync=1; #241; cam_vsync=0; #239; end
    endtask
    task arm;
        begin
            writes=0;
            @(negedge clk);request=1;
            @(negedge clk);request=0;
            #117;
        end
    endtask
    task full_frame;
        begin
            boundary;
            for(y=0;y<3;y=y+1) begin
                cam_href=1; #77;
                for(x=0;x<4;x=x+1) begin
                    byte_out(20+y*4+x); byte_out(8'he1);
                end
                cam_href=0; #317;
            end
            boundary;
            #200;
        end
    endtask
    initial begin
        repeat(5) @(negedge clk); reset=0; enable=1;
        // A stream alone cannot write memory or signal success.
        full_frame;
        if(writes!=0 || done_count!=0) $fatal(1,"Unrequested frame captured");
        arm; full_frame;
        if(writes!=12 || done_count!=1 || error || busy)
            $fatal(1,"Valid frame failed writes=%0d done=%0d error=%b",writes,done_count,error);
        $display("PASS: exact frame, YUYV extraction, coherent asynchronous sampling");
        // Partial frame, then next VSYNC must not trigger classification.
        arm; boundary; cam_href=1; #71;
        byte_out(20);byte_out(0);cam_href=0;#300;boundary;#200;
        if(!error || busy || done_count!=1) $fatal(1,"Short row accepted");
        $display("PASS: malformed short row rejected");
        // Recovery works without a reset.
        arm; full_frame;
        if(writes!=12 || done_count!=2 || error) $fatal(1,"Recovery failed");
        // Full valid rows but too few rows.
        arm; boundary; cam_href=1;#71;
        for(x=0;x<4;x=x+1)begin byte_out(20+x);byte_out(0);end
        cam_href=0;#300;boundary;#200;
        if(!error || done_count!=2) $fatal(1,"Truncated frame accepted");
        $display("PASS: incomplete frame rejected and retry recovered");
        // No VSYNC at all: timeout, never done.
        arm; repeat(4100) @(negedge clk);
        if(!error || busy || done_count!=2) $fatal(1,"Disconnected input did not time out");
        $display("PASS: disconnected capture timeout");
        enable=0;repeat(4)@(negedge clk);
        if(wr_en || busy || error) $fatal(1,"Disable did not clear capture");
        $display("OV7670_CAPTURE_TEST_PASS");$finish;
    end
    initial begin #1000000;$fatal(1,"Capture test timeout");end
endmodule
