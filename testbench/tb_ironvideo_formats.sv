`timescale 1ns/1ps

module tb_ironvideo_zero_mask;
  ironvideo_scanout #(.FORMAT_MASK(0)) dut ();
endmodule

module tb_ironvideo_unknown_mask;
  ironvideo_scanout #(.FORMAT_MASK(16)) dut ();
endmodule

module tb_ironvideo_formats;
  bit axi_clk, pixel_clk, reset_n;
  wire [15:1] done;
  always #3ns axi_clk = !axi_clk;
  always #7ns pixel_clk = !pixel_clk;
  initial begin
    repeat (8) @(negedge pixel_clk);
    reset_n = 1;
  end
  for (genvar mask = 1; mask < 16; mask++) begin : masks
    ironvideo_formats_case #(.MASK(mask)) test_case (.*,.done(done[mask]));
  end
  initial begin
    wait (&done);
    $display("TEST PASS: IronVideo all 15 format masks, live DDR pixels, plane bounds and row telemetry");
    $finish;
  end
  initial begin
    #5ms;
    $fatal(1, "TEST FAIL: format integration timeout: completed masks %h", done);
  end
endmodule

module ironvideo_formats_case #(parameter int MASK = 15) (
  input wire axi_clk, pixel_clk, reset_n, output bit done
);
  import ironvideo_format_model::*;
  localparam int W = 16, H = 4, HT = W+8, VT = H+4;
  localparam int DATA_WIDTH = 64, B = DATA_WIDTH/8, STRIDE = 80, UV_STRIDE = 48;
  localparam int UV_BASE = 'h60000;
  bit [7:0] awaddr, araddr;
  bit [31:0] wdata;
  bit awvalid, wvalid, arvalid;
  wire awready, wready, bvalid, arready, rvalid;
  wire [1:0] bresp, rresp;
  wire [31:0] rdata;
  wire [31:0] dma_addr;
  wire [7:0] dma_len;
  wire dma_valid, dma_ready;
  wire [23:0] rgb;
  wire de, hs, vs;
  int accepted, quota = -1, remaining;
  logic [31:0] returning_address;
  wire accept_address = remaining == 0 && (quota < 0 || accepted < quota);
  logic [DATA_WIDTH-1:0] mem_data;

  ironvideo_scanout #(.DATA_WIDTH(DATA_WIDTH), .MAX_BURST(16), .FORMAT_MASK(MASK)) dut (
    .axi_clk(axi_clk), .pixel_clk(pixel_clk), .reset_n(reset_n),
    .s_axi_awaddr(awaddr), .s_axi_awprot('0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(4'hf), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bvalid(bvalid), .s_axi_bresp(bresp), .s_axi_bready(1'b1),
    .s_axi_araddr(araddr), .s_axi_arprot('0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(1'b1),
    .m_axi_araddr(dma_addr), .m_axi_arlen(dma_len), .m_axi_arvalid(dma_valid),
    .m_axi_arready(accept_address), .m_axi_rdata(mem_data), .m_axi_rvalid(remaining != 0),
    .m_axi_rready(dma_ready), .m_axi_rlast(remaining == 1), .m_axi_rid('0), .m_axi_rresp('0),
    .m_axi_arid(), .m_axi_arsize(), .m_axi_arburst(), .m_axi_arlock(), .m_axi_arcache(),
    .m_axi_arprot(), .m_axi_arqos(), .rgb(rgb), .de(de), .hs(hs), .vs(vs), .irq()
  );

  function automatic int base(input int fmt);
    return (fmt+1)*'h10000;
  endfunction
  function automatic int row_size(input int fmt);
    return fmt == 0 ? 4*W : fmt == 3 ? W : 2*W;
  endfunction

  // Distinct memory banks encode image layout independent of the live DUT
  // mode. A read remaining from the previous mode still sees the old image.
  function automatic byte unsigned image_byte(input int address);
    int fmt, offset, xbyte, y, x;
    logic [31:0] word32;
    logic [15:0] word16;
    if (address >= UV_BASE) begin
      offset = address - UV_BASE;
      y = offset / UV_STRIDE;
      xbyte = offset % UV_STRIDE;
      if (y >= H/2 || xbyte >= W) $fatal(1, "mask=%h UV bounds %h", MASK, address);
      return xbyte%2 ? cr(xbyte/2,y) : cb(xbyte/2,y);
    end
    fmt = (address >> 16)-1;
    offset = address - base(fmt);
    y = offset/STRIDE;
    xbyte = offset%STRIDE;
    if (fmt < 0 || fmt > 3 || y >= H || xbyte >= row_size(fmt))
      $fatal(1, "mask=%h primary bounds %h", MASK, address);
    case (fmt)
      0: begin
        word32 = {8'hb6, color(0,xbyte/4,y,STRIDE)};
        return 8'(word32 >> (8*(xbyte%4)));
      end
      1: begin
        word16 = rgb565(xbyte/2,y);
        return 8'(word16 >> (8*(xbyte%2)));
      end
      2: begin
        x = xbyte/2;
        if (!(xbyte%2)) return luma(x,y);
        return x%2 ? cr(x/2,y) : cb(x/2,y);
      end
      default: return luma(xbyte,y);
    endcase
  endfunction

  always_comb begin
    mem_data = '0;
    if (remaining != 0)
      for (int i = 0; i < B; i++) mem_data[i*8 +: 8] = image_byte(returning_address+i);
  end
  always_ff @(posedge axi_clk) begin
    if (dma_valid && accept_address) begin
      remaining <= int'(dma_len) + 1;
      returning_address <= dma_addr;
      accepted <= accepted + 1;
    end else if (remaining != 0 && dma_ready) begin
      remaining <= remaining - 1;
      returning_address <= returning_address+B;
    end
  end

  task automatic wr(input logic [7:0] addr, input logic [31:0] data,
                    input logic [1:0] expected = 0);
    @(negedge axi_clk);
    awaddr = addr; wdata = data; awvalid = 1; wvalid = 1;
    do @(posedge axi_clk); while (!(awready && wready));
    @(negedge axi_clk);
    awvalid = 0; wvalid = 0;
    do @(posedge axi_clk); while (!bvalid);
    if (bresp !== expected) $fatal(1, "mask=%h write %h=%h response %h expected %h",
                                   MASK, addr, data, bresp, expected);
  endtask
  task automatic rd(input logic [7:0] addr, output logic [31:0] data,
                    input logic [1:0] expected = 0, input bit at_row_end = 0);
    @(negedge axi_clk);
    if (at_row_end)
      while (!dut.row_done) @(negedge axi_clk);
    araddr = addr; arvalid = 1;
    do @(posedge axi_clk); while (!arready);
    if (at_row_end && !dut.row_done) $fatal(1, "read missed concurrent row completion");
    @(negedge axi_clk);
    arvalid = 0;
    do @(posedge axi_clk); while (!rvalid);
    if (rresp !== expected) $fatal(1, "mask=%h read %h response %h expected %h",
                                   MASK, addr, rresp, expected);
    data = rdata;
  endtask
  task automatic expect_value(input logic [7:0] addr, input logic [31:0] value);
    logic [31:0] result;
    rd(addr, result);
    if (result !== value)
      $fatal(1, "mask=%h read %h returned %h expected %h", MASK, addr, result, value);
  endtask

  task automatic set_plane(input int fmt);
    if (MASK != 1) wr('h9c,fmt);
    wr('h20,base(fmt)); wr('h24,STRIDE); wr('h28,base(fmt));
    wr('h2c,(H-1)*STRIDE+row_size(fmt));
    wr('h54, (fmt == 0 ? W*4 : W*2)/B);
  endtask
  task automatic transition(input int value);
    logic [31:0] status;
    wr('h0c,value);
    do rd('h10,status); while (status[1]);
    if (status[2] !== value[0] || status[3] === value[0])
      $fatal(1, "mask=%h transition failed: status %h", MASK, status);
  endtask
  task automatic reject_commit();
    logic [31:0] faults;
    wr('h0c,5,2);
    rd('h14,faults);
    if (!faults[0]) $fatal(1, "mask=%h rejected COMMIT without control fault", MASK);
    wr('h14,1);
  endtask

  // Synchronize from visible pins only. Entire black startup frames are
  // legal; once pixels appear, every pixel, blank and sync must match.
  task automatic compare_frame(input int fmt);
    bit nonblack, bad;
    logic [23:0] expected;
    for (int attempt = 0; attempt < 6; attempt++) begin
      @(posedge vs);
      @(negedge vs);
      @(posedge de);
      @(negedge pixel_clk);
      nonblack = 0;
      bad = 0;
      for (int y = 0; y < VT; y++) begin
        for (int x = 0; x < HT; x++) begin
          if (de !== (x<W && y<H) || hs !== (x>=W+2 && x<W+4) || vs !== (y==H+1))
            $fatal(1, "mask=%h fmt=%0d timing mismatch at %0d,%0d DE/HS/VS=%b%b%b",
                   MASK, fmt, x, y, de, hs, vs);
          expected = de ? color(fmt,x,y,STRIDE) : 24'b0;
          if (rgb !== expected) bad = 1;
          if (rgb !== 24'b0) nonblack = 1;
          @(negedge pixel_clk);
        end
      end
      if (nonblack) begin
        if (bad) $fatal(1, "mask=%h live format %0d pixel/blank mismatch", MASK, fmt);
        return;
      end
    end
    $fatal(1, "mask=%h fmt=%0d never displayed framebuffer", MASK, fmt);
  endtask

  // Hold the next AXI address until all the preceding row's MMIO values have
  // been sampled. Every active plane row here fits in exactly one burst.
  task automatic telemetry();
    logic [31:0] n, bytes, ticks, even_ticks, peak_cycles, peak_bytes;
    int best_bytes, best_ticks;
    quota = accepted;
    transition(5);
    for (int row = 0; row < 4; row++) begin
      // In the second interval the slower even row has the greater byte rate.
      case (row)
        0: repeat (240) @(negedge axi_clk);
        2: repeat (150) @(negedge axi_clk);
        3: repeat (110) @(negedge axi_clk);
      endcase
      quota += row%2 == 0 ? 2 : 1;
      do rd('h80,n); while (n < row+1);
      if (n != row+1) $fatal(1,"unexpected row completion while holding DDR");
      rd('h7c,bytes); rd('h78,ticks);
      if (bytes != (row%2 == 0 ? 2*W : W) || !ticks)
        $fatal(1, "row %0d bytes/ticks = %0d/%0d", row, bytes, ticks);
      if (!(row%2)) even_ticks = ticks;
      if (row == 3 && !(ticks < even_ticks && even_ticks < 2*ticks))
        $fatal(1, "peak fixture requires T_odd < T_even < 2*T_odd, even=%0d odd=%0d", even_ticks, ticks);
      if (!(row%2) || bytes*best_ticks > best_bytes*ticks) begin
        best_ticks = ticks;
        best_bytes = bytes;
      end
      if (row%2) begin
        rd('hb0,peak_cycles);
        rd('hb4,peak_bytes);
        if (peak_cycles !== best_ticks || peak_bytes !== best_bytes ||
            peak_bytes !== (row == 1 ? W : 2*W))
          $fatal(1, "row %0d peak bytes/ticks %0d/%0d expected %0d/%0d",
                 row, peak_bytes, peak_cycles, best_bytes, best_ticks);
        expect_value('hb4,peak_bytes);
        expect_value('hb0,0);
        expect_value('hb4,0);
      end
    end
    // Complete one row before clearing and another on the clear itself.
    // Compare the old and new byte/tick pairs across the interval boundary.
    quota += 2;
    do rd('h80,n); while (n < 5);
    rd('h78,even_ticks);
    if (n != 5 || !even_ticks) $fatal(1, "missing pre-clear row");
    quota++;
    rd('hb0,peak_cycles,0,1);
    if (peak_cycles !== even_ticks) $fatal(1, "concurrent clear lost previous peak");
    expect_value('hb4,2*W);
    expect_value('h80,6);
    expect_value('h7c,W);
    rd('h78,ticks);
    if (!ticks) $fatal(1, "missing post-clear row");
    expect_value('hb0,ticks);
    expect_value('hb4,W);
    expect_value('hb0,0);
    expect_value('hb4,0);
    quota = -1;
    transition(0);
    wr('h14,15);
  endtask

  initial begin
    logic [31:0] result;
    int first, formats;
    wait (reset_n);
    repeat (7) @(negedge axi_clk);
    expect_value('h00,32'h49525644);
    expect_value('h04,MASK == 1 ? 'h10001 : 'h10002);
    if (MASK == 1) begin
      rd('h98,result,2); wr('h9c,1,2); rd('hb0,result,2);
    end else begin
      expect_value('h98,MASK); wr('h98,15,2);
    end
    wr('h30,W); wr('h34,2); wr('h38,2); wr('h3c,4);
    wr('h40,H); wr('h44,1); wr('h48,1); wr('h4c,2); wr('h50,3);
    if (MASK != 1) begin
      wr('ha0,UV_BASE); wr('ha4,UV_STRIDE); wr('ha8,UV_BASE); wr('hac,UV_STRIDE+W);
      for (int fmt = 0; fmt < 4; fmt++) begin
        if (!MASK[fmt]) begin
          set_plane(fmt);
          reject_commit();
        end
      end
    end
    if (MASK[3]) begin
      set_plane(3);
      wr('hac,UV_STRIDE+W-1); reject_commit(); wr('hac,UV_STRIDE+W);
      wr('ha4,W-1); reject_commit(); wr('ha4,UV_STRIDE);
      wr('ha0,UV_BASE+1); reject_commit(); wr('ha0,UV_BASE);
      wr('h40,H-1); reject_commit(); wr('h40,H);
      wr('h2c,(H-1)*STRIDE+W-1); reject_commit(); wr('h2c,(H-1)*STRIDE+W);
      if (MASK == 8) telemetry();
    end
    first = -1; formats = 0;
    for (int fmt = 0; fmt < 4; fmt++) begin
      if (MASK[fmt]) begin
        if (first < 0) first = fmt;
        formats++;
        set_plane(fmt);
        transition(5);
        compare_frame(fmt);
        expect_value('h14,0);
      end
    end
    if (formats > 1) begin
      set_plane(first);
      transition(5);
      compare_frame(first);
    end
    transition(0);
    expect_value('h14,0);
    done = 1;
  end
endmodule
