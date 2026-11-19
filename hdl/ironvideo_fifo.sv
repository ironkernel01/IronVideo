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
  ptr_t write_ptr;
  ptr_t write_gray;
  ptr_t read_ptr;
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

  assign wr_free = ptr_t'(DEPTH) - (write_ptr - binary(read_gray_sync[3]));
  assign wr_cursor = write_gray;
  assign rd_count = binary(write_gray_sync[3]) - read_ptr + ptr_t'(rd_valid);
  assign rd_cursor = read_gray;
  wire write_memory = !wr_rst && wr_push && wr_free != 0;
  wire read_memory = !rd_rst && (!rd_valid || rd_pop)
           && read_gray != write_gray_sync[3];

  always_ff @(posedge wr_clk)
    if (write_memory)
      memory[write_ptr[FIFO_AW-1:0]] <= wr_data;

  always_ff @(posedge rd_clk)
    if (read_memory)
      rd_data <= memory[read_ptr[FIFO_AW-1:0]];

  always_ff @(posedge wr_clk) begin
    if (wr_rst) begin
      write_ptr <= '0;
      write_gray <= '0;
      for (int stage = 0; stage < 4; stage++)
        read_gray_sync[stage] <= '0;
    end else begin
      read_gray_sync[0] <= read_gray;
      for (int stage = 1; stage < 4; stage++)
        read_gray_sync[stage] <= read_gray_sync[stage-1];
      if (write_memory) begin
        write_ptr <= write_ptr + 1'b1;
        write_gray <= gray(write_ptr + 1'b1);
      end
    end
  end

  always_ff @(posedge rd_clk) begin
    if (rd_rst) begin
      read_ptr <= '0;
      read_gray <= '0;
      rd_valid <= 1'b0;
      for (int stage = 0; stage < 4; stage++)
        write_gray_sync[stage] <= '0;
    end else begin
      write_gray_sync[0] <= write_gray;
      for (int stage = 1; stage < 4; stage++)
        write_gray_sync[stage] <= write_gray_sync[stage-1];
      if (read_memory) begin
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
