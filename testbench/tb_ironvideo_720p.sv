`timescale 1ns/1fs

// 11-18-2026, SystemVerilog-2012. Initial full-size IronVideo scanout regression.
// Check startup blacking and a complete 720p60 framebuffer raster with DDR stalls.
module tb_ironvideo_720p #(
  parameter int DATA_WIDTH = 64,
  parameter int STRIDE = 5184,
  parameter int PREFILL = 256,
  parameter int MAX_BURST = 64,
  parameter bit CHECK_SERIAL = 0,
  parameter bit MODE_1080 = 0,
  parameter int FORMAT_ID = 0,
  parameter int FORMAT_MASK = 1
);
  localparam int H_ACTIVE = MODE_1080 ? 1920 : 1280, H_FRONT = MODE_1080 ? 88 : 110;
  localparam int H_SYNC = MODE_1080 ? 44 : 40, H_BACK = MODE_1080 ? 148 : 220;
  localparam int V_ACTIVE = MODE_1080 ? 1080 : 720, V_FRONT = MODE_1080 ? 4 : 5;
  localparam int V_SYNC = 5, V_BACK = MODE_1080 ? 36 : 20;
  localparam int H_TOTAL = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;
  localparam int V_TOTAL = V_ACTIVE + V_FRONT + V_SYNC + V_BACK;
  localparam int PIXEL_BYTES = FORMAT_ID == 0 ? 4 : FORMAT_ID == 3 ? 1 : 2;
  localparam int BEAT_BYTES = DATA_WIDTH / 8;
  localparam logic [2:0] AXI_SIZE = 3'($clog2(BEAT_BYTES));
  localparam logic [31:0] BASE = 32'h0100_0000;
  localparam logic [31:0] UV_BASE = 32'h0200_0ff0;
  localparam int UV_STRIDE = H_ACTIVE + 32;
  localparam realtime SERIAL_BIT_PERIOD = MODE_1080 ? 673401fs : 1346801fs;
  localparam realtime PIXEL_HALF_PERIOD = 5 * SERIAL_BIT_PERIOD;
  localparam logic [7:0] REG_CAPS = 'h08, REG_CONTROL = 'h0c, REG_STATUS = 'h10, REG_FAULT = 'h14, REG_MASK = 'h18,
    REG_BASE = 'h20, REG_STRIDE = 'h24, REG_WINDOW_BASE = 'h28, REG_WINDOW_BYTES = 'h2c,
    REG_H_ACTIVE = 'h30, REG_H_FRONT = 'h34, REG_H_SYNC = 'h38, REG_H_BACK = 'h3c,
    REG_V_ACTIVE = 'h40, REG_V_FRONT = 'h44, REG_V_SYNC = 'h48, REG_V_BACK = 'h4c,
    REG_POLARITY = 'h50, REG_PREFILL = 'h54, REG_UNDERFLOWS = 'h58, REG_FRAMES = 'h64;
  localparam logic [31:0] ENABLE = 1, COMMIT = 4, SNAPSHOT = 8, SNAPSHOT_BUSY = 16;

  logic axi_clk = 0;
  logic pixel_clk = 0;
  logic reset_n = 0;
  always #5ns axi_clk = ~axi_clk; // 100 MHz
  always #(PIXEL_HALF_PERIOD) pixel_clk = ~pixel_clk; // 74.25 MHz

  logic [7:0] awaddr = 0;
  logic awvalid = 0;
  wire awready;
  logic [31:0] wdata = 0;
  logic wvalid = 0;
  wire wready;
  wire [1:0] bresp;
  wire bvalid;
  logic [7:0] araddr = 0;
  logic arvalid = 0;
  wire arready;
  wire [31:0] rdata;
  wire [1:0] rresp;
  wire rvalid;

  wire [31:0] mem_araddr;
  wire [7:0] mem_arlen;
  wire [2:0] mem_arsize;
  wire [1:0] mem_arburst;
  wire mem_arvalid;
  wire mem_arready;
  wire [DATA_WIDTH-1:0] mem_rdata;
  wire mem_rlast;
  wire mem_rvalid;
  wire mem_rready;

  wire [23:0] rgb;
  wire de, hs, vs, irq;
  logic rasters_checked = 0;
  wire serial_checked;
  localparam int FRAME_COUNT = CHECK_SERIAL ? 3 : 2;

`define IRONVIDEO_RASTER_AXI(AW, AR) \
    .axi_clk(axi_clk), .pixel_clk(pixel_clk), .reset_n(reset_n), \
    .s_axi_awaddr(AW), .s_axi_awprot(3'b000), .s_axi_awvalid(awvalid), .s_axi_awready(awready), \
    .s_axi_wdata(wdata), .s_axi_wstrb(4'hf), .s_axi_wvalid(wvalid), .s_axi_wready(wready), \
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(1'b1), \
    .s_axi_araddr(AR), .s_axi_arprot(3'b000), .s_axi_arvalid(arvalid), .s_axi_arready(arready), \
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(1'b1), \
    .m_axi_araddr(mem_araddr), .m_axi_arlen(mem_arlen), .m_axi_arsize(mem_arsize), \
    .m_axi_arburst(mem_arburst), .m_axi_arlock(), .m_axi_arcache(), \
    .m_axi_arprot(), .m_axi_arqos(), .m_axi_arid(), \
    .m_axi_arvalid(mem_arvalid), .m_axi_arready(mem_arready), \
    .m_axi_rdata(mem_rdata), .m_axi_rresp(2'b00), .m_axi_rid(1'b0), \
    .m_axi_rlast(mem_rlast), .m_axi_rvalid(mem_rvalid), .m_axi_rready(mem_rready), .irq(irq)

  if (CHECK_SERIAL) begin : serialized_output
    logic serial_clk = 0;
    wire [2:0] data_p, data_n;
    wire clk_p, clk_n;
    wire [15:0] board_awaddr = {8'b0, awaddr}, board_araddr = {8'b0, araddr};
    always #(SERIAL_BIT_PERIOD) serial_clk = ~serial_clk;

    ironvideo_top #(.DATA_WIDTH(DATA_WIDTH), .MAX_BURST(MAX_BURST), .FORMAT_MASK(FORMAT_MASK)) dut (
      `IRONVIDEO_RASTER_AXI(board_awaddr, board_araddr),
      .serial_clk(serial_clk), .tmds_data_p(data_p),
      .tmds_data_n(data_n), .tmds_clk_p(clk_p), .tmds_clk_n(clk_n)
    );
    // Probe the production wrapper's raster for the parallel scoreboard.
    // The serial receiver observes only the output pins.
    assign {rgb, de, hs, vs} = {dut.video.rgb, dut.video.de, dut.video.hs, dut.video.vs};
    ironvideo_serial_receiver #(.MODE_1080(MODE_1080), .FORMAT_ID(FORMAT_ID), .STRIDE(STRIDE)) receiver (
      .clk_p(clk_p), .clk_n(clk_n), .data_p(data_p), .data_n(data_n),
      .checked(serial_checked)
    );
  end else begin : parallel_only
    assign serial_checked = 1;
    ironvideo_scanout #(.DATA_WIDTH(DATA_WIDTH), .MAX_BURST(MAX_BURST), .FIFO_KIB(16), .FORMAT_MASK(FORMAT_MASK)) dut (
      `IRONVIDEO_RASTER_AXI(awaddr, araddr), .rgb(rgb), .de(de), .hs(hs), .vs(vs)
    );
  end
