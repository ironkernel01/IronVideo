`timescale 1ns/1ps

// 11-18-2026, SystemVerilog-2012. Initial local reset synchronizer.
module ironvideo_reset (
  // Destination clock, shared active-low assertion, and active-high local reset.
  input logic clk,
  input logic reset_n,
  output logic rst
);
  (* ASYNC_REG = "TRUE" *) logic [3:0] release_sync;
  always_ff @(posedge clk or negedge reset_n)
    if (!reset_n)
      release_sync <= '0;
    else
      release_sync <= {release_sync[2:0], 1'b1};
  assign rst = !release_sync[3];
endmodule
