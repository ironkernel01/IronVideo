`timescale 1ns/1ps

// 11-18-2026, SystemVerilog-2012. Initial DVI TMDS channel encoder.
// Minimize transitions, balance DC disparity during DE, and emit control
// symbols during blanking. Symbol bit zero is the first bit on the wire.
module ironvideo_tmds_encoder (
  // Pixel clock and active-high synchronous encoder reset.
  input logic clk,
  input logic rst,
  // Eight-bit channel sample or two control bits during blanking.
  input logic [7:0] data,
  input logic de,
  input logic [1:0] control,
  output logic [9:0] symbol
);
  localparam logic [9:0] CONTROL_00 = 10'b1101010100;
  localparam logic [9:0] CONTROL_01 = 10'b0010101011;
  localparam logic [9:0] CONTROL_10 = 10'b0101010100;
  localparam logic [9:0] CONTROL_11 = 10'b1010101011;

  logic [8:0] transition_word;
  logic [3:0] input_ones;
  logic [3:0] transition_ones;
  logic signed [4:0] balance;
  logic signed [4:0] disparity;
  logic signed [4:0] next_disparity;
  logic [9:0] next_symbol;

  always_comb begin
    input_ones = '0;
    for (int bit_index = 0; bit_index < 8; bit_index++)
      input_ones = input_ones + {3'b0, data[bit_index]};

    transition_word[8] = input_ones < 4 || (input_ones == 4 && data[0]);
    transition_word[0] = data[0];
    for (int bit_index = 1; bit_index < 8; bit_index++)
      transition_word[bit_index] = transition_word[bit_index-1] ^ data[bit_index]
                                   ^ !transition_word[8];

    transition_ones = '0;
    for (int bit_index = 0; bit_index < 8; bit_index++)
      transition_ones = transition_ones + {3'b0, transition_word[bit_index]};
    balance = $signed({transition_ones, 1'b0}) - 5'sd8;

    if (!de) begin
      case (control)
        2'b00: next_symbol = CONTROL_00;
        2'b01: next_symbol = CONTROL_01;
        2'b10: next_symbol = CONTROL_10;
        default: next_symbol = CONTROL_11;
      endcase
      next_disparity = '0;
    end else if (disparity == 0 || balance == 0) begin
      next_symbol = {!transition_word[8], transition_word[8],
                     transition_word[8] ? transition_word[7:0] : ~transition_word[7:0]};
      next_disparity = disparity + (transition_word[8] ? balance : -balance);
    end else if (disparity[4] == balance[4]) begin
      next_symbol = {1'b1, transition_word[8], ~transition_word[7:0]};
      next_disparity = disparity - balance + (transition_word[8] ? 5'sd2 : 5'sd0);
    end else begin
      next_symbol = {1'b0, transition_word};
      next_disparity = disparity + balance - (transition_word[8] ? 5'sd0 : 5'sd2);
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      disparity <= '0;
      symbol <= CONTROL_00;
    end else begin
      disparity <= next_disparity;
      symbol <= next_symbol;
    end
  end
endmodule
