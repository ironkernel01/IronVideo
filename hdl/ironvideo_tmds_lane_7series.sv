`timescale 1ns/1ps

// 11-18-2026, SystemVerilog-2012. Initial 7-series TMDS output lane.
// The two OSERDESE2s use the 10-bit DDR cascade mapping in AMD UG471.
module ironvideo_tmds_lane_7series (
  // Phase-related 1x CLKDIV and 5x DDR serial clocks, plus serializer reset.
  input logic pixel_clk,
  input logic serial_clk,
  input logic rst,
  // One LSB-first symbol per pixel clock, and the differential output pair.
  input logic [9:0] symbol,
  output wire serial_p,
  output wire serial_n
);
  wire shift_one;
  wire shift_two;
  wire serial_data;

  OSERDESE2 #(
    .DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("SDR"), .DATA_WIDTH(10),
    .SERDES_MODE("SLAVE"), .TRISTATE_WIDTH(1)
  ) slave (
    .CLK(serial_clk), .CLKDIV(pixel_clk), .RST(rst),
    .D1(1'b0), .D2(1'b0), .D3(symbol[8]), .D4(symbol[9]),
    .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0),
    .OCE(1'b1), .SHIFTIN1(1'b0), .SHIFTIN2(1'b0),
    .SHIFTOUT1(shift_one), .SHIFTOUT2(shift_two),
    .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0),
    .TCE(1'b0), .TBYTEIN(1'b0),
    .OQ(), .OFB(), .TQ(), .TFB(), .TBYTEOUT()
  );

  OSERDESE2 #(
    .DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("SDR"), .DATA_WIDTH(10),
    .SERDES_MODE("MASTER"), .TRISTATE_WIDTH(1)
  ) master (
    .CLK(serial_clk), .CLKDIV(pixel_clk), .RST(rst),
    .D1(symbol[0]), .D2(symbol[1]), .D3(symbol[2]), .D4(symbol[3]),
    .D5(symbol[4]), .D6(symbol[5]), .D7(symbol[6]), .D8(symbol[7]),
    .OCE(1'b1), .SHIFTIN1(shift_one), .SHIFTIN2(shift_two),
    .SHIFTOUT1(), .SHIFTOUT2(),
    .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0),
    .TCE(1'b0), .TBYTEIN(1'b0),
    .OQ(serial_data), .OFB(), .TQ(), .TFB(), .TBYTEOUT()
  );

  OBUFDS #(.IOSTANDARD("TMDS_33")) output_buffer
  (.I(serial_data), .O(serial_p), .OB(serial_n));
endmodule
