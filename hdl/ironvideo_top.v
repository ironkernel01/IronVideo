`timescale 1ns/1ps

// Public 7-series AXI-to-TMDS top. Supply a pixel clock and a phase-related
// serial clock at five times its frequency, plus an independent AXI clock.
module ironvideo_top #(
  parameter integer DATA_WIDTH = 64,
  parameter integer MAX_BURST = 64,
  parameter integer PACKED_READS = 1,
  parameter integer FIFO_KIB = 16,
  parameter integer ARQOS = 15,
  parameter integer AXI_ID_WIDTH = 1,
  parameter FAMILY = "7SERIES",
  // Bit 0 XRGB8888, bit 1 RGB565, bit 2 YUV422 (YUYV), bit 3 YUV420 (NV12).
  parameter integer FORMAT_MASK = 1,
  parameter integer CLOCK_SELECT = 0
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axi_clk CLK", X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI:M_AXI, ASSOCIATED_RESET reset_n" *)
  input wire axi_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 pixel_clk CLK" *)
  input wire pixel_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 serial_clk CLK" *)
  input wire serial_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 pixel_clk_alt CLK" *)
  input wire pixel_clk_alt,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 serial_clk_alt CLK" *)
  input wire serial_clk_alt,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 reset_n RST", X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input wire reset_n,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR", X_INTERFACE_PARAMETER = "PROTOCOL AXI4LITE, ADDR_WIDTH 16, DATA_WIDTH 32, HAS_PROT 1" *)
  input wire [15:0] s_axi_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
  input wire [2:0] s_axi_awprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
  input wire s_axi_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
  output wire s_axi_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
  input wire [31:0] s_axi_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
  input wire [3:0] s_axi_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
  input wire s_axi_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
  output wire s_axi_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
  output wire [1:0] s_axi_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
  output wire s_axi_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
  input wire s_axi_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
  input wire [15:0] s_axi_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
  input wire [2:0] s_axi_arprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
  input wire s_axi_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
  output wire s_axi_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
  output wire [31:0] s_axi_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
  output wire [1:0] s_axi_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
  output wire s_axi_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
  input wire s_axi_rready,
  // The interface advertises the maximum capability across PACKED_READS values.
  // Vivado infers data and ID widths from their ports. MAX_BURST
  // sets the request limit within the AXI4 ceiling of 256 beats.
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARADDR", X_INTERFACE_PARAMETER = "PROTOCOL AXI4, READ_WRITE_MODE READ_ONLY, ADDR_WIDTH 32, HAS_BURST 1, HAS_LOCK 1, HAS_CACHE 1, HAS_PROT 1, HAS_QOS 1, HAS_REGION 0, SUPPORTS_NARROW_BURST 0, MAX_BURST_LENGTH 256, NUM_READ_OUTSTANDING 4" *)
  output wire [31:0] m_axi_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLEN" *)
  output wire [7:0] m_axi_arlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARSIZE" *)
  output wire [2:0] m_axi_arsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARBURST" *)
  output wire [1:0] m_axi_arburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLOCK" *)
  output wire m_axi_arlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARCACHE" *)
  output wire [3:0] m_axi_arcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARPROT" *)
  output wire [2:0] m_axi_arprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARQOS" *)
  output wire [3:0] m_axi_arqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARID" *)
  output wire [AXI_ID_WIDTH-1:0] m_axi_arid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARVALID" *)
  output wire m_axi_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARREADY" *)
  input wire m_axi_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RDATA" *)
  input wire [DATA_WIDTH-1:0] m_axi_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RRESP" *)
  input wire [1:0] m_axi_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RID" *)
  input wire [AXI_ID_WIDTH-1:0] m_axi_rid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RLAST" *)
  input wire m_axi_rlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RVALID" *)
  input wire m_axi_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RREADY" *)
  output wire m_axi_rready,
  output wire [2:0] tmds_data_p,
  output wire [2:0] tmds_data_n,
  output wire tmds_clk_p,
  output wire tmds_clk_n,
  (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq INTERRUPT", X_INTERFACE_PARAMETER = "SENSITIVITY LEVEL_HIGH" *)
  output wire irq
);
  generate
    if (FAMILY != "7SERIES") begin : reject_unsupported_family
      // Deliberately unresolved so unsupported values fail at elaboration.
      IRONVIDEO_UNSUPPORTED_FAMILY__USE_7SERIES unsupported_family ();
    end
  endgenerate

  ironvideo_hdmi_7series #(
    .DATA_WIDTH(DATA_WIDTH), .MAX_BURST(MAX_BURST), .PACKED_READS(PACKED_READS), .FIFO_KIB(FIFO_KIB),
    .ARQOS(ARQOS), .AXI_ID_WIDTH(AXI_ID_WIDTH), .FORMAT_MASK(FORMAT_MASK), .CLOCK_SELECT(CLOCK_SELECT)
  ) video (
    .axi_clk(axi_clk),
    .pixel_clk(pixel_clk),
    .serial_clk(serial_clk),
    .pixel_clk_alt(pixel_clk_alt), .serial_clk_alt(serial_clk_alt),
    .reset_n(reset_n),
    .s_axi_awaddr((|s_axi_awaddr[15:8]) ? 8'hff : s_axi_awaddr[7:0]),
    .s_axi_awprot(s_axi_awprot),
    .s_axi_awvalid(s_axi_awvalid),
    .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata),
    .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid),
    .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp),
    .s_axi_bvalid(s_axi_bvalid),
    .s_axi_bready(s_axi_bready),
    .s_axi_araddr((|s_axi_araddr[15:8]) ? 8'hff : s_axi_araddr[7:0]),
    .s_axi_arprot(s_axi_arprot),
    .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata),
    .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid),
    .s_axi_rready(s_axi_rready),
    .m_axi_araddr(m_axi_araddr),
    .m_axi_arlen(m_axi_arlen),
    .m_axi_arsize(m_axi_arsize),
    .m_axi_arburst(m_axi_arburst),
    .m_axi_arlock(m_axi_arlock),
    .m_axi_arcache(m_axi_arcache),
    .m_axi_arprot(m_axi_arprot),
    .m_axi_arqos(m_axi_arqos),
    .m_axi_arid(m_axi_arid),
    .m_axi_arvalid(m_axi_arvalid),
    .m_axi_arready(m_axi_arready),
    .m_axi_rdata(m_axi_rdata),
    .m_axi_rresp(m_axi_rresp),
    .m_axi_rid(m_axi_rid),
    .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid),
    .m_axi_rready(m_axi_rready),
    .tmds_data_p(tmds_data_p),
    .tmds_data_n(tmds_data_n),
    .tmds_clk_p(tmds_clk_p),
    .tmds_clk_n(tmds_clk_n),
    .irq(irq)
  );
endmodule
