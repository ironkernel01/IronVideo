`timescale 1ns/1ps

// 11-18-2026, SystemVerilog-2012. Measure completed DDR rows in pixel ticks.
module ironvideo_row_stats (
  // Independent pixel timer and AXI telemetry clocks, with local resets.
  input logic pixel_clk,
  input logic pixel_rst,
  input logic axi_clk,
  input logic axi_rst,
  // AXI-domain measurement inputs and committed mode changes.
  input logic clear_mode,
  input logic [31:0] mode_row_bytes,
  input logic row_start,
  input logic row_done,
  input logic read_beat,
  input logic read_burst,
  input logic read_error,
  // AXI-domain destructive read strobes and diagnostic values.
  input logic take_worst,
  input logic take_best,
  output logic [31:0] last_cycles,
  output logic [31:0] row_bytes,
  output logic [31:0] samples,
  output logic [31:0] worst_cycles,
  output logic [31:0] best_cycles,
  output logic [31:0] beats,
  output logic [31:0] bursts,
  output logic [31:0] errors,
  output logic saturated
);
  logic [63:0] pixel_ticks;
  logic [63:0] pixel_ticks_gray;
  (* ASYNC_REG = "TRUE" *) logic [63:0] ticks_sync [0:3];
  logic [63:0] axi_ticks;
  logic [63:0] start_ticks;
  wire [63:0] next_ticks = pixel_ticks + 64'd1;
  wire [63:0] elapsed = axi_ticks - start_ticks;
  wire overflow = |elapsed[63:32];
  wire [31:0] cycles = overflow ? 32'hffffffff : (elapsed == 0 ? 32'd1 : elapsed[31:0]);

  function automatic logic [63:0] decode_gray(input logic [63:0] gray);
    logic [63:0] value;
    value = gray;
    for (int span = 1; span < 64; span = span * 2)
      value = value ^ (value >> span);
    return value;
  endfunction

  always_ff @(posedge pixel_clk) begin
    if (pixel_rst) begin
      pixel_ticks <= '0;
      pixel_ticks_gray <= '0;
    end else begin
      pixel_ticks <= next_ticks;
      pixel_ticks_gray <= next_ticks ^ (next_ticks >> 1);
    end
  end

  always_ff @(posedge axi_clk) begin
    if (axi_rst) begin
      for (int stage = 0; stage < 4; stage++)
        ticks_sync[stage] <= '0;
      axi_ticks <= '0;
    end else begin
      ticks_sync[0] <= pixel_ticks_gray;
      for (int stage = 1; stage < 4; stage++)
        ticks_sync[stage] <= ticks_sync[stage-1];
      axi_ticks <= decode_gray(ticks_sync[3]);
    end
  end

  always_ff @(posedge axi_clk) begin
    if (axi_rst || clear_mode) begin
      start_ticks <= '0;
      last_cycles <= '0;
      row_bytes <= axi_rst ? 32'd0 : mode_row_bytes;
      samples <= '0;
      worst_cycles <= '0;
      best_cycles <= '0;
      beats <= '0;
      bursts <= '0;
      errors <= '0;
      saturated <= 1'b0;
    end else begin
      if (read_beat) beats <= beats + 1'b1;
      if (read_burst) bursts <= bursts + 1'b1;
      if (read_error) errors <= errors + 1'b1;
      if (row_start) start_ticks <= axi_ticks;
      if (take_worst) worst_cycles <= '0;
      if (take_best) best_cycles <= '0;
      if (row_done) begin
        last_cycles <= cycles;
        samples <= samples + 1'b1;
        if (overflow) saturated <= 1'b1;
        if (take_worst || cycles > worst_cycles) worst_cycles <= cycles;
        if (take_best || best_cycles == 0 || cycles < best_cycles) best_cycles <= cycles;
      end
    end
  end
endmodule
