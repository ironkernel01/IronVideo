# SPDX-License-Identifier: GPL-2.0-only
# First-stage synchronizers and held request/acknowledgment payloads only.
namespace eval reference_cdc {
  proc registers {patterns} {
    set result {}
    foreach pattern $patterns {
      set result [concat $result [get_cells -quiet -hier -regexp [format {^%s$} $pattern]]]
    }
    if {![llength $result]} {error "Missing reference CDC register: $patterns"}
    return $result
  }

  proc pins {cells name} {
    set result [get_pins -of_objects $cells -filter "REF_PIN_NAME == $name"]
    if {[llength $result] != [llength $cells]} {error "Missing CDC $name pin on $cells"}
    return $result
  }

  proc period {pin expected} {
    set clock [get_clocks -of_objects $pin]
    if {[llength $clock] != 1 || abs([get_property PERIOD $clock] - $expected) > 0.01} {
      error "Expected $expected ns at $pin"
    }
  }

  proc path {phase name beginnings endings source_period dest_period skew async} {
    set source [registers $beginnings]
    set dest [registers $endings]
    if {$async} {
      foreach reg $dest {
        if {![get_property ASYNC_REG $reg]} {error "Missing ASYNC_REG on $reg"}
      }
    }
    set source_q [pins $source Q]
    set dest_d [pins $dest D]
    set bound [expr {min($source_period, $dest_period)}]
    set launches {}
    foreach pin $dest_d {
      set driver [get_pins -leaf -of_objects [get_nets -segments -of_objects $pin] -filter {DIRECTION == OUT}]
      if {[llength $driver] != 1 || $driver ni $source_q} {
        error "Unexpected crossing driver $driver -> $pin"
      }
      set clock_pin [pins [get_cells -of_objects $driver] C]
      period $clock_pin $source_period
      period [pins [get_cells -of_objects $pin] C] $dest_period
      lappend launches $clock_pin
    }
    set launches [lsort -unique $launches]
    if {$phase eq "preopt"} {
      set_max_delay -datapath_only $bound -from $launches -through $source_q -to $dest_d
      if {$skew} {set_bus_skew $bound -from $launches -to $dest_d}
    } else {
      foreach pin $dest_d {
        set timed [get_timing_paths -quiet -from $launches -through $source_q -to $pin -max_paths 1]
        if {[llength $timed] != 1 || abs([get_property REQUIREMENT $timed] - $bound) > 0.01} {
          error "Missing routed $bound ns crossing check $name -> $pin"
        }
      }
    }
    puts "REFERENCE CDC $phase $name endpoints=[llength $dest_d] bound_ns=$bound"
  }

  proc check {phase} {
    set core system_i/ironvideo/inst/video
    set scan $core/scanout
    set fifo $scan/pixel_fifo
    set raster $scan/raster
    set timer $scan/row_stats
    set v {\[[0-9]+\]}
    set first {\[0\]}
    set axi 12.500
    set pixel 13.468
    set mode {\[(ha|hf|hs|hb|va|vf|vs|vb|prefill|format)\]\[[0-9]+\]|\[(h_positive|v_positive|pattern)\]}
    set snap {\[(frames|underflows|x|y|fault_x|fault_y|low_water)\]\[[0-9]+\]}
    foreach {name src dst from to skew async} [list \
        fifo_write [list $fifo/write_gray_reg$v $fifo/write_ptr_reg$v] [list $fifo/write_gray_sync_reg$first$v] $axi $pixel 1 1 \
        fifo_read [list $fifo/read_gray_reg$v] [list $fifo/read_gray_sync_reg$first$v] $pixel $axi 1 1 \
        pixel_ticks [list $timer/pixel_ticks_gray_reg$v] [list $timer/ticks_sync_reg$first$v] $pixel $axi 1 1 \
        underflows [list $raster/underflow_gray_reg$v] [list $scan/underflow_sync_reg$first$v] $pixel $axi 1 1 \
        config_request [list $scan/config_toggle_reg] [list $raster/config_sync_reg$first] $axi $pixel 0 1 \
        snapshot_request [list $scan/snapshot_toggle_reg] [list $raster/snapshot_sync_reg$first] $axi $pixel 0 1 \
        config_ack [list $raster/config_ack_reg] [list $scan/config_ack_sync_reg$first] $pixel $axi 0 1 \
        snapshot_ack [list $raster/snapshot_ack_reg] [list $scan/snapshot_ack_sync_reg$first] $pixel $axi 0 1 \
        read_fault [list $scan/read_fault_reg] [list $raster/fault_sync_reg$first] $axi $pixel 0 1 \
        config [list "$scan/active_config_reg($mode)"] [list "$raster/mode_reg($mode)"] $axi $pixel 0 0 \
        enable [list $scan/target_enable_reg] [list $raster/running_reg] $axi $pixel 0 0 \
        flush [list $scan/flush_cursor_reg$v] [list $raster/flush_target_reg$v] $axi $pixel 0 0 \
        snapshot [list "$raster/snapshot_data_reg($snap)"] [list "$scan/snapshot_reg($snap)"] $pixel $axi 0 0] {
      path $phase $name $src $dst $from $to $skew $async
    }

    if {$phase eq "preopt"} {
      set chains [registers [list "$core/(scanout/(axi_reset|pixel_reset)|backend/reset_sync)/release_sync_reg$v" \
                      "system_i/clocks/inst/ready_sync_reg$v"]]
      if {[llength $chains] != 15} {error "Unexpected reset synchronizer topology"}
      set_false_path -to [pins $chains CLR]
    }
    set serdes [get_cells -quiet -hier -filter "NAME =~ $core/backend/* && REF_NAME == OSERDESE2"]
    set buffers [get_cells -quiet -hier -filter "NAME =~ $core/backend/* && REF_NAME == OBUFDS"]
    if {[llength $serdes] != 8 || [llength $buffers] != 4} {error "Unexpected TMDS lane topology"}
    foreach pin [pins $serdes CLK] {period $pin 2.694}
    foreach pin [pins $serdes CLKDIV] {period $pin $pixel}
  }
}

if {![info exists reference_cdc_phase]} {set reference_cdc_phase preopt}
reference_cdc::check $reference_cdc_phase
