`timescale 1ns/1ps

// BT.709 limited-range Y'CbCr to full-range RGB. The packed input is
// {Y,Cb,Cr} when convert is set, otherwise RGB. Carry timing and RGB bypass
// through the same three pixel clocks, including pattern and blanking.
module ironvideo_color (
  input logic clk, rst,
  input logic convert,
  input logic [23:0] sample,
  input logic [2:0] timing_in,
  output logic [23:0] rgb,
  output logic [2:0] timing_out
);
  wire signed [8:0] luma = $signed({1'b0,sample[23:16]}) - 9'sd16;
  wire signed [8:0] cb = $signed({1'b0,sample[15:8]}) - 9'sd128;
  wire signed [8:0] cr = $signed({1'b0,sample[7:0]}) - 9'sd128;
  logic signed [18:0] y_term, red_cr, green_cb, green_cr, blue_cb;
  logic signed [18:0] red, green, blue;
  logic [23:0] bypass1, bypass2;
  logic [2:0] timing1, timing2;
  logic convert1, convert2;

  function automatic logic [7:0] clamp(input logic signed [18:0] rounded);
    if (rounded < 0) return 8'd0;
    if (rounded >= 19'sd65280) return 8'd255;
    return rounded[15:8];
  endfunction

  always_ff @(posedge clk) begin
    y_term <= luma * 10'sd298;
    red_cr <= cr * 10'sd459;
    green_cb <= cb * 8'sd55;
    green_cr <= cr * 9'sd136;
    blue_cb <= cb * 11'sd541;
    red <= y_term + red_cr + 19'sd128;
    green <= y_term - green_cb - green_cr + 19'sd128;
    blue <= y_term + blue_cb + 19'sd128;
    bypass1 <= sample;
    bypass2 <= bypass1;
    convert1 <= convert;
    convert2 <= convert1;
    if (rst) begin
      timing1 <= '0;
      timing2 <= '0;
      timing_out <= '0;
      rgb <= '0;
    end else begin
      timing1 <= timing_in;
      timing2 <= timing1;
      timing_out <= timing2;
      rgb <= convert2 ? {clamp(red),clamp(green),clamp(blue)} : bypass2;
    end
  end
endmodule
