`timescale 1ns/1ps
module tb_ov7670_config;
    reg clk=0, reset=1;
    always #10 clk=~clk;
    tri1 sioc, siod;
    wire ready,error,cam_reset_n,cam_pwdn;
    wire [7:0] debug_index;
    wire [7:0] debug_register,debug_readback,debug_expected;
    reg connected=1, corrupt=0;
    reg [7:0] corrupt_register=8'h72;
    integer writes, reads, starts, stops;
    ov7670_config #(.SCCB_QUARTER_CYCLES(3), .RESET_CYCLES(8),
        .SETTLE_CYCLES(8),.SOFT_RESET_CYCLES(8),.FRAME_SETTLE_CYCLES(8)) dut (
        .clk(clk),.reset(reset),.siod(siod),.sioc(sioc),
        .cam_reset_n(cam_reset_n),.cam_pwdn(cam_pwdn),.ready(ready),
        .error(error),.debug_index(debug_index),.debug_register(debug_register),
        .debug_readback(debug_readback),.debug_expected(debug_expected)
    );
    // A bus-level slave, independent of DUT internals. It intentionally
    // leaves all ninth TX bits HIGH: legal SCCB don't-care, not I2C ACK.
    reg slave_low=0, active=0, reading=0;
    reg [7:0] regs[0:255];
    reg [7:0] shift=0, pointer=0, received;
    integer bit_no=0, byte_no=0, i;
    reg [7:0] read_value;
    assign siod = connected && slave_low ? 1'b0 : 1'bz;
    always @(*) begin
        read_value = regs[pointer];
        // Real AEC/AGC updates these fields independently of SCCB writes.
        if (pointer == 8'h03) read_value = regs[pointer] | 8'hc0;
        if (pointer == 8'h04) read_value = regs[pointer] | 8'h03;
        // Reserved fields need not echo written values on every revision.
        if (pointer == 8'h73) read_value = regs[pointer] & 8'h0f;
        if (corrupt && pointer == corrupt_register) read_value = 8'h00;
    end
    always @(negedge cam_reset_n) begin
        active=0; slave_low=0;
        for (i=0;i<256;i=i+1) regs[i]=0;
        regs[8'h0a]=8'h76; regs[8'h0b]=8'h73;
    end
    always @(negedge siod) if (sioc===1'b1 && connected) begin
        active=1; reading=0; bit_no=0; byte_no=0; shift=0;
        starts=starts+1;
    end
    always @(posedge siod) if (sioc===1'b1 && active) begin
        active=0; slave_low=0; stops=stops+1;
    end
    always @(posedge sioc) if (active && connected) begin
        if (!reading || byte_no==0) begin
            if (bit_no<8) begin
                received={shift[6:0],siod}; shift=received;
                if (bit_no==7) begin
                    if (byte_no==0) begin
                        if (received!==8'h42 && received!==8'h43)
                            $fatal(1,"Wrong SCCB wire ID: %h",received);
                        reading=(received==8'h43);
                    end else if (byte_no==1) pointer=received;
                    else if (byte_no==2) begin
                        regs[pointer]=received; writes=writes+1;
                    end
                end
                bit_no=bit_no+1;
            end else begin bit_no=0; byte_no=byte_no+1; end
        end else begin
            if (bit_no==8) begin
                if (siod!==1'b1) $fatal(1,"Read ninth bit must be released HIGH");
                bit_no=0; byte_no=byte_no+1; reads=reads+1;
            end else bit_no=bit_no+1;
        end
    end
    always @(negedge sioc) begin
        if (active && connected && reading && byte_no==1 && bit_no<8)
            slave_low=!read_value[7-bit_no];
        else slave_low=0;
    end
    task restart;
        begin
            reset=1; repeat(6) @(negedge clk); reset=0;
            writes=0; reads=0; starts=0; stops=0;
        end
    endtask
    initial begin
        writes=0; reads=0; starts=0; stops=0;
        for(i=0;i<256;i=i+1) regs[i]=0;
        regs[8'h0a]=8'h76; regs[8'h0b]=8'h73;
        restart;
        wait(ready || error);
        if(!ready || error) $fatal(1,"Present camera failed index=%d",debug_index);
        if(writes!=24 || reads!=25 || starts!=74 || stops!=74)
            $fatal(1,"Bus transaction counts wrong w=%0d r=%0d start=%0d stop=%0d",writes,reads,starts,stops);
        if(regs[8'h11]!=8'h03 || regs[8'h6b]!=8'h0a ||
           regs[8'h72]!=8'h22 || regs[8'h73]!=8'hf2 ||
           regs[8'h3a]!=8'h04 || regs[8'h3d]!=8'h88)
            $fatal(1,"Clock/QQVGA/YUYV configuration mismatch");
        if(cam_pwdn!==0 || cam_reset_n!==1) $fatal(1,"Wrong control pin levels");
        $display("PASS: present camera, all writes/readbacks, SCCB ninth bit ignored");
        connected=0; restart;
        wait(ready || error);
        if(ready || !error) $fatal(1,"Disconnected camera falsely became ready");
        if(debug_register!==8'h0a || debug_readback!==8'hff || debug_expected!==8'h76)
            $fatal(1,"Absent sensor diagnostics incorrect reg=%h actual=%h expected=%h",debug_register,debug_readback,debug_expected);
        $display("PASS: absent camera cannot become ready");
        connected=1; corrupt=1; restart;
        wait(ready || error);
        if(ready || !error || debug_index!=8)
            $fatal(1,"Corrupt register readback not rejected index=%0d",debug_index);
        if(debug_register!==8'h72 || debug_readback!==8'h00 || debug_expected!==8'h22)
            $fatal(1,"Corrupt register diagnostics incorrect");
        $display("PASS: wrong configuration readback rejected");
        corrupt_register=8'h11; restart;
        wait(ready || error);
        if(ready || !error || debug_index!=0 || debug_register!==8'h11 ||
           debug_readback!==8'h00 || debug_expected!==8'h03)
            $fatal(1,"First config failure not distinguished from PID failure");
        $display("PASS: first configuration error reports CLKRC rather than PID");
        $display("OV7670_CONFIG_TEST_PASS"); $finish;
    end
    initial begin #10000000; $fatal(1,"Configuration test timeout"); end
endmodule
