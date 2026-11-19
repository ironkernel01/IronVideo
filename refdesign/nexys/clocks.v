// SPDX-License-Identifier: GPL-2.0-only
module nexys_reference_clocks (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 sys_clock CLK", X_INTERFACE_PARAMETER = "FREQ_HZ 100000000" *)
  input wire sys_clock,
  input wire resetn,
  input wire ddr_ready,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 sys CLK", X_INTERFACE_PARAMETER = "FREQ_HZ 80000000" *)
  output wire sys,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 mig_sys CLK", X_INTERFACE_PARAMETER = "FREQ_HZ 100000000" *)
  output wire mig_sys,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ref_clk CLK", X_INTERFACE_PARAMETER = "FREQ_HZ 200000000" *)
  output wire ref_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 pixel CLK", X_INTERFACE_PARAMETER = "FREQ_HZ 74250000" *)
  output wire pixel,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 serial CLK", X_INTERFACE_PARAMETER = "FREQ_HZ 371250000" *)
  output wire serial,
  output wire ddr_clock_locked,
  output wire ready
);
  wire clkin, sys_fb, video_fb, sys_fb_buf, video_fb_buf;
  wire sys_raw, mig_sys_raw, ref_raw, pixel_raw, serial_raw, video_locked;
  IBUF osc (.I(sys_clock), .O(clkin));
  BUFG system_feedback (.I(sys_fb), .O(sys_fb_buf));
  BUFG video_feedback (.I(video_fb), .O(video_fb_buf));
  MMCME2_BASE #(.CLKIN1_PERIOD(10.0), .DIVCLK_DIVIDE(1),
    .CLKFBOUT_MULT_F(10.0), .CLKOUT0_DIVIDE_F(12.5), .CLKOUT1_DIVIDE(5),
    .CLKOUT2_DIVIDE(10)) system_mmcm (
    .CLKIN1(clkin), .CLKFBIN(sys_fb_buf), .RST(!resetn), .PWRDWN(1'b0),
    .CLKFBOUT(sys_fb), .CLKOUT0(sys_raw), .CLKOUT1(ref_raw), .CLKOUT2(mig_sys_raw),
    .LOCKED(ddr_clock_locked));
  MMCME2_BASE #(.CLKIN1_PERIOD(10.0), .DIVCLK_DIVIDE(5),
    .CLKFBOUT_MULT_F(37.125), .CLKOUT0_DIVIDE_F(10.0), .CLKOUT1_DIVIDE(2)) video_mmcm (
    .CLKIN1(clkin), .CLKFBIN(video_fb_buf), .RST(!resetn), .PWRDWN(1'b0),
    .CLKFBOUT(video_fb), .CLKOUT0(pixel_raw), .CLKOUT1(serial_raw), .LOCKED(video_locked));
  BUFG system_buf (.I(sys_raw), .O(sys));
  BUFG mig_sys_buf (.I(mig_sys_raw), .O(mig_sys));
  BUFG reference_buf (.I(ref_raw), .O(ref_clk));
  BUFG pixel_buf (.I(pixel_raw), .O(pixel));
  BUFG serial_buf (.I(serial_raw), .O(serial));

  // Assert on clock, calibration or board reset loss. Release on the AXI clock.
  wire calibrated = resetn && ddr_ready && ddr_clock_locked && video_locked;
  (* ASYNC_REG = "TRUE" *) reg [2:0] ready_sync = 0;
  always @(posedge sys or negedge calibrated) begin
    if (!calibrated) ready_sync <= 0;
    else ready_sync <= {ready_sync[1:0], 1'b1};
  end
  assign ready = ready_sync[2];
endmodule
