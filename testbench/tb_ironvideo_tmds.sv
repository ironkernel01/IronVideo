`timescale 1ns/1ps

// Verifies the DVI TMDS control and video symbol encodings and registered output.
// 11-18-2026: Initial exhaustive byte and running disparity regression.
// SystemVerilog-2012.
module tb_ironvideo_tmds;
  localparam logic [9:0] CONTROL_00 = 10'b1101010100;
  localparam int DISPARITY_LIMIT = 8;
  localparam int DISPARITY_STATES = DISPARITY_LIMIT + 1;

  logic clk = 0;
  logic rst = 0;
  logic [7:0] data = 0;
  logic de = 0;
  logic [1:0] control = 0;
  wire [9:0] symbol;
  int running_disparity = 0;
  logic [7:0] disparity_prefix [0:DISPARITY_STATES-1];
  bit [DISPARITY_STATES-1:0] prefix_found = '0;

  ironvideo_tmds_encoder dut (
    .clk(clk),
    .rst(rst),
    .data(data),
    .de(de),
    .control(control),
    .symbol(symbol)
  );

  always #5ns clk = ~clk;

  function automatic logic [9:0] control_symbol(input logic [1:0] value);
    case (value)
      2'b00: return CONTROL_00;
      2'b01: return 10'b0010101011;
      2'b10: return 10'b0101010100;
      2'b11: return 10'b1010101011;
      default: return 'x;
    endcase
  endfunction

  task automatic drive(
    input logic reset_value,
    input logic active_video,
    input logic [7:0] pixel,
    input logic [1:0] control_value
  );
    logic [9:0] previous_symbol;

    @(negedge clk);
    previous_symbol = symbol;
    rst = reset_value;
    de = active_video;
    data = pixel;
    control = control_value;
    #1ns;
    if (symbol !== previous_symbol)
      $fatal(1, "TEST FAIL: TMDS symbol changed between rising clock edges");
    @(posedge clk);
    #1ns;
  endtask

  task automatic check_control(input logic reset_value, input logic [1:0] control_value);
    logic [9:0] expected;

    // Reset overrides active video and a nonzero control value.
    drive(reset_value, reset_value, 8'hff, control_value);
    expected = reset_value ? CONTROL_00 : control_symbol(control_value);
    if (symbol !== expected)
      $fatal(1, "TEST FAIL: reset=%b control=%b symbol=%b expected=%b",
             reset_value, control_value, symbol, expected);
    running_disparity = 0;
  endtask

  task automatic check_video(input logic [7:0] pixel, input logic [1:0] control_value);
    logic [7:0] intermediate;
    logic [7:0] decoded;
    bit expected_xor;
    bit expected_inverted;
    int xor_transitions;
    int intermediate_disparity;

    drive(1'b0, 1'b1, pixel, control_value);
    if ($isunknown(symbol))
      $fatal(1, "TEST FAIL: unknown TMDS symbol for pixel %h", pixel);

    // Recover the transition-minimized byte and decode its adjacent-bit differences.
    intermediate = symbol[9] ? ~symbol[7:0] : symbol[7:0];
    decoded[0] = intermediate[0];
    for (int i = 1; i < 8; i++)
      decoded[i] = intermediate[i] ^ intermediate[i-1] ^ !symbol[8];
    if (decoded !== pixel)
      $fatal(1, "TEST FAIL: TMDS symbol %b decoded to %h instead of %h", symbol, decoded, pixel);

    // XOR transitions match the upper seven input bits. XNOR takes their complement.
    // The first bit is copied, so comparing transition counts needs no tiebreaker.
    xor_transitions = $countones(pixel[7:1]);
    expected_xor = xor_transitions < (7 - xor_transitions);
    if (symbol[8] !== expected_xor)
      $fatal(1, "TEST FAIL: TMDS XOR/XNOR choice for pixel %h symbol=%b", pixel, symbol);

    // The two encodings of the intermediate byte have opposite payload disparities.
    // On neutral payload or accumulator disparity, DVI uses complementary flags.
    intermediate_disparity = 2 * $countones(intermediate) - 8;
    expected_inverted = !symbol[8];
    if ((running_disparity != 0) && (intermediate_disparity != 0))
      expected_inverted = (running_disparity > 0) == (intermediate_disparity > 0);
    if (symbol[9] !== expected_inverted)
      $fatal(1, "TEST FAIL: TMDS inversion for pixel %h disparity=%0d symbol=%b expected invert=%b",
             pixel, running_disparity, symbol, expected_inverted);

    running_disparity += 2 * $countones(symbol) - 10;
    if ((running_disparity < -DISPARITY_LIMIT) || (running_disparity > DISPARITY_LIMIT))
      $fatal(1, "TEST FAIL: TMDS running disparity %0d outside legal range", running_disparity);
  endtask

  initial begin
    logic [15:0] lfsr;
    int disparity_index;

    // The first edge can use blanking. Apply reset with active video and C=11.
    check_control(1'b1, 2'b11);
    check_video(8'h00, 2'b01);
    check_control(1'b1, 2'b11);
    check_video(8'h00, 2'b10);
    for (int value = 0; value < 4; value++) begin
      check_control(1'b0, value[1:0]);
      check_video(8'h00, value[1:0]);
    end

    // Find a one-byte prefix for each legal disparity from neutral.
    for (int pixel = 0; pixel < 256; pixel++) begin
      check_control(1'b0, 2'b00);
      check_video(pixel[7:0], 2'b00);
      disparity_index = (running_disparity + DISPARITY_LIMIT) / 2;
      if (!prefix_found[disparity_index]) begin
        disparity_prefix[disparity_index] = pixel[7:0];
        prefix_found[disparity_index] = 1'b1;
      end
    end
    if (!(&prefix_found))
      $fatal(1, "TEST FAIL: missing TMDS disparity prefixes, coverage=%b", prefix_found);

    // Exercise all 256 input bytes from each of the nine legal disparities.
    for (int state = 0; state < DISPARITY_STATES; state++) begin
      for (int pixel = 0; pixel < 256; pixel++) begin
        check_control(1'b0, pixel[1:0]);
        check_video(disparity_prefix[state], 2'b11);
        if (running_disparity != (2 * state - DISPARITY_LIMIT))
          $fatal(1, "TEST FAIL: TMDS prefix %h produced disparity %0d, expected %0d",
                 disparity_prefix[state], running_disparity, 2 * state - DISPARITY_LIMIT);
        check_video(pixel[7:0], pixel[3:2]);
      end
    end

    // Check a color that repeats and a reproducible stream interrupted by blanking.
    for (int pixel = 0; pixel < 1024; pixel++)
      check_video(8'hff, pixel[1:0]);
    lfsr = 16'h1ace;
    for (int line = 0; line < 16; line++) begin
      for (int pixel = 0; pixel < 512; pixel++) begin
        check_video(lfsr[7:0], lfsr[9:8]);
        lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
      end
      for (int blank = 0; blank < 16; blank++)
        check_control(1'b0, blank[1:0]);
    end

    $display("TEST PASS: IronVideo TMDS encoder regression");
    $finish;
  end

  initial begin
    #1ms;
    $fatal(1, "TEST FAIL: TMDS encoder regression watchdog");
  end
endmodule
