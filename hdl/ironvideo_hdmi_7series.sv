`timescale 1ns/1ps

// Internal composition of the generic scanout and 7-series TMDS backend.
module ironvideo_hdmi_7series #(
  parameter int DATA_WIDTH = 64,
  parameter int MAX_BURST = 64,
  parameter int PACKED_READS = 1,
  parameter int FIFO_KIB = 16,
  parameter int ARQOS = 15,
  parameter int AXI_ID_WIDTH = 1,
  parameter int FORMAT_MASK = 1,
  parameter bit CLOCK_SELECT = 0
) (
  // Independent AXI clock, phase-related pixel and 5x serial clocks, and active-low reset.
  input logic axi_clk,
  input logic pixel_clk,
  input logic serial_clk,
  input logic pixel_clk_alt, serial_clk_alt,
  input logic reset_n,

  // AXI4-Lite control and diagnostics, clocked by axi_clk.
  input logic [7:0] s_axi_awaddr,
  input logic [2:0] s_axi_awprot,
  input logic s_axi_awvalid,
  output logic s_axi_awready,
  input logic [31:0] s_axi_wdata,
  input logic [3:0] s_axi_wstrb,
  input logic s_axi_wvalid,
  output logic s_axi_wready,
  output logic [1:0] s_axi_bresp,
  output logic s_axi_bvalid,
  input logic s_axi_bready,
  input logic [7:0] s_axi_araddr,
  input logic [2:0] s_axi_arprot,
  input logic s_axi_arvalid,
  output logic s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0] s_axi_rresp,
  output logic s_axi_rvalid,
  input logic s_axi_rready,

  // Read-only AXI4 DDR master, clocked by axi_clk, with byte addresses.
  output logic [31:0] m_axi_araddr,
  output logic [7:0] m_axi_arlen,
  output logic [2:0] m_axi_arsize,
  output logic [1:0] m_axi_arburst,
  output logic m_axi_arlock,
  output logic [3:0] m_axi_arcache,
  output logic [2:0] m_axi_arprot,
  output logic [3:0] m_axi_arqos,
  output logic [AXI_ID_WIDTH-1:0] m_axi_arid,
  output logic m_axi_arvalid,
  input logic m_axi_arready,
  input logic [DATA_WIDTH-1:0] m_axi_rdata,
  input logic [1:0] m_axi_rresp,
  input logic [AXI_ID_WIDTH-1:0] m_axi_rid,
  input logic m_axi_rlast,
  input logic m_axi_rvalid,
  output logic m_axi_rready,

  // Positive and negative TMDS data and forwarded clock pairs.
  output wire [2:0] tmds_data_p,
  output wire [2:0] tmds_data_n,
  output wire tmds_clk_p,
  output wire tmds_clk_n,
  // Active-high consolidated interrupt, synchronous to axi_clk.
  output wire irq
);
  wire [23:0] rgb;
  wire de;
  wire hs;
  wire vs;
  wire selected_pixel, selected_serial, clock_request, clock_active, clock_ready;
  if (CLOCK_SELECT) begin : clock_mux
    logic select_reg;
    logic [4:0] settle;
    // Both input pairs run continuously. Hold the serializer in reset while
    // the two glitchless muxes independently transfer to their new inputs.
    BUFGMUX_CTRL pixel_mux (.I0(pixel_clk), .I1(pixel_clk_alt), .S(select_reg), .O(selected_pixel));
    BUFGMUX_CTRL serial_mux (.I0(serial_clk), .I1(serial_clk_alt), .S(select_reg), .O(selected_serial));
    wire pixel_reset, serial_reset;
    wire clocks_settled = reset_n && select_reg == clock_request && settle == 0;
    ironvideo_reset pixel_edges (.clk(selected_pixel), .reset_n(clocks_settled), .rst(pixel_reset));
    ironvideo_reset serial_edges (.clk(selected_serial), .reset_n(clocks_settled), .rst(serial_reset));
    (* ASYNC_REG = "TRUE" *) logic [2:0] pixel_ok, serial_ok;
    always_ff @(posedge axi_clk or negedge reset_n) begin
      if (!reset_n) begin
        select_reg <= 0;
        settle <= '1;
        pixel_ok <= 0;
        serial_ok <= 0;
      end else begin
        pixel_ok <= {pixel_ok[1:0], !pixel_reset};
        serial_ok <= {serial_ok[1:0], !serial_reset};
        if (select_reg != clock_request) begin
          select_reg <= clock_request;
          settle <= '1;
        end else if (settle != 0)
          settle <= settle - 1'b1;
      end
    end
    assign clock_active = select_reg;
    assign clock_ready = clocks_settled && pixel_ok[2] && serial_ok[2];
  end else begin : fixed_clock
    assign selected_pixel = pixel_clk;
    assign selected_serial = serial_clk;
    assign clock_active = 0;
    assign clock_ready = 1;
  end

  ironvideo_scanout #(
    .DATA_WIDTH(DATA_WIDTH), .MAX_BURST(MAX_BURST), .PACKED_READS(PACKED_READS), .FIFO_KIB(FIFO_KIB),
    .ARQOS(ARQOS), .AXI_ID_WIDTH(AXI_ID_WIDTH), .FORMAT_MASK(FORMAT_MASK), .CLOCK_SELECT(CLOCK_SELECT)
  ) scanout (
    .axi_clk(axi_clk), .pixel_clk(selected_pixel), .reset_n(reset_n),
    .clock_request(clock_request), .clock_active(clock_active), .clock_ready(clock_ready),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awprot(s_axi_awprot),
    .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arprot(s_axi_arprot),
    .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
    .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
    .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock),
    .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot), .m_axi_arqos(m_axi_arqos),
    .m_axi_arid(m_axi_arid), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rid(m_axi_rid),
    .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
    .rgb(rgb), .de(de), .hs(hs), .vs(vs), .irq(irq)
  );

  ironvideo_tmds_7series backend (
    .pixel_clk(selected_pixel), .serial_clk(selected_serial), .reset_n(reset_n && clock_ready),
    .rgb(rgb), .de(de), .hs(hs), .vs(vs),
    .tmds_data_p(tmds_data_p), .tmds_data_n(tmds_data_n),
    .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n)
  );
endmodule
