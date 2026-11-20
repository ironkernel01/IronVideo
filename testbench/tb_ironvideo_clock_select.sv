`timescale 1ps/1ps
module tb_ironvideo_clock_select;
  bit bus_clk, pixel0, serial0, pixel1, serial1, reset_n;
  integer edge_count = 0;
  always #5000 bus_clk = !bus_clk;
  // All outputs derive from one source. One tick represents half a 742 MHz cycle.
  always #674 begin
    edge_count++;
    serial1 = !serial1;
    if (!(edge_count % 2)) serial0 = !serial0;
    if (!(edge_count % 5)) pixel1 = !pixel1;
    if (!(edge_count % 10)) pixel0 = !pixel0;
  end
  logic [15:0] awaddr, araddr;
  logic [31:0] wdata;
  bit awvalid, wvalid, arvalid;
  wire awready, wready, arready, bvalid, rvalid;
  wire [1:0] bresp, rresp;
  wire [31:0] rdata;
  ironvideo_top #(.CLOCK_SELECT(1), .FORMAT_MASK(7), .MAX_BURST(16), .PACKED_READS(4)) dut (
    .axi_clk(bus_clk), .reset_n(reset_n),
    .pixel_clk(pixel0), .serial_clk(serial0), .pixel_clk_alt(pixel1), .serial_clk_alt(serial1),
    .s_axi_awaddr(awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(4'hf), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(1'b1),
    .s_axi_araddr(araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(1'b1),
    .m_axi_arready(1'b1), .m_axi_rvalid(1'b0), .m_axi_rlast(1'b0), .m_axi_rresp(2'b0),
    .m_axi_rid(1'b0), .m_axi_rdata(64'b0)
  );
  task automatic write_reg(input int addr, value, input logic [1:0] expected=0);
    @(negedge bus_clk);
    awaddr = addr; wdata = value; awvalid = 1; wvalid = 1;
    do @(posedge bus_clk); while (!(awready && wready));
    @(negedge bus_clk);
    awvalid = 0; wvalid = 0;
    do @(posedge bus_clk); while (!bvalid);
    if (bresp !== expected) $fatal(1,"unexpected write response %h at %h",bresp,addr);
  endtask
  task automatic read_reg(input int addr, output logic [31:0] value);
    @(negedge bus_clk); araddr = addr; arvalid = 1;
    do @(posedge bus_clk); while (!arready);
    @(negedge bus_clk); arvalid = 0;
    do @(posedge bus_clk); while (!rvalid);
    if (rresp !== 0) $fatal(1,"unexpected read response");
    value = rdata;
  endtask
  task automatic poll(input int addr, mask, expected);
    logic [31:0] value;
    for (int i=0; i<200; i++) begin
      read_reg(addr,value);
      if ((value & mask) === expected) return;
    end
    $fatal(1,"timeout at %h waiting for %h",addr,expected);
  endtask
  task automatic periods(input time pixel_period, serial_period);
    time t;
    @(posedge dut.video.selected_pixel); t = $time;
    @(posedge dut.video.selected_pixel);
    if (($time-t) != pixel_period) $fatal(1,"wrong selected pixel clock period");
    @(posedge dut.video.selected_serial); t = $time;
    @(posedge dut.video.selected_serial);
    if (($time-t) != serial_period) $fatal(1,"wrong selected serializer clock period");
  endtask
  initial begin
    if (dut.video.scanout.reader.PACKED_READS != 4)
      $fatal(1,"packed reads did not reach the production reader");
    repeat (15) @(negedge bus_clk);
    reset_n = 1;
    poll('h08, 1<<25, 1<<25);
    poll('hb8, 7, 4);
    periods(13480,2696);
    write_reg('hb8,1);
    poll('hb8,7,7);
    periods(6740,1348);
    // Start and stop a real short raster to exercise the live-switch interlock.
    write_reg('h30,16); write_reg('h34,2); write_reg('h38,2); write_reg('h3c,2);
    write_reg('h40,8); write_reg('h44,2); write_reg('h48,2); write_reg('h4c,2);
    write_reg('h0c,7); poll('h10,6,4);
    write_reg('hb8,0,2'b10);
    poll('hb8,7,7);
    write_reg('h0c,0); poll('h10,10,8);
    write_reg('hb8,0); poll('hb8,7,4);
    periods(13480,2696);
    $display("TEST PASS: IronVideo software clock selection, both clock pairs and active scanout interlock");
    $finish;
  end
  initial begin #100000000; $fatal(1,"clock selection test timed out"); end
endmodule
