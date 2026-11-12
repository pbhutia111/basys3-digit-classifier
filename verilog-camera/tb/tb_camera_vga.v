`timescale 1ns / 1ps

module tb_camera_vga;
    reg clk = 1'b0;
    always #10 clk = ~clk;
    reg reset = 1'b1;
    reg frame_valid = 1'b0;
    reg pixels_valid = 1'b0;
    wire [14:0] frame_addr;
    wire [9:0] pix_addr;
    reg [7:0] frame_data;
    reg [7:0] pix_data;
    wire [3:0] red, green, blue;
    wire hs, vs;

    camera_vga dut (
        .clk(clk), .reset(reset), .frame_valid(frame_valid),
        .pixels_valid(pixels_valid), .frame_addr(frame_addr),
        .frame_data(frame_data), .pix_addr(pix_addr), .pix_data(pix_data),
        .vgaRed(red), .vgaGreen(green), .vgaBlue(blue),
        .Hsync(hs), .Vsync(vs)
    );

    // Different, address-dependent patterns expose stale addresses, wrong
    // scaling, crossed memory ports, and a one-clock RAM alignment error.
    function [7:0] raw_pattern;
        input integer address;
        begin
            raw_pattern = (address ^ (address >> 4) ^ (address >> 8)) ^ 8'ha5;
        end
    endfunction
    function [7:0] pixel_pattern;
        input integer address;
        begin
            pixel_pattern = ((address * 7) ^ (address >> 3)) ^ 8'h3c;
        end
    endfunction
    always @(posedge clk) begin
        // Invalid memory deliberately produces X. Valid flags must mask it.
        frame_data <= frame_valid ? raw_pattern(frame_addr) : 8'hxx;
        pix_data <= pixels_valid ? pixel_pattern(pix_addr) : 8'hxx;
    end

    integer x = 0;
    integer y = 0;
    integer phase = 0;
    integer previous_x = 0;
    integer previous_y = 0;
    integer cycles;
    integer frame_index;
    integer want_raw_addr;
    integer want_pix_addr;
    integer raw_first_hits = 0;
    integer raw_last_hits = 0;
    integer pix_first_hits = 0;
    integer pix_last_hits = 0;
    integer hlow_count = 0;
    integer vlow_count = 0;
    integer image_clock_count = 0;
    reg previous_valid = 1'b0;
    reg previous_frame_valid = 1'b0;
    reg previous_pixels_valid = 1'b0;
    reg want_hs;
    reg want_vs;
    reg [11:0] want_rgb;
    reg [7:0] value;

    task check_cycle;
        begin
            // Check requested addresses independently of DUT internals.
            want_raw_addr = 0;
            want_pix_addr = 0;
            if (x >= 16 && x < 336 && y >= 120 && y < 360)
                want_raw_addr = ((y - 120) / 2) * 160 + ((x - 16) / 2);
            if (x >= 368 && x < 592 && y >= 128 && y < 352)
                want_pix_addr = ((y - 128) / 8) * 28 + ((x - 368) / 8);
            if (frame_addr !== want_raw_addr[14:0] || pix_addr !== want_pix_addr[9:0])
                $fatal(1, "Read address mismatch x=%0d y=%0d raw=%0d/%0d pix=%0d/%0d",
                    x, y, frame_addr, want_raw_addr, pix_addr, want_pix_addr);
            if (frame_addr >= 19200 || pix_addr >= 784)
                $fatal(1, "Read address out of range");

            // Previous request enters registered VGA outputs at this edge.
            want_rgb = 12'd0;
            want_hs = 1'b1;
            want_vs = 1'b1;
            if (previous_valid) begin
                want_hs = !(previous_x >= 656 && previous_x < 752);
                want_vs = !(previous_y >= 490 && previous_y < 492);
                if (previous_frame_valid &&
                    (((previous_x == 64 || previous_x == 287) && previous_y >= 128 && previous_y <= 351) ||
                     ((previous_y == 128 || previous_y == 351) && previous_x >= 64 && previous_x <= 287))) begin
                    want_rgb = 12'h0f0;
                end else if (previous_frame_valid && previous_x >= 16 && previous_x < 336 &&
                             previous_y >= 120 && previous_y < 360) begin
                    value = raw_pattern(((previous_y - 120) / 2) * 160 + ((previous_x - 16) / 2));
                    want_rgb = {value[7:4], value[7:4], value[7:4]};
                    if (previous_x == 16 && previous_y == 120) raw_first_hits = raw_first_hits + 1;
                    if (previous_x == 335 && previous_y == 359) raw_last_hits = raw_last_hits + 1;
                end else if (previous_pixels_valid && previous_x >= 368 && previous_x < 592 &&
                             previous_y >= 128 && previous_y < 352) begin
                    value = pixel_pattern(((previous_y - 128) / 8) * 28 + ((previous_x - 368) / 8));
                    want_rgb = {value[7:4], value[7:4], value[7:4]};
                    if (previous_x == 368 && previous_y == 128) pix_first_hits = pix_first_hits + 1;
                    if (previous_x == 591 && previous_y == 351) pix_last_hits = pix_last_hits + 1;
                end
            end

            @(posedge clk);
            #1;
            if ({red, green, blue} !== want_rgb || hs !== want_hs || vs !== want_vs)
                $fatal(1, "VGA mismatch x=%0d y=%0d rgb=%03h/%03h hs=%b/%b vs=%b/%b",
                    previous_x, previous_y, {red, green, blue}, want_rgb, hs, want_hs, vs, want_vs);
            if (previous_valid) begin
                image_clock_count = image_clock_count + 1;
                if (!hs) hlow_count = hlow_count + 1;
                if (!vs) vlow_count = vlow_count + 1;
            end

            previous_x = x;
            previous_y = y;
            previous_frame_valid = frame_valid;
            previous_pixels_valid = pixels_valid;
            previous_valid = 1'b1;
            if (phase == 1) begin
                if (x == 799) begin
                    x = 0;
                    y = (y == 524) ? 0 : y + 1;
                end else x = x + 1;
            end
            phase = 1 - phase;
            @(negedge clk);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        #1;
        if ({red, green, blue, hs, vs} !== {12'd0, 2'b11})
            $fatal(1, "Reset outputs wrong");
        @(negedge clk);
        reset = 1'b0;

        // Full rasters for each validity combination prove independent gating.
        for (frame_index = 0; frame_index < 4; frame_index = frame_index + 1) begin
            frame_valid = frame_index[0];
            pixels_valid = frame_index[1];
            for (cycles = 0; cycles < 800 * 525 * 2; cycles = cycles + 1)
                check_cycle;
        end
        // Flush the final requested pixel without adding another raster.
        check_cycle;
        if (image_clock_count != 4 * 800 * 525 * 2 ||
            hlow_count != 4 * 96 * 525 * 2 || vlow_count != 4 * 2 * 800 * 2)
            $fatal(1, "Raster/sync counts wrong: clocks=%0d hlow=%0d vlow=%0d",
                image_clock_count, hlow_count, vlow_count);
        if (raw_first_hits != 4 || raw_last_hits != 4 || pix_first_hits != 4 || pix_last_hits != 4)
            $fatal(1, "Missing image endpoints: raw=%0d/%0d pix=%0d/%0d",
                raw_first_hits, raw_last_hits, pix_first_hits, pix_last_hits);
        $display("PASS: camera_vga four full rasters, sync timing, memory pipeline, ROI, endpoints, independent validity gating");
        $finish;
    end

    initial begin
        #100000000;
        $fatal(1, "Timeout");
    end
endmodule
