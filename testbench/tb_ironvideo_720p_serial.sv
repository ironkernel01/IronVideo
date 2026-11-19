`timescale 1ns/1fs

module tb_ironvideo_720p_serial;
  tb_ironvideo_720p #(.DATA_WIDTH(128), .STRIDE(5120), .PREFILL(320),
                       .MAX_BURST(32), .CHECK_SERIAL(1)) bench ();
endmodule
