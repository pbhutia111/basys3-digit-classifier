`timescale 1ns/1ps
module tb_camera_preprocess;
    reg clk=0;
    always #10 clk=~clk;
    reg reset=1, start=0, invert=1;
    reg [7:0] threshold=80;
    wire [14:0] frame_addr;
    reg [7:0] frame_data;
    wire pix_wr_en;
    wire [9:0] pix_wr_addr;
    wire [7:0] pix_wr_data;
    wire done,busy,blank;
    reg [7:0] frame [0:19199];
    reg [7:0] expected [0:783];
    integer count=0, tests=0, expected_blank=0;
    reg checking=0;
    integer i,x,y;
    camera_preprocess dut(
        .clk(clk),.reset(reset),.start(start),.threshold(threshold),.invert(invert),
        .frame_addr(frame_addr),.frame_data(frame_data),
        .pix_wr_en(pix_wr_en),.pix_wr_addr(pix_wr_addr),.pix_wr_data(pix_wr_data),
        .done(done),.busy(busy),.blank(blank));
    // Deliberately registered memory: combinational memory would hide a
    // one-cycle read-address mistake in the implementation.
    always @(posedge clk) begin
        if (frame_addr < 19200) frame_data <= frame[frame_addr];
        else if (!reset) $fatal(1,"Out-of-range frame read %0d",frame_addr);
        if (!reset && pix_wr_en) begin
            if (!checking) $fatal(1,"Unexpected output write");
            if (count >= 784 || pix_wr_addr !== count)
                $fatal(1,"Write order: count=%0d address=%0d",count,pix_wr_addr);
            if (pix_wr_data !== expected[count])
                $fatal(1,"Test %0d pixel %0d got %0d expected %0d",tests,count,pix_wr_data,expected[count]);
            count=count+1;
        end
    end
    task fill;
        input [7:0] value;
        integer n;
        begin for(n=0;n<19200;n=n+1) frame[n]=value; end
    endtask
    // Independent behavioral reference: direct integer coordinate division
    // and rectangular-area sums instead of the RTL's incremental boundary
    // generator and sequential division FSMs.
    task reference;
        integer xx,yy,v,n,lo_x,hi_x,lo_y,hi_y,bw,bh,sw,sh,ox,oy;
        integer dx,dy,sx,sy,ax,bx,ay,by,total,samples;
        begin
            n=0; lo_x=160; hi_x=0; lo_y=120; hi_y=0;
            for(yy=4;yy<=115;yy=yy+1) begin
                for(xx=24;xx<=135;xx=xx+1) begin
                    v=invert ? 255-frame[yy*160+xx] : frame[yy*160+xx];
                    if(v!=0 && v>=threshold) begin
                        n=n+1;
                        if(xx<lo_x)lo_x=xx;
                        if(xx>hi_x)hi_x=xx;
                        if(yy<lo_y)lo_y=yy;
                        if(yy>hi_y)hi_y=yy;
                    end
                end
            end
            for(xx=0;xx<784;xx=xx+1) expected[xx]=0;
            expected_blank=(n<8);
            if(!expected_blank) begin
                bw=hi_x-lo_x+1; bh=hi_y-lo_y+1;
                if(bw>=bh) begin
                    sw=20; sh=(bh*20+bw/2)/bw;
                    if(sh<1)sh=1;
                end else begin
                    sh=20; sw=(bw*20+bh/2)/bh;
                    if(sw<1)sw=1;
                end
                ox=(28-sw)/2; oy=(28-sh)/2;
                for(dy=0;dy<sh;dy=dy+1) begin
                    for(dx=0;dx<sw;dx=dx+1) begin
                        ax=dx*bw/sw; bx=(dx+1)*bw/sw;
                        ay=dy*bh/sh; by=(dy+1)*bh/sh;
                        if(bx<=ax)bx=ax+1;
                        if(by<=ay)by=ay+1;
                        total=0;samples=0;
                        for(sy=ay;sy<by;sy=sy+1) begin
                            for(sx=ax;sx<bx;sx=sx+1) begin
                                v=invert ? 255-frame[(lo_y+sy)*160+lo_x+sx]
                                         : frame[(lo_y+sy)*160+lo_x+sx];
                                if(v!=0 && v>=threshold)total=total+v;
                                samples=samples+1;
                            end
                        end
                        expected[(oy+dy)*28+ox+dx]=(total+samples/2)/samples;
                    end
                end
            end
        end
    endtask
    task run_case;
        input integer perturb_controls;
        integer cycles;
        reg [7:0] saved_threshold;
        reg saved_invert;
        begin
            tests=tests+1;
            reference;
            saved_threshold=threshold; saved_invert=invert;
            count=0; checking=1;
            @(negedge clk);start=1;
            @(negedge clk);start=0;
            if(!busy)$fatal(1,"Start not accepted");
            if(perturb_controls) begin
                repeat(100)@(negedge clk);
                threshold=250;invert=~saved_invert;start=1;
                @(negedge clk);start=0;
            end
            cycles=0;
            while(!done && cycles<200000) begin
                @(negedge clk);cycles=cycles+1;
            end
            if(!done)$fatal(1,"Preprocessor timeout");
            if(busy)$fatal(1,"busy still high at done");
            if(blank!==expected_blank[0])$fatal(1,"Wrong blank result");
            if(count!=784)$fatal(1,"Wrong write count %0d",count);
            checking=0;
            @(negedge clk);
            if(done)$fatal(1,"done not a pulse");
            threshold=saved_threshold;invert=saved_invert;
            $display("PREPROCESS_CASE_PASS %0d cycles=%0d blank=%0d",tests,cycles,expected_blank);
        end
    endtask
    initial begin
        fill(255);
        repeat(4)@(negedge clk);reset=0;
        run_case(0); // Blank paper.
        fill(255);
        for(y=25;y<85;y=y+1)for(x=70;x<88;x=x+1)frame[y*160+x]=20;
        run_case(1); // Portrait: aspect, gray intensity, latched controls/start.
        fill(0);invert=0;
        for(y=50;y<68;y=y+1)for(x=40;x<100;x=x+1)
            frame[y*160+x]=((x+y)%5==0)?0:((x*3+y)%176+80);
        run_case(0); // Landscape, bright ink, sparse gray edges.
        fill(255);invert=1;
        for(y=4;y<=115;y=y+1)for(x=24;x<=135;x=x+1)
            frame[y*160+x]=((x+y)%3==0)?255:0;
        run_case(0); // Largest ROI, averaging and final scan pixel.
        fill(255);
        for(y=108;y<=115;y=y+1)frame[y*160+135]=0;
        run_case(0); // Exactly eight pixels on bottom-right ROI boundary.
        fill(255);
        for(x=24;x<32;x=x+1)frame[4*160+x]=0;
        run_case(0); // Exactly eight pixels on top-left ROI boundary.
        fill(255);
        for(x=24;x<31;x=x+1)frame[4*160+x]=0;
        run_case(0); // Seven pixels are noise/blank, previous result erased.
        fill(255);
        for(y=0;y<120;y=y+1)begin frame[y*160]=0;frame[y*160+159]=0;end
        for(x=0;x<160;x=x+1)begin frame[x]=0;frame[119*160+x]=0;end
        run_case(0); // Out-of-ROI ink cannot define the bounding box.
        fill(176);
        for(y=40;y<48;y=y+1)frame[y*160+50]=175;
        run_case(0); // Threshold80 includes exactly80, excludes79 background.

        // Reset must abort a scan without done or writes, then permit restart.
        @(negedge clk);start=1;
        @(negedge clk);start=0;
        repeat(10)@(negedge clk);
        reset=1;
        @(negedge clk);
        if(busy||done||pix_wr_en)$fatal(1,"Reset did not abort");
        reset=0;
        fill(255);
        run_case(0);
        $display("CAMERA_PREPROCESS_PASS tests=%0d",tests);
        $finish;
    end
    initial begin #100000000; $fatal(1,"Global timeout"); end
endmodule
