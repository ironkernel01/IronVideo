`timescale 1ns/1fs

module tb_ironvideo_720p_serial #(parameter int FORMAT_ID = 0);
  localparam int BYTES = FORMAT_ID == 0 ? 4 : FORMAT_ID == 3 ? 1 : 2;
  tb_ironvideo_720p #(.DATA_WIDTH(128), .STRIDE(1280*BYTES), .PREFILL(FORMAT_ID == 0 ? 320 : 160),
                       .FORMAT_ID(FORMAT_ID), .FORMAT_MASK(15), .MAX_BURST(32), .CHECK_SERIAL(1)) bench ();
endmodule
