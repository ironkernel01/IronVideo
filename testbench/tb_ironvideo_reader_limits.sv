`timescale 1ns/1ps

// Runs the standalone AXI framebuffer reader at all supported beat widths.
// 11-18-2026: Initial burst limit, page boundary, and FIFO capacity regression.
// SystemVerilog-2012.
module tb_ironvideo_reader_limits;
  logic clk = 0;
  wire [8:0] done;

  always #5ns clk = ~clk;

  for (genvar width_index = 0; width_index < 3; width_index++) begin : widths
    localparam int DATA_WIDTH = 32 << width_index;
    for (genvar limit_index = 0; limit_index < 3; limit_index++) begin : limits
      localparam int MAX_BURST = limit_index == 0 ? 1 : (limit_index == 1 ? 64 : 256);
      ironvideo_reader_limits_case #(
        .DATA_WIDTH(DATA_WIDTH),
        .MAX_BURST(MAX_BURST)
      ) test_case (
        .clk(clk),
        .done(done[width_index * 3 + limit_index])
      );
    end
  end

  initial begin
    wait (&done);
    $display("TEST PASS: IronVideo reader burst limits");
    $finish;
  end

  initial begin
    #100us;
    $fatal(1, "TEST FAIL: IronVideo reader burst limits timed out, completed cases=%b", done);
  end
endmodule

// Models the memory and FIFO ports for one width and maximum burst length.
// 11-18-2026: Initial AXI request and FIFO beat checks.
// SystemVerilog-2012.
module ironvideo_reader_limits_case #(
  parameter int DATA_WIDTH = 32,
  parameter int MAX_BURST = 1
) (
  // Memory clock for the reader, AXI memory model and FIFO capacity model.
  input logic clk,
  // High after all transfers and the final idle check complete.
  output bit done = 0
);
  localparam int BEAT_BYTES = DATA_WIDTH / 8;
  localparam int PAGE_BYTES = 4096;
  localparam int PAGE_BEATS = PAGE_BYTES / BEAT_BYTES;
  localparam int FIFO_AW = 11;
  localparam int PREFIX_BEATS = 5;
  localparam int TAIL_BEATS = 7;
  localparam logic [31:0] PAGE_START = 32'h00002000;
  localparam logic [31:0] BASE = PAGE_START - PREFIX_BEATS * BEAT_BYTES;
  localparam int LINE_BYTES = (PREFIX_BEATS + PAGE_BEATS + TAIL_BEATS) * BEAT_BYTES;
  localparam int LINE_BEATS = LINE_BYTES / BEAT_BYTES;

  logic rst = 1;
  logic run = 0;
  logic [FIFO_AW:0] fifo_free = 0;
  wire fifo_write;
  wire [DATA_WIDTH-1:0] fifo_data;
  wire fifo_sof;
  wire fifo_sol;
  wire [31:0] araddr;
  wire [7:0] arlen;
  wire [2:0] arsize;
  wire [1:0] arburst;
  wire arvalid;
  logic arready = 0;
  logic [DATA_WIDTH-1:0] rdata = 0;
  logic rlast = 0;
  logic rvalid = 0;
  wire rready;
  wire idle;
  wire resp_fault;
  wire last_fault;
  logic [31:0] expected_addr = BASE;

  ironvideo_reader #(
    .DATA_WIDTH(DATA_WIDTH),
    .MAX_BURST(MAX_BURST),
    .FIFO_AW(FIFO_AW)
  ) dut (
    .clk(clk),
    .rst(rst),
    .run(run),
    .base(BASE),
    .stride(32'(LINE_BYTES)),
    .line_bytes(32'(LINE_BYTES)),
    .lines(16'd1),
    .fifo_free(fifo_free),
    .fifo_write(fifo_write),
    .fifo_data(fifo_data),
    .fifo_sof(fifo_sof),
    .fifo_sol(fifo_sol),
    .m_axi_arid(),
    .m_axi_araddr(araddr),
    .m_axi_arlen(arlen),
    .m_axi_arsize(arsize),
    .m_axi_arburst(arburst),
    .m_axi_arlock(),
    .m_axi_arcache(),
    .m_axi_arprot(),
    .m_axi_arqos(),
    .m_axi_arvalid(arvalid),
    .m_axi_arready(arready),
    .m_axi_rid(1'b0),
    .m_axi_rdata(rdata),
    .m_axi_rresp(2'b00),
    .m_axi_rlast(rlast),
    .m_axi_rvalid(rvalid),
    .m_axi_rready(rready),
    .idle(idle),
    .row_busy(),
    .row_start(),
    .row_done(),
    .resp_fault(resp_fault),
    .last_fault(last_fault),
    .fault_addr()
  );

  always @(posedge clk) begin
    if (!rst && ({resp_fault, last_fault} !== 2'b00))
      $fatal(1, "TEST FAIL: width=%0d max=%0d unexpected reader fault", DATA_WIDTH, MAX_BURST);
  end

  task automatic expect_idle(input int cycles);
    repeat (cycles) begin
      @(posedge clk);
      if ({idle, arvalid, rready, fifo_write} !== 4'b1000)
        $fatal(1, "TEST FAIL: width=%0d max=%0d reader active with no work or credit",
               DATA_WIDTH, MAX_BURST);
      @(negedge clk);
    end
  endtask

  task automatic check_address(input int expected_beats);
    if (arvalid !== 1'b1 || araddr !== expected_addr || int'(arlen) + 1 !== expected_beats ||
        arsize !== 3'($clog2(BEAT_BYTES)) || arburst !== 2'b01 ||
        (araddr % BEAT_BYTES) != 0 ||
        int'(araddr[11:0]) + expected_beats * BEAT_BYTES > PAGE_BYTES ||
        expected_beats > int'(fifo_free) || rready !== 1'b0 || fifo_write !== 1'b0)
      $fatal(1, "TEST FAIL: width=%0d max=%0d AR addr=%h beats=%0d size=%0d burst=%b expected addr=%h beats=%0d credit=%0d",
             DATA_WIDTH, MAX_BURST, araddr, int'(arlen) + 1, arsize, arburst, expected_addr,
             expected_beats, fifo_free);
  endtask

  task automatic transfer_burst(input int expected_beats);
    // Stall the address channel and check that the full request stays stable.
    do @(negedge clk); while (arvalid === 1'b0);
    repeat (2) begin
      @(posedge clk);
      check_address(expected_beats);
      @(negedge clk);
    end
    arready = 1;
    @(posedge clk);
    check_address(expected_beats);
    @(negedge clk);
    arready = 0;

    // The memory pauses before beat zero, then returns one beat per cycle.
    @(posedge clk);
    if ({arvalid, fifo_write} !== 2'b00)
      $fatal(1, "TEST FAIL: width=%0d max=%0d reader active before any R beat", DATA_WIDTH, MAX_BURST);
    @(negedge clk);
    for (int beat = 0; beat < expected_beats; beat++) begin
      rvalid = 1;
      rlast = beat == expected_beats - 1;
      rdata = {(DATA_WIDTH / 32){expected_addr}};
      @(posedge clk);
      if ({arvalid, rready, fifo_write} !== 3'b011 || fifo_data !== rdata ||
          fifo_sof !== (expected_addr == BASE) || fifo_sol !== (expected_addr == BASE) ||
          fifo_free == 0)
        $fatal(1, "TEST FAIL: width=%0d max=%0d incorrect FIFO transfer at addr=%h, burst beat=%0d",
               DATA_WIDTH, MAX_BURST, expected_addr, beat);
      @(negedge clk);
      fifo_free = fifo_free - 1'b1;
      expected_addr = expected_addr + 32'(BEAT_BYTES);
    end
    rvalid = 0;
    rlast = 0;
  endtask

  task automatic transfer_segment(input int segment_beats);
    int remaining;
    int burst_beats;

    remaining = segment_beats;
    while (remaining > 0) begin
      burst_beats = remaining < MAX_BURST ? remaining : MAX_BURST;
      transfer_burst(burst_beats);
      remaining = remaining - burst_beats;
    end
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst = 0;
    run = 1;
    expect_idle(6);

    // Even a full burst's worth of credit is insufficient until the line fits.
    fifo_free = (FIFO_AW + 1)'(LINE_BEATS - 1);
    expect_idle(6);

    // Reserve exactly one row without returning any credit from the consumer.
    // The line spans a page tail, a full page, and a short
    // segment. At 128 bits and MAX_BURST=256 the full page is a single request
    // with ARLEN=255 whose last byte is exactly at the end of the page.
    fifo_free = (FIFO_AW + 1)'(LINE_BEATS);
    transfer_segment(PREFIX_BEATS);
    transfer_segment(PAGE_BEATS);
    transfer_segment(TAIL_BEATS);
    expect_idle(6);
    run = 0;
    expect_idle(6);
    done = 1;
  end
endmodule