`undef IRONVIDEO_RASTER_AXI

  task automatic write_reg(input logic [7:0] address, input logic [31:0] value);
    @(negedge axi_clk);
    awaddr = address;
    awvalid = 1;
    wdata = value;
    wvalid = 1;
    fork
      begin
        do @(posedge axi_clk); while (!awready);
        @(negedge axi_clk);
        awvalid = 0;
      end
      begin
        do @(posedge axi_clk); while (!wready);
        @(negedge axi_clk);
        wvalid = 0;
      end
    join
    do @(posedge axi_clk); while (!bvalid);
    if (bresp !== 0)
      $fatal(1, "TEST FAIL: register %h write returned %b", address, bresp);
  endtask

  task automatic read_reg(input logic [7:0] address, output logic [31:0] value);
    @(negedge axi_clk);
    araddr = address;
    arvalid = 1;
    do @(posedge axi_clk); while (!arready);
    @(negedge axi_clk);
    arvalid = 0;
    do @(posedge axi_clk); while (!rvalid);
    if (rresp !== 0)
      $fatal(1, "TEST FAIL: register %h read returned %b", address, rresp);
    value = rdata;
  endtask

  function automatic byte unsigned framebuffer_byte(input logic [31:0] address);
    int offset, x, y, column;
    logic [31:0] packed_pixel;
    if (address >= UV_BASE) begin
      offset = int'(address - UV_BASE);
      column = offset % UV_STRIDE;
      y = offset / UV_STRIDE;
      return column[0] ? ironvideo_format_model::cr(column/2,y) : ironvideo_format_model::cb(column/2,y);
    end
    offset = int'(address - BASE);
    column = offset % STRIDE;
    y = offset / STRIDE;
    x = column / PIXEL_BYTES;
    case (FORMAT_ID)
      0: begin
        packed_pixel = {8'hff ^ 8'(offset/4), ironvideo_format_model::color(0,x,y,STRIDE)};
        return 8'(packed_pixel >> (8 * (column % 4)));
      end
      1: return 8'(ironvideo_format_model::rgb565(x,y) >> (8 * (column % 2)));
      2: return !column[0] ? ironvideo_format_model::luma(x,y) :
                  column[1] ? ironvideo_format_model::cr(x/2,y) : ironvideo_format_model::cb(x/2,y);
      default: return ironvideo_format_model::luma(x,y);
    endcase
  endfunction

  int cycle = 0;
  int remaining = 0;
  int first_beat_delay = 0;
  int ar_stall_cycles = 0;
  int response_bubbles = 0;
  int complete_read_frames = 0;
  logic full_burst_seen = 0;
  logic [31:0] read_address = BASE;
  bit chroma_segment = FORMAT_ID == 3;
  int line_number = 0;
  logic [31:0] next_address = FORMAT_ID == 3 ? UV_BASE : BASE;
  wire [31:0] line_end = chroma_segment ? UV_BASE + (line_number/2)*UV_STRIDE + H_ACTIVE :
                             BASE + line_number*STRIDE + H_ACTIVE*PIXEL_BYTES;
  wire [31:0] burst_end = mem_araddr + (32'(mem_arlen) + 1) * BEAT_BYTES;

  // The slave models periodic address arbitration, 120 to 230 ns initial
  // latency, and occasional data bubbles. It returns consecutive beats between bubbles.
  assign mem_arready = reset_n && remaining == 0 && cycle % 13 >= 4;
  bit stalled_response = 0;
  assign mem_rvalid = remaining != 0 && first_beat_delay == 0 && (stalled_response || cycle % 19 >= 3);
  assign mem_rlast = remaining == 1;
  for (genvar lane = 0; lane < BEAT_BYTES; lane++) begin : memory_lanes
    assign mem_rdata[lane * 8 +: 8] = framebuffer_byte(read_address + lane);
  end

  always @(posedge axi_clk) begin
    if (reset_n) begin
      cycle <= cycle + 1;
      stalled_response <= mem_rvalid && !mem_rready;
      if (mem_arvalid && !mem_arready)
        ar_stall_cycles <= ar_stall_cycles + 1;
      if (mem_arvalid && mem_arready) begin
        if (mem_araddr !== next_address || mem_arsize !== AXI_SIZE || mem_arburst !== 2'b01 ||
            mem_arlen >= MAX_BURST || burst_end > line_end || mem_araddr[31:12] != ((burst_end - 1) >> 12))
          $fatal(1, "TEST FAIL: invalid DDR burst at %h through %h, expected start %h and line end %h",
                 mem_araddr, burst_end - 1, next_address, line_end);

        if (burst_end == line_end) begin
          if (chroma_segment) begin
            next_address <= BASE + line_number * STRIDE;
            chroma_segment <= 0;
          end else if (line_number == V_ACTIVE - 1) begin
            line_number <= 0;
            next_address <= FORMAT_ID == 3 ? UV_BASE : BASE;
            chroma_segment <= FORMAT_ID == 3;
            complete_read_frames <= complete_read_frames + 1;
          end else begin
            line_number <= line_number + 1;
            chroma_segment <= FORMAT_ID == 3 && line_number[0];
            next_address <= FORMAT_ID == 3 && line_number[0] ? UV_BASE + ((line_number+1)/2)*UV_STRIDE :
                            BASE + (line_number+1)*STRIDE;
          end
        end else begin
          next_address <= burst_end;
        end

        remaining <= 32'(mem_arlen) + 1;
        if (32'(mem_arlen) + 1 == MAX_BURST)
          full_burst_seen <= 1;
        read_address <= mem_araddr;
        first_beat_delay <= 11 + cycle % 12;
      end else if (first_beat_delay != 0) begin
        first_beat_delay <= first_beat_delay - 1;
      end else if (mem_rvalid && mem_rready) begin
        remaining <= remaining - 1;
        read_address <= read_address + BEAT_BYTES;
      end else if (remaining != 0) begin
        response_bubbles <= response_bubbles + 1;
      end
      if (irq !== 1'b0)
        $fatal(1, "TEST FAIL: unexpected IRQ during 720p60 scanout");
    end
  end

  // The first DE edge marks the origin. Check every subsequent pixel clock
  // through two raster periods, including both porches and both sync pulses.
  initial begin : verify_raster
    logic expected_de, expected_hs, expected_vs;
    logic [23:0] expected_rgb;

    @(posedge de);
    @(negedge pixel_clk);
    for (int frame = 0; frame < FRAME_COUNT; frame++) begin
      for (int y = 0; y < V_TOTAL; y++) begin
        for (int x = 0; x < H_TOTAL; x++) begin
          expected_de = x < H_ACTIVE && y < V_ACTIVE;
          expected_hs = x >= H_ACTIVE + H_FRONT && x < H_ACTIVE + H_FRONT + H_SYNC;
          expected_vs = y >= V_ACTIVE + V_FRONT && y < V_ACTIVE + V_FRONT + V_SYNC;
          expected_rgb = 0;
          if (frame != 0 && expected_de) begin
            expected_rgb = ironvideo_format_model::color(FORMAT_ID,x,y,STRIDE);
          end
          if ({de, hs, vs, rgb} !== {expected_de, expected_hs, expected_vs, expected_rgb})
            $fatal(1, "TEST FAIL: frame %0d pixel (%0d,%0d) got DE/HS/VS %b%b%b RGB %h, expected %b%b%b RGB %h",
                   frame, x, y, de, hs, vs, rgb, expected_de, expected_hs, expected_vs, expected_rgb);
          @(negedge pixel_clk);
        end
      end
    end
    rasters_checked = 1;
  end

  initial begin : control_and_diagnostics
    logic [31:0] value;

    repeat (10) @(negedge axi_clk);
    reset_n = 1;
    repeat (8) @(negedge axi_clk);
    read_reg(REG_CAPS, value);
    $display("Checking native framebuffer format %0d at %0dp60", FORMAT_ID, V_ACTIVE);
    if (value[24:16] !== 9'(MAX_BURST))
      $fatal(1, "TEST FAIL: CAPS burst limit is %0d, expected %0d", value[24:16], MAX_BURST);
    write_reg(REG_MASK, 32'hf);
    if (FORMAT_MASK != 1) begin
      read_reg('h98, value);
      if (value !== FORMAT_MASK) $fatal(1, "TEST FAIL: format discovery got %h", value);
      write_reg('h9c, FORMAT_ID);
    end
    if (FORMAT_ID == 3) begin
      write_reg('ha0, UV_BASE);
      write_reg('ha4, UV_STRIDE);
      write_reg('ha8, UV_BASE);
      write_reg('hac, (V_ACTIVE/2)*UV_STRIDE);
    end
    write_reg(REG_BASE, BASE);
    write_reg(REG_STRIDE, STRIDE);
    write_reg(REG_WINDOW_BASE, BASE);
    write_reg(REG_WINDOW_BYTES, V_ACTIVE * STRIDE);
    write_reg(REG_H_ACTIVE, H_ACTIVE);
    write_reg(REG_H_FRONT, H_FRONT);
    write_reg(REG_H_SYNC, H_SYNC);
    write_reg(REG_H_BACK, H_BACK);
    write_reg(REG_V_ACTIVE, V_ACTIVE);
    write_reg(REG_V_FRONT, V_FRONT);
    write_reg(REG_V_SYNC, V_SYNC);
    write_reg(REG_V_BACK, V_BACK);
    write_reg(REG_POLARITY, 3);
    write_reg(REG_PREFILL, PREFILL);
    write_reg(REG_CONTROL, ENABLE | COMMIT);

    wait (rasters_checked && serial_checked);
    write_reg(REG_CONTROL, ENABLE | SNAPSHOT);
    do read_reg(REG_STATUS, value); while ((value & SNAPSHOT_BUSY) != 0);
    read_reg(REG_UNDERFLOWS, value);
    if (value !== 0)
      $fatal(1, "TEST FAIL: 720p60 underflow count is %0d", value);
    read_reg(REG_FAULT, value);
    if (value !== 0)
      $fatal(1, "TEST FAIL: 720p60 fault status is %h", value);
    read_reg(REG_FRAMES, value);
    if (value !== FRAME_COUNT || complete_read_frames < FRAME_COUNT - 1 || ar_stall_cycles == 0 || response_bubbles == 0)
      $fatal(1, "TEST FAIL: frames=%0d DDR frames=%0d AR stalls=%0d R bubbles=%0d",
             value, complete_read_frames, ar_stall_cycles, response_bubbles);
    if (!full_burst_seen)
      $fatal(1, "TEST FAIL: no %0d-beat burst was exercised", MAX_BURST);

    $display("%0d-bit scanout: frames=%0d DDR frames=%0d AR stalls=%0d R bubbles=%0d",
             DATA_WIDTH, value, complete_read_frames, ar_stall_cycles, response_bubbles);
    if (CHECK_SERIAL)
      $display("TEST PASS: IronVideo continuous serialized %0dp60 with 32-beat bursts", V_ACTIVE);
    else if (DATA_WIDTH == 64)
      $display("TEST PASS: IronVideo 720p60 full frame");
    else if (MAX_BURST != 64)
      $display("TEST PASS: IronVideo 720p60 %0d-bit full frame with %0d-beat bursts", DATA_WIDTH, MAX_BURST);
    else
      $display("TEST PASS: IronVideo 720p60 %0d-bit full frame", DATA_WIDTH);
    $finish;
  end

  initial begin
    #(CHECK_SERIAL ? 60ms : 40ms);
    $fatal(1, "TEST FAIL: 720p60 regression watchdog");
  end
endmodule

module tb_ironvideo_720p_128_burst32;
  localparam int DATA_WIDTH = 128;
  localparam int STRIDE = 1280 * 4;
  localparam int PREFILL = STRIDE / (DATA_WIDTH / 8);

  tb_ironvideo_720p #(.DATA_WIDTH(DATA_WIDTH), .STRIDE(STRIDE), .PREFILL(PREFILL), .MAX_BURST(32)) bench ();
endmodule

module tb_ironvideo_720p_128;
  localparam int DATA_WIDTH = 128;
  localparam int STRIDE = 1280 * 4;
  localparam int PREFILL = STRIDE / (DATA_WIDTH / 8);

  tb_ironvideo_720p #(.DATA_WIDTH(DATA_WIDTH), .STRIDE(STRIDE), .PREFILL(PREFILL)) bench ();
endmodule
