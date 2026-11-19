`timescale 1ns/1ps

// Validate one linear AXI plane. All addition is wide enough to distinguish
// a legal exclusive end at 4 GiB from a wrap beyond the DMA address space.
module ironvideo_plane_bounds #(parameter int ALIGN_BITS = 3) (
  input logic clk,
  input logic [31:0] base, stride, row_bytes, window_base, window_bytes,
  input logic [15:0] rows,
  output logic valid
);
  logic [15:0] last_line;
  logic [31:0] offset_low, offset_high;
  logic [47:0] offset;
  logic [48:0] address, plane_end;
  logic [32:0] window_end;
  logic geometry_valid;

  always_ff @(posedge clk) begin
    last_line <= rows - 16'd1;
    offset_low <= last_line * stride[15:0];
    offset_high <= last_line * stride[31:16];
    offset <= {offset_high, 16'b0} + {16'b0, offset_low};
    address <= 49'(base) + 49'(offset);
    plane_end <= address + 49'(row_bytes);
    window_end <= {1'b0, window_base} + {1'b0, window_bytes};
    geometry_valid <= rows != 0 && row_bytes != 0 && stride >= row_bytes
                   && base[ALIGN_BITS-1:0] == 0 && stride[ALIGN_BITS-1:0] == 0
                   && row_bytes[ALIGN_BITS-1:0] == 0 && base >= window_base
                   && window_bytes != 0;
    valid <= geometry_valid && window_end <= 33'h100000000 && plane_end <= 49'(window_end);
  end
endmodule
