`timescale 1ns/1ps

// Runs three independent scanout and AXI slave models with unrelated clock periods.
module tb_ironvideo;
  wire [2:0] done;

  ironvideo_case #(.DATA_WIDTH(32)) width32 (.done(done[0]));
  ironvideo_case #(.DATA_WIDTH(64)) width64 (.done(done[1]));
  ironvideo_case #(.DATA_WIDTH(128)) width128 (.done(done[2]));

  initial begin
    wait (&done);
    $display("TEST PASS: IronVideo 32/64/128-bit regression");
    $finish;
  end

  initial begin
    #8ms;
    $fatal(1, "TEST FAIL: regression watchdog, done=%b", done);
  end
endmodule

module ironvideo_case #(
  parameter int DATA_WIDTH = 64
) (
  // Regression result for this AXI read width.
  output logic done = 0
);
  localparam int BEAT_BYTES = DATA_WIDTH / 8;
  localparam int MAX_BURST = 4;
  localparam int FIFO_AW = $clog2(16 * 1024 / BEAT_BYTES);
  localparam int HA = 32;
  localparam int HF = 7;
  localparam int HS = 5;
  localparam int HB = 20;
  localparam int VA = 3;
  localparam int VF = 2;
  localparam int VS = 2;
  localparam int VB = 11;
  localparam int HT = HA + HF + HS + HB;
  localparam int VT = VA + VF + VS + VB;
  localparam int STRIDE = 160;
  localparam logic [31:0] BASE0 = 32'h00000ff0;
  localparam logic [31:0] BASE1 = 32'h00002000;
  localparam logic [31:0] WINDOW_BYTES = 32'h00004000;
  localparam logic [7:0] REG_ID = 8'h00;
  localparam logic [7:0] REG_VERSION = 8'h04;
  localparam logic [7:0] REG_CAPS = 8'h08;
  localparam logic [7:0] REG_CONTROL = 8'h0c;
  localparam logic [7:0] REG_STATUS = 8'h10;
  localparam logic [7:0] REG_FAULT = 8'h14;
  localparam logic [7:0] REG_MASK = 8'h18;
  localparam logic [7:0] REG_FIRST_FAULT = 8'h1c;
  localparam logic [7:0] REG_BASE = 8'h20;
  localparam logic [7:0] REG_STRIDE = 8'h24;
  localparam logic [7:0] REG_WINDOW = 8'h28;
  localparam logic [7:0] REG_WINDOW_BYTES = 8'h2c;
  localparam logic [7:0] REG_HACTIVE = 8'h30;
  localparam logic [7:0] REG_HFRONT = 8'h34;
  localparam logic [7:0] REG_POLARITY = 8'h50;
  localparam logic [7:0] REG_PREFILL = 8'h54;
  localparam logic [7:0] REG_UNDERFLOWS = 8'h58;
  localparam logic [7:0] REG_FRAMES = 8'h64;
  localparam logic [7:0] REG_FAULT_ADDRESS = 8'h6c;
  localparam logic [31:0] ENABLE = 1;
  localparam logic [31:0] PATTERN = 2;
  localparam logic [31:0] COMMIT = 4;
  localparam logic [31:0] SNAPSHOT = 8;
  localparam logic [31:0] BAD_CONFIG = 1;
  localparam logic [31:0] BAD_RESPONSE = 2;
  localparam logic [31:0] BAD_LAST = 4;
  localparam logic [31:0] UNDERFLOW = 8;
  localparam logic [31:0] IDLE_CONFIGURED = 9;
  localparam logic [31:0] RUNNING = 5;
  typedef enum {
    FAULT_NONE, FAULT_RESP, FAULT_LATE_LAST, FAULT_ID, FAULT_EARLY_LAST
  } injection_t;

  logic axi_clk = 0;
  logic pixel_clk = 0;
  logic serial_clk = 0;
  logic reset_n = 0;
  always #5 axi_clk = ~axi_clk;
  always #(19 + DATA_WIDTH / 32) pixel_clk = ~pixel_clk;
  always #((19.0 + DATA_WIDTH / 32) / 5) serial_clk = ~serial_clk;

  logic [15:0] awaddr = 0;
  logic awvalid = 0;
  wire awready;
  logic [31:0] wdata = 0;
  logic [3:0] wstrb = 0;
  logic wvalid = 0;
  wire wready;
  wire [1:0] bresp;
  wire bvalid;
  logic bready = 0;
  logic [15:0] araddr = 0;
  logic arvalid = 0;
  wire arready;
  wire [31:0] rdata;
  wire [1:0] rresp;
  wire rvalid;
  logic rready = 0;

  wire [31:0] mem_araddr;
  wire [7:0] mem_arlen;
  wire [2:0] mem_arsize;
  wire [1:0] mem_arburst;
  wire mem_arlock;
  wire [3:0] mem_arcache;
  wire [2:0] mem_arprot;
  wire [3:0] mem_arqos;
  wire mem_arid;
  wire mem_arvalid;
  wire mem_arready;
  logic [DATA_WIDTH-1:0] mem_rdata = 0;
  logic [1:0] mem_rresp = 0;
  logic mem_rid = 0;
  logic mem_rlast = 0;
  logic mem_rvalid = 0;
  wire mem_rready;

  wire [23:0] rgb;
  wire de;
  wire hs;
  wire vs;
  wire irq;

  ironvideo_top #(.DATA_WIDTH(DATA_WIDTH), .MAX_BURST(MAX_BURST)) dut (
    .axi_clk(axi_clk), .pixel_clk(pixel_clk), .serial_clk(serial_clk), .reset_n(reset_n),
    .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arprot(3'b000), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .m_axi_araddr(mem_araddr), .m_axi_arlen(mem_arlen), .m_axi_arsize(mem_arsize),
    .m_axi_arburst(mem_arburst), .m_axi_arlock(mem_arlock), .m_axi_arcache(mem_arcache),
    .m_axi_arprot(mem_arprot), .m_axi_arqos(mem_arqos), .m_axi_arid(mem_arid),
    .m_axi_arvalid(mem_arvalid), .m_axi_arready(mem_arready),
    .m_axi_rdata(mem_rdata), .m_axi_rresp(mem_rresp), .m_axi_rid(mem_rid),
    .m_axi_rlast(mem_rlast), .m_axi_rvalid(mem_rvalid), .m_axi_rready(mem_rready),
    .tmds_data_p(), .tmds_data_n(), .tmds_clk_p(), .tmds_clk_n(), .irq(irq)
  );
  assign {rgb, de, hs, vs} = {dut.video.rgb, dut.video.de, dut.video.hs, dut.video.vs};

  task automatic write_aw(input logic [15:0] address, input int delay_cycles);
    repeat (delay_cycles + 1) @(negedge axi_clk);
    awaddr = address;
    awvalid = 1;
    do @(posedge axi_clk); while (!awready);
    @(negedge axi_clk);
    awvalid = 0;
  endtask

  task automatic write_w(input logic [31:0] value, input logic [3:0] strobes, input int delay_cycles);
    repeat (delay_cycles + 1) @(negedge axi_clk);
    wdata = value;
    wstrb = strobes;
    wvalid = 1;
    do @(posedge axi_clk); while (!wready);
    @(negedge axi_clk);
    wvalid = 0;
  endtask

  task automatic write_reg(
    input logic [15:0] address,
    input logic [31:0] value,
    input int skew = 0,
    input logic [3:0] strobes = 4'hf,
    input logic [1:0] response = 0,
    input int response_hold = 3
  );
    fork
      write_aw(address, skew < 0 ? -skew : 0);
      write_w(value, strobes, skew > 0 ? skew : 0);
    join
    while (!bvalid) @(negedge axi_clk);
    if (bresp !== response)
      $fatal(1, "TEST FAIL: width %0d AXI Lite write %h returned %b, expected %b",
             DATA_WIDTH, address, bresp, response);
    repeat (response_hold) begin
      @(negedge axi_clk);
      if (bvalid !== 1 || bresp !== response)
        $fatal(1, "TEST FAIL: width %0d AXI Lite write %h lost held response", DATA_WIDTH, address);
    end
    bready = 1;
    @(negedge axi_clk);
    bready = 0;
  endtask

  task automatic write_shadow_immediate(input logic [7:0] address, input logic [31:0] value);
    write_reg(address, value, 0, 4'hf, 0, 0);
  endtask

  task automatic read_reg(
    input logic [15:0] address,
    output logic [31:0] value,
    input logic [1:0] response = 0
  );
    @(negedge axi_clk);
    araddr = address;
    arvalid = 1;
    do @(posedge axi_clk); while (!arready);
    @(negedge axi_clk);
    arvalid = 0;
    while (!rvalid) @(negedge axi_clk);
    value = rdata;
    repeat (3) begin
      if (rvalid !== 1 || rresp !== response || rdata !== value)
        $fatal(1, "TEST FAIL: width %0d AXI Lite read %h held response %b data %h", DATA_WIDTH, address, rresp, rdata);
      @(negedge axi_clk);
    end
    rready = 1;
    @(negedge axi_clk);
    rready = 0;
  endtask

  task automatic expect_reg(
    input logic [7:0] address,
    input logic [31:0] mask,
    input logic [31:0] expected
  );
    logic [31:0] value;
    read_reg(address, value);
    if ((value & mask) !== expected)
      $fatal(1, "TEST FAIL: width %0d register %h got %h expected %h masked by %h",
             DATA_WIDTH, address, value, expected, mask);
  endtask

  task automatic wait_reg(
    input logic [7:0] address,
    input logic [31:0] mask,
    input logic [31:0] expected
  );
    logic [31:0] value;
    for (int attempt = 0; attempt < 60000; attempt++) begin
      read_reg(address, value);
      if ((value & mask) === expected) return;
    end
    $fatal(1, "TEST FAIL: width %0d timed out reading %h got %h expected %h mask %h",
           DATA_WIDTH, address, value, expected, mask);
  endtask

  task automatic wait_running;
    wait_reg(REG_STATUS, 7, RUNNING);
  endtask

  function automatic logic [23:0] memory_pixel(input logic [31:0] address);
    return {8'(address >> 12) ^ 8'h67, 8'(address >> 6) ^ 8'h42, 8'(address >> 2) ^ 8'h35};
  endfunction

  function automatic logic [DATA_WIDTH-1:0] memory_beat(input logic [31:0] address);
    for (int lane = 0; lane < DATA_WIDTH / 32; lane++) begin
      memory_beat[lane*32 +: 32] = {8'hfa, memory_pixel(address + lane * 4)};
    end
  endfunction

  int cycle = 0;
  int requests = 0;
  int complete_read_frames = 0;
  int page_splits = 0;
  int held_ar_cycles = 0;
  int response_wait_cycles = 0;
  int remaining = 0;
  int transferred = 0;
  injection_t inject_fault = FAULT_NONE;
  injection_t active_injection = FAULT_NONE;
  logic hold_ar = 0;
  logic hold_r = 0;
  logic hold_late_last = 0;
  logic check_sequence = 0;
  logic stalled_ar = 0;
  logic [60:0] saved_ar;
  logic [31:0] next_address = BASE0;
  logic [31:0] pending_address;
  logic [31:0] sequence_base = BASE0;
  wire [60:0] ar_payload = {mem_araddr, mem_arlen, mem_arsize, mem_arburst, mem_arlock,
                            mem_arcache, mem_arprot, mem_arqos, mem_arid, 3'b000};
  wire [31:0] request_base = mem_araddr >= BASE1 ? BASE1 : BASE0;
  wire [31:0] line_number = (mem_araddr - request_base) / STRIDE;
  wire [31:0] line_end = request_base + line_number * STRIDE + HA * 4;
  wire [31:0] end_address = mem_araddr + (32'(mem_arlen) + 1) * BEAT_BYTES;
  assign mem_arready = reset_n && !hold_ar && remaining == 0 && !mem_rvalid && cycle % 7 >= 3;

  // The slave accepts one burst at a time and checks every request before returning data.
  always @(posedge axi_clk) begin
    if (!reset_n) begin
      cycle <= 0;
      remaining <= 0;
      mem_rvalid <= 0;
      stalled_ar <= 0;
      next_address <= BASE0;
      sequence_base <= BASE0;
    end else begin
      cycle <= cycle + 1;
      if (stalled_ar && (!mem_arvalid || ar_payload !== saved_ar))
        $fatal(1, "TEST FAIL: width %0d AR changed under backpressure", DATA_WIDTH);
      stalled_ar <= mem_arvalid && !mem_arready;
      if (mem_arvalid && !mem_arready) begin
        saved_ar <= ar_payload;
        held_ar_cycles <= held_ar_cycles + 1;
      end

      if (mem_arvalid && mem_arready) begin
        if (mem_arsize !== 3'($clog2(BEAT_BYTES)) || mem_arburst !== 2'b01 || mem_arlock !== 0 ||
            mem_arcache !== 4'b0011 || mem_arprot !== 0 || mem_arqos !== 4'hf || mem_arid !== 0 ||
            mem_arlen >= MAX_BURST || mem_araddr % BEAT_BYTES != 0)
          $fatal(1, "TEST FAIL: width %0d invalid AR attributes at %h", DATA_WIDTH, mem_araddr);
        if (mem_araddr < request_base || line_number >= VA || end_address > line_end ||
            (mem_araddr >> 12) != ((end_address - 1) >> 12))
          $fatal(1, "TEST FAIL: width %0d burst crosses page, line or framebuffer at %h through %h",
                 DATA_WIDTH, mem_araddr, end_address - 1);
        if (mem_araddr !== next_address && (check_sequence || mem_araddr !== request_base))
          $fatal(1, "TEST FAIL: width %0d request address %h expected %h", DATA_WIDTH, mem_araddr, next_address);
        if (sequence_base != request_base && mem_araddr != request_base)
          $fatal(1, "TEST FAIL: width %0d new framebuffer started at %h", DATA_WIDTH, mem_araddr);

        requests <= requests + 1;
        if (end_address == 32'h1000) page_splits <= page_splits + 1;
        sequence_base <= request_base;
        if (end_address != line_end) begin
          next_address <= end_address;
        end else if (line_number != VA - 1) begin
          next_address <= request_base + (line_number + 1) * STRIDE;
        end else begin
          next_address <= request_base;
          complete_read_frames <= complete_read_frames + 1;
        end
        pending_address <= mem_araddr;
        active_injection <= inject_fault;
        if (inject_fault == FAULT_EARLY_LAST)
          remaining <= 1;
        else
          remaining <= 32'(mem_arlen) + ((inject_fault == FAULT_LATE_LAST || inject_fault == FAULT_ID) ? 2 : 1);
        transferred <= 0;
      end

      if (mem_rvalid && mem_rready) begin
        mem_rvalid <= 0;
        if (!mem_rid)
          pending_address <= pending_address + BEAT_BYTES;
        remaining <= remaining - 1;
        transferred <= transferred + 1;
      end else if (!mem_rvalid && remaining != 0) begin
        if (!hold_r && !(hold_late_last && active_injection == FAULT_LATE_LAST && remaining == 1) && cycle % 5 != 0) begin
          mem_rvalid <= 1;
          mem_rdata <= memory_beat(pending_address);
          mem_rresp <= active_injection == FAULT_RESP && transferred == 0 ? 2'b10 : 2'b00;
          mem_rid <= active_injection == FAULT_ID && transferred == 0;
          mem_rlast <= remaining == 1;
        end else begin
          response_wait_cycles <= response_wait_cycles + 1;
        end
      end
    end
  end

  task automatic configure_frame;
    int timing [8];
    timing = '{HA, HF, HS, HB, VA, VF, VS, VB};
    write_reg(REG_BASE, BASE0);
    write_reg(REG_STRIDE, STRIDE);
    write_reg(REG_WINDOW_BYTES, WINDOW_BYTES);
    for (int word_index = 0; word_index < 8; word_index++)
      write_reg(REG_HACTIVE + 8'(word_index * 4), timing[word_index]);
    write_reg(REG_POLARITY, 1);
    write_reg(REG_PREFILL, 4);
  endtask

  task automatic check_frame(input logic [31:0] base, input bit pattern = 0);
    logic active;
    logic hsync;
    logic vsync;
    logic [23:0] expected_rgb;

    // Falling VS marks x=0 and y=VA+VF for this negative-polarity mode.
    @(negedge vs);
    repeat ((VT - VA - VF) * HT) @(negedge pixel_clk);
    @(negedge pixel_clk);
    check_sequence = 1;
    for (int y = 0; y < VT; y++) begin
      for (int x = 0; x < HT; x++) begin
        active = x < HA && y < VA;
        hsync = x >= HA + HF && x < HA + HF + HS;
        vsync = !(y >= VA + VF && y < VA + VF + VS);
        expected_rgb = 0;
        if (active)
          expected_rgb = pattern ? {8'(x), 8'(y), 8'(x ^ y)} : memory_pixel(base + y * STRIDE + x * 4);
        if ({de, hs, vs, rgb} !== {active, hsync, vsync, expected_rgb})
          $fatal(1, "TEST FAIL: width %0d raster (%0d,%0d) got %b%b%b %h expected %b%b%b %h",
                 DATA_WIDTH, x, y, de, hs, vs, rgb, active, hsync, vsync, expected_rgb);
        @(negedge pixel_clk);
      end
    end
    check_sequence = 0;
  endtask

  task automatic stop_reader;
    int request_count;
    write_reg(REG_CONTROL, 0);
    wait_reg(REG_STATUS, 15, IDLE_CONFIGURED);
    request_count = requests;
    repeat (25) @(negedge axi_clk);
    if (requests != request_count || mem_arvalid || mem_rvalid || de)
      $fatal(1, "TEST FAIL: width %0d activity after stop acknowledgement", DATA_WIDTH);
  endtask

  task automatic exercise_fault(input injection_t injection, input logic [31:0] fault);
    logic [31:0] expected_address;
    int request_count;

    hold_r = 1;
    hold_late_last = injection == FAULT_LATE_LAST;
    inject_fault = injection;
    write_reg(REG_CONTROL, ENABLE);
    wait (remaining > 0);
    @(negedge axi_clk);
    expected_address = pending_address;
    if (injection == FAULT_LATE_LAST)
      expected_address += (remaining - 2) * BEAT_BYTES;
    if (injection == FAULT_EARLY_LAST && mem_arlen == 0)
      $fatal(1, "TEST FAIL: width %0d early RLAST test did not start a multibeat read", DATA_WIDTH);
    request_count = requests;
    inject_fault = FAULT_NONE;
    hold_r = 0;
    wait_reg(REG_FAULT, fault, fault);
    if (!irq) $fatal(1, "TEST FAIL: width %0d no IRQ for fault %h", DATA_WIDTH, fault);
    expect_reg(REG_FIRST_FAULT, 15, fault);
    expect_reg(REG_FAULT_ADDRESS, '1, expected_address);
    if (hold_late_last) begin
      write_reg(REG_CONTROL, 0);
      expect_reg(REG_STATUS, 10, 2);
      if (!mem_rready || requests != request_count)
        $fatal(1, "TEST FAIL: width %0d stopped draining before late RLAST", DATA_WIDTH);
      hold_late_last = 0;
      wait_reg(REG_STATUS, 15, IDLE_CONFIGURED);
    end else begin
      stop_reader();
    end
    if (requests != request_count)
      $fatal(1, "TEST FAIL: width %0d issued another read after reporting fault %h", DATA_WIDTH, fault);
    write_reg(REG_FAULT, fault);
    expect_reg(REG_FAULT, fault, 0);
    if (irq) $fatal(1, "TEST FAIL: width %0d IRQ stayed set after W1C", DATA_WIDTH);
  endtask

  task automatic stop_stalled_read;
    int request_count;
    hold_ar = 1;
    wait (mem_arvalid);
    write_reg(REG_CONTROL, 0);
    expect_reg(REG_STATUS, 10, 2);
    write_reg(REG_CONTROL, ENABLE | COMMIT, 0, 4'hf, 2'b10);
    hold_r = 1;
    hold_ar = 0;
    wait (remaining > 0);
    expect_reg(REG_STATUS, 10, 2);
    if (!mem_rready)
      $fatal(1, "TEST FAIL: width %0d stopped before accepting an outstanding read", DATA_WIDTH);
    request_count = requests;
    hold_r = 0;
    wait_reg(REG_STATUS, 15, IDLE_CONFIGURED);
    if (requests != request_count || mem_arvalid || mem_rvalid || de)
      $fatal(1, "TEST FAIL: width %0d activity after outstanding read drained", DATA_WIDTH);
    write_reg(REG_FAULT, BAD_CONFIG);
  endtask

  task automatic reset_busy_bus(input bit stalled_address);
    // Accept a Lite write and read, but hold both responses under backpressure.
    fork
      write_aw(REG_MASK, 0);
      write_w(32'b0, 4'hf, 0);
      begin
        @(negedge axi_clk);
        araddr = REG_ID;
        arvalid = 1;
        do @(posedge axi_clk); while (!arready);
        @(negedge axi_clk);
        arvalid = 0;
      end
    join
    wait (bvalid && rvalid);
    @(negedge axi_clk);
    if (bready !== 0 || rready !== 0 || bvalid !== 1 || rvalid !== 1 ||
        mem_arvalid !== stalled_address || mem_rready !== !stalled_address)
      $fatal(1, "TEST FAIL: width %0d did not establish AXI reset preconditions", DATA_WIDTH);
    #1;
    reset_n = 0;
    #1;
    // The next rising edge is still three ns away.
    if ({mem_arvalid, mem_rready, bvalid, rvalid, awready, wready, arready} !== 7'b0)
      $fatal(1, "TEST FAIL: width %0d AXI outputs did not drop before the reset clock edge", DATA_WIDTH);
    repeat (12) @(negedge axi_clk);
    if (de || mem_arvalid || mem_rvalid || irq)
      $fatal(1, "TEST FAIL: width %0d outputs active during reset", DATA_WIDTH);
    reset_n = 1;
    hold_ar = 0;
    hold_r = 0;
  endtask

  initial begin : regression
    logic [31:0] value;
    int stopped_requests;
    int black_pixels;
    time frame_origin;
    localparam time FRAME_TIME = HT * VT * 2 * (19 + DATA_WIDTH / 32);

    repeat (10) @(negedge axi_clk);
    reset_n = 1;
    expect_reg(REG_ID, '1, 32'h49525644);
    expect_reg(REG_VERSION, '1, 32'h00010001);
    expect_reg(REG_CAPS, 32'h01ffffff, DATA_WIDTH | (FIFO_AW << 8) | (MAX_BURST << 16));
    expect_reg(8'h70, '1, 16 * 1024);
    expect_reg(REG_STATUS, 7, 0);
    read_reg(8'h21, value, 2'b10);
    write_reg(8'hfc, 0, 0, 4'hf, 2'b10);
    read_reg(16'h0100, value, 2'b10);
    write_reg(16'h0120, '1, 0, 4'hf, 2'b10);
    expect_reg(REG_BASE, '1, 0);
    write_reg(REG_MASK, '1, 5, 4'b0001);
    write_reg(REG_MASK, 32'h00000000, -5, 4'b1110);
    expect_reg(REG_MASK, 15, 15);

    configure_frame();
    write_shadow_immediate(REG_BASE, BASE0 + 1);
    write_reg(REG_CONTROL, COMMIT | ENABLE, 0, 4'hf, 2'b10);
    wait_reg(REG_FAULT, BAD_CONFIG, BAD_CONFIG);
    expect_reg(REG_FIRST_FAULT, 15, BAD_CONFIG);
    if (!irq || requests != 0) $fatal(1, "TEST FAIL: width %0d invalid commit accessed DDR or missed IRQ", DATA_WIDTH);
    write_reg(REG_FAULT, BAD_CONFIG);
    write_reg(REG_BASE, BASE0);
    write_shadow_immediate(REG_STRIDE, 64);
    write_reg(REG_CONTROL, COMMIT | ENABLE, 0, 4'hf, 2'b10);
    expect_reg(REG_FAULT, BAD_CONFIG, BAD_CONFIG);
    write_reg(REG_FAULT, BAD_CONFIG);
    write_reg(REG_STRIDE, STRIDE);
    write_shadow_immediate(REG_WINDOW_BYTES, BASE0 + HA * 4);
    write_reg(REG_CONTROL, COMMIT | ENABLE, 0, 4'hf, 2'b10);
    expect_reg(REG_FAULT, BAD_CONFIG, BAD_CONFIG);
    write_reg(REG_FAULT, BAD_CONFIG);
    write_shadow_immediate(REG_WINDOW_BYTES, WINDOW_BYTES);
    write_shadow_immediate(REG_STRIDE, 32'hfffffff0);
    write_reg(REG_CONTROL, COMMIT, 0, 4'hf, 2'b10);
    expect_reg(REG_FAULT, BAD_CONFIG, BAD_CONFIG);
    write_reg(REG_FAULT, BAD_CONFIG);

    // An invalid framebuffer cannot block a valid pattern, but the same
    // tightly spaced writes must still invalidate overflowing pattern timing.
    write_shadow_immediate(REG_HFRONT, 32'hffff);
    write_reg(REG_CONTROL, COMMIT | PATTERN, 0, 4'hf, 2'b10);
    expect_reg(REG_FAULT, BAD_CONFIG, BAD_CONFIG);
    write_reg(REG_FAULT, BAD_CONFIG);
    write_shadow_immediate(REG_HFRONT, HF);
    write_reg(REG_CONTROL, COMMIT | PATTERN);
    wait_reg(REG_STATUS, 3, 1);
    expect_reg(REG_CONTROL, PATTERN, PATTERN);
    expect_reg(REG_FAULT, BAD_CONFIG, 0);

    // The exact 2^32 exclusive address is valid. Increasing the window
    // by one byte overflows it and must reject the next commit.
    write_shadow_immediate(REG_STRIDE, STRIDE);
    write_shadow_immediate(REG_BASE, 32'hfffffe40);
    write_shadow_immediate(REG_WINDOW, 32'hfffffe40);
    write_shadow_immediate(REG_WINDOW_BYTES, (VA - 1) * STRIDE + HA * 4);
    write_reg(REG_CONTROL, COMMIT);
    wait_reg(REG_STATUS, 3, 1);
    write_shadow_immediate(REG_WINDOW_BYTES, (VA - 1) * STRIDE + HA * 4 + 1);
    write_reg(REG_CONTROL, COMMIT, 0, 4'hf, 2'b10);
    expect_reg(REG_FAULT, BAD_CONFIG, BAD_CONFIG);
    write_reg(REG_FAULT, BAD_CONFIG);
    write_shadow_immediate(REG_BASE, BASE0);
    write_shadow_immediate(REG_WINDOW, 0);
    write_shadow_immediate(REG_WINDOW_BYTES, WINDOW_BYTES);
    write_reg(REG_CONTROL, COMMIT | ENABLE);
    wait_running();
    check_frame(BASE0);
    expect_reg(REG_FAULT, 15, 0);
    write_reg(REG_CONTROL, SNAPSHOT | ENABLE);
    wait_reg(REG_STATUS, 16, 0);
    read_reg(REG_FRAMES, value);
    if (value == 0) $fatal(1, "TEST FAIL: width %0d snapshot frame counter is zero", DATA_WIDTH);

    write_reg(REG_BASE, BASE1);
    check_frame(BASE0);
    frame_origin = $time;
    write_reg(REG_CONTROL, COMMIT | ENABLE);
    expect_reg(REG_STATUS, 2, 2);
    wait_running();
    if ($time < frame_origin + FRAME_TIME ||
        ($time - frame_origin) % FRAME_TIME >= 2us)
      $fatal(1, "TEST FAIL: width %0d live commit did not complete at the frame boundary", DATA_WIDTH);
    check_frame(BASE1);
    expect_reg(REG_FAULT, 15, 0);
    stop_stalled_read();
    exercise_fault(FAULT_RESP, BAD_RESPONSE);
    exercise_fault(FAULT_LATE_LAST, BAD_LAST);
    exercise_fault(FAULT_ID, BAD_RESPONSE);
    exercise_fault(FAULT_EARLY_LAST, BAD_LAST);

    write_reg(REG_CONTROL, ENABLE);
    wait_running();
    check_frame(BASE1);
    @(negedge axi_clk);
    hold_r = 1;
    wait_reg(REG_FAULT, UNDERFLOW, UNDERFLOW);
    if (!irq) $fatal(1, "TEST FAIL: width %0d no underflow IRQ", DATA_WIDTH);
    hold_r = 0;
    black_pixels = 0;
    // Released data stays suppressed until the next frame boundary.
    while (vs) begin
      @(negedge pixel_clk);
      if (de) begin
        if (rgb !== 24'b0)
          $fatal(1, "TEST FAIL: width %0d returned data midframe after underflow", DATA_WIDTH);
        black_pixels++;
      end
    end
    if (black_pixels == 0)
      $fatal(1, "TEST FAIL: width %0d did not observe active black after underflow", DATA_WIDTH);
    check_frame(BASE1);
    write_reg(REG_CONTROL, SNAPSHOT | ENABLE);
    wait_reg(REG_STATUS, 16, 0);
    read_reg(REG_UNDERFLOWS, value);
    if (value == 0) $fatal(1, "TEST FAIL: width %0d snapshot underflow counter is zero", DATA_WIDTH);
    write_reg(REG_FAULT, UNDERFLOW);
    expect_reg(REG_FAULT, 15, 0);

    write_reg(REG_CONTROL, COMMIT | PATTERN | ENABLE);
    wait_running();
    stopped_requests = requests;
    check_frame(0, 1);
    if (requests != stopped_requests)
      $fatal(1, "TEST FAIL: width %0d pattern mode issued a read", DATA_WIDTH);
    hold_ar = 1;
    write_reg(REG_CONTROL, COMMIT | ENABLE);
    wait_running();
    wait (mem_arvalid && !mem_arready);
    reset_busy_bus(1);

    // Exercise reset during an accepted read, independently of the stalled AR case.
    configure_frame();
    hold_r = 1;
    write_reg(REG_CONTROL, COMMIT | ENABLE);
    wait_running();
    wait (remaining > 0);
    reset_busy_bus(0);
    stopped_requests = requests;
    repeat (30) @(negedge axi_clk);
    expect_reg(REG_STATUS, 7, 0);
    expect_reg(REG_FAULT, 15, 0);
    if (requests != stopped_requests)
      $fatal(1, "TEST FAIL: width %0d issued a read without a post-reset commit", DATA_WIDTH);
    configure_frame();
    write_reg(REG_CONTROL, COMMIT | ENABLE);
    wait_running();
    check_frame(BASE0);
    stop_reader();
    if (complete_read_frames < 4 || page_splits == 0 || held_ar_cycles == 0 || response_wait_cycles == 0)
      $fatal(1, "TEST FAIL: width %0d insufficient AXI traffic coverage", DATA_WIDTH);
    $display("IronVideo %0d-bit verified %0d requests, %0d complete read frames, %0d page splits",
             DATA_WIDTH, requests, complete_read_frames, page_splits);
    done = 1;
  end
endmodule
