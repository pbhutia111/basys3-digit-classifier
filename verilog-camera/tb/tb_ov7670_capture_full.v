`timescale 1ns/1ps
module tb_ov7670_capture_full;
    reg clk=0,reset=1,enable=0,request=0;
    always #10 clk=~clk;
    reg cam_pclk=0,cam_vsync=0,cam_href=0;
    reg [7:0] cam_data=0;
    wire wr_en,frame_done,busy,error;
    wire [14:0] wr_addr;
    wire [7:0] wr_data;
    integer writes=0,done_count=0,x,y;
    reg [7:0] expected;
    ov7670_capture #(.TIMEOUT_CLKS(2000000)) dut (
        .clk(clk),.reset(reset),.enable(enable),.request(request),
        .cam_pclk(cam_pclk),.cam_vsync(cam_vsync),.cam_href(cam_href),.cam_data(cam_data),
        .wr_en(wr_en),.wr_addr(wr_addr),.wr_data(wr_data),.frame_done(frame_done),
        .busy(busy),.error(error)
    );
    always @(negedge clk) begin
        if(wr_en) begin
            expected=writes*13+17;
            if(wr_addr!=writes || wr_data!==expected)
                $fatal(1,"Full frame mismatch n=%0d addr=%0d Y=%0d expected=%0d",writes,wr_addr,wr_data,expected);
            writes=writes+1;
        end
        if(frame_done)done_count=done_count+1;
    end
    task byte_out(input [7:0] value);
        begin
            // Maximum supported 6.25MHz, unrelated phase to system clock.
            cam_pclk=0;cam_data=value;#80;cam_pclk=1;#80;cam_pclk=0;
        end
    endtask
    task boundary;
        begin cam_href=0;cam_pclk=0;cam_vsync=1;#401;cam_vsync=0;#393;end
    endtask
    task arm;
        begin
            writes=0;@(negedge clk);request=1;@(negedge clk);request=0;#113;
        end
    endtask
    task rows_out;
        begin
            for(y=0;y<120;y=y+1)begin
                cam_href=1;#71;
                for(x=0;x<160;x=x+1)begin
                    byte_out((y*160+x)*13+17);byte_out(8'haa);
                end
                cam_href=0;#313;
            end
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);reset=0;enable=1;
        arm;boundary;rows_out;#200;
        if(writes!=19200 || done_count!=0 || error || !busy)
            $fatal(1,"Full frame must await closing VSYNC");
        boundary;#200;
        if(done_count!=1 || error || busy)$fatal(1,"Full160x120 frame failed");
        $display("PASS: all19200 Y samples at6.25MHz; done only after closing VSYNC");
        arm;boundary;rows_out;
        cam_href=1;#500;
        if(!error || busy || done_count!=1)$fatal(1,"121st row accepted");
        cam_href=0;#300;
        $display("PASS: extra row rejected");
        $display("OV7670_CAPTURE_FULL_TEST_PASS");$finish;
    end
    initial begin #50000000;$fatal(1,"Full capture test timeout");end
endmodule
