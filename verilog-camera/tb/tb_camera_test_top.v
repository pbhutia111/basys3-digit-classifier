`timescale 1ns/1ps
// Diagnostic build integration: an actual SCCB peripheral model and real
// asynchronous camera pins drive the top. No ready/error/internal data forces.
// MMCM is bypassed and long delays shortened for behavioral simulation only.
module tb_camera_test_top;
    reg clk=0;
    always #10 clk=~clk;
    reg btnC=0;
    reg [15:0] sw=16'h8000;
    reg [7:0] cam_data=0;
    reg cam_pclk=0,cam_href=0,cam_vsync=0;
    wire cam_xclk,cam_reset_n,cam_pwdn,uart_tx;
    tri1 cam_sioc,cam_siod;
    wire [6:0] seg;
    wire [3:0] an,vgaRed,vgaGreen,vgaBlue;
    wire dp,Hsync,Vsync;
    wire [15:0] led;
    basys3_camera_test_top #(
        .RESET_CYCLES(8),.CAPTURE_TIMEOUT_CLKS(700000),
        .FRAME_PAUSE_CLKS(100),.REPORT_CLKS(20000),
        .UART_BAUD(1000000),.SIM_BYPASS_MMCM(1)
    ) dut(
        .clk(clk),.btnC(btnC),.sw(sw),.cam_data(cam_data),.cam_pclk(cam_pclk),
        .cam_href(cam_href),.cam_vsync(cam_vsync),.cam_xclk(cam_xclk),
        .cam_sioc(cam_sioc),.cam_siod(cam_siod),.cam_reset_n(cam_reset_n),
        .cam_pwdn(cam_pwdn),.seg(seg),.an(an),.dp(dp),.led(led),
        .vgaRed(vgaRed),.vgaGreen(vgaGreen),.vgaBlue(vgaBlue),
        .Hsync(Hsync),.Vsync(Vsync),.uart_tx(uart_tx));
    defparam dut.u_config.SCCB_QUARTER_CYCLES=3;
    defparam dut.u_config.RESET_CYCLES=8;
    defparam dut.u_config.SETTLE_CYCLES=8;
    defparam dut.u_config.SOFT_RESET_CYCLES=8;
    defparam dut.u_config.FRAME_SETTLE_CYCLES=8;

    // Register-level OV7670 model; transmit ninth bits are intentionally not
    // acknowledged, matching SCCB. The DUT must establish presence by reads.
    reg connected=0,slave_low=0,active=0,reading=0;
    reg [7:0] regs[0:255],shift=0,pointer=0,received,read_value;
    integer bit_no=0,byte_no=0,sccb_writes=0,sccb_reads=0,i;
    assign cam_siod=connected && slave_low ? 1'b0 : 1'bz;
    always @(*) begin
        read_value=regs[pointer];
        if(pointer==8'h03)read_value=regs[pointer]|8'hc0;
        if(pointer==8'h04)read_value=regs[pointer]|8'h03;
        if(pointer==8'h73)read_value=regs[pointer]&8'h0f;
    end
    always @(negedge cam_reset_n) begin
        active=0;slave_low=0;
        for(i=0;i<256;i=i+1)regs[i]=0;
        regs[8'h0a]=8'h76;regs[8'h0b]=8'h73;
    end
    always @(negedge cam_siod)if(cam_sioc===1'b1 && connected)begin
        active=1;reading=0;bit_no=0;byte_no=0;shift=0;
    end
    always @(posedge cam_siod)if(cam_sioc===1'b1 && active)begin
        active=0;slave_low=0;
    end
    always @(posedge cam_sioc)if(active && connected)begin
        if(!reading || byte_no==0)begin
            if(bit_no<8)begin
                received={shift[6:0],cam_siod};shift=received;
                if(bit_no==7)begin
                    if(byte_no==0)begin
                        if(received!==8'h42 && received!==8'h43)
                            $fatal(1,"Invalid SCCB address %h",received);
                        reading=(received==8'h43);
                    end else if(byte_no==1)pointer=received;
                    else if(byte_no==2)begin regs[pointer]=received;sccb_writes=sccb_writes+1;end
                end
                bit_no=bit_no+1;
            end else begin bit_no=0;byte_no=byte_no+1;end
        end else begin
            if(bit_no==8)begin
                if(cam_siod!==1'b1)$fatal(1,"SCCB read ninth bit is not released");
                bit_no=0;byte_no=byte_no+1;sccb_reads=sccb_reads+1;
            end else bit_no=bit_no+1;
        end
    end
    always @(negedge cam_sioc)begin
        if(active && connected && reading && byte_no==1 && bit_no<8)
            slave_low=!read_value[7-bit_no];
        else slave_low=0;
    end

    // Serialize all diagnostic traffic through the actual top's UART pin.
    wire [7:0] rx_data;
    wire rx_valid,rx_error;
    uart_rx #(.CLK_HZ(50000000),.BAUD(1000000)) u_monitor(
        .clk(clk),.reset(dut.reset),.rx(uart_tx),.data(rx_data),
        .valid(rx_valid),.framing_error(rx_error));
    reg [7:0] packet[0:9];
    reg [7:0] last_seq=0,last_flags=0,last_cfg_index=0,last_min=0,last_max=0;
    reg [15:0] last_frames=0;
    integer rx_index=0,packet_count=0,sum=0;
    reg have_seq=0;
    always @(posedge clk)begin
        if(dut.reset)begin rx_index=0;have_seq=0;end
        else begin
            if(rx_error)$fatal(1,"UART framing error");
            if(rx_valid)begin
                packet[rx_index]=rx_data;
                if(rx_index==0 && rx_data!==8'haa)$fatal(1,"UART magic AA missing");
                if(rx_index==1 && rx_data!==8'hc1)$fatal(1,"UART diagnostic type C1 missing");
                if(rx_index==9)begin
                    sum=packet[2]+packet[3]+packet[4]+packet[5]+packet[6]+packet[7]+packet[8];
                    if(rx_data!==sum[7:0])$fatal(1,"UART checksum mismatch");
                    if(have_seq && packet[2]!==((last_seq+1)&8'hff))
                        $fatal(1,"UART packet sequence skipped");
                    if(packet[3][6]!==0)$fatal(1,"Reserved UART flag asserted");
                    if(packet[3][2] && (packet[7]>packet[8]))$fatal(1,"Invalid min/max snapshot");
                    last_seq=packet[2];last_flags=packet[3];last_cfg_index=packet[4];
                    last_frames={packet[6],packet[5]};last_min=packet[7];last_max=packet[8];
                    packet_count=packet_count+1;have_seq=1;rx_index=0;
                end else rx_index=rx_index+1;
            end
        end
    end

    integer writes=0,total_writes=0,good_frames=0;
    reg check_pixels=0;
    function [7:0] pattern;
        input integer address;
        begin pattern=(address*13+17)%256;end
    endfunction
    always @(posedge clk)if(!dut.reset)begin
        if(dut.frame_wr_en)begin
            if(dut.frame_wr_addr!==writes)$fatal(1,"Frame write order failed %0d/%0d",dut.frame_wr_addr,writes);
            if(check_pixels && dut.frame_wr_data!==pattern(writes))
                $fatal(1,"Y byte mismatch at%0d got%0d expected%0d",writes,dut.frame_wr_data,pattern(writes));
            writes=writes+1;total_writes=total_writes+1;
        end
        if(dut.capture_done)begin
            if(writes!=19200)$fatal(1,"Frame accepted with %0d pixels",writes);
            good_frames=good_frames+1;
        end
    end
    task reset_board;
        begin
            sw[15]=1;btnC=1;
            repeat(10)@(negedge clk);
            btnC=0;
            repeat(10)@(negedge clk);
        end
    endtask
    task wait_configuration;
        input integer want_ready;
        integer n;
        begin
            n=0;
            while(!dut.config_ready && !dut.config_error && n<100000)begin
                @(negedge clk);n=n+1;
            end
            if(want_ready && (!dut.config_ready || dut.config_error))
                $fatal(1,"Camera configuration did not succeed");
            if(!want_ready && (!dut.config_error || dut.config_ready))
                $fatal(1,"Absent camera falsely detected");
        end
    endtask
    task wait_packet;
        input [7:0] mask,flags;
        input [15:0] frames;
        integer n,old_count;
        begin
            n=0;old_count=packet_count;
            while((packet_count==old_count || (last_flags&mask)!=flags || last_frames!=frames) && n<1000000)begin
                @(negedge clk);n=n+1;
            end
            if(n>=1000000)$fatal(1,"Status timeout flags%h expected%h mask%h frames%0d/%0d",last_flags,flags,mask,last_frames,frames);
        end
    endtask
    task arm;
        integer n;
        begin
            writes=0;sw[15]=0;n=0;
            while(!dut.capture_busy && n<10000)begin @(negedge clk);n=n+1;end
            if(!dut.capture_busy)$fatal(1,"Capture did not start/recover");
            #137;
        end
    endtask
    task boundary;
        begin cam_href=0;cam_pclk=0;cam_vsync=1;#241;cam_vsync=0;#239;end
    endtask
    task byte_out;
        input [7:0] value;
        begin cam_pclk=0;cam_data=value;#100;cam_pclk=1;#100;cam_pclk=0;end
    endtask
    task complete_frame;
        integer x,y;
        begin
            check_pixels=1;boundary;
            for(y=0;y<120;y=y+1)begin
                cam_href=1;#77;
                for(x=0;x<160;x=x+1)begin
                    byte_out(pattern(y*160+x));byte_out(8'he1);
                end
                cam_href=0;#317;
            end
            if(dut.frame_count!=good_frames)$fatal(1,"Unexpected early completion");
            sw[15]=1;boundary;repeat(10)@(negedge clk);
            if(!dut.frame_valid || dut.frame_fault || dut.last_min!=0 || dut.last_max!=255)
                $fatal(1,"Complete frame status/min/max wrong");
            for(x=0;x<19200;x=x+1)
                if(dut.frame_mem[x]!==pattern(x))$fatal(1,"Stored frame pixel mismatch%0d",x);
            if(!led[0] || !led[1] || led[5] || seg!==7'b0001110)
                $fatal(1,"Valid frame indicators incorrect");
        end
    endtask
    integer before_frames;
    initial begin
        for(i=0;i<256;i=i+1)regs[i]=0;
        regs[8'h0a]=8'h76;regs[8'h0b]=8'h73;
        repeat(30)@(negedge clk);
        wait_configuration(0);
        wait_packet(8'h87,8'h82,0);
        if(last_cfg_index!==8'h0a || last_min!==8'hff || last_max!==8'h76)
            $fatal(1,"UART lost failed register/readback/expected diagnostics");
        if(!led[4] || led[0] || seg!==7'b0000110)$fatal(1,"Absent camera indicators incorrect");
        $display("PASS: absent camera ID read fails; UART and E indicator agree");
        connected=1;reset_board;wait_configuration(1);
        wait_packet(8'h87,8'h81,0);
        if(!led[0] || led[1] || seg!==7'b1000110)$fatal(1,"Identified camera indicators incorrect");
        if(sccb_writes!=24 || sccb_reads!=25)$fatal(1,"Missing actual SCCB configuration transactions");
        $display("PASS: actual SCCB ID/config/readback reaches camera-ready and UART C status");
        arm;complete_frame;
        wait_packet(8'h97,8'h85,1);
        if(last_min!=0 || last_max!=255)$fatal(1,"UART extrema incorrect");
        $display("PASS: complete camera frame has19200 verified pixels and snapshot UART min/max/count");

        // No more PCLK/VSYNC: stale success must disappear after timeout.
        arm;sw[15]=1;
        wait_packet(8'h97,8'h91,1);
        if(dut.frame_valid || !dut.frame_fault || seg!==7'b0100001)
            $fatal(1,"Disconnected stream retained valid frame");
        $display("PASS: stream timeout clears stale success and reports d/fault");
        arm;complete_frame;
        wait_packet(8'h97,8'h85,2);
        $display("PASS: valid frame recovers without reset after sticky capture fault");

        // An incomplete row cannot increment complete-frame count.
        before_frames=good_frames;arm;check_pixels=0;boundary;
        cam_href=1;#77;byte_out(17);byte_out(8'he1);cam_href=0;sw[15]=1;#317;
        wait_packet(8'h97,8'h91,2);
        if(good_frames!=before_frames || writes!=1 || dut.frame_valid)
            $fatal(1,"Malformed frame accepted");
        $display("PASS: malformed row rejected, no completion or stale preview");

        // Reset during a new capture aborts it and rechecks the sensor.
        arm;reset_board;wait_configuration(1);
        wait_packet(8'h97,8'h81,0);
        if(dut.frame_valid || dut.frame_fault || dut.frame_count!=0 || dut.capture_busy)
            $fatal(1,"Reset did not clear frame state");
        if(packet_count<6)$fatal(1,"Insufficient UART checks");
        $display("PASS: button reset aborts capture, clears counters and reconfigures camera");
        $display("CAMERA_TEST_TOP_PASS good_frames=%0d raw_pixels=%0d uart_packets=%0d",good_frames,total_writes,packet_count);
        $finish;
    end
    initial begin #100000000;$fatal(1,"Diagnostic integration timeout");end
endmodule
