`timescale 1ns/1ps

// 11-18-2026, SystemVerilog-2012. Initial IronVideo raster and lane unpacker.
// Advance timing every pixel clock and recover stream lock at a frame boundary.
module ironvideo_raster #(
  parameter int DATA_WIDTH = 64,
  parameter int FIFO_AW = 9,
  parameter int FORMAT_MASK = 1
) (
  // Pixel clock and active-high synchronous reset.
  input logic clk,
  input logic rst,
  // AXI-domain configuration payload and toggle, with pixel-domain acknowledgment.
  input logic config_toggle,
  input logic config_enable,
  input ironvideo_pkg::video_config_t config_data,
  output logic config_ack,
  // Software-requested status capture and pixel-domain return payload.
  input logic snapshot_toggle,
  output logic snapshot_ack,
  output ironvideo_pkg::video_snapshot_t snapshot_data,
  // AXI fault level and pixel-domain Gray count of stream losses.
  input logic read_fault,
  output logic [31:0] underflow_gray,
  // Held FIFO data and markers in the pixel domain. Counts use AXI beats.
  input logic fifo_valid,
  input logic fifo_sof,
  input logic fifo_sol,
  input logic [DATA_WIDTH-1:0] fifo_data,
  input logic [FIFO_AW:0] fifo_count,
  input logic [FIFO_AW:0] fifo_cursor,
  output logic fifo_pop,
  // Stable AXI-domain final FIFO cursor, bundled with the config request.
  input logic [FIFO_AW:0] flush_cursor,
  // Registered pixel-domain color and raster timing.
  output logic [23:0] rgb,
  output logic de,
  output logic hs,
  output logic vs
);
  import ironvideo_pkg::*;
  localparam int LANES = DATA_WIDTH / ((FORMAT_MASK & 14) != 0 ? 16 : 32);
  localparam int LANE_BITS = LANES > 1 ? $clog2(LANES) : 1;
  (* ASYNC_REG = "TRUE" *) logic [3:0] config_sync;
  (* ASYNC_REG = "TRUE" *) logic [3:0] snapshot_sync;
  (* ASYNC_REG = "TRUE" *) logic [3:0] fault_sync;
  video_config_t mode;
  logic running;
  logic locked;
  logic [15:0] x;
  logic [15:0] y;
  logic [15:0] low_water;
  logic [15:0] fault_x;
  logic [15:0] fault_y;
  logic [31:0] frames;
  logic [31:0] underflows;
  logic [LANE_BITS-1:0] lane;
  logic flush_latched;
  logic [FIFO_AW:0] flush_target;

  wire pending = config_sync[3] != config_ack;
  wire active = x < mode.ha && y < mode.va;
  wire [15:0] h_sync_start = mode.ha + mode.hf;
  wire [15:0] h_sync_end = h_sync_start + mode.hs;
  wire [15:0] v_sync_start = mode.va + mode.vf;
  wire [15:0] v_sync_end = v_sync_start + mode.vs;
  wire end_line = x == h_sync_end + mode.hb - 16'd1;
  wire end_frame = end_line && y == v_sync_end + mode.vb - 16'd1;
  wire origin = x == 0 && y == 0;

  wire start_frame = origin && fifo_valid && fifo_sof
           && fifo_count >= mode.prefill;
  wire markers_match = lane != 0 ||
            (fifo_sol == (x == 0) && fifo_sof == origin);
  wire consume = !pending && running && !mode.pattern && !fault_sync[3]
         && active && (locked || start_frame) && fifo_valid && markers_match;
  wire underflow = !pending && running && !mode.pattern && !fault_sync[3]
          && active && locked && !consume;
  wire apply_config = pending && flush_latched
            && !fifo_valid && fifo_cursor == flush_target
            && (!running || end_frame);
  wire [LANE_BITS-1:0] last_lane = mode.format == FMT_XRGB8888
                           ? LANE_BITS'(DATA_WIDTH / 32 - 1) : LANE_BITS'(DATA_WIDTH / 16 - 1);
  wire [23:0] xrgb_pixel;
  wire [23:0] rgb565_pixel;
  wire [23:0] yuv_pixel;
  if (FORMAT_MASK[0]) assign xrgb_pixel = fifo_data[32*lane +: 24];
  else assign xrgb_pixel = '0;
  if (FORMAT_MASK[1]) begin : unpack_rgb565
    wire [15:0] word16 = fifo_data[16*lane +: 16];
    assign rgb565_pixel = {word16[15:11],word16[15:13],word16[10:5],word16[10:9],
                           word16[4:0],word16[4:2]};
  end else assign rgb565_pixel = '0;
  if ((FORMAT_MASK & 12) != 0) begin : unpack_yuyv
    wire [31:0] pair_word = fifo_data[32*(lane >> 1) +: 32];
    assign yuv_pixel = {lane[0] ? pair_word[23:16] : pair_word[7:0], pair_word[15:8], pair_word[31:24]};
  end else assign yuv_pixel = '0;
  wire [23:0] pixel = mode.format == FMT_XRGB8888 ? xrgb_pixel :
                      mode.format == FMT_RGB565 ? rgb565_pixel : yuv_pixel;
  logic [23:0] sample;
  logic sample_yuv;
  logic raster_de, raster_hs, raster_vs;
  if ((FORMAT_MASK & 12) != 0) begin : convert_color
    ironvideo_color color (.clk(clk), .rst(rst), .convert(sample_yuv), .sample(sample),
      .timing_in({raster_de,raster_hs,raster_vs}), .timing_out({de,hs,vs}), .rgb(rgb));
  end else assign {rgb,de,hs,vs} = {sample,raster_de,raster_hs,raster_vs};

  always_comb begin
    fifo_pop = 1'b0;
    if (fifo_valid) begin
      if (pending || fault_sync[3] || !running || mode.pattern)
        fifo_pop = 1'b1;
      else if (!locked && !fifo_sof)
        fifo_pop = 1'b1;
      else if (consume && lane == last_lane)
        fifo_pop = 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      config_sync <= '0;
      snapshot_sync <= '0;
      fault_sync <= '0;
      config_ack <= 1'b0;
      snapshot_ack <= 1'b0;
      snapshot_data <= '0;
      running <= 1'b0;
      locked <= 1'b0;
      mode <= '0;
      x <= '0;
      y <= '0;
      frames <= '0;
      underflows <= '0;
      underflow_gray <= '0;
      fault_x <= '0;
      fault_y <= '0;
      low_water <= '1;
      lane <= '0;
      flush_latched <= 1'b0;
      flush_target <= '0;
      sample <= '0;
      sample_yuv <= 1'b0;
      raster_de <= 1'b0;
      raster_hs <= 1'b0;
      raster_vs <= 1'b0;
    end else begin
      config_sync <= {config_sync[2:0], config_toggle};
      snapshot_sync <= {snapshot_sync[2:0], snapshot_toggle};
      fault_sync <= {fault_sync[2:0], read_fault};
      if (snapshot_sync[3] != snapshot_ack) begin
        snapshot_data <= {frames, underflows, low_water, x, y, fault_x, fault_y};
        snapshot_ack <= snapshot_sync[3];
      end

      sample <= '0;
      sample_yuv <= consume && mode.format[1];
      raster_de <= running && active;
      raster_hs <= (x >= h_sync_start && x < h_sync_end && running)
         ? mode.h_positive : !mode.h_positive;
      raster_vs <= (y >= v_sync_start && y < v_sync_end && running)
         ? mode.v_positive : !mode.v_positive;

      if (running) begin
        if (end_line) begin
          x <= '0;
          y <= end_frame ? 16'd0 : y + 1'b1;
        end else
          x <= x + 1'b1;
        if (end_frame)
          frames <= frames + 1'b1;
      end

      if (pending) begin
        // Apply only once the consumer has reached the bundled final
        // write cursor. A transient empty indication cannot finish the flush.
        if (!flush_latched) begin
          flush_target <= flush_cursor;
          flush_latched <= 1'b1;
        end
        locked <= 1'b0;
        lane <= '0;
      end else begin
        if (running && mode.pattern && active)
          sample <= {x[7:0], y[7:0], x[7:0] ^ y[7:0]};
        if (consume) begin
          sample <= pixel;
          locked <= 1'b1;
          lane <= lane == last_lane ? '0 : lane + 1'b1;
          if (16'(fifo_count) < low_water)
            low_water <= 16'(fifo_count);
        end
        if (underflow) begin
          underflows <= underflows + 1'b1;
          underflow_gray <= (underflows + 1'b1) ^ ((underflows + 1'b1) >> 1);
          fault_x <= x;
          fault_y <= y;
        end
        if (underflow || fault_sync[3]) begin
          locked <= 1'b0;
          lane <= '0;
        end
      end

      if (apply_config) begin
        mode <= config_data;
        running <= config_enable;
        config_ack <= config_sync[3];
        x <= '0;
        y <= '0;
        low_water <= '1;
        flush_latched <= 1'b0;
      end
    end
  end
endmodule
