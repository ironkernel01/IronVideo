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
  // An even NV12 row loads luma plus one equally sized chroma row.
  input logic row_extra_chroma,
  input logic row_start,
  input logic row_done,
  input logic read_beat,
  input logic read_burst,
  input logic read_error,
  // AXI-domain destructive read strobes and diagnostic values.
  input logic take_worst,
  input logic take_best,
  input logic take_peak,
  input logic snapshot_read,
  output logic snapshot_valid,
  output logic [31:0] last_cycles,
  output logic [31:0] row_bytes,
  output logic [31:0] samples,
  output logic [31:0] worst_cycles,
  output logic [31:0] best_cycles,
  output logic [31:0] peak_cycles,
  output logic [31:0] peak_bytes_latched,
  output logic [31:0] beats,
  output logic [31:0] bursts,
  output logic [31:0] errors,
  output logic saturated
);
  // Registered carry lookahead keeps each tick increment local to a 16-bit limb.
  logic [63:0] pixel_ticks, next_ticks;
  logic [2:0] pixel_carry;
  logic [63:0] pixel_ticks_gray;
  (* ASYNC_REG = "TRUE" *) logic [63:0] ticks_sync [0:3];
  assign next_ticks[15:0] = pixel_ticks[15:0] + 16'd1;
  for (genvar limb = 1; limb < 4; limb++) begin : pixel_timer
    assign next_ticks[16*limb +: 16] = pixel_ticks[16*limb +: 16] + 16'(pixel_carry[limb-1]);
    always_ff @(posedge pixel_clk)
      pixel_carry[limb-1] <= !pixel_rst &&
          pixel_ticks[16*limb-1:0] == { { (16*limb-16){1'b1} }, 16'hfffe };
  end
  always_ff @(posedge pixel_clk) begin
    if (pixel_rst) begin
      pixel_ticks <= '0;
      pixel_ticks_gray <= '0;
    end else begin
      pixel_ticks <= next_ticks;
      pixel_ticks_gray <= next_ticks ^ (next_ticks >> 1);
    end
  end

  // Decode each synchronizer output sample in parallel 8-bit groups, then
  // correct each group with the parity of the higher groups of that sample.
  logic [63:0] decoded_groups, axi_ticks;
  logic [7:0] group_parity;
  function automatic logic [7:0] decode_gray(input logic [7:0] gray);
    logic [7:0] value;
    value = gray ^ (gray >> 1);
    value = value ^ (value >> 2);
    return value ^ (value >> 4);
  endfunction

  always_ff @(posedge axi_clk) begin
    if (axi_rst) begin
      for (int stage = 0; stage < 4; stage++)
        ticks_sync[stage] <= '0;
    end else begin
      ticks_sync[0] <= pixel_ticks_gray;
      for (int stage = 1; stage < 4; stage++)
        ticks_sync[stage] <= ticks_sync[stage-1];
    end
  end

  for (genvar group = 0; group < 8; group++) begin : decode
    wire correction = group == 7 ? 1'b0 : ^(group_parity >> (group+1));
    always_ff @(posedge axi_clk) begin
      if (axi_rst) begin
        decoded_groups[8*group +: 8] <= '0;
        group_parity[group] <= 1'b0;
        axi_ticks[8*group +: 8] <= '0;
      end else begin
        decoded_groups[8*group +: 8] <= decode_gray(ticks_sync[3][8*group +: 8]);
        group_parity[group] <= ^ticks_sync[3][8*group +: 8];
        axi_ticks[8*group +: 8] <= decoded_groups[8*group +: 8] ^ {8{correction}};
      end
    end
  end

  typedef struct packed {
    logic clear_mode, done, extra_chroma;
    logic take_worst, take_best, take_peak, snapshot_read;
    logic [31:0] bytes;
  } row_event_t;
  row_event_t diff_event, elapsed_event, result_event;
  logic [63:0] start_ticks;
  logic [63:0] diff_normal, diff_borrowed, elapsed;
  logic [3:0] borrow_zero, borrow_one;
  logic [4:0] borrow;
  logic [31:0] cycles;
  logic overflow;

  assign borrow[0] = 1'b0;
  for (genvar limb = 0; limb < 4; limb++) begin : subtract
    wire [16:0] end_part = {1'b0, axi_ticks[16*limb +: 16]};
    wire [16:0] start_part = {1'b0, start_ticks[16*limb +: 16]};
    wire [16:0] borrowed_part = end_part + {1'b0, ~start_part[15:0]};
    // Both results and both borrow decisions are available before the prefix
    // scan. No wide arithmetic carry runs through the elapsed pipeline.
    always_ff @(posedge axi_clk) begin
      {borrow_zero[limb], diff_normal[16*limb +: 16]} <= end_part - start_part;
      borrow_one[limb] <= !borrowed_part[16];
      diff_borrowed[16*limb +: 16] <= borrowed_part[15:0];
      elapsed[16*limb +: 16] <= borrow[limb] ? diff_borrowed[16*limb +: 16]
                                           : diff_normal[16*limb +: 16];
    end
    assign borrow[limb+1] = borrow_zero[limb] || (borrow_one[limb] && borrow[limb]);
  end

  always_ff @(posedge axi_clk) begin
    if (axi_rst || clear_mode)
      start_ticks <= '0;
    else if (row_start)
      start_ticks <= axi_ticks;

    if (axi_rst) begin
      diff_event <= '0;
      elapsed_event <= '0;
      result_event <= '0;
    end else begin
      diff_event <= {clear_mode, row_done, row_extra_chroma, take_worst, take_best,
                     take_peak, snapshot_read,
                     row_extra_chroma && !clear_mode ? mode_row_bytes << 1 : mode_row_bytes};
      elapsed_event <= diff_event;
      result_event <= elapsed_event;
    end
    overflow <= |elapsed[63:32];
    cycles <= |elapsed[63:32] ? 32'hffffffff : (elapsed[31:0] == 0 ? 32'd1 : elapsed[31:0]);
  end

  logic peak_extra_chroma;
  logic [31:0] peak_bytes;
  function automatic logic below(input logic [31:0] lhs, input logic [31:0] rhs);
    return lhs[31:16] < rhs[31:16] ||
           (lhs[31:16] == rhs[31:16] && lhs[15:0] < rhs[15:0]);
  endfunction
  // Compare time/byte without division or overflow. B and 2B are the only
  // possible row sizes in an epoch, so the shift is fixed in each comparison.
  function automatic logic row_event_faster(
      input logic [31:0] next_cycles, prev_cycles, input logic more, prev_more);
    if (more == prev_more)
      return below(next_cycles, prev_cycles);
    if (more)
      return below(next_cycles >> 1, prev_cycles);
    return below(next_cycles, prev_cycles >> 1) ||
           (next_cycles == (prev_cycles >> 1) && prev_cycles[0]);
  endfunction
  wire faster = row_event_faster(cycles, peak_cycles, result_event.extra_chroma, peak_extra_chroma);

  // A read observes the state before its own clear, even when a row completes
  // on the same cycle. The row then populates the newly cleared extrema.
  assign snapshot_valid = result_event.snapshot_read;
  always_ff @(posedge axi_clk) begin
    if (axi_rst || result_event.clear_mode) begin
      last_cycles <= '0;
      row_bytes <= axi_rst ? 32'd0 : result_event.bytes;
      worst_cycles <= '0;
      best_cycles <= '0;
      peak_cycles <= '0;
      peak_bytes <= '0;
      peak_bytes_latched <= '0;
      peak_extra_chroma <= 1'b0;
      saturated <= 1'b0;
    end else begin
      if (result_event.take_worst) worst_cycles <= '0;
      if (result_event.take_best) best_cycles <= '0;
      if (result_event.take_peak) begin
        peak_bytes_latched <= peak_bytes;
        peak_cycles <= '0;
        peak_bytes <= '0;
      end
      if (result_event.done) begin
        last_cycles <= cycles;
        row_bytes <= result_event.bytes;
        if (result_event.take_peak || peak_cycles == 0 || faster) begin
          peak_cycles <= cycles;
          peak_bytes <= result_event.bytes;
          peak_extra_chroma <= result_event.extra_chroma;
        end
        if (overflow) saturated <= 1'b1;
        if (result_event.take_worst || below(worst_cycles, cycles)) worst_cycles <= cycles;
        if (result_event.take_best || best_cycles == 0 || below(cycles, best_cycles)) best_cycles <= cycles;
      end
    end
  end

  ironvideo_stats_count row_count (
    .clk(axi_clk), .clear(axi_rst || result_event.clear_mode),
    .increment(result_event.done), .count(samples));
  ironvideo_stats_count beat_count (
    .clk(axi_clk), .clear(axi_rst || clear_mode), .increment(read_beat), .count(beats));
  ironvideo_stats_count burst_count (
    .clk(axi_clk), .clear(axi_rst || clear_mode), .increment(read_burst), .count(bursts));
  ironvideo_stats_count error_count (
    .clk(axi_clk), .clear(axi_rst || clear_mode), .increment(read_error), .count(errors));
endmodule

module ironvideo_stats_count (
  input logic clk, clear, increment,
  output logic [31:0] count
);
  logic carry;
  always_ff @(posedge clk)
    if (clear) begin
      count <= '0;
      carry <= 1'b0;
    end else if (increment) begin
      count[15:0] <= count[15:0] + 16'd1;
      count[31:16] <= count[31:16] + 16'(carry);
      carry <= count[15:0] == 16'hfffe;
    end
endmodule
