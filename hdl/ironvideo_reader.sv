`timescale 1ns/1ps

// IronVideo framebuffer reader, SystemVerilog-2012.
// Revision 11-18-2026: initial single-outstanding AXI4 read scheduler.
// Schedule aligned bursts by line, address page, and available FIFO space.
// Mark frame and line boundaries and drain accepted reads on stop or error.
module ironvideo_reader #(
  parameter int DATA_WIDTH = 64,
  parameter int MAX_BURST = 64,
  parameter int FIFO_AW = 9,
  parameter int ARQOS = 15,
  parameter int AXI_ID_WIDTH = 1,
  parameter bit SUPPORT_NV12 = 0
) (
  // Memory AXI clock and active-high synchronous reset.
  input  logic                    clk,
  input  logic                    rst,

  // Frame geometry in the memory clock domain, validated and held while running.
  // Addresses and pitches use bytes. The frame height uses active lines.
  input  logic                    run,
  input  logic [31:0]             base,
  input  logic [31:0]             stride,
  input  logic [31:0]             line_bytes,
  input  logic [15:0]             lines,

  // FIFO write port in the memory clock domain. Capacity uses full AXI beats.
  input  logic [FIFO_AW:0]        fifo_free,
  output logic                    fifo_write,
  output logic [DATA_WIDTH-1:0]   fifo_data,
  output logic                    fifo_sof,
  output logic                    fifo_sol,

  // AXI4 read channels in the memory clock domain. All requests use ID zero.
  output logic [AXI_ID_WIDTH-1:0] m_axi_arid,
  output logic [31:0]             m_axi_araddr,
  output logic [7:0]              m_axi_arlen,
  output logic [2:0]              m_axi_arsize,
  output logic [1:0]              m_axi_arburst,
  output logic                    m_axi_arlock,
  output logic [3:0]              m_axi_arcache,
  output logic [2:0]              m_axi_arprot,
  output logic [3:0]              m_axi_arqos,
  output logic                    m_axi_arvalid,
  input  logic                    m_axi_arready,
  input  logic [AXI_ID_WIDTH-1:0] m_axi_rid,
  input  logic [DATA_WIDTH-1:0]   m_axi_rdata,
  input  logic [1:0]              m_axi_rresp,
  input  logic                    m_axi_rlast,
  input  logic                    m_axi_rvalid,
  output logic                    m_axi_rready,

  // Memory clock status. Idle means the AR and R channels have no open read.
  // Fault pulses identify response/ID and RLAST errors at the reported byte address.
  output logic                    idle,
  output logic                    row_busy,
  output logic                    row_start,
  output logic                    row_done,
  output logic                    resp_fault,
  output logic                    last_fault,
  output logic [31:0]             fault_addr,

  // NV12 uses line_bytes luma bytes per row and the same number of UV bytes
  // per pair of rows. The FIFO receives packed Y0,Cb,Y1,Cr byte order.
  input  logic                    nv12,
  input  logic [31:0]             uv_base,
  input  logic [31:0]             uv_stride,
  output logic                    row_extra_chroma
);
  localparam int BEAT_BYTES = DATA_WIDTH / 8;
  localparam int BEAT_SHIFT = $clog2(BEAT_BYTES);
  localparam logic [12:0] PAGE_BYTES = 13'd4096;

  typedef enum logic [2:0] {
    IDLE_ST, PLAN_ST, ADDRESS_ST, READ_ST, FAULT_ST, PACK_TAIL_ST
  } reader_state_t;

  reader_state_t state;
  logic [31:0] line_addr;
  logic [31:0] next_addr;
  logic [31:0] bytes_left;
  logic [15:0] line_index;
  logic use_nv12;
  logic reading_uv;
  logic [31:0] uv_line_addr;

  logic [31:0] available_beats;
  logic [31:0] line_beats;
  logic [12:0] page_bytes_left;
  logic [12:0] page_beats;
  logic [31:0] planned_beats;
  logic [8:0] burst_beats;
  logic [31:0] burst_bytes;

  logic [8:0] beats_left;
  logic [31:0] beat_addr;
  logic line_start;
  logic frame_start;
  logic stop_requested;
  logic burst_faulted;
  logic reported_resp_fault;
  logic reported_last_fault;
  logic r_transfer;
  logic matching_id;
  logic bad_response;
  logic bad_last;
  logic pack_pending, pack_high, pack_write, pack_first, pack_frame, pack_last;
  logic [DATA_WIDTH-1:0] pack_data;

  assign available_beats = 32'(fifo_free);
  assign line_beats = bytes_left >> BEAT_SHIFT;
  assign page_bytes_left = PAGE_BYTES - {1'b0, next_addr[11:0]};
  assign page_beats = page_bytes_left >> BEAT_SHIFT;
  assign burst_bytes = 32'(burst_beats) << BEAT_SHIFT;

  always_comb begin
    planned_beats = 32'(MAX_BURST);
    if (planned_beats > line_beats)
      planned_beats = line_beats;
    if (planned_beats > 32'(page_beats))
      planned_beats = 32'(page_beats);
  end

  assign m_axi_arid = '0;
  assign m_axi_arsize = 3'(BEAT_SHIFT);
  assign m_axi_arburst = 2'b01;
  assign m_axi_arlock = 1'b0;
  assign m_axi_arcache = 4'b0011;
  assign m_axi_arprot = 3'b000;
  assign m_axi_arqos = 4'(ARQOS);
  assign m_axi_arvalid = !rst && (state == ADDRESS_ST);
  // A Y beat generates two FIFO words. Accept the next Y beat on the same
  // edge that writes the upper word. A stopped/faulted burst drains freely.
  assign m_axi_rready = !rst && state == READ_ST &&
                        (!pack_pending || pack_high || !run || stop_requested || burst_faulted);
  assign idle = rst || (state != ADDRESS_ST && state != READ_ST && !pack_pending);

  assign r_transfer = m_axi_rvalid && m_axi_rready;
  assign matching_id = (m_axi_rid == 0);
  assign bad_response = !matching_id || (m_axi_rresp != 2'b00);
  assign bad_last = matching_id && (m_axi_rlast != (beats_left == 9'd1));
  assign burst_faulted = reported_resp_fault || reported_last_fault;
  wire good_beat = r_transfer && run && !stop_requested && !burst_faulted && !bad_response && !bad_last;
  wire plane_end = beats_left == 9'd1 && bytes_left == burst_bytes;
  assign fifo_write = use_nv12 ? pack_write : good_beat;
  assign fifo_data = use_nv12 ? pack_data : m_axi_rdata;
  assign fifo_sof = fifo_write && (use_nv12 ? pack_first && pack_frame : frame_start);
  assign fifo_sol = fifo_write && (use_nv12 ? pack_first : line_start);
  assign row_extra_chroma = use_nv12 && !line_index[0];
  wire [31:0] reserve_beats = use_nv12 ? line_beats << 1 : line_beats;
  wire launch = state == PLAN_ST && run && planned_beats != 0 &&
                (row_busy || available_beats >= reserve_beats);
  assign row_start = launch && !row_busy;
  assign row_done = fifo_write && (use_nv12 ? pack_high && pack_last : plane_end);

  if (SUPPORT_NV12) begin : nv12_adapter
    // A normalized row occupies twice the Y plane's bytes in the FIFO. The
    // largest supported UV row therefore takes only half the FIFO's RAM depth.
    localparam int UV_DEPTH = 1 << (FIFO_AW-1);
    localparam int UV_AW = FIFO_AW > 1 ? FIFO_AW-1 : 1;
    (* ram_style = "block" *) logic [DATA_WIDTH-1:0] chroma [0:UV_DEPTH-1];
    logic [UV_AW-1:0] index_in_row;
    logic [DATA_WIDTH-1:0] uv_word, y_word;
    logic held_sol;
    wire accept_uv = good_beat && use_nv12 && reading_uv;
    wire accept_y = good_beat && use_nv12 && !reading_uv;
    wire discard = !run || stop_requested || burst_faulted ||
                   (r_transfer && (bad_response || bad_last));
    wire [2*DATA_WIDTH-1:0] interleaved;
    for (genvar i = 0; i < BEAT_BYTES; i++) begin : pack_byte
      assign interleaved[16*i +: 16] = {uv_word[8*i +: 8], y_word[8*i +: 8]};
    end
    assign pack_data = pack_high ? interleaved[DATA_WIDTH +: DATA_WIDTH] : interleaved[0 +: DATA_WIDTH];
    assign pack_first = !pack_high && held_sol;
    assign pack_write = !rst && pack_pending && !discard;

    // The cache is written once at the start of each two-row group and read
    // synchronously on each good Y beat. No cache data crosses clock domains.
    always_ff @(posedge clk) begin
      if (accept_uv)
        chroma[index_in_row] <= m_axi_rdata;
      if (accept_y) begin
        uv_word <= chroma[index_in_row];
        y_word <= m_axi_rdata;
      end
    end
    always_ff @(posedge clk) begin
      if (rst || discard) begin
        index_in_row <= '0;
        pack_pending <= 1'b0;
        pack_high <= 1'b0;
        held_sol <= 1'b0;
        pack_frame <= 1'b0;
        pack_last <= 1'b0;
      end else begin
        if (accept_uv || accept_y)
          index_in_row <= plane_end ? '0 : index_in_row + 1'b1;
        if (accept_y) begin
          pack_pending <= 1'b1;
          pack_high <= 1'b0;
          held_sol <= line_start;
          pack_frame <= frame_start;
          pack_last <= plane_end;
        end else if (pack_pending) begin
          pack_pending <= !pack_high;
          pack_high <= !pack_high;
        end
      end
    end
  end else begin : packed_only
    assign {pack_pending, pack_high, pack_write, pack_first, pack_frame, pack_last, pack_data} = '0;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE_ST;
      line_addr <= '0;
      next_addr <= '0;
      bytes_left <= '0;
      line_index <= '0;
      use_nv12 <= 1'b0;
      reading_uv <= 1'b0;
      uv_line_addr <= '0;
      burst_beats <= '0;
      m_axi_araddr <= '0;
      m_axi_arlen <= '0;
      beats_left <= '0;
      beat_addr <= '0;
      line_start <= 1'b0;
      frame_start <= 1'b0;
      row_busy <= 1'b0;
      stop_requested <= 1'b0;
      reported_resp_fault <= 1'b0;
      reported_last_fault <= 1'b0;
      resp_fault <= 1'b0;
      last_fault <= 1'b0;
      fault_addr <= '0;
    end else begin
      resp_fault <= 1'b0;
      last_fault <= 1'b0;
      case (state)
        IDLE_ST: begin
          if (run) begin
            line_addr <= base;
            use_nv12 <= SUPPORT_NV12 && nv12;
            reading_uv <= SUPPORT_NV12 && nv12;
            uv_line_addr <= uv_base;
            next_addr <= SUPPORT_NV12 && nv12 ? uv_base : base;
            bytes_left <= line_bytes;
            line_index <= '0;
            stop_requested <= 1'b0;
            reported_resp_fault <= 1'b0;
            reported_last_fault <= 1'b0;
            state <= PLAN_ST;
          end
        end

        PLAN_ST: begin
          if (!run) begin
            row_busy <= 1'b0;
            state <= IDLE_ST;
          end else if (launch) begin
            m_axi_araddr <= next_addr;
            m_axi_arlen <= 8'(planned_beats - 32'd1);
            burst_beats <= 9'(planned_beats);
            line_start <= (bytes_left == line_bytes);
            frame_start <= (bytes_left == line_bytes) && (line_index == 0);
            row_busy <= 1'b1;
            state <= ADDRESS_ST;
          end
        end

        ADDRESS_ST: begin
          // Keep the presented request stable even while a stop is pending.
          if (!run)
            stop_requested <= 1'b1;
          if (m_axi_arready) begin
            beats_left <= burst_beats;
            beat_addr <= m_axi_araddr;
            state <= READ_ST;
          end
        end

        READ_ST: begin
          if (!run)
            stop_requested <= 1'b1;
          if (r_transfer) begin
            if ((bad_response && !reported_resp_fault) || (bad_last && !reported_last_fault))
              fault_addr <= beat_addr;
            if (bad_response && !reported_resp_fault) begin
              resp_fault <= 1'b1;
              reported_resp_fault <= 1'b1;
            end
            if (bad_last && !reported_last_fault) begin
              last_fault <= 1'b1;
              reported_last_fault <= 1'b1;
            end
            if (matching_id) begin
              if (beats_left != 0) begin
                beats_left <= beats_left - 9'd1;
                beat_addr <= beat_addr + 32'(BEAT_BYTES);
              end
              line_start <= 1'b0;
              frame_start <= 1'b0;
              // Drain through a matching RLAST even after the expected beat count expires.
              if (m_axi_rlast) begin
                if (stop_requested || !run || burst_faulted || bad_response || bad_last)
                  row_busy <= 1'b0;
                if (stop_requested || !run) begin
                  state <= IDLE_ST;
                end else if (burst_faulted || bad_response || bad_last) begin
                  state <= FAULT_ST;
                end else begin
                  state <= PLAN_ST;
                  if (bytes_left != burst_bytes) begin
                    next_addr <= next_addr + burst_bytes;
                    bytes_left <= bytes_left - burst_bytes;
                  end else if (reading_uv) begin
                    reading_uv <= 1'b0;
                    next_addr <= line_addr;
                    bytes_left <= line_bytes;
                  end else if (use_nv12) begin
                    state <= PACK_TAIL_ST;
                  end
                end
              end
            end
          end
        end

        PACK_TAIL_ST: begin
          if (!run) begin
            row_busy <= 1'b0;
            state <= IDLE_ST;
          end
        end

        FAULT_ST: begin
          if (!run)
            state <= IDLE_ST;
        end

        default: state <= FAULT_ST;
      endcase

      // Packed rows finish on their final R beat, NV12 rows when the second
      // word of that beat has actually been accepted by the FIFO.
      if (row_done) begin
        row_busy <= 1'b0;
        bytes_left <= line_bytes;
        state <= PLAN_ST;
        if (line_index == lines - 16'd1) begin
          line_index <= '0;
          line_addr <= base;
          reading_uv <= use_nv12;
          uv_line_addr <= uv_base;
          next_addr <= use_nv12 ? uv_base : base;
        end else begin
          line_index <= line_index + 16'd1;
          line_addr <= line_addr + stride;
          reading_uv <= use_nv12 && line_index[0];
          if (use_nv12 && line_index[0]) begin
            uv_line_addr <= uv_line_addr + uv_stride;
            next_addr <= uv_line_addr + uv_stride;
          end else
            next_addr <= line_addr + stride;
        end
      end
    end
  end

`ifndef SYNTHESIS
  logic ar_stalled;
  logic [39:0] stalled_ar;

  initial begin
    if (DATA_WIDTH != 32 && DATA_WIDTH != 64 && DATA_WIDTH != 128)
      $fatal(1, "IronVideo AXI data width must be 32, 64, or 128 bits");
    if (MAX_BURST < 1 || MAX_BURST > 256 || FIFO_AW < 1 || FIFO_AW > 15 ||
        ARQOS < 0 || ARQOS > 15 || AXI_ID_WIDTH < 1)
      $fatal(1, "IronVideo AXI reader parameters out of range");
  end

  always @(posedge clk) begin
    if (rst) begin
      ar_stalled <= 1'b0;
      stalled_ar <= '0;
    end else begin
      if (ar_stalled && (!m_axi_arvalid || {m_axi_araddr, m_axi_arlen} != stalled_ar))
        $fatal(1, "IronVideo changed a stalled AXI read request");
      if (m_axi_arvalid && (m_axi_araddr[BEAT_SHIFT-1:0] != 0 ||
          32'(m_axi_araddr[11:0]) + burst_bytes > 32'(PAGE_BYTES)))
        $fatal(1, "IronVideo issued an unaligned or page-crossing read request");
      if (fifo_write && fifo_free == 0)
        $fatal(1, "IronVideo exhausted the reserved FIFO capacity");
      ar_stalled <= m_axi_arvalid && !m_axi_arready;
      stalled_ar <= {m_axi_araddr, m_axi_arlen};
    end
  end
`endif
endmodule
