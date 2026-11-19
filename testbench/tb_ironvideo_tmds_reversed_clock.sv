`timescale 1ns/1fs

// Negative control. Swapping only the forwarded clock pins recreates the
// previous clock word's polarity while leaving the data lanes intact.
module tb_ironvideo_tmds_reversed_clock;
  tb_ironvideo_720p #(.DATA_WIDTH(128), .STRIDE(5120), .PREFILL(320),
                       .MAX_BURST(32), .CHECK_SERIAL(1)) bench ();

  ironvideo_serial_receiver reversed_clock_receiver (
    .clk_p(bench.serialized_output.clk_n), .clk_n(bench.serialized_output.clk_p),
    .data_p(bench.serialized_output.data_p), .data_n(bench.serialized_output.data_n),
    .checked()
  );

  initial begin
    #50us;
    $fatal(1, "NEGATIVE CONTROL FAIL: the reversed forwarded clock escaped the receiver");
  end
endmodule
