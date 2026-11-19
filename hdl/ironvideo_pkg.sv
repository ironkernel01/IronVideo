`timescale 1ns/1ps

// 11-18-2026, SystemVerilog-2012. Initial bundled CDC payload definitions.
package ironvideo_pkg;
  typedef enum logic [1:0] {
    FMT_XRGB8888, FMT_RGB565, FMT_YUV422, FMT_YUV420
  } pixel_format_t;

  // The primary memory plane contains packed pixels or full-resolution luma.
  function automatic logic [31:0] plane_row_bytes(input pixel_format_t fmt, input logic [15:0] width);
    case (fmt)
      FMT_XRGB8888: return {14'b0, width, 2'b0};
      FMT_YUV420:   return {16'b0, width};
      default:      return {15'b0, width, 1'b0};
    endcase
  endfunction

  // The AXI reader expands NV12 into YUYV while inserting it into the FIFO.
  function automatic logic [31:0] fifo_row_bytes(input pixel_format_t fmt, input logic [15:0] width);
    return fmt == FMT_XRGB8888 ? {14'b0, width, 2'b0} : {15'b0, width, 1'b0};
  endfunction

  typedef struct packed {
    pixel_format_t format;
    logic [31:0] base;
    logic [31:0] stride;
    logic [15:0] ha;
    logic [15:0] hf;
    logic [15:0] hs;
    logic [15:0] hb;
    logic [15:0] va;
    logic [15:0] vf;
    logic [15:0] vs;
    logic [15:0] vb;
    logic h_positive;
    logic v_positive;
    logic pattern;
    logic [15:0] prefill;
  } video_config_t;

  typedef struct packed {
    logic [31:0] frames;
    logic [31:0] underflows;
    logic [15:0] low_water;
    logic [15:0] x;
    logic [15:0] y;
    logic [15:0] fault_x;
    logic [15:0] fault_y;
  } video_snapshot_t;
endpackage
