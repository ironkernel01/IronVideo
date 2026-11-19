`timescale 1ns/1ps

// 11-18-2026, SystemVerilog-2012. Verify the 7-series UNISIM lane cascade
// and the backend's forwarded clock, differential outputs, and channel map.
module tb_ironvideo_tmds_7series;
  logic pixel_clk = 0;
  logic serial_clk = 0;
  logic reset_n = 0;
  logic [23:0] rgb = '0;
  logic de = 0;
  logic hs = 1;
  logic vs = 0;
  wire [2:0] tmds_data_p;
  wire [2:0] tmds_data_n;
  wire tmds_clk_p;
  wire tmds_clk_n;

  always #10 pixel_clk = !pixel_clk;
  always #2 serial_clk = !serial_clk;

  ironvideo_tmds_7series dut (
    .pixel_clk(pixel_clk), .serial_clk(serial_clk), .reset_n(reset_n),
    .rgb(rgb), .de(de), .hs(hs), .vs(vs), .tmds_data_p(tmds_data_p),
    .tmds_data_n(tmds_data_n), .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n)
  );

  task automatic receive_symbol(
    output logic [9:0] red, green, blue
  );
    // The falling forwarded clock edge marks bit zero of the serialized word.
    @(negedge tmds_clk_p);
    #0.8;
    for (int bit_index = 0; bit_index < 10; bit_index++) begin
      if (bit_index != 0) begin
        @(serial_clk);
        #0.8;
      end
      if (tmds_clk_p !== (bit_index >= 5) || tmds_clk_n !== !tmds_clk_p)
        $fatal(1, "Expected five low then five high TMDS clock bits, bit %0d P=%b N=%b",
               bit_index, tmds_clk_p, tmds_clk_n);
      if (tmds_data_n !== ~tmds_data_p)
        $fatal(1, "TMDS differential output is not complementary");
      {red[bit_index], green[bit_index], blue[bit_index]} = tmds_data_p;
    end
  endtask

  function automatic logic [7:0] decode_symbol(input logic [9:0] symbol);
    logic [7:0] intermediate;
    logic [7:0] data;
    intermediate = symbol[9] ? ~symbol[7:0] : symbol[7:0];
    data[0] = intermediate[0];
    for (int bit_index = 1; bit_index < 8; bit_index++)
      data[bit_index] = intermediate[bit_index] ^ intermediate[bit_index-1] ^ !symbol[8];
    return data;
  endfunction

  logic [9:0] red_symbol;
  logic [9:0] green_symbol;
  logic [9:0] blue_symbol;

  initial begin
    repeat (12) @(negedge pixel_clk);
    reset_n = 1;
    repeat (12) @(negedge pixel_clk);
    repeat (5) begin
      receive_symbol(red_symbol, green_symbol, blue_symbol);
      if (red_symbol !== 10'b1101010100 || green_symbol !== 10'b1101010100 ||
          blue_symbol !== 10'b0010101011)
        $fatal(1, "Incorrect serialized blanking words R=%b G=%b B=%b",
               red_symbol, green_symbol, blue_symbol);
    end
    @(negedge pixel_clk);
    rgb = 24'hb46329;
    de = 1;
    repeat (8) @(negedge pixel_clk);
    repeat (20) begin
      receive_symbol(red_symbol, green_symbol, blue_symbol);
      if ({decode_symbol(red_symbol), decode_symbol(green_symbol), decode_symbol(blue_symbol)}
          !== rgb)
        $fatal(1, "Incorrect serialized color lane data R=%b G=%b B=%b",
               red_symbol, green_symbol, blue_symbol);
    end
    $display("TEST PASS: IronVideo 7-series TMDS serialization");
    $finish;
  end

  initial begin
    #4000;
    $fatal(1, "Timed out waiting for serialized symbols");
  end
endmodule
