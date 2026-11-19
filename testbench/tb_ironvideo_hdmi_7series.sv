`timescale 1ns/1ps

// 11-18-2026, SystemVerilog-2012. Exercise the full AXI-to-TMDS top in UNISIM.
// Program a small DDR-fed mode and check both AXI fetches and serial colors.
module tb_ironvideo_hdmi_7series;
  logic axi_clk = 0;
  logic pixel_clk = 0;
  logic serial_clk = 0;
  logic reset_n = 0;

  logic [7:0] awaddr = 0;
  logic [31:0] wdata = 0;
  logic awvalid = 0;
  logic wvalid = 0;
  wire awready;
  wire wready;
  wire [1:0] bresp;
  wire bvalid;

  wire [31:0] araddr;
  wire [7:0] arlen;
  wire [2:0] arsize;
  wire arvalid;
  wire rready;
  logic rvalid = 0;
  logic [63:0] rdata = 0;
  logic remaining = 0;
  int requests = 0;

  wire [2:0] tmds_data_p;
  wire [2:0] tmds_data_n;
  wire tmds_clk_p;
  wire tmds_clk_n;

  always #5 axi_clk = !axi_clk;
  always #10 pixel_clk = !pixel_clk;
  always #2 serial_clk = !serial_clk;

  ironvideo_top #(.FAMILY("7SERIES")) dut (
    .axi_clk(axi_clk), .pixel_clk(pixel_clk), .serial_clk(serial_clk), .reset_n(reset_n),
    .s_axi_awaddr({8'b0, awaddr}), .s_axi_awprot(3'b0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(4'hf), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(1'b1),
    .s_axi_araddr(16'b0), .s_axi_arprot(3'b0), .s_axi_arvalid(1'b0), .s_axi_arready(),
    .s_axi_rdata(), .s_axi_rresp(), .s_axi_rvalid(), .s_axi_rready(1'b1),
    .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize),
    .m_axi_arburst(), .m_axi_arlock(), .m_axi_arcache(), .m_axi_arprot(),
    .m_axi_arqos(), .m_axi_arid(), .m_axi_arvalid(arvalid), .m_axi_arready(!rvalid),
    .m_axi_rdata(rdata), .m_axi_rresp(2'b0), .m_axi_rid(1'b0),
    .m_axi_rlast(!remaining), .m_axi_rvalid(rvalid), .m_axi_rready(rready),
    .tmds_data_p(tmds_data_p), .tmds_data_n(tmds_data_n),
    .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n), .irq()
  );

  localparam logic [23:0] PIXEL_0 = 24'hb46329;
  localparam logic [23:0] PIXEL_1 = 24'h19ae53;
  localparam logic [23:0] PIXEL_2 = 24'hf7396d;
  localparam logic [23:0] PIXEL_3 = 24'h655fd2;

  always @(posedge axi_clk) begin
    if (!reset_n) begin
      rvalid <= 0;
      remaining <= 0;
      requests <= 0;
    end else if (arvalid && !rvalid) begin
      if (araddr != 32'h1000 || arlen != 1 || arsize != 3)
        $fatal(1, "Unexpected HDMI scanout request address=%h len=%d size=%d", araddr, arlen, arsize);
      remaining <= 1;
      rvalid <= 1;
      rdata <= {8'b0, PIXEL_1, 8'b0, PIXEL_0};
      requests <= requests + 1;
    end else if (rvalid && rready) begin
      if (remaining) begin
        remaining <= 0;
        rdata <= {8'b0, PIXEL_3, 8'b0, PIXEL_2};
      end else
        rvalid <= 0;
    end
  end

  task automatic write_reg(input logic [7:0] addr, input logic [31:0] value);
    @(negedge axi_clk);
    awaddr = addr;
    wdata = value;
    awvalid = 1;
    wvalid = 1;
    do @(posedge axi_clk); while (!(awready && wready));
    @(negedge axi_clk);
    awvalid = 0;
    wvalid = 0;
    do @(posedge axi_clk); while (!bvalid);
    if (bresp != 0)
      $fatal(1, "HDMI configuration write %h failed", addr);
  endtask

  function automatic logic [7:0] decode(input logic [9:0] symbol);
    logic [7:0] payload;
    logic [7:0] decoded;
    payload = symbol[9] ? ~symbol[7:0] : symbol[7:0];
    decoded[0] = payload[0];
    for (int bit_index = 1; bit_index < 8; bit_index++)
      decoded[bit_index] = payload[bit_index] ^ payload[bit_index-1] ^ !symbol[8];
    return decoded;
  endfunction

  task automatic receive_pixel(output logic video, output logic [23:0] pixel);
    logic [9:0] red;
    logic [9:0] green;
    logic [9:0] blue;
    @(negedge tmds_clk_p);
    #0.8;
    for (int bit_index = 0; bit_index < 10; bit_index++) begin
      if (bit_index != 0) begin
        @(serial_clk);
        #0.8;
      end
      if (tmds_clk_p !== (bit_index >= 5) || tmds_clk_n !== !tmds_clk_p)
        $fatal(1, "Unexpected forwarded TMDS clock at bit %0d P=%b N=%b",
               bit_index, tmds_clk_p, tmds_clk_n);
      {red[bit_index], green[bit_index], blue[bit_index]} = tmds_data_p;
    end
    video = red != 10'b1101010100;
    pixel = {decode(red), decode(green), decode(blue)};
  endtask

  logic active;
  logic [23:0] pixel;
  initial begin
    repeat (12) @(negedge pixel_clk);
    reset_n = 1;
    write_reg(8'h20, 32'h1000);
    write_reg(8'h24, 16);
    write_reg(8'h28, 32'h1000);
    write_reg(8'h2c, 16);
    write_reg(8'h30, 4);
    write_reg(8'h34, 1);
    write_reg(8'h38, 1);
    write_reg(8'h3c, 2);
    write_reg(8'h40, 1);
    write_reg(8'h44, 1);
    write_reg(8'h48, 1);
    write_reg(8'h4c, 1);
    write_reg(8'h50, 3);
    write_reg(8'h54, 2);
    write_reg(8'h0c, 5);
    do receive_pixel(active, pixel); while (!active || pixel !== PIXEL_0);
    receive_pixel(active, pixel);
    if (!active || pixel !== PIXEL_1) $fatal(1, "HDMI lost pixel 1");
    receive_pixel(active, pixel);
    if (!active || pixel !== PIXEL_2) $fatal(1, "HDMI lost pixel 2");
    receive_pixel(active, pixel);
    if (!active || pixel !== PIXEL_3) $fatal(1, "HDMI lost pixel 3");
    receive_pixel(active, pixel);
    if (active || requests == 0) $fatal(1, "HDMI blanking or DDR request missing");
    $display("TEST PASS: IronVideo AXI-to-TMDS top");
    $finish;
  end

  initial begin
    #12000;
    $fatal(1, "Timed out waiting for AXI-to-TMDS pixels");
  end
endmodule

module tb_ironvideo_unsupported_family;
  ironvideo_top #(.FAMILY("ULTRASCALE")) dut ();
endmodule
