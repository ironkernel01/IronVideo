`timescale 1ns/1fs

module tb_ironvideo_1080p_serial #(parameter int FORMAT_ID = 0);
  localparam int BYTES = FORMAT_ID == 0 ? 4 : FORMAT_ID == 3 ? 1 : 2;
  tb_ironvideo_720p #(.DATA_WIDTH(128), .STRIDE(1920*BYTES), .PREFILL(FORMAT_ID == 0 ? 480 : 240),
                       .FORMAT_ID(FORMAT_ID), .FORMAT_MASK(15), .MAX_BURST(32), .CHECK_SERIAL(1), .MODE_1080(1)) bench ();
endmodule
