`timescale 1ns/1ps

module tb_ironvideo_row_stats;
  wire [2:0] done;
  ironvideo_row_stats_case #(.DATA_WIDTH(32), .FIFO_KIB(8), .EXPECTED_KIB(16)) width32 (.done(done[0]));
  ironvideo_row_stats_case #(.DATA_WIDTH(64), .FIFO_KIB(16), .EXPECTED_KIB(16)) width64 (.done(done[1]));
  ironvideo_row_stats_case #(.DATA_WIDTH(128), .FIFO_KIB(17), .EXPECTED_KIB(32)) width128 (.done(done[2]));

  initial begin
    wait (&done);
    $display("TEST PASS: IronVideo row fetch statistics");
    $finish;
  end

  initial begin
    #10ms;
    $fatal(1, "TEST FAIL: row statistics watchdog, done=%b", done);
  end
endmodule

module ironvideo_row_stats_case #(
  parameter int DATA_WIDTH = 64,
  parameter int FIFO_KIB = 16,
  parameter int EXPECTED_KIB = 16
) (
  output logic done = 0
);
  localparam int ROW_BYTES = 4096;
  localparam int BEAT_BYTES = DATA_WIDTH / 8;
  localparam int ROW_BEATS = ROW_BYTES / BEAT_BYTES;
  localparam int BURST_BEATS = 256;
  localparam int ROW_BURSTS = ROW_BEATS / BURST_BEATS;
  localparam int PIXEL_HALF_PERIOD = 13 + DATA_WIDTH / 32;
  localparam int PIXEL_PERIOD = 2 * PIXEL_HALF_PERIOD;
  localparam logic [31:0] BASE = 32'h1000;
  localparam logic [7:0] CONTROL = 8'h0c, STATUS = 8'h10, FAULT = 8'h14;
  localparam logic [7:0] CAPACITY = 8'h70, DMA_STATUS = 8'h74, LAST_ROW = 8'h78,
                         ROW_SIZE = 8'h7c, SAMPLES = 8'h80, WORST = 8'h84,
                         FASTEST = 8'h88, BEATS = 8'h8c, BURSTS = 8'h90,
                         ERRORS = 8'h94;

  logic axi_clk = 0, pixel_clk = 0, reset_n = 0;
  always #5 axi_clk = ~axi_clk;
  always #(PIXEL_HALF_PERIOD) pixel_clk = ~pixel_clk;

  logic [7:0] awaddr = 0, araddr = 0;
  logic [31:0] wdata = 0;
  logic awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
  wire awready, wready, bvalid, arready, rvalid;
  wire [1:0] bresp, rresp;
  wire [31:0] rdata;
  wire [31:0] mem_araddr;
  wire [7:0] mem_arlen;
  wire [2:0] mem_arsize;
  wire mem_arvalid, mem_rready;
  logic mem_arready = 0, mem_rvalid = 0, mem_rlast = 0;
  logic [1:0] mem_rresp = 0;

  ironvideo_scanout #(.DATA_WIDTH(DATA_WIDTH), .MAX_BURST(BURST_BEATS), .FIFO_KIB(FIFO_KIB)) dut (
    .axi_clk(axi_clk), .pixel_clk(pixel_clk), .reset_n(reset_n),
    .s_axi_awaddr(awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(4'hf), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .m_axi_araddr(mem_araddr), .m_axi_arlen(mem_arlen), .m_axi_arsize(mem_arsize),
    .m_axi_arburst(), .m_axi_arlock(), .m_axi_arcache(), .m_axi_arprot(),
    .m_axi_arqos(), .m_axi_arid(), .m_axi_arvalid(mem_arvalid), .m_axi_arready(mem_arready),
    .m_axi_rdata({DATA_WIDTH{1'b0}}), .m_axi_rresp(mem_rresp), .m_axi_rid(1'b0),
    .m_axi_rlast(mem_rlast), .m_axi_rvalid(mem_rvalid), .m_axi_rready(mem_rready),
    .rgb(), .de(), .hs(), .vs(), .irq()
  );

  task automatic write_reg(input logic [7:0] address, input logic [31:0] value,
                           input logic [1:0] response = 0);
    @(negedge axi_clk);
    awaddr = address;
    awvalid = 1;
    wdata = value;
    wvalid = 1;
    @(posedge axi_clk);
    if (!awready || !wready)
      $fatal(1, "TEST FAIL: width %0d AXI-Lite write not accepted", DATA_WIDTH);
    @(negedge axi_clk);
    awvalid = 0;
    wvalid = 0;
    while (!bvalid) @(negedge axi_clk);
    if (bresp !== response)
      $fatal(1, "TEST FAIL: width %0d AXI-Lite write %h response %b expected %b",
             DATA_WIDTH, address, bresp, response);
    bready = 1;
    @(negedge axi_clk);
    bready = 0;
  endtask

  task automatic collect_read(output logic [31:0] value, input int hold_cycles);
    while (!rvalid) @(negedge axi_clk);
    value = rdata;
    repeat (hold_cycles) begin
      @(negedge axi_clk);
      if (rvalid !== 1 || rdata !== value || rresp !== 0 || arready !== 0)
        $fatal(1, "TEST FAIL: width %0d AXI-Lite held read response", DATA_WIDTH);
    end
    if (rresp !== 0)
      $fatal(1, "TEST FAIL: width %0d AXI-Lite read %h response %b", DATA_WIDTH, araddr, rresp);
    rready = 1;
    @(negedge axi_clk);
    rready = 0;
  endtask

  task automatic read_reg(input logic [7:0] address, output logic [31:0] value,
                          input int hold_cycles = 0);
    @(negedge axi_clk);
    araddr = address;
    arvalid = 1;
    do @(posedge axi_clk); while (!arready);
    @(negedge axi_clk);
    arvalid = 0;
    collect_read(value, hold_cycles);
  endtask

  task automatic expect_reg(input logic [7:0] address, input logic [31:0] expected,
                            input logic [31:0] mask = '1);
    logic [31:0] value;
    read_reg(address, value);
    if ((value & mask) !== expected)
      $fatal(1, "TEST FAIL: width %0d CSR %h got %h expected %h mask %h",
             DATA_WIDTH, address, value, expected, mask);
  endtask

  task automatic wait_for_mode(input logic [3:0] expected);
    logic [31:0] value;
    repeat (40000) begin
      read_reg(STATUS, value);
      if (value[3:0] === expected) return;
    end
    $fatal(1, "TEST FAIL: width %0d mode transition status %h expected %h", DATA_WIDTH, value, expected);
  endtask

  time ar_presented;
  always @(posedge mem_arvalid) ar_presented = $time;

  task automatic take_ar(input logic [31:0] address);
    @(negedge axi_clk);
    while (!mem_arvalid) @(negedge axi_clk);
    if (mem_araddr !== address || mem_arlen !== 8'(BURST_BEATS-1) ||
        mem_arsize !== 3'($clog2(BEAT_BYTES)))
      $fatal(1, "TEST FAIL: width %0d AR address %h expected %h, len %0d size %0d",
             DATA_WIDTH, mem_araddr, address, mem_arlen, mem_arsize);
    mem_arready = 1;
    @(negedge axi_clk);
    mem_arready = 0;
  endtask

  // Drive the entire response at AXI clock edges, with optional R-channel gaps
  // and an AXI-Lite address handshake on the last response beat.
  task automatic send_burst(input int gap_cycles, input bit inject_error,
                            input logic [7:0] coincident_csr, output time finished_at);
    repeat (gap_cycles) @(negedge axi_clk);
    for (int beat = 0; beat < BURST_BEATS; beat++) begin
      @(negedge axi_clk);
      mem_rvalid = 1;
      mem_rlast = beat == BURST_BEATS - 1;
      mem_rresp = inject_error && beat == 3 ? 2'b10 : 2'b00;
      if (mem_rlast && coincident_csr != 0) begin
        araddr = coincident_csr;
        arvalid = 1;
      end
      @(posedge axi_clk);
      if (!mem_rready || (arvalid && !arready))
        $fatal(1, "TEST FAIL: width %0d stalled response beat %0d", DATA_WIDTH, beat);
      finished_at = $time;
    end
    @(negedge axi_clk);
    mem_rvalid = 0;
    mem_rlast = 0;
    mem_rresp = 0;
    arvalid = 0;
  endtask

  task automatic fetch_row(input int row, input int ar_delay, input int r_delay,
                           input logic [7:0] coincident_csr,
                           input logic [31:0] prior_extreme, output logic [31:0] duration);
    time started_at, finished_at;
    int elapsed_ticks;
    logic [31:0] value;
    @(negedge axi_clk);
    while (!mem_arvalid) @(negedge axi_clk);
    started_at = ar_presented;
    if (ar_delay != 0) begin
      expect_reg(DMA_STATUS, 3, 5'h1f);
      repeat (ar_delay) @(negedge axi_clk);
    end
    for (int burst_index = 0; burst_index < ROW_BURSTS; burst_index++) begin
      take_ar(BASE + row * ROW_BYTES + burst_index * BURST_BEATS * BEAT_BYTES);
      if (r_delay != 0) expect_reg(DMA_STATUS, 5, 5'h1f);
      send_burst(r_delay, 0, burst_index == ROW_BURSTS-1 ? coincident_csr : 0, finished_at);
    end
    if (coincident_csr != 0) begin
      collect_read(value, 8);
      if (value !== prior_extreme)
        $fatal(1, "TEST FAIL: width %0d coincident CSR %h got %0d expected prior %0d",
               DATA_WIDTH, coincident_csr, value, prior_extreme);
    end
    elapsed_ticks = int'((finished_at - started_at) / PIXEL_PERIOD);
    read_reg(LAST_ROW, duration);
    if ($isunknown(duration) || duration < elapsed_ticks || duration > elapsed_ticks + 1)
      $fatal(1, "TEST FAIL: width %0d row %0d duration %0d expected %0d..%0d pixel ticks",
             DATA_WIDTH, row, duration, elapsed_ticks, elapsed_ticks + 1);
    expect_reg(SAMPLES, row + 1);
    expect_reg(BEATS, (row + 1) * ROW_BEATS);
    expect_reg(BURSTS, (row + 1) * ROW_BURSTS);
  endtask

  initial begin
    logic [31:0] fast_row, slow_row, middle_row, final_row, held_extreme;
    time ignored_time;
    int timing [8];
    timing = '{1024, 24, 136, 160, 8, 1, 1, 1};

    repeat (10) @(negedge axi_clk);
    reset_n = 1;
    repeat (10) @(negedge axi_clk);
    expect_reg(CAPACITY, EXPECTED_KIB * 1024);
    expect_reg(DMA_STATUS, 0);
    expect_reg(ROW_SIZE, 0);
    expect_reg(SAMPLES, 0);
    write_reg(CAPACITY, 0, 2'b10);
    write_reg(8'h20, BASE);
    write_reg(8'h2c, 32'h00020000);
    for (int index = 0; index < 8; index++)
      write_reg(8'h30 + 8'(4 * index), timing[index]);
    write_reg(8'h54, ROW_BEATS);

    // Valid alignment, one line, and a wide DDR aperture isolate the FIFO limit.
    write_reg(8'h40, 1);
    write_reg(8'h30, EXPECTED_KIB * 256 + 4);
    write_reg(8'h24, EXPECTED_KIB * 1024 + 16);
    write_reg(CONTROL, 5, 2'b10);
    expect_reg(FAULT, 1, 1);
    expect_reg(ROW_SIZE, 0);
    write_reg(FAULT, 1);
    write_reg(8'h40, timing[4]);
    write_reg(8'h30, timing[0]);
    write_reg(8'h24, ROW_BYTES);

    write_reg(CONTROL, 5);
    wait_for_mode(5);
    expect_reg(ROW_SIZE, ROW_BYTES);

    fetch_row(0, 0, 0, 0, 0, fast_row);
    fetch_row(1, 51, 40, 0, 0, slow_row);
    if (slow_row <= fast_row)
      $fatal(1, "TEST FAIL: width %0d row latency did not include injected stalls", DATA_WIDTH);
    fetch_row(2, 19, 7, WORST, slow_row, middle_row);
    if (middle_row <= fast_row || middle_row >= slow_row)
      $fatal(1, "TEST FAIL: width %0d middle row latency outside test bounds", DATA_WIDTH);
    read_reg(WORST, held_extreme, 8);
    if (held_extreme !== middle_row)
      $fatal(1, "TEST FAIL: width %0d completion was lost on max clear", DATA_WIDTH);
    expect_reg(WORST, 0);
    fetch_row(3, 36, 20, FASTEST, fast_row, final_row);
    if (final_row <= middle_row)
      $fatal(1, "TEST FAIL: width %0d final row latency outside test bounds", DATA_WIDTH);
    read_reg(FASTEST, held_extreme, 8);
    if (held_extreme !== final_row)
      $fatal(1, "TEST FAIL: width %0d completion was lost on min clear", DATA_WIDTH);
    expect_reg(FASTEST, 0);

    // A stop after AR has been presented must drain the burst without publishing a row.
    @(negedge axi_clk);
    while (!mem_arvalid) @(negedge axi_clk);
    write_reg(CONTROL, 0);
    expect_reg(SAMPLES, 4);
    take_ar(BASE + 4 * ROW_BYTES);
    send_burst(0, 0, 0, ignored_time);
    wait_for_mode(9);
    expect_reg(SAMPLES, 4);
    expect_reg(LAST_ROW, final_row);
    expect_reg(BEATS, 4 * ROW_BEATS + BURST_BEATS);
    expect_reg(BURSTS, 4 * ROW_BURSTS + 1);
    expect_reg(DMA_STATUS, 0, 5'h1f);

    // An enable-only transition retains counters. A pattern commit drains
    // its outstanding burst, then resets the completed framebuffer epoch.
    write_reg(CONTROL, 1);
    wait_for_mode(5);
    expect_reg(SAMPLES, 4);
    take_ar(BASE);
    write_reg(CONTROL, 7);
    expect_reg(SAMPLES, 4);
    send_burst(0, 0, 0, ignored_time);
    wait_for_mode(5);
    expect_reg(ROW_SIZE, 0);
    expect_reg(SAMPLES, 0);
    expect_reg(LAST_ROW, 0);
    expect_reg(WORST, 0);
    expect_reg(FASTEST, 0);
    expect_reg(BEATS, 0);
    expect_reg(BURSTS, 0);
    expect_reg(ERRORS, 0);
    expect_reg(DMA_STATUS, 0, 5'h1f);

    write_reg(CONTROL, 5);
    wait_for_mode(5);
    take_ar(BASE);
    send_burst(0, 1, 0, ignored_time);
    expect_reg(SAMPLES, 0);
    expect_reg(LAST_ROW, 0);
    expect_reg(BEATS, BURST_BEATS);
    expect_reg(BURSTS, 1);
    expect_reg(ERRORS, 1);
    expect_reg(DMA_STATUS, 8, 5'h1f);
    expect_reg(FAULT, 2, 2);
    done = 1;
  end
endmodule
