`timescale 1ns / 1ps

// Verification only. Drives the unmodified upstream inference engine and ROMs.
// Checks genuine MNIST images against the independently generated integer model.
module tb_inference_reference;
    localparam NUM_CASES = 20;
    localparam MAX_CYCLES_PER_CASE = 60000;

    reg clk = 1'b0;
    always #5 clk = ~clk; // Basys 3 oscillator: 100 MHz.

    reg reset = 1'b1;
    reg start = 1'b0;
    wire [9:0] pix_addr;
    reg [7:0] pix_data = 8'd0;
    wire [3:0] digit;
    wire [6:0] confidence;
    wire done;
    wire busy;

    reg [7:0] pixels [0:NUM_CASES*784-1];
    reg [7:0] expected_digits [0:NUM_CASES-1];
    reg [7:0] expected_hidden [0:NUM_CASES*32-1];
    reg signed [31:0] expected_logits [0:NUM_CASES*10-1];
    integer case_index = 0;
    integer case_cycles;
    integer first_case_cycles = -1;
    integer case_logit_checks = 0;
    integer total_logit_checks = 0;
    integer total_hidden_checks = 0;
    integer hidden_index;
    integer report_file;
    reg running_case = 1'b0;

    // Exactly the same one-cycle synchronous pixel RAM contract as the board.
    always @(posedge clk)
        if (pix_addr < 784 && case_index < NUM_CASES)
            pix_data <= pixels[case_index*784 + pix_addr];

    inference_engine #(.SHIFT1(10)) dut (
        .clk(clk), .reset(reset), .start(start),
        .pix_addr(pix_addr), .pix_data(pix_data),
        .digit(digit), .confidence(confidence), .done(done), .busy(busy)
    );

    // At S_L2_STORE, the final MAC has completed and acc is the signed logit.
    // Inspect on the falling edge so all preceding nonblocking writes settled.
    always @(negedge clk) begin
        if (!reset && running_case && dut.state === 4'd12) begin
            if (dut.h !== case_logit_checks)
                $fatal(1, "Unexpected output order: image=%0d neuron=%0d expected=%0d",
                       case_index, dut.h, case_logit_checks);
            if (dut.acc !== expected_logits[case_index*10 + dut.h])
                $fatal(1, "Logit mismatch: image=%0d neuron=%0d actual=%0d expected=%0d",
                       case_index, dut.h, dut.acc, expected_logits[case_index*10 + dut.h]);
            case_logit_checks = case_logit_checks + 1;
            total_logit_checks = total_logit_checks + 1;
        end
    end

    initial begin
        $readmemh("test_pixels.mem", pixels);
        $readmemh("test_expected.mem", expected_digits);
        $readmemh("test_hidden.mem", expected_hidden);
        $readmemh("test_logits.mem", expected_logits);
        repeat (5) @(negedge clk);
        reset = 1'b0;
        repeat (2) @(negedge clk);

        for (case_index = 0; case_index < NUM_CASES; case_index = case_index + 1) begin
            // Deliberately no reset between cases: test repeated inference.
            case_logit_checks = 0;
            case_cycles = 0;
            running_case = 1'b1;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            while (done !== 1'b1 && case_cycles < MAX_CYCLES_PER_CASE) begin
                @(negedge clk);
                case_cycles = case_cycles + 1;
            end
            if (done !== 1'b1)
                $fatal(1, "Inference timeout: image=%0d cycles=%0d", case_index, case_cycles);
            if (busy !== 1'b0)
                $fatal(1, "busy must be low with done: image=%0d", case_index);
            if (digit !== expected_digits[case_index][3:0])
                $fatal(1, "Prediction mismatch: image=%0d actual=%0d expected=%0d",
                       case_index, digit, expected_digits[case_index]);
            if (case_logit_checks != 10)
                $fatal(1, "Missing logit checks: image=%0d checked=%0d", case_index, case_logit_checks);
            for (hidden_index = 0; hidden_index < 32; hidden_index = hidden_index + 1) begin
                if (dut.hidden[hidden_index] !== expected_hidden[case_index*32 + hidden_index])
                    $fatal(1, "Hidden mismatch: image=%0d neuron=%0d actual=%0d expected=%0d",
                           case_index, hidden_index, dut.hidden[hidden_index],
                           expected_hidden[case_index*32 + hidden_index]);
                total_hidden_checks = total_hidden_checks + 1;
            end
            if (first_case_cycles == -1)
                first_case_cycles = case_cycles;
            else if (case_cycles != first_case_cycles)
                $fatal(1, "Inference latency changed between images");
            $display("PASS image=%0d prediction=%0d cycles=%0d hidden=32 logits=10",
                     case_index, digit, case_cycles);
            running_case = 1'b0;
            @(negedge clk);
            if (done !== 1'b0)
                $fatal(1, "done did not return low after one clock");
            repeat (2) @(negedge clk);
        end

        if (total_logit_checks != NUM_CASES*10 || total_hidden_checks != NUM_CASES*32)
            $fatal(1, "Incomplete verification coverage");
        report_file = $fopen("rtl_reference_report.json", "w");
        if (!report_file)
            $fatal(1, "Cannot write RTL verification report");
        $fdisplay(report_file, "{");
        $fdisplay(report_file, "  \"result\": \"PASS\",");
        $fdisplay(report_file, "  \"simulator\": \"Vivado XSim 2026.1\",");
        $fdisplay(report_file, "  \"subject\": \"Unmodified upstream inference_engine.v and weight_rom.v\",");
        $fdisplay(report_file, "  \"mnist_original_test_indices\": \"0 through 19\",");
        $fdisplay(report_file, "  \"predictions_compared\": %0d,", NUM_CASES);
        $fdisplay(report_file, "  \"hidden_activations_compared\": %0d,", total_hidden_checks);
        $fdisplay(report_file, "  \"signed_logits_compared\": %0d,", total_logit_checks);
        $fdisplay(report_file, "  \"cycles_from_start_acceptance_to_done\": %0d,", first_case_cycles);
        $fdisplay(report_file, "  \"clock_hz\": 100000000,");
        $fdisplay(report_file, "  \"reset_between_inferences\": false,");
        $fdisplay(report_file, "  \"physical_hardware_test\": false");
        $fdisplay(report_file, "}");
        $fclose(report_file);
        $display("REFERENCE_SIM_PASS predictions=%0d hidden=%0d logits=%0d cycles=%0d",
                 NUM_CASES, total_hidden_checks, total_logit_checks, first_case_cycles);
        $finish;
    end

    initial begin
        #13000000;
        $fatal(1, "Global simulation watchdog expired");
    end
endmodule
