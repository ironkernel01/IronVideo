`timescale 1ns/1ps

// Runs the standalone AXI framebuffer reader at all supported beat widths.
// 11-18-2026: Initial burst limit, page boundary, and FIFO capacity regression.
// SystemVerilog-2012.
module tb_ironvideo_reader_limits;
  logic clk = 0;
  wire [10:0] done;
  ironvideo_packed_read_queue packed_reads (.done(done[10]));
  ironvideo_fifo_credits fifo_credits (.done(done[9]));

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

// Exercise real FIFO credits with independent clocks, a held read beat,
// full RAM, concurrent writes/pops, repeated pointer wrap, and credit recovery.
module ironvideo_fifo_credits(output logic done = 0);
  localparam int DEPTH = 8;
  localparam int TOTAL = 96;
  logic wr_clk = 0, rd_clk = 0, rst = 1, pop_enable = 0;
  always #3.367 wr_clk = ~wr_clk;
  initial begin
    #1;
    forever #3.599 rd_clk = ~rd_clk;
  end
  wire [3:0] capacity, count;
  wire rd_valid;
  wire [31:0] rd_data;
  int written = 0, popped = 0, write_run = 0;
  bit wrote_consecutively = 0;
  wire push = !rst && written < TOTAL && capacity != 0;
  wire pop = !rst && pop_enable && rd_valid;

  ironvideo_fifo #(.DATA_WIDTH(32), .FIFO_AW(3)) fifo (
    .wr_clk(wr_clk), .wr_rst(rst), .wr_push(push), .wr_data(32'(written)),
    .wr_free(capacity), .wr_cursor(), .rd_clk(rd_clk), .rd_rst(rst),
    .rd_pop(pop), .rd_cursor(), .rd_valid(rd_valid), .rd_data(rd_data), .rd_count(count)
  );

  always @(posedge wr_clk)
    if (push) begin
      written <= written + 1;
      write_run <= write_run + 1;
      if (write_run == DEPTH-1)
        wrote_consecutively <= 1'b1;
    end else
      write_run <= 0;

  always @(posedge rd_clk)
    if (pop) begin
      if (rd_data !== 32'(popped))
        $fatal(1, "TEST FAIL: FIFO credit overwrite, got %h expected %h", rd_data, popped);
      popped <= popped + 1;
    end

  always @(negedge wr_clk)
    if (!rst && capacity > DEPTH - (written - popped - int'(rd_valid)))
      $fatal(1, "TEST FAIL: FIFO reports more space than concurrently available");

  always @(negedge rd_clk)
    if (!rst && (count > written - popped || count < int'(rd_valid)))
      $fatal(1, "TEST FAIL: FIFO reports an invalid conservative read count");

  initial begin
    repeat (6) @(negedge wr_clk);
    rst = 0;
    wait (written == DEPTH + 1);
    repeat (8) @(negedge wr_clk);
    if (capacity !== 0 || !rd_valid || rd_data !== 0 || !wrote_consecutively)
      $fatal(1, "TEST FAIL: FIFO full boundary or back-to-back write");
    pop_enable = 1;
    wait (popped == TOTAL);
    repeat (12) @(negedge wr_clk);
    if (capacity !== DEPTH || count !== 0 || rd_valid || written != TOTAL)
      $fatal(1, "TEST FAIL: FIFO did not recover capacity after drain");
    done = 1;
  end
endmodule

// Drive four in-order ID-zero HP0 bursts before presenting any response.
module ironvideo_packed_read_queue(output logic done = 0);
  localparam logic [31:0] BASE = 32'h0ff0, STRIDE = 32'h210;
  logic clk = 0, reset = 1, run = 0;
  always #3.367 clk = ~clk;
  logic [11:0] capacity = 63;
  logic [31:0] active_row_bytes = 512;
  logic arready = 0, rvalid = 0, rlast = 0, rid = 0;
  logic [1:0] rresp = 0;
  wire arvalid, rready, fifo_write, sol, sof, idle, row_start, row_done;
  wire resp_fault, last_fault;
  wire [31:0] araddr, fault_addr;
  wire [7:0] arlen;

  ironvideo_reader #(.DATA_WIDTH(64), .FIFO_AW(11), .MAX_BURST(16), .PACKED_READS(4)) reader (
    .clk(clk), .rst(reset), .run(run), .base(BASE), .stride(STRIDE),
    .line_bytes(active_row_bytes), .lines(16'd2), .fifo_free(capacity),
    .fifo_write(fifo_write), .fifo_data(), .fifo_sof(sof), .fifo_sol(sol),
    .m_axi_arid(), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
    .m_axi_arsize(), .m_axi_arburst(), .m_axi_arlock(), .m_axi_arcache(),
    .m_axi_arprot(), .m_axi_arqos(), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
    .m_axi_rid(rid), .m_axi_rdata(64'd0), .m_axi_rresp(rresp), .m_axi_rlast(rlast),
    .m_axi_rvalid(rvalid), .m_axi_rready(rready), .idle(idle), .row_busy(),
    .row_start(row_start), .row_done(row_done), .resp_fault(resp_fault),
    .last_fault(last_fault), .fault_addr(fault_addr),
    .nv12(1'b0), .uv_base(32'd0), .uv_stride(32'd0), .row_extra_chroma()
  );

  int starts = 0, completions = 0;
  always @(posedge clk) begin
    if (row_start) starts <= starts + 1;
    if (row_done) completions <= completions + 1;
  end

  task automatic take_ar(input logic [31:0] address, input int beats);
    @(negedge clk);
    while (!arvalid) @(negedge clk);
    if (araddr !== address || arlen !== 8'(beats-1))
      $fatal(1, "TEST FAIL: queued AR %h/%d expected %h/%d", araddr, arlen + 1, address, beats);
    arready = 1;
    @(posedge clk);
    @(negedge clk);
    arready = 0;
  endtask

  task automatic send_r(input bit last, write_expected,
                        input bit start_line = 0, start_frame = 0, end_row = 0,
                        input bit response_id = 0, input logic [1:0] status = 0);
    @(negedge clk);
    rvalid = 1;
    rlast = last;
    rresp = status;
    rid = response_id;
    @(posedge clk);
    if (!rready || {fifo_write,sol,sof,row_done} !== {write_expected,start_line,start_frame,end_row})
      $fatal(1, "TEST FAIL: queued R ready/write/SOL/SOF/end %b%b%b%b%b", rready,fifo_write,sol,sof,row_done);
  endtask

  task automatic send_burst(input int beats, input bit write_expected,
                            input bit start_line = 0, start_frame = 0, end_row = 0);
    for (int beat = 0; beat < beats; beat++)
      send_r(beat == beats-1, write_expected, start_line && beat == 0,
             start_frame && beat == 0, end_row && beat == beats-1);
  endtask

  task automatic finish_r;
    @(negedge clk);
    rvalid = 0;
  endtask

  task automatic restart;
    @(negedge clk);
    run = 0;
    repeat (4) @(negedge clk);
    if (!idle || arvalid || rready)
      $fatal(1, "TEST FAIL: queued reader did not drain");
    run = 1;
  endtask

  // Model 32 AXI clocks of command-to-data latency per burst, with a
  // full-rate return channel. A single outstanding 16-beat reader would
  // miss the 2,200-clock line budget even before refresh or other clients.
  task automatic time_1080_row;
    int posted = 0, retired = 0, in_burst = 0, returned = 0;
    int command_ready [0:63], command_beats [0:63];
    int the_cycle = 0;
    logic [31:0] address = BASE;
    active_row_bytes = 7680;
    capacity = 960;
    restart();
    while (returned < 960 && the_cycle < 2200) begin
      @(negedge clk);
      arready = 1;
      rvalid = posted > retired && the_cycle >= command_ready[retired];
      rlast = rvalid && in_burst == command_beats[retired]-1;
      @(posedge clk);
      if (arvalid) begin
        int limit;
        limit = (4096 - int'(address[11:0])) / 8;
        if (limit > 16) limit = 16;
        if (limit > (BASE+7680-address)/8) limit = (BASE+7680-address)/8;
        if (araddr !== address || arlen !== 8'(limit-1))
          $fatal(1, "TEST FAIL: 1080p queued burst %d breaks line or page bounds", posted);
        command_ready[posted] = the_cycle + 32;
        command_beats[posted] = limit;
        posted++;
        address += 32'(limit*8);
      end
      if (rvalid) begin
        if (!rready || !fifo_write || row_done !== (returned == 959))
          $fatal(1, "TEST FAIL: 1080p queued return stalled or cut the row");
        returned++;
        if (rlast) begin
          in_burst = 0;
          retired++;
        end else
          in_burst++;
      end
      the_cycle++;
    end
    @(negedge clk);
    run = 0;
    arready = 0;
    rvalid = 0;
    if (returned != 960 || posted != 61 || retired != 61 || the_cycle > 1320)
      $fatal(1, "TEST FAIL: 1080p queued row took %d clocks with %d/%d bursts and %d beats",
             the_cycle, posted, retired, returned);
    $display("IronVideo queued XRGB8888 row: %d beats in %d AXI clocks", returned, the_cycle);
  endtask

  initial begin
    repeat (4) @(negedge clk);
    reset = 0;
    run = 1;
    repeat (10) begin
      @(negedge clk);
      if (arvalid || row_start)
        $fatal(1, "TEST FAIL: queued read without whole-row credit");
    end
    capacity = 64;
    take_ar(BASE, 2);
    take_ar(32'h1000, 16);
    take_ar(32'h1080, 16);
    take_ar(32'h1100, 16);
    repeat (6) begin
      @(negedge clk);
      if (arvalid || !rready || idle)
        $fatal(1, "TEST FAIL: queue allowed fifth read or lost outstanding requests");
    end
    send_burst(2, 1, 1, 1);
    finish_r();
    take_ar(32'h1180, 14);

    // Return four consecutive bursts without gaps on the R channel.
    repeat (3) send_burst(16, 1);
    send_burst(14, 1, 0, 0, 1);
    finish_r();
    take_ar(BASE+STRIDE, 16);
    take_ar(BASE+STRIDE+128, 16);
    take_ar(BASE+STRIDE+256, 16);
    take_ar(BASE+STRIDE+384, 16);
    send_burst(16, 1, 1);
    repeat (2) send_burst(16, 1);
    send_burst(16, 1, 0, 0, 1);
    finish_r();
    take_ar(BASE, 2);

    // A stalled, presented AR remains stable under stop, then must drain
    // along with the older read. A foreign RLAST cannot retire either.
    while (!arvalid) @(negedge clk);
    run = 0;
    repeat (4) begin
      @(negedge clk);
      if (!arvalid || araddr !== 32'h1000 || arlen !== 15 || idle)
        $fatal(1, "TEST FAIL: stopped queued reader withdrew an AR");
    end
    take_ar(32'h1000, 16);
    send_r(1, 0, 0, 0, 0, 1);
    finish_r();
    if (!resp_fault || last_fault || fault_addr != BASE || idle)
      $fatal(1, "TEST FAIL: foreign RLAST changed queue position");
    send_burst(2, 0);
    send_burst(16, 0);
    finish_r();
    restart();

    // Early RLAST retires only its own descriptor. An already-offered
    // third AR can still be accepted, but no other address may be offered.
    take_ar(BASE, 2);
    take_ar(32'h1000, 16);
    while (!arvalid) @(negedge clk);
    send_r(1, 0);
    finish_r();
    if (!last_fault || resp_fault || fault_addr != BASE || idle)
      $fatal(1, "TEST FAIL: early queued RLAST lost the following read");
    take_ar(32'h1080, 16);
    send_burst(16, 0);
    send_burst(16, 0);
    finish_r();
    repeat (4) @(negedge clk);
    if (!idle || arvalid || rready)
      $fatal(1, "TEST FAIL: early RLAST drain issued new work");
    restart();

    // Accepting a late RLAST drains the original head even when its
    // expected beat count has expired. The second read remains queued.
    take_ar(BASE, 2);
    take_ar(32'h1000, 16);
    run = 0;
    send_r(0, 0);
    send_r(0, 0);
    finish_r();
    if (!last_fault || resp_fault || fault_addr !== BASE + 8 || idle)
      $fatal(1, "TEST FAIL: missing queued RLAST did not hold the head");
    send_r(1, 0);
    send_r(0, 0, 0, 0, 0, 0, 2'b10);
    finish_r();
    if (!resp_fault || fault_addr !== 32'h1000 || idle)
      $fatal(1, "TEST FAIL: queued response error used the wrong burst address");
    for (int index = 1; index < 16; index++) send_r(index == 15, 0);
    finish_r();
    if (!idle || starts != 5 || completions != 2)
      $fatal(1, "TEST FAIL: queued completions after drain starts=%d completions=%d idle=%b",
             starts, completions, idle);
    time_1080_row();
    done = 1;
  end
endmodule
