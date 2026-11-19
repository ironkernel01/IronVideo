`timescale 1ns/1ps

module tb_ironvideo_nv12_reader;
  bit clk;
  wire [2:0] done;
  always #5ns clk = !clk;
  for (genvar i = 0; i < 3; i++) begin : widths
    ironvideo_nv12_reader_case #(.DATA_WIDTH(32 << i)) test_case (.clk(clk), .done(done[i]));
  end
  initial begin
    wait (&done);
    $display("TEST PASS: IronVideo NV12 reader widths, chroma reuse, packing and drain");
    $finish;
  end
  initial begin
    #100us;
    $fatal(1, "NV12 reader timeout, finished widths=%b", done);
  end
endmodule

module ironvideo_nv12_reader_case #(parameter int DATA_WIDTH = 32) (
  input wire clk, output bit done
);
  localparam int B = DATA_WIDTH / 8;
  localparam int ROW = 7 * B;
  localparam int HEIGHT = 4;
  localparam int MAX_BURST = 3;
  localparam int FIFO_AW = 4;
  // Both plane starts exercise a partial first page. Their padding differs.
  localparam int Y_BASE = 'h2000 - 2*B, UV_BASE = 'h6000 - B;
  localparam int Y_PITCH = ROW + 3*B, UV_PITCH = ROW + 5*B;
  localparam int FIFO_WORDS_PER_ROW = 2*ROW/B;

  bit rst = 1, run, nv12 = 1, arready, rvalid, rid, rlast;
  bit [1:0] rresp;
  logic [DATA_WIDTH-1:0] rdata;
  logic [FIFO_AW:0] fifo_free;
  wire arvalid, rready, fifo_write, fifo_sol, fifo_sof, idle, row_busy, row_start, row_done;
  wire row_extra_chroma, resp_fault, last_fault;
  wire [7:0] arlen;
  wire [2:0] arsize;
  wire [1:0] arburst;
  wire [31:0] araddr, fault_addr;
  wire [DATA_WIDTH-1:0] fifo_data;
  bit checking, forbid_write;
  int words, starts, ends, reads, writes_total;

  ironvideo_reader #(.DATA_WIDTH(DATA_WIDTH), .MAX_BURST(MAX_BURST),
                     .FIFO_AW(FIFO_AW), .SUPPORT_NV12(1)) dut (
    .clk(clk), .rst(rst), .run(run), .base(Y_BASE), .stride(Y_PITCH),
    .line_bytes(ROW), .lines(16'(HEIGHT)), .nv12(nv12), .uv_base(UV_BASE), .uv_stride(UV_PITCH),
    .fifo_free(fifo_free), .fifo_write(fifo_write), .fifo_sof(fifo_sof), .fifo_sol(fifo_sol),
    .fifo_data(fifo_data), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
    .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize), .m_axi_arburst(arburst),
    .m_axi_arid(), .m_axi_arlock(), .m_axi_arcache(), .m_axi_arprot(), .m_axi_arqos(),
    .m_axi_rvalid(rvalid), .m_axi_rready(rready), .m_axi_rdata(rdata), .m_axi_rid(rid),
    .m_axi_rlast(rlast), .m_axi_rresp(rresp), .idle(idle), .row_busy(row_busy),
    .row_start(row_start), .row_done(row_done), .row_extra_chroma(row_extra_chroma),
    .resp_fault(resp_fault), .last_fault(last_fault), .fault_addr(fault_addr)
  );

  function automatic byte unsigned y_byte(input int row, x);
    return 8'(17*row + 3*x + 21);
  endfunction
  function automatic byte unsigned uv_byte(input int row, x);
    return x%2 ? 8'(181 - 11*row - x) : 8'(43 + 29*row + x);
  endfunction

  // Respond from independent plane addresses. Any attempt to access padding
  // or reach beyond the allocated image is an immediate test failure.
  function automatic logic [DATA_WIDTH-1:0] memory_word(input int address);
    logic [DATA_WIDTH-1:0] result;
    for (int i = 0; i < B; i++) begin
      int offset, y, x;
      if (address >= UV_BASE) begin
        offset = address + i - UV_BASE;
        y = offset / UV_PITCH;
        x = offset % UV_PITCH;
        if (y >= HEIGHT/2 || x >= ROW) $fatal(1, "Invalid UV access %h", address+i);
        result[8*i +: 8] = uv_byte(y,x);
      end else begin
        offset = address + i - Y_BASE;
        y = offset / Y_PITCH;
        x = offset % Y_PITCH;
        if (offset < 0 || y >= HEIGHT || x >= ROW) $fatal(1, "Invalid Y access %h", address+i);
        result[8*i +: 8] = y_byte(y,x);
      end
    end
    return result;
  endfunction

  always @(posedge clk) begin
    if (forbid_write && (fifo_write || row_done))
      $fatal(1, "width=%0d leaked FIFO write or row completion during abort", DATA_WIDTH);
    if (fifo_write) writes_total++;
    if (checking) begin
      if (resp_fault || last_fault) $fatal(1, "Unexpected fault at %h", fault_addr);
      if (arvalid && arready) reads += int'(arlen) + 1;
      if (row_start) begin
        if (starts != ends || row_extra_chroma !== !(starts%2))
          $fatal(1, "width=%0d wrong start or chroma metadata for row %0d", DATA_WIDTH, starts);
        starts++;
      end
      if (fifo_write) begin
        int row, word_in_row;
        row = (words / FIFO_WORDS_PER_ROW) % HEIGHT;
        word_in_row = words % FIFO_WORDS_PER_ROW;
        if (!row_busy || fifo_sol !== (word_in_row == 0) ||
            fifo_sof !== (word_in_row == 0 && row == 0) ||
            row_done !== (word_in_row == FIFO_WORDS_PER_ROW-1))
          $fatal(1, "width=%0d incorrect FIFO boundary at word %0d", DATA_WIDTH, words);
        // Output oracle uses visible pixel coordinates independently of the
        // scheduler's plane order, cache index and packing implementation.
        for (int i = 0; i < B; i++) begin
          int x;
          byte unsigned expected;
          x = (word_in_row*B + i)/2;
          expected = (i%2) ? uv_byte(row/2, x) : y_byte(row, x);
          if (fifo_data[8*i +: 8] !== expected)
            $fatal(1, "width=%0d row=%0d x=%0d byte=%0d got=%h expected=%h",
                   DATA_WIDTH, row, x, i, fifo_data[8*i +: 8], expected);
        end
        words++;
      end
      if (row_done) begin
        if (!fifo_write || row_extra_chroma !== !(ends%2))
          $fatal(1, "width=%0d wrong row completion %0d", DATA_WIDTH, ends);
        ends++;
      end
    end
  end

  task automatic accept_ar(input int address, beats);
    while (!arvalid) @(negedge clk);
    repeat (2) begin
      @(posedge clk);
      if (araddr !== 32'(address) || int'(arlen)+1 != beats || idle ||
          arsize !== 3'($clog2(B)) || arburst !== 2'b01)
        $fatal(1, "width=%0d got AR %h+%0d beats, expected %h+%0d",
               DATA_WIDTH, araddr, int'(arlen)+1, address, beats);
      @(negedge clk);
    end
    arready = 1;
    @(negedge clk);
    arready = 0;
  endtask

  task automatic send_r(input int address, input bit last,
                        input logic [1:0] response = 0, input bit id = 0);
    rvalid = 1;
    rdata = memory_word(address);
    rlast = last;
    rresp = response;
    rid = id;
    do @(posedge clk); while (!rready);
    @(negedge clk);
    rvalid = 0;
    rlast = 0;
    rresp = 0;
    rid = 0;
  endtask

  task automatic serve_plane(input int base);
    int address, remaining, beats, page;
    address = base;
    remaining = ROW/B;
    while (remaining > 0) begin
      page = (4096 - address%4096)/B;
      beats = remaining < MAX_BURST ? remaining : MAX_BURST;
      if (page < beats) beats = page;
      accept_ar(address, beats);
      for (int i = 0; i < beats; i++) begin
        if ((address/B)%3 == 2) @(negedge clk);
        send_r(address, i == beats-1);
        address += B;
      end
      remaining -= beats;
    end
  endtask

  task automatic restart();
    run = 0;
    repeat (3) @(negedge clk);
    if (!idle || arvalid || rready) $fatal(1, "Reader failed to quiesce");
    forbid_write = 0;
    fifo_free = (FIFO_AW+1)'(FIFO_WORDS_PER_ROW);
    nv12 = 1;
    run = 1;
  endtask

  task automatic stop_at_half(input bit after_low);
    int before_abort;
    restart();
    serve_plane(UV_BASE);
    accept_ar(Y_BASE, 2);
    before_abort = writes_total;
    send_r(Y_BASE, 0);
    if (after_low) begin
      @(posedge clk);
      @(negedge clk);
    end
    if (writes_total != before_abort + int'(after_low) || idle)
      $fatal(1, "width=%0d stop after_low=%0b writes=%0d expected=%0d idle=%b",
             DATA_WIDTH, after_low, writes_total, before_abort + int'(after_low), idle);
    run = 0;
    nv12 = 0; // New shadow mode cannot affect the old burst's drain.
    forbid_write = 1;
    repeat (2) @(negedge clk);
    if (idle || !rready) $fatal(1, "Open Y burst reported idle");
    send_r(Y_BASE+B, 1);
  endtask

  initial begin
    repeat (4) @(negedge clk);
    rst = 0;
    restart();
    checking = 1;
    fifo_free = (FIFO_AW+1)'(FIFO_WORDS_PER_ROW-1);
    repeat (6) begin
      @(negedge clk);
      if (arvalid || row_busy) $fatal(1, "Started UV without credit for the entire packed row");
    end
    fifo_free = (FIFO_AW+1)'(FIFO_WORDS_PER_ROW);
    for (int row = 0; row < HEIGHT*2; row++) begin
      if (row%2 == 0) serve_plane(UV_BASE + ((row%HEIGHT)/2)*UV_PITCH);
      serve_plane(Y_BASE + (row%HEIGHT)*Y_PITCH);
    end
    fifo_free = 2; // The final luma beat still owns two reserved FIFO slots.
    wait (ends == HEIGHT*2);
    @(negedge clk);
    if (starts != ends || words != HEIGHT*2*FIFO_WORDS_PER_ROW || reads != HEIGHT*3*ROW/B)
      $fatal(1, "Incorrect image traffic or row samples at width=%0d", DATA_WIDTH);
    checking = 0;

    stop_at_half(0);
    stop_at_half(1);

    // Last Y RLAST is already accepted, but a two-word tail is still pending.
    restart();
    serve_plane(UV_BASE);
    serve_plane(Y_BASE);
    if (idle) $fatal(1, "Idle before delayed final FIFO words");
    run = 0;
    forbid_write = 1;
    restart();

    // A stopped, stalled UV address must remain valid. A foreign RID/RLAST
    // cannot retire it. Only the matching ID's RLAST completes the drain.
    while (!arvalid) @(negedge clk);
    run = 0;
    forbid_write = 1;
    accept_ar(UV_BASE, 1);
    send_r(UV_BASE, 1, 0, 1);
    if (!resp_fault || last_fault || fault_addr != UV_BASE || idle)
      $fatal(1, "Wrong RID response fault/address during UV drain");
    send_r(UV_BASE, 1);
    restart();

    // A real SLVERR on the second beat of a Y burst reports that Y address.
    serve_plane(UV_BASE);
    accept_ar(Y_BASE, 2);
    send_r(Y_BASE, 0);
    send_r(Y_BASE+B, 1, 2'b10);
    if (!resp_fault || last_fault || fault_addr != Y_BASE+B)
      $fatal(1, "SLVERR attributed to wrong beat");
    forbid_write = 1;
    restart();

    // Matching ID without its required RLAST must remain drainable.
    accept_ar(UV_BASE, 1);
    send_r(UV_BASE, 0);
    if (!last_fault || resp_fault || idle || fault_addr != UV_BASE)
      $fatal(1, "Missing UV RLAST failed to report the open transaction");
    run = 0;
    forbid_write = 1;
    repeat (2) @(negedge clk);
    if (idle || !rready) $fatal(1, "Premature idle on late RLAST");
    send_r(UV_BASE, 1);
    repeat (3) @(negedge clk);
    if (!idle || arvalid || rready) $fatal(1, "Late RLAST did not finish drain");
    done = 1;
  end
endmodule
