`timescale 1ns/1ps

// 11-18-2026, SystemVerilog-2012. Initial bundled CDC payload definitions.
package ironvideo_pkg;
  typedef struct packed {
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
