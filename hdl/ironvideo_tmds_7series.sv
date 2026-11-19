`timescale 1ns/1ps

// 11-18-2026, SystemVerilog-2012. Initial 7-series DVI-compatible output backend.
// Three TMDS data lanes and the forwarded pixel clock, all using 10:1 DDR.
module ironvideo_tmds_7series (
  // Phase-related pixel and 5x serializer clocks. Hold reset_n low through
  // external clock changes and release after both clocks are stable.
  input logic pixel_clk,
  input logic serial_clk,
  input logic reset_n,
  // Pixel-domain RGB and timing from ironvideo, one pixel per rising edge.
  input logic [23:0] rgb,
  input logic de,
  input logic hs,
  input logic vs,
  // TMDS lane order: data 0 blue, data 1 green, data 2 red.
  output wire [2:0] tmds_data_p,
  output wire [2:0] tmds_data_n,
  output wire tmds_clk_p,
  output wire tmds_clk_n
);
  logic rst;
  logic [9:0] symbol [0:2];

  ironvideo_reset reset_sync (.clk(pixel_clk), .reset_n(reset_n), .rst(rst));
  ironvideo_tmds_encoder blue
  (.clk(pixel_clk), .rst(rst), .data(rgb[7:0]), .de(de), .control({vs, hs}), .symbol(symbol[0]));
  ironvideo_tmds_encoder green
  (.clk(pixel_clk), .rst(rst), .data(rgb[15:8]), .de(de), .control(2'b00), .symbol(symbol[1]));
  ironvideo_tmds_encoder red
  (.clk(pixel_clk), .rst(rst), .data(rgb[23:16]), .de(de), .control(2'b00), .symbol(symbol[2]));

  for (genvar lane = 0; lane < 3; lane++) begin : data_lanes
    ironvideo_tmds_lane_7series data_lane (
      .pixel_clk(pixel_clk), .serial_clk(serial_clk), .rst(rst),
      .symbol(symbol[lane]), .serial_p(tmds_data_p[lane]), .serial_n(tmds_data_n[lane])
    );
  end

  // Match the default Digilent rgb2dvi clock phase. The LSB-first lane
  // drives five low bits, then five high bits, per data word.
  ironvideo_tmds_lane_7series clock_lane (
    .pixel_clk(pixel_clk), .serial_clk(serial_clk), .rst(rst),
    .symbol(10'b1111100000), .serial_p(tmds_clk_p), .serial_n(tmds_clk_n)
  );
endmodule
