`timescale 1ns/1ps

// 11-18-2026, SystemVerilog-2012. Initial asynchronous beat FIFO.
// Use synchronous dual-port RAM, registered Gray cursors, and one held read beat.
module ironvideo_fifo #(
  parameter int DATA_WIDTH = 64,
  parameter int FIFO_AW = 9
) (
  // AXI domain: synchronous active-high reset, write beat and RAM free count.
  input logic wr_clk,
  input logic wr_rst,
  input logic wr_push,
  input logic [DATA_WIDTH-1:0] wr_data,
  output logic [FIFO_AW:0] wr_free,
  output logic [FIFO_AW:0] wr_cursor,
  // Pixel domain: synchronous active-high reset, held beat and total beat count.
  input logic rd_clk,
  input logic rd_rst,
  input logic rd_pop,
  output logic [FIFO_AW:0] rd_cursor,
  output logic rd_valid,
  output logic [DATA_WIDTH-1:0] rd_data,
  output logic [FIFO_AW:0] rd_count
);
  localparam int DEPTH = 2**FIFO_AW;
  typedef logic [FIFO_AW:0] ptr_t;
  (* ram_style = "block" *) logic [DATA_WIDTH-1:0] memory [0:DEPTH-1];
  ptr_t write_ptr, write_next, read_limit;
  ptr_t write_gray;
  ptr_t read_ptr, read_previous, write_sample;
  ptr_t read_gray;
  (* ASYNC_REG = "TRUE" *) ptr_t read_gray_sync [0:3];
  (* ASYNC_REG = "TRUE" *) ptr_t write_gray_sync [0:3];

  function automatic ptr_t gray(input ptr_t value);
    return value ^ (value >> 1);
  endfunction

  function automatic ptr_t binary(input ptr_t value);
    ptr_t result;
    result[FIFO_AW] = value[FIFO_AW];
    for (int bit_index = FIFO_AW-1; bit_index >= 0; bit_index--)
      result[bit_index] = result[bit_index+1] ^ value[bit_index];
    return result;
  endfunction

  assign wr_cursor = write_gray;
  assign rd_cursor = read_gray;
  wire write_memory = !wr_rst && wr_push && wr_free != 0;
  wire read_memory = !rd_rst && (!rd_valid || rd_pop) && rd_count > ptr_t'(rd_valid);
  wire ptr_t count_after_pop = write_sample - read_ptr;
  wire ptr_t count_with_held = write_sample - read_previous;

  always_ff @(posedge wr_clk)
    if (write_memory)
      memory[write_ptr[FIFO_AW-1:0]] <= wr_data;

  always_ff @(posedge rd_clk)
    if (read_memory)
      rd_data <= memory[read_ptr[FIFO_AW-1:0]];

  always_ff @(posedge wr_clk) begin
    if (wr_rst) begin
      write_ptr <= '0;
      write_next <= ptr_t'(1);
      write_gray <= '0;
      read_limit <= ptr_t'(DEPTH);
      wr_free <= ptr_t'(DEPTH);
      for (int stage = 0; stage < 4; stage++)
        read_gray_sync[stage] <= '0;
    end else begin
      read_gray_sync[0] <= read_gray;
      for (int stage = 1; stage < 4; stage++)
        read_gray_sync[stage] <= read_gray_sync[stage-1];
      // The sampled RAM read cursor can only lag the reader. Register
      // capacity for the pointer *after* any push accepted on this edge.
      // Adding DEPTH modulo the pointer width toggles only the wrap bit.
      read_limit <= binary(read_gray_sync[3]) ^ ptr_t'(DEPTH);
      wr_free <= read_limit - (write_memory ? write_next : write_ptr);
      if (write_memory) begin
        write_ptr <= write_next;
        write_next <= write_next + 1'b1;
        write_gray <= gray(write_next);
      end
    end
  end

  always_ff @(posedge rd_clk) begin
    if (rd_rst) begin
      read_ptr <= '0;
      read_previous <= '0;
      read_gray <= '0;
      write_sample <= '0;
      rd_count <= '0;
      rd_valid <= 1'b0;
      for (int stage = 0; stage < 4; stage++)
        write_gray_sync[stage] <= '0;
    end else begin
      write_gray_sync[0] <= write_gray;
      for (int stage = 1; stage < 4; stage++)
        write_gray_sync[stage] <= write_gray_sync[stage-1];
      // Count the held beat until the consumer pops it. Prefetching a
      // replacement changes the RAM cursor but cannot consume that beat.
      write_sample <= binary(write_gray_sync[3]);
      rd_count <= rd_valid && !rd_pop ? count_with_held : count_after_pop;
      if (read_memory) begin
        read_previous <= read_ptr;
        read_ptr <= read_ptr + 1'b1;
        read_gray <= gray(read_ptr + 1'b1);
        rd_valid <= 1'b1;
      end else if (rd_pop)
        rd_valid <= 1'b0;
    end
  end

  // synthesis translate_off
  always @(posedge wr_clk)
    if (!wr_rst && wr_push)
      assert (wr_free != 0) else $fatal(1, "IronVideo FIFO overflow");
  // synthesis translate_on
endmodule
