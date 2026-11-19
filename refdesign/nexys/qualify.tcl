# SPDX-License-Identifier: GPL-2.0-only
set reference_cdc_phase routed
source $here/video_cdc.tcl
set timing [report_timing_summary -return_string -file $out/timing.rpt -report_unconstrained -check_timing_verbose]
set coverage [check_timing -return_string -file $out/check_timing.rpt -verbose]
set skew [report_bus_skew -return_string -file $out/bus_skew.rpt]
report_cdc -details -file $out/cdc.rpt
report_clocks -file $out/clocks.rpt
report_utilization -file $out/utilization.rpt
report_drc -file $out/drc.rpt
report_io -file $out/io.rpt
if {![regexp {All user specified timing constraints are met\.} $timing]} {error "Reference design timing failed"}
if {[regexp {VIOLATED} $skew]} {error "Reference design bus skew failed"}
foreach check {no_clock constant_clock pulse_width_clock multiple_clock generated_clocks loops latch_loops unconstrained_internal_endpoints partial_input_delay partial_output_delay} {
  if {![regexp [format {checking %s \(([0-9]+)\)} $check] $coverage -> count] || $count != 0} {
    error "Reference design incomplete timing coverage: $check"
  }
}
foreach mode {min max} {
  set path [get_timing_paths -delay_type $mode -max_paths 1]
  if {![llength $path] || [get_property SLACK $path] < 0} {error "Reference design $mode timing failed"}
  puts "REFERENCE TIMING $mode slack_ns=[get_property SLACK $path]"
}
if {[llength [get_drc_violations -quiet -filter {SEVERITY == "Error" || SEVERITY == "Critical Warning"}]]} {
  error "Reference design has a critical DRC violation"
}
