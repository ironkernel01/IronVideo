`timescale 1ns/1ps

// 11-18-2026, SystemVerilog-2012. Initial IronVideo controller.
// Validate AXI4-Lite shadow settings, coordinate frame-boundary commits,
// and compose the AXI4 reader, dual-clock FIFO, and pixel raster.
module ironvideo_scanout #(
  parameter int DATA_WIDTH = 64,
  parameter int MAX_BURST = 64,
  parameter int PACKED_READS = 1,
  parameter int FIFO_KIB = 16,
  parameter int ARQOS = 15,
  parameter int AXI_ID_WIDTH = 1,
  parameter int FORMAT_MASK = 1,
  parameter bit CLOCK_SELECT = 0
) (
  // Independent bus and pixel clocks, plus the shared active-low reset.
  input logic axi_clk,
  input logic pixel_clk,
  input logic reset_n,
  output logic clock_request,
  input logic clock_active, clock_ready,

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

  // RGB [23:16] red, [15:8] green, [7:0] blue, and raster timing at pixel_clk.
  output logic [23:0] rgb,
  output logic de,
  output logic hs,
  output logic vs,
  // Active-high consolidated interrupt, synchronous to axi_clk.
  output logic irq
);
  import ironvideo_pkg::*;
  if (FORMAT_MASK < 1 || FORMAT_MASK > 15) begin : invalid_format_mask
    IRONVIDEO_FORMAT_MASK_MUST_BE_1_TO_15 invalid_parameter ();
  end
  localparam bit EXTENDED_ABI = FORMAT_MASK != 1;
  localparam int BEAT_BYTES = DATA_WIDTH/8;
  localparam int FIFO_REQUEST = FIFO_KIB < 16 ? 16 : FIFO_KIB;
  localparam int FIFO_PAYLOAD_BYTES = 1024 << $clog2(FIFO_REQUEST);
  localparam int FIFO_DEPTH = FIFO_PAYLOAD_BYTES / BEAT_BYTES;
  localparam int FIFO_AW = $clog2(FIFO_DEPTH);
  localparam int ALIGN_BITS = $clog2(BEAT_BYTES);
  localparam logic [1:0] OKAY = 2'b00, SLVERR = 2'b10;
  localparam logic [7:0] REG_ID = 'h00, REG_VERSION = 'h04, REG_CAPS = 'h08,
    REG_CONTROL = 'h0c, REG_STATUS = 'h10, REG_FAULT = 'h14,
    REG_MASK = 'h18, REG_FIRST = 'h1c, REG_BASE = 'h20, REG_STRIDE = 'h24,
    REG_WINDOW = 'h28, REG_SIZE = 'h2c, REG_HA = 'h30, REG_HF = 'h34,
    REG_HS = 'h38, REG_HB = 'h3c, REG_VA = 'h40, REG_VF = 'h44,
    REG_VS = 'h48, REG_VB = 'h4c, REG_POLARITY = 'h50, REG_PREFILL = 'h54,
    REG_UNDERFLOW = 'h58, REG_LOW_WATER = 'h5c, REG_XY = 'h60,
    REG_FRAME = 'h64, REG_FAULT_XY = 'h68, REG_FAULT_ADDR = 'h6c,
    REG_FIFO_BYTES = 'h70, REG_DMA_STATUS = 'h74, REG_ROW_LAST = 'h78,
    REG_ROW_BYTES = 'h7c, REG_ROW_SAMPLES = 'h80, REG_ROW_WORST = 'h84,
    REG_ROW_BEST = 'h88, REG_READ_BEATS = 'h8c, REG_READ_BURSTS = 'h90,
    REG_READ_ERRORS = 'h94, REG_FORMAT_CAPS = 'h98, REG_FORMAT = 'h9c,
    REG_UV_BASE = 'ha0, REG_UV_STRIDE = 'ha4, REG_UV_WINDOW = 'ha8, REG_UV_SIZE = 'hac,
    REG_PEAK_RATE_CYCLES = 'hb0, REG_PEAK_RATE_BYTES = 'hb4, REG_CLOCK_SELECT = 'hb8;
  typedef enum logic [1:0] {S_IDLE, S_DRAIN, S_APPLY} config_state_t;

  logic axi_rst;
  logic pixel_rst;
  video_config_t shadow;
  video_config_t active_config;
  video_snapshot_t pixel_snapshot;
  video_snapshot_t snapshot;
  logic [31:0] window_base;
  logic [31:0] window_bytes;
  logic [31:0] uv_base, uv_stride, uv_window, uv_size;
  logic [31:0] active_uv_base, active_uv_stride;
  logic configured;
  logic target_enable;
  logic applied_enable;
  logic config_toggle;
  logic config_ack;
  logic snapshot_toggle;
  logic snapshot_ack;
  logic snapshot_read;
  logic read_fault;
  logic mode_commit_pending;
  config_state_t state;
  (* ASYNC_REG = "TRUE" *) logic [3:0] config_ack_sync;
  (* ASYNC_REG = "TRUE" *) logic [3:0] snapshot_ack_sync;
  (* ASYNC_REG = "TRUE" *) logic [31:0] underflow_sync [0:3];
  logic [31:0] underflow_seen;
  logic [31:0] pixel_underflow_gray;

  logic aw_pending;
  logic w_pending;
  logic write_response_valid;
  logic read_response_valid;
  logic [7:0] write_addr;
  logic [31:0] write_data;
  logic [3:0] write_strobes;

  logic [3:0] faults;
  logic [3:0] irq_mask;
  logic [3:0] first_fault;
  logic [3:0] events;
  logic [3:0] clear_faults;
  logic [31:0] first_addr;
  logic [31:0] read_fault_addr;
  logic reader_idle;
  logic resp_fault;
  logic last_fault;
  logic fifo_write;
  logic fifo_valid;
  logic fifo_pop;
  logic wr_sof;
  logic wr_sol;
  logic rd_sof;
  logic rd_sol;
  logic [FIFO_AW:0] fifo_free;
  logic [FIFO_AW:0] fifo_count;
  logic [FIFO_AW:0] fifo_wr_cursor;
  logic [FIFO_AW:0] fifo_rd_cursor;
  logic [FIFO_AW:0] flush_cursor;
  logic [DATA_WIDTH-1:0] fifo_in;
  logic [DATA_WIDTH-1:0] fifo_out;
  logic row_busy;
  logic row_start;
  logic row_done;
  logic row_saturated;
  logic stats_read_pending, stats_snapshot_valid;
  logic [7:0] stats_read_addr;
  logic [3:0] stats_dma_status;
  logic [31:0] row_last;
  logic [31:0] row_bytes;
  logic [31:0] row_samples;
  logic [31:0] row_worst;
  logic [31:0] row_best;
  logic row_extra_chroma;
  logic [31:0] peak_rate_cycles, peak_rate_bytes;
  logic [31:0] read_beats;
  logic [31:0] read_bursts;
  logic [31:0] read_errors;

  wire busy = state != S_IDLE;
  wire snapshot_busy = snapshot_toggle != snapshot_read;
  wire quiet = !busy && !applied_enable && reader_idle;
  wire reader_run = !busy && applied_enable && !active_config.pattern
           && !read_fault && !resp_fault && !last_fault;
  wire low_byte = write_strobes[0];
  wire commit_write = write_addr == REG_CONTROL && low_byte && write_data[2];
  wire shadow_write_addr = write_addr[1:0] == 0 &&
           ((write_addr >= REG_BASE && write_addr <= REG_PREFILL) ||
            (EXTENDED_ABI && write_addr >= REG_FORMAT && write_addr <= REG_UV_SIZE));
  localparam logic [2:0] VALIDATION_STAGES = 3'd6;
  logic [2:0] validation_wait;
  wire accept_write = aw_pending && w_pending && !write_response_valid
           && (!commit_write || busy || validation_wait == 0);
  wire control = accept_write && write_addr == REG_CONTROL && low_byte;
  wire commit = control && write_data[2];
  wire snapshot_request = control && write_data[3];
  wire accept_read = s_axi_arready && s_axi_arvalid;
  wire [3:0] dma_status = {read_fault, (m_axi_rready && !m_axi_rvalid),
                           (m_axi_arvalid && !m_axi_arready), row_busy};
  wire stats_read = accept_read && (
      s_axi_araddr == REG_DMA_STATUS || s_axi_araddr == REG_ROW_LAST ||
      s_axi_araddr == REG_ROW_BYTES || s_axi_araddr == REG_ROW_SAMPLES ||
      s_axi_araddr == REG_ROW_WORST || s_axi_araddr == REG_ROW_BEST ||
      (EXTENDED_ABI && (s_axi_araddr == REG_PEAK_RATE_CYCLES ||
                        s_axi_araddr == REG_PEAK_RATE_BYTES)));

  wire [31:0] line_bytes = plane_row_bytes(shadow.format, shadow.ha);
  wire [31:0] active_line_bytes = plane_row_bytes(active_config.format, active_config.ha);
  wire nv12_shadow = shadow.format == FMT_YUV420;
  logic primary_valid, uv_valid;
  ironvideo_plane_bounds #(.ALIGN_BITS(ALIGN_BITS)) primary_bounds (
    .clk(axi_clk), .base(shadow.base), .stride(shadow.stride), .row_bytes(line_bytes),
    .rows(shadow.va), .window_base(window_base), .window_bytes(window_bytes), .valid(primary_valid)
  );
  if (FORMAT_MASK[3]) begin : chroma_bounds
    ironvideo_plane_bounds #(.ALIGN_BITS(ALIGN_BITS)) bounds (
      .clk(axi_clk), .base(uv_base), .stride(uv_stride), .row_bytes({16'b0,shadow.ha}),
      .rows(shadow.va >> 1), .window_base(uv_window), .window_bytes(uv_size), .valid(uv_valid)
    );
  end else assign uv_valid = 1'b0;
  logic [16:0] h_active_front, h_sync_back, v_active_front, v_sync_back;
  logic [17:0] h_total, v_total;
  logic [15:0] h_sync_end, v_sync_end;
  logic [15:0] h_last, v_last;
  logic timing_nonzero;
  logic frame_fits;
  logic prefill_valid;
  logic valid_timing;
  wire valid_frame = FORMAT_MASK[shadow.format] && frame_fits && prefill_valid && primary_valid
                  && (!nv12_shadow || (uv_valid && !shadow.va[0]));
  wire valid_mode = valid_timing && (write_data[1] || valid_frame);
  wire bad_control = control && ((commit && !valid_mode)
            || (CLOCK_SELECT && (commit || write_data[0]) && !clock_ready)
            || (busy && (commit || write_data[0] != target_enable))
            || (snapshot_request && snapshot_busy)
            || (write_data[0] && !commit && !configured));
  wire [3:0] present_faults = (faults & ~clear_faults) | events;

  // The pipeline runs every cycle so its multiplier registers have no
  // control-dependent enable. After a shadow write, intermediate stages can
  // mix old and new fields. A commit waits for all stages to see the new data.
  always_ff @(posedge axi_clk) begin
    h_active_front <= 17'(shadow.ha) + 17'(shadow.hf);
    h_sync_back <= 17'(shadow.hs) + 17'(shadow.hb);
    v_active_front <= 17'(shadow.va) + 17'(shadow.vf);
    v_sync_back <= 17'(shadow.vs) + 17'(shadow.vb);
    h_total <= 18'(h_active_front) + 18'(h_sync_back);
    v_total <= 18'(v_active_front) + 18'(v_sync_back);
    h_sync_end <= h_active_front[15:0] + shadow.hs;
    v_sync_end <= v_active_front[15:0] + shadow.vs;
    h_last <= h_total[15:0] - 16'd1;
    v_last <= v_total[15:0] - 16'd1;
    timing_nonzero <= shadow.ha != 0 && shadow.va != 0
             && shadow.hs != 0 && shadow.vs != 0;
    valid_timing <= timing_nonzero && h_total[17:16] == 0 && v_total[17:16] == 0;

    frame_fits <= fifo_row_bytes(shadow.format, shadow.ha) <= FIFO_PAYLOAD_BYTES;
    prefill_valid <= shadow.prefill != 0 && 32'(shadow.prefill) <= FIFO_DEPTH;
  end

  always_ff @(posedge axi_clk) begin
    if (axi_rst || (accept_write && shadow_write_addr))
      validation_wait <= VALIDATION_STAGES;
    else if (validation_wait != 0)
      validation_wait <= validation_wait - 1'b1;
  end

  // Readbacks of shadow registers are independent of active configuration.
  function automatic logic [31:0] merge_bytes(
    input logic [31:0] previous,
    input logic [31:0] value,
    input logic [3:0] strobes
  );
    logic [31:0] merged;
    for (int lane = 0; lane < 4; lane++)
      merged[8*lane +: 8] = strobes[lane] ? value[8*lane +: 8] : previous[8*lane +: 8];
    return merged;
  endfunction

  logic [31:0] read_value;
  logic [31:0] old_write_value;
  logic [31:0] merged_value;
  logic read_known;
  logic write_allowed;
  logic [31:0] register_value [0:REG_CLOCK_SELECT/4];

  always_comb begin
    register_value[REG_ID / 4] = 32'h49525644;
    register_value[REG_VERSION / 4] = EXTENDED_ABI ? 32'h00010002 : 32'h00010001;
    register_value[REG_CAPS / 4] = {6'b0, CLOCK_SELECT, 9'(MAX_BURST), 8'(FIFO_AW), 8'(DATA_WIDTH)};
    register_value[REG_CONTROL / 4] = {30'b0, shadow.pattern, target_enable};
    register_value[REG_STATUS / 4] = {26'b0, target_enable, snapshot_busy,
                     quiet, applied_enable, busy, configured};
    register_value[REG_FAULT / 4] = {28'b0, faults};
    register_value[REG_MASK / 4] = {28'b0, irq_mask};
    register_value[REG_FIRST / 4] = {28'b0, first_fault};
    register_value[REG_BASE / 4] = shadow.base;
    register_value[REG_STRIDE / 4] = shadow.stride;
    register_value[REG_WINDOW / 4] = window_base;
    register_value[REG_SIZE / 4] = window_bytes;
    register_value[REG_HA / 4] = {16'b0, shadow.ha};
    register_value[REG_HF / 4] = {16'b0, shadow.hf};
    register_value[REG_HS / 4] = {16'b0, shadow.hs};
    register_value[REG_HB / 4] = {16'b0, shadow.hb};
    register_value[REG_VA / 4] = {16'b0, shadow.va};
    register_value[REG_VF / 4] = {16'b0, shadow.vf};
    register_value[REG_VS / 4] = {16'b0, shadow.vs};
    register_value[REG_VB / 4] = {16'b0, shadow.vb};
    register_value[REG_POLARITY / 4] = {30'b0, shadow.v_positive, shadow.h_positive};
    register_value[REG_PREFILL / 4] = {16'b0, shadow.prefill};
    register_value[REG_UNDERFLOW / 4] = snapshot.underflows;
    register_value[REG_LOW_WATER / 4] = {16'b0, snapshot.low_water};
    register_value[REG_XY / 4] = {snapshot.y, snapshot.x};
    register_value[REG_FRAME / 4] = snapshot.frames;
    register_value[REG_FAULT_XY / 4] = {snapshot.fault_y, snapshot.fault_x};
    register_value[REG_FAULT_ADDR / 4] = first_addr;
    register_value[REG_FIFO_BYTES / 4] = 32'(FIFO_PAYLOAD_BYTES);
    register_value[REG_READ_BEATS / 4] = read_beats;
    register_value[REG_READ_BURSTS / 4] = read_bursts;
    register_value[REG_READ_ERRORS / 4] = read_errors;
    register_value[REG_FORMAT_CAPS / 4] = FORMAT_MASK;
    register_value[REG_FORMAT / 4] = 32'(shadow.format);
    register_value[REG_UV_BASE / 4] = uv_base;
    register_value[REG_UV_STRIDE / 4] = uv_stride;
    register_value[REG_UV_WINDOW / 4] = uv_window;
    register_value[REG_UV_SIZE / 4] = uv_size;
    register_value[REG_CLOCK_SELECT / 4] = {29'b0,clock_ready,clock_active,clock_request};

    read_known = (s_axi_araddr <= (EXTENDED_ABI ? REG_PEAK_RATE_BYTES : REG_READ_ERRORS)
              && s_axi_araddr[1:0] == 0) || (CLOCK_SELECT && s_axi_araddr == REG_CLOCK_SELECT);
    read_value = read_known ? register_value[s_axi_araddr[7:2]] : '0;
    write_allowed = write_addr == REG_CONTROL || write_addr == REG_FAULT
            || write_addr == REG_MASK
            || shadow_write_addr
            || (CLOCK_SELECT && write_addr == REG_CLOCK_SELECT && quiet && !snapshot_busy && clock_ready);
    old_write_value = write_allowed ? register_value[write_addr[7:2]] : '0;
    merged_value = merge_bytes(old_write_value, write_data, write_strobes);
  end

  assign s_axi_awready = !axi_rst && !aw_pending && !write_response_valid;
  assign s_axi_wready = !axi_rst && !w_pending && !write_response_valid;
  assign s_axi_arready = !axi_rst && !read_response_valid && !stats_read_pending;
  assign s_axi_bvalid = !axi_rst && write_response_valid;
  assign s_axi_rvalid = !axi_rst && read_response_valid;
  assign clear_faults = accept_write && write_addr == REG_FAULT && low_byte
             ? write_data[3:0] : 4'b0;
  assign events = {(underflow_sync[3] != underflow_seen), last_fault,
          resp_fault, bad_control};
  assign irq = !axi_rst && |(faults & irq_mask);

  always_ff @(posedge axi_clk) begin
    if (axi_rst) begin
      aw_pending <= 1'b0;
      w_pending <= 1'b0;
      write_addr <= '0;
      write_data <= '0;
      write_strobes <= '0;
      s_axi_bresp <= OKAY;
      write_response_valid <= 1'b0;
      s_axi_rdata <= '0;
      s_axi_rresp <= OKAY;
      read_response_valid <= 1'b0;
      stats_read_pending <= 1'b0;
      stats_read_addr <= '0;
      stats_dma_status <= '0;
      shadow <= '0;
      clock_request <= 1'b0;
      window_base <= '0;
      window_bytes <= '0;
      uv_base <= '0;
      uv_stride <= '0;
      uv_window <= '0;
      uv_size <= '0;
      active_uv_base <= '0;
      active_uv_stride <= '0;
      active_config <= '0;
      state <= S_IDLE;
      configured <= 1'b0;
      flush_cursor <= '0;
      target_enable <= 1'b0;
      applied_enable <= 1'b0;
      config_toggle <= 1'b0;
      config_ack_sync <= '0;
      snapshot_toggle <= 1'b0;
      snapshot_ack_sync <= '0;
      snapshot_read <= 1'b0;
      snapshot <= '0;
      read_fault <= 1'b0;
      mode_commit_pending <= 1'b0;
      for (int stage = 0; stage < 4; stage++)
        underflow_sync[stage] <= '0;
      underflow_seen <= '0;
      faults <= '0;
      irq_mask <= '0;
      first_fault <= '0;
      first_addr <= '0;
    end else begin
      config_ack_sync <= {config_ack_sync[2:0],config_ack};
      snapshot_ack_sync <= {snapshot_ack_sync[2:0],snapshot_ack};
      underflow_sync[0] <= pixel_underflow_gray;
      for (int stage = 1; stage < 4; stage++)
        underflow_sync[stage] <= underflow_sync[stage-1];
      underflow_seen <= underflow_sync[3];

      if (snapshot_ack_sync[3] != snapshot_read) begin
        snapshot <= pixel_snapshot;
        snapshot_read <= snapshot_ack_sync[3];
      end

      faults <= present_faults;
      if ((first_fault & ~clear_faults) == 0) begin
        first_addr <= '0;
        if (resp_fault || last_fault) begin
          first_fault <= resp_fault ? 4'b0010 : 4'b0100;
          first_addr <= read_fault_addr;
        end else if (events[3])
          first_fault <= 4'b1000;
        else if (events[0])
          first_fault <= 4'b0001;
        else
          first_fault <= '0;
      end

      case (state)
        S_DRAIN: if (reader_idle) begin
          mode_commit_pending <= 1'b0;
          flush_cursor <= fifo_wr_cursor;
          config_toggle <= !config_toggle;
          state <= S_APPLY;
        end
        S_APPLY: if (config_ack_sync[3] == config_toggle) begin
          state <= S_IDLE;
          applied_enable <= target_enable;
          read_fault <= 1'b0;
        end
        default: begin
        end
      endcase

      if (s_axi_awready && s_axi_awvalid) begin
        aw_pending <= 1'b1;
        write_addr <= s_axi_awaddr;
      end
      if (s_axi_wready && s_axi_wvalid) begin
        w_pending <= 1'b1;
        write_data <= s_axi_wdata;
        write_strobes <= s_axi_wstrb;
      end
      if (write_response_valid && s_axi_bready)
        write_response_valid <= 1'b0;
      if (accept_write) begin
        aw_pending <= 1'b0;
        w_pending <= 1'b0;
        write_response_valid <= 1'b1;
        s_axi_bresp <= write_allowed && !bad_control ? OKAY : SLVERR;
        if (write_allowed && !bad_control) begin
          case (write_addr)
            REG_CLOCK_SELECT: if (low_byte) clock_request <= write_data[0];
            REG_CONTROL: if (low_byte) begin
              shadow.pattern <= write_data[1];
              if (snapshot_request)
                snapshot_toggle <= !snapshot_toggle;
              if (commit) begin
                mode_commit_pending <= 1'b1;
                active_config <= shadow;
                // Software encodes intervals. Transfer their calculated
                // endpoints in the same bundled raster configuration.
                active_config.hf <= h_active_front[15:0];
                active_config.hs <= h_sync_end;
                active_config.hb <= h_last;
                active_config.vf <= v_active_front[15:0];
                active_config.vs <= v_sync_end;
                active_config.vb <= v_last;
                active_uv_base <= uv_base;
                active_uv_stride <= uv_stride;
                active_config.pattern <= write_data[1];
                configured <= 1'b1;
              end
              if (commit || write_data[0] != target_enable) begin
                target_enable <= write_data[0];
                state <= S_DRAIN;
              end
            end
            REG_MASK: irq_mask <= merged_value[3:0];
            REG_BASE: shadow.base <= merged_value;
            REG_STRIDE: shadow.stride <= merged_value;
            REG_FORMAT: shadow.format <= pixel_format_t'(merged_value[1:0]);
            REG_UV_BASE: uv_base <= merged_value;
            REG_UV_STRIDE: uv_stride <= merged_value;
            REG_UV_WINDOW: uv_window <= merged_value;
            REG_UV_SIZE: uv_size <= merged_value;
            REG_WINDOW: window_base <= merged_value;
            REG_SIZE: window_bytes <= merged_value;
            REG_HA: shadow.ha <= merged_value[15:0];
            REG_HF: shadow.hf <= merged_value[15:0];
            REG_HS: shadow.hs <= merged_value[15:0];
            REG_HB: shadow.hb <= merged_value[15:0];
            REG_VA: shadow.va <= merged_value[15:0];
            REG_VF: shadow.vf <= merged_value[15:0];
            REG_VS: shadow.vs <= merged_value[15:0];
            REG_VB: shadow.vb <= merged_value[15:0];
            REG_POLARITY: {shadow.v_positive,shadow.h_positive} <= merged_value[1:0];
            REG_PREFILL: shadow.prefill <= merged_value[15:0];
            default: begin
            end
          endcase
        end
      end

      if (resp_fault || last_fault)
        read_fault <= 1'b1;

      if (read_response_valid && s_axi_rready)
        read_response_valid <= 1'b0;
      if (stats_read) begin
        stats_read_pending <= 1'b1;
        stats_read_addr <= s_axi_araddr;
        stats_dma_status <= dma_status;
      end else if (stats_snapshot_valid) begin
        stats_read_pending <= 1'b0;
        read_response_valid <= 1'b1;
        s_axi_rresp <= OKAY;
        case (stats_read_addr)
          REG_DMA_STATUS: s_axi_rdata <= {27'b0, row_saturated, stats_dma_status};
          REG_ROW_LAST: s_axi_rdata <= row_last;
          REG_ROW_BYTES: s_axi_rdata <= row_bytes;
          REG_ROW_SAMPLES: s_axi_rdata <= row_samples;
          REG_ROW_WORST: s_axi_rdata <= row_worst;
          REG_ROW_BEST: s_axi_rdata <= row_best;
          REG_PEAK_RATE_CYCLES: s_axi_rdata <= peak_rate_cycles;
          REG_PEAK_RATE_BYTES: s_axi_rdata <= peak_rate_bytes;
          default: s_axi_rdata <= '0;
        endcase
      end else if (accept_read) begin
        read_response_valid <= 1'b1;
        s_axi_rdata <= read_value;
        s_axi_rresp <= read_known ? OKAY : SLVERR;
      end
    end
  end

  ironvideo_reset axi_reset (.clk(axi_clk), .reset_n(reset_n), .rst(axi_rst));
  ironvideo_reset pixel_reset (.clk(pixel_clk), .reset_n(reset_n), .rst(pixel_rst));

  ironvideo_reader #(.DATA_WIDTH(DATA_WIDTH), .MAX_BURST(MAX_BURST),
           .FIFO_AW(FIFO_AW), .ARQOS(ARQOS), .AXI_ID_WIDTH(AXI_ID_WIDTH),
           .SUPPORT_NV12(FORMAT_MASK[3]), .PACKED_READS(PACKED_READS))
  reader (
    .clk(axi_clk), .rst(axi_rst), .run(reader_run),
    .base(active_config.base), .stride(active_config.stride),
    .line_bytes(active_line_bytes), .lines(active_config.va),
    .nv12(active_config.format == FMT_YUV420), .uv_base(active_uv_base), .uv_stride(active_uv_stride),
    .row_extra_chroma(row_extra_chroma),
    .fifo_free(fifo_free), .fifo_write(fifo_write), .fifo_data(fifo_in),
    .fifo_sof(wr_sof), .fifo_sol(wr_sol), .idle(reader_idle),
    .row_busy(row_busy), .row_start(row_start), .row_done(row_done),
    .resp_fault(resp_fault), .last_fault(last_fault), .fault_addr(read_fault_addr),
    .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
    .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
    .m_axi_arlock(m_axi_arlock), .m_axi_arcache(m_axi_arcache),
    .m_axi_arprot(m_axi_arprot), .m_axi_arqos(m_axi_arqos),
    .m_axi_arid(m_axi_arid), .m_axi_arvalid(m_axi_arvalid),
    .m_axi_arready(m_axi_arready), .m_axi_rdata(m_axi_rdata),
    .m_axi_rresp(m_axi_rresp), .m_axi_rid(m_axi_rid), .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
  );

  ironvideo_row_stats row_stats (
    .pixel_clk(pixel_clk), .pixel_rst(pixel_rst), .axi_clk(axi_clk), .axi_rst(axi_rst),
    .clear_mode(state == S_DRAIN && reader_idle && mode_commit_pending),
    .mode_row_bytes(active_config.pattern ? 32'd0 : active_line_bytes),
    .row_extra_chroma(row_extra_chroma),
    .take_peak(accept_read && EXTENDED_ABI && s_axi_araddr == REG_PEAK_RATE_CYCLES),
    .peak_cycles(peak_rate_cycles), .peak_bytes_latched(peak_rate_bytes),
    .row_start(row_start), .row_done(row_done),
    .snapshot_read(stats_read), .snapshot_valid(stats_snapshot_valid),
    .read_beat(m_axi_rvalid && m_axi_rready), .read_burst(m_axi_arvalid && m_axi_arready),
    .read_error(resp_fault || last_fault),
    .take_worst(accept_read && s_axi_araddr == REG_ROW_WORST),
    .take_best(accept_read && s_axi_araddr == REG_ROW_BEST),
    .last_cycles(row_last), .row_bytes(row_bytes), .samples(row_samples),
    .worst_cycles(row_worst), .best_cycles(row_best), .beats(read_beats),
    .bursts(read_bursts), .errors(read_errors), .saturated(row_saturated)
  );

  ironvideo_fifo #(.DATA_WIDTH(DATA_WIDTH+2), .FIFO_AW(FIFO_AW))
  pixel_fifo (
    .wr_clk(axi_clk), .wr_rst(axi_rst), .wr_push(fifo_write),
    .wr_data({wr_sof,wr_sol,fifo_in}), .wr_free(fifo_free), .wr_cursor(fifo_wr_cursor),
    .rd_clk(pixel_clk), .rd_rst(pixel_rst), .rd_pop(fifo_pop),
    .rd_cursor(fifo_rd_cursor),
    .rd_valid(fifo_valid), .rd_data({rd_sof,rd_sol,fifo_out}), .rd_count(fifo_count)
  );

  ironvideo_raster #(.DATA_WIDTH(DATA_WIDTH), .FIFO_AW(FIFO_AW), .FORMAT_MASK(FORMAT_MASK))
  raster (
    .clk(pixel_clk), .rst(pixel_rst),
    .config_toggle(config_toggle), .config_enable(target_enable),
    .config_data(active_config), .config_ack(config_ack),
    .snapshot_toggle(snapshot_toggle), .snapshot_ack(snapshot_ack),
    .snapshot_data(pixel_snapshot), .read_fault(read_fault),
    .underflow_gray(pixel_underflow_gray),
    .fifo_valid(fifo_valid), .fifo_sof(rd_sof), .fifo_sol(rd_sol),
    .fifo_cursor(fifo_rd_cursor), .flush_cursor(flush_cursor),
    .fifo_data(fifo_out), .fifo_count(fifo_count), .fifo_pop(fifo_pop),
    .rgb(rgb), .de(de), .hs(hs), .vs(vs)
  );

  // synthesis translate_off
  initial begin
    if (FIFO_KIB > 128)
      $fatal(1, "IronVideo FIFO_KIB must not exceed 128 KiB");
  end
  // synthesis translate_on
endmodule
