`timescale 1ns/1fs

module tb_ironvideo_1080p_serial;
  tb_ironvideo_720p #(.DATA_WIDTH(128), .STRIDE(7680), .PREFILL(480),
                       .MAX_BURST(32), .CHECK_SERIAL(1), .MODE_1080(1)) bench ();
endmodule
